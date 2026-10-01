import AppKit

/// Callbacks shared by the note-related views.
@MainActor
protocol NoteNavigator: AnyObject {
  func openNote(_ ref: NoteRef)
  func openLink(_ url: URL)
}

/// A heading the table of contents can jump to.
struct TocTarget {
  var entry: TocEntry
  /// Makes the heading visible (expands collapsed sections around it).
  var reveal: (() -> Void)? = nil
  /// Where the heading is, in the page's document coordinates.
  var locate: () -> NSRect?
}

/// A vertically scrolling page with a centered column, like a document, and
/// a table of contents in the left margin.
class ColumnPageView: NSView {
  let scrollView = NSScrollView()
  let document = PageDocumentView()
  let column = NSStackView()
  let toc = TableOfContentsView()
  private var tocTargets: [TocTarget] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.drawsBackground = false
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.wantsLayer = true
    addSubview(scrollView)
    scrollView.pinEdges(to: self)

    scrollView.documentView = document
    document.translatesAutoresizingMaskIntoConstraints = false
    let clip = scrollView.contentView
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
    ])

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 12
    column.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(column)
    let preferred = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -112)
    preferred.priority = NSLayoutConstraint.Priority(490)  // below the window size (500)
    NSLayoutConstraint.activate([
      column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
      column.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.columnWidth),
      column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24),
      preferred,
      column.topAnchor.constraint(equalTo: document.topAnchor, constant: 48),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor, constant: 160),
    ])

    toc.translatesAutoresizingMaskIntoConstraints = false
    toc.isHidden = true
    toc.onSelect = { [weak self] index in self?.scrollToTocEntry(index) }
    addSubview(toc)
    NSLayoutConstraint.activate([
      toc.leadingAnchor.constraint(equalTo: leadingAnchor),
      toc.topAnchor.constraint(equalTo: topAnchor),
      toc.bottomAnchor.constraint(equalTo: bottomAnchor),
      toc.widthAnchor.constraint(equalToConstant: 320),
    ])
    clip.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(pageScrolled), name: NSView.boundsDidChangeNotification, object: clip)
    // The column recenters after this view's own layout pass.
    column.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(updateTocRoom), name: NSView.frameDidChangeNotification, object: column)
    // Heading positions settle only after the editors lay out.
    document.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(pageScrolled), name: NSView.frameDidChangeNotification, object: document)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Content fades out under the top edge once the page is scrolled, like
  /// the table of contents.
  private let topFade = CAGradientLayer()
  private let topFadeHeight: CGFloat = 14

  private func updateTopFade() {
    guard let layer = scrollView.layer else { return }
    let offset = scrollView.contentView.bounds.minY
    let strength = min(max(offset / topFadeHeight, 0), 1)
    Motion.withoutAnimation {
      topFade.frame = layer.bounds
      // Top of the view is location 0 (the gradient runs top to bottom).
      topFade.startPoint = CGPoint(x: 0.5, y: layer.isGeometryFlipped ? 0 : 1)
      topFade.endPoint = CGPoint(x: 0.5, y: layer.isGeometryFlipped ? 1 : 0)
      // Eased (ease-in-out) rather than linear, so the fade has no hard edge.
      let top = 1 - strength
      let end = Double(topFadeHeight / max(layer.bounds.height, 1))
      let steps = 8
      topFade.colors = (0...steps).map { i -> CGColor in
        let t = CGFloat(i) / CGFloat(steps)
        return NSColor.black.withAlphaComponent(top + (1 - top) * t * t * (3 - 2 * t)).cgColor
      }
      topFade.locations = (0...steps).map { NSNumber(value: end * Double($0) / Double(steps)) }
      if layer.mask !== topFade { layer.mask = topFade }
    }
  }

  override func layout() {
    super.layout()
    updateTopFade()
    updateTocRoom()
    updateActiveTocEntry()
  }

  /// Labels may use the margin up to the text column; markers shrink with it.
  @objc private func updateTocRoom() {
    let columnX = column.convert(column.bounds, to: self).minX
    toc.labelRoom = columnX - 26 - 28
    // Its dashes would run under the note's gutter (grips, chevrons): it
    // steps aside until there's room again.
    toc.setTucked(columnX - NoteGutterView.width < toc.dashesExtent + 8, animated: window?.isVisible == true)
  }

  /// Adds a view to the column, stretched to the column's width.
  func addToColumn(_ view: NSView, spacingAfter: CGFloat? = nil) {
    column.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    if let spacingAfter { column.setCustomSpacing(spacingAfter, after: view) }
  }

  func clearColumn() {
    for view in column.arrangedSubviews {
      column.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  func scrollToTop() {
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  /// Fades the page content in, rising slightly.
  func revealContent() {
    column.animateIn(scale: 1, offsetY: 10, fade: 0.22, duration: 0.45, timing: Motion.easeOut)
  }

  // MARK: Table of contents

  func setTocTargets(_ targets: [TocTarget]) {
    tocTargets = targets
    toc.setEntries(targets.map(\.entry))
    // Deeper headings reach further right.
    updateTocRoom()
    updateActiveTocEntry()
    DispatchQueue.main.async { [weak self] in
      self?.layoutSubtreeIfNeeded()
      self?.updateActiveTocEntry()
    }
  }

  @objc private func pageScrolled() {
    updateTopFade()
    updateActiveTocEntry()
  }

  /// Set after a click so the chosen heading stays active even when the page
  /// can't scroll it to the top; cleared when the reader scrolls.
  private var pinnedEntry: (index: Int, origin: CGFloat)?

  /// The active entry is the last heading that has reached the top of the page.
  private func updateActiveTocEntry() {
    guard !tocTargets.isEmpty else { return }
    let visible = scrollView.contentView.bounds
    if let pinned = pinnedEntry {
      if abs(pinned.origin - visible.minY) < 1 {
        toc.setActiveIndex(pinned.index)
        return
      }
      pinnedEntry = nil
    }
    let threshold = visible.minY + 72
    var active = 0
    for (index, target) in tocTargets.enumerated() {
      guard let rect = target.locate() else { continue }
      if rect.minY <= threshold { active = index }
    }
    toc.setActiveIndex(active)
  }

  private func scrollToTocEntry(_ index: Int) {
    guard tocTargets.indices.contains(index) else { return }
    tocTargets[index].reveal?()
    guard let rect = tocTargets[index].locate() else { return }
    let clip = scrollView.contentView
    let maxY = max(0, document.bounds.height - clip.bounds.height)
    let y = min(max(0, rect.minY - 40), maxY)
    // The heading lights up at once and rides in with the page (the scroll
    // looks settled well before its end), fading once it has arrived.
    flash(rect, fadingAfter: 0.5)
    Motion.animate(0.5, timing: Motion.easeOut, {
      clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
    }, completion: { [weak self] in
      guard let self else { return }
      self.scrollView.reflectScrolledClipView(clip)
      self.pinnedEntry = (index, clip.bounds.minY)
      self.toc.setActiveIndex(index)
    })
  }

  /// Briefly highlights a heading that was jumped to.
  private func flash(_ rect: NSRect, fadingAfter delay: CFTimeInterval) {
    let highlight = NSView(frame: rect.insetBy(dx: -8, dy: -2))
    highlight.wantsLayer = true
    highlight.layer?.cornerRadius = 8
    highlight.layer?.cornerCurve = .continuous
    highlight.layer?.backgroundColor = resolvedCGColor(Theme.accentWash)
    document.addSubview(highlight, positioned: .below, relativeTo: column)
    let fade = Motion.basic("opacity", duration: 1.1, timing: Motion.easeInOut)
    fade.fromValue = 1
    fade.toValue = 0
    fade.beginTime = CACurrentMediaTime() + delay
    fade.fillMode = .both
    fade.isRemovedOnCompletion = false
    CATransaction.begin()
    CATransaction.setCompletionBlock { highlight.removeFromSuperview() }
    highlight.layer?.add(fade, forKey: "flash")
    CATransaction.commit()
  }
}

/// Clicking empty space below the text focuses the page's main editor.
final class PageDocumentView: FlippedView {
  var onClickEmptySpace: (() -> Void)?
  /// Images dropped on the page outside the text (e.g. below it).
  var onDropImages: ((NSPasteboard, NSPoint) -> Bool)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])
  }

  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {
    onClickEmptySpace?()
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    MarkdownTextView.hasImages(sender.draggingPasteboard) && onDropImages != nil ? .copy : []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    onDropImages?(sender.draggingPasteboard, convert(sender.draggingLocation, from: nil)) ?? false
  }
}

/// Clickable label, used for day titles and backlink sources.
final class LinkLabel: NSTextField {
  var onClick: (() -> Void)?

  convenience init(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    self.init(labelWithString: text)
    font = .systemFont(ofSize: size, weight: weight)
    textColor = color
    translatesAutoresizingMaskIntoConstraints = false
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseDown(with event: NSEvent) {
    // Once the click is over: opening a note may remove this label.
    guard let onClick else { return }
    DispatchQueue.main.async { onClick() }
  }
}

/// A view that says when the pointer is over it, also when the page
/// scrolls under a still pointer.
final class HoverView: NSView {
  var onHover: ((Bool) -> Void)?
  private(set) var hovering = false {
    didSet { if hovering != oldValue { onHover?(hovering) } }
  }
  private var tracking: NSTrackingArea?
  private var syncPending = false

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  /// For automated checks: the pointer as if over it or not.
  func debugSetHovering(_ value: Bool) { hovering = value }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    if let clip = enclosingScrollView?.contentView {
      NotificationCenter.default.addObserver(self, selector: #selector(pageScrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }
  }

  /// Once per run loop turn: scrolling sends no enter or exit events.
  @objc private func pageScrolled() {
    guard !syncPending else { return }
    syncPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.syncPending = false
      guard let window = self.window, !self.isHiddenOrHasHiddenAncestor else { return self.hovering = false }
      self.hovering = window.isKeyWindow && self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
  }
}

extension NSView {
  /// Fades in or out like an embed's expand / collapse toggle on hover;
  /// hidden once out, so it can't be clicked.
  func fade(in shows: Bool) {
    if shows { isHidden = false }
    Motion.animate(0.2, timing: Motion.easeInOut, { animator().alphaValue = shows ? 1 : 0 }, completion: { [weak self] in
      guard let self, !shows, self.alphaValue == 0 else { return }
      self.isHidden = true
    })
  }
}

/// A small grey text button, like an embed's expand / collapse toggle: no
/// background, darker while the pointer is over it.
final class QuietButton: NSView {
  var onClick: (() -> Void)?
  private let label: NSTextField
  private var tracking: NSTrackingArea?
  private var hovering = false { didSet { label.textColor = hovering ? Theme.text : Theme.tertiaryText } }

  init(title: String) {
    label = NSTextField.label(title, size: 12, weight: .regular, color: Theme.tertiaryText)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    label.pinEdges(to: self, insets: NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4))
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Its label's baseline, to line it up with the text it acts on.
  override var firstBaselineOffsetFromTop: CGFloat { 3 + label.firstBaselineOffsetFromTop }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    // Once the click is over: what it does may remove this button.
    if bounds.contains(convert(event.locationInWindow, from: nil)), let onClick { DispatchQueue.main.async { onClick() } }
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}

/// A section title that folds and unfolds what follows, with a chevron
/// that turns like a note section's.
final class DisclosureHeader: NSView {
  var onToggle: (() -> Void)?
  /// How open the section is, from 0 to 1: turns the chevron.
  var openness: CGFloat = 0 { didSet { needsDisplay = true } }
  var title: String {
    get { label.stringValue }
    set {
      label.stringValue = newValue
      setAccessibilityLabel(newValue)
    }
  }

  private let label = NSTextField.label("", size: 11, weight: .semibold, color: Theme.tertiaryText)
  private static let chevronSpace: CGFloat = 16

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
      trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: DisclosureHeader.chevronSpace),
    ])
    setAccessibilityRole(.disclosureTriangle)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var firstBaselineOffsetFromTop: CGFloat { label.firstBaselineOffsetFromTop }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseDown(with event: NSEvent) {
    onToggle?()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let glyph = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) else { return }
    // The label's color exactly: a palette color that's translucent (like
    // tertiary text) comes out fainter, so fill the solid glyph with it.
    let size = glyph.size
    let color = label.textColor ?? Theme.tertiaryText
    let image = NSImage(size: size, flipped: false) { rect in
      glyph.draw(in: rect)
      color.set()
      rect.fill(using: .sourceIn)
      return true
    }
    NSGraphicsContext.saveGraphicsState()
    // Turns from right (folded) to down (open) as the section opens.
    let turn = NSAffineTransform()
    turn.translateX(by: label.frame.maxX + DisclosureHeader.chevronSpace / 2 + 1, yBy: label.frame.midY)
    turn.rotate(byDegrees: (isFlipped ? 90 : -90) * openness)
    turn.concat()
    image.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
  }
}

// MARK: - Journal

/// Today's journal entry on top, previous days below, all editable in place.
final class JournalView: ColumnPageView {
  weak var navigator: NoteNavigator?

  private var shownDays: [NoteRef] = []
  private var editors: [NoteRef: MarkdownEditorView] = [:]
  private var headers: [NoteRef: NSView] = [:]
  private var dayLimit = 10
  private var builtForToday: NoteRef?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    column.spacing = 8
    document.onClickEmptySpace = { [weak self] in self?.focusToday() }
    document.onDropImages = { [weak self] pasteboard, point in
      guard let self else { return false }
      let editor = self.editors.values.min { a, b in
        abs(a.convert(a.bounds, to: self.document).midY - point.y) < abs(b.convert(b.bounds, to: self.document).midY - point.y)
      }
      guard let text = editor?.textView, let images = text.imageMarkdown(from: pasteboard) else { return false }
      text.insertImages(images, at: (text.string as NSString).length)
      return true
    }
    NotificationCenter.default.addObserver(self, selector: #selector(notesChanged(_:)), name: .notesDidChange, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var wantedDays: [NoteRef] {
    let today = NoteStore.shared.today
    let past = NoteStore.shared.journalDays.filter { $0 != today }
    return [today] + past.prefix(dayLimit)
  }

  /// Rebuilds if the day changed or journal entries appeared/disappeared.
  func reloadIfNeeded() {
    if wantedDays != shownDays || builtForToday != NoteStore.shared.today { reload() }
  }

  func reload() {
    MarkdownEditorView.flushAll()
    clearColumn()
    editors = [:]
    shownDays = wantedDays
    builtForToday = NoteStore.shared.today
    let today = NoteStore.shared.today

    for (index, day) in shownDays.enumerated() {
      let header = makeHeader(for: day, isToday: day == today)
      addToColumn(header, spacingAfter: 10)
      if day == today, let summary = makeSummary() {
        addToColumn(summary, spacingAfter: 20)
      }
      let editor = MarkdownEditorView(ref: day, placeholder: day == today ? "What's on your mind today?" : "")
      editor.onOpenLink = { [weak self] url in self?.navigator?.openLink(url) }
      editors[day] = editor
      addToColumn(editor, spacingAfter: index == shownDays.count - 1 ? 32 : 48)
    }

    headers = [:]
    for view in column.arrangedSubviews {
      if let header = view as? DayHeaderView { headers[header.day] = header }
    }
    for editor in editors.values {
      editor.onTextChange = { [weak self] in self?.refreshToc() }
    }
    refreshToc()
    revealContent()

    let remaining = NoteStore.shared.journalDays.filter { $0 != today }.count - (shownDays.count - 1)
    if remaining > 0 {
      let more = NSButton(title: "Show \(min(remaining, 10)) earlier days", target: self, action: #selector(showMore))
      more.bezelStyle = .inline
      more.isBordered = false
      more.contentTintColor = Theme.accent
      column.addArrangedSubview(more)
    }
  }

  /// What happened on the last active day, unless hidden for today.
  private func makeSummary() -> DailySummaryView? {
    guard DailySummaryView.hiddenOn != NoteStore.shared.today.name,
          let summary = ActivityLog.shared.summary() else { return nil }
    let view = DailySummaryView(summary: summary)
    guard view.hasContent else { return nil }
    view.navigator = navigator
    // The gap below closes along with it.
    view.onFold = { [weak self, weak view] shown in
      guard let self, let view else { return }
      self.column.setCustomSpacing(20 * shown, after: view)
    }
    view.onHide = { [weak self, weak view] in
      guard let self, let view else { return }
      self.column.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    return view
  }

  private func makeHeader(for day: NoteRef, isToday: Bool) -> NSView {
    let date = day.date ?? Date()
    let weekday = DateFormatter()
    weekday.dateFormat = "EEEE"
    let full = DateFormatter()
    full.dateStyle = .long

    let title = LinkLabel(isToday ? "Today" : weekday.string(from: date), size: isToday ? 30 : 20, weight: .semibold, color: Theme.text)
    title.onClick = { [weak self] in self?.navigator?.openNote(day) }
    let subtitle = NSTextField.label(isToday ? "\(weekday.string(from: date)), \(full.string(from: date))" : full.string(from: date), size: 13, color: Theme.tertiaryText)
    let stack = DayHeaderView(views: [title, subtitle])
    stack.day = day
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    return stack
  }

  /// Today is the top-level entry; earlier days sit a level below it (like
  /// heading 2s), and each day's headings nest under their day.
  private func refreshToc() {
    var levels: [Int] = []
    /// How far each entry is pushed in: 1 for earlier days and their headings.
    var indents: [Int] = []
    var titles: [String] = []
    var locators: [() -> NSRect?] = []
    var revealers: [Int: () -> Void] = [:]
    let today = NoteStore.shared.today
    for day in shownDays {
      guard let header = headers[day], let editor = editors[day] else { continue }
      let indent = day == today ? 0 : 1
      levels.append(0)
      indents.append(indent)
      titles.append(day == today ? "Today" : day.displayTitle)
      locators.append { [weak self, weak header] in
        guard let self, let header else { return nil }
        return header.convert(header.bounds, to: self.document)
      }
      for heading in markdownHeadings(in: editor.content) {
        levels.append(heading.level)
        indents.append(indent)
        titles.append(heading.title)
        locators.append { [weak self, weak editor] in
          guard let self, let editor, let rect = editor.lineRect(forCharacterAt: heading.offset) else { return nil }
          return editor.convert(rect, to: self.document)
        }
        revealers[locators.count - 1] = { [weak editor] in editor?.reveal(heading.offset) }
      }
    }
    let depths = tocDepths(forHeadingLevels: levels)
    setTocTargets(depths.indices.map { i in
      TocTarget(entry: TocEntry(depth: depths[i] + indents[i], title: titles[i]), reveal: revealers[i], locate: locators[i])
    })
  }

  @objc private func showMore() {
    dayLimit += 10
    reload()
  }

  func focusToday() {
    guard let editor = editors[NoteStore.shared.today] else { return }
    editor.focus()
  }

  @objc private func notesChanged(_ notification: Notification) {
    guard !isHidden, let ids = notification.userInfo?["ids"] as? Set<String> else { return }
    if ids.contains(where: { $0.hasPrefix("journal/") }) && wantedDays != shownDays { reload() }
  }
}

private final class DayHeaderView: NSStackView {
  var day = NoteStore.shared.today
}

// MARK: - Single note

final class NoteView: ColumnPageView, NSTextFieldDelegate {
  weak var navigator: NoteNavigator?
  private(set) var ref: NoteRef?

  private let titleField = NSTextField()
  private let metaLabel = NSTextField.label("", size: 12, color: Theme.tertiaryText)
  /// The title on the left, export and trash on the right of its first line.
  private let titleRow = NSView()
  private let exportButton = IconButton(symbol: "square.and.arrow.up", size: 12, tooltip: "Export as Markdown…",
                                        target: nil, action: #selector(BrowserWindowController.exportCurrentNote(_:)))
  private let trashButton = IconButton(symbol: "trash", size: 12, tooltip: "Move to Trash (⌥⌘⌫)",
                                       target: nil, action: #selector(BrowserWindowController.deleteNote(_:)))
  private var editor: MarkdownEditorView?
  private let backlinks = NSStackView()
  /// Unlinked references: a header, then the mentions in a clip that
  /// folds like a note section.
  private let unlinked = NSStackView()
  private let unlinkedHeader = DisclosureHeader()
  private let unlinkedLinkAll = QuietButton(title: "Link All")
  private let unlinkedClip = NSView()
  private let unlinkedBody = NSStackView()
  /// The clip's height while folded or folding; open, it follows the body.
  private var unlinkedClipHeight: NSLayoutConstraint!
  private var unlinkedClipFollowsBody: NSLayoutConstraint!
  /// Unlinked references start folded, and stay as last set.
  private var showsUnlinked = false
  /// How much of them shows, from 0 to 1, and the fold under way.
  private var unlinkedShown: CGFloat = 0
  private var unlinkedFold: (from: CGFloat, began: CFTimeInterval, duration: CFTimeInterval, timer: Timer)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    titleField.font = .systemFont(ofSize: 30, weight: .semibold)
    titleField.isBordered = false
    titleField.drawsBackground = false
    titleField.focusRingType = .none
    titleField.delegate = self
    titleField.placeholderString = "Untitled"
    titleField.cell?.usesSingleLineMode = false
    titleField.cell?.wraps = true
    titleField.lineBreakMode = .byWordWrapping
    titleField.translatesAutoresizingMaskIntoConstraints = false

    titleRow.translatesAutoresizingMaskIntoConstraints = false
    titleRow.addSubview(titleField)
    let buttons = NSStackView(views: [exportButton, trashButton])
    buttons.spacing = 2
    buttons.setHuggingPriority(.required, for: .horizontal)
    buttons.translatesAutoresizingMaskIntoConstraints = false
    titleRow.addSubview(buttons)
    let firstLine = ceil(NSLayoutManager().defaultLineHeight(for: titleField.font ?? .systemFont(ofSize: 30, weight: .semibold)))
    NSLayoutConstraint.activate([
      titleField.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
      titleField.topAnchor.constraint(equalTo: titleRow.topAnchor),
      titleField.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),
      titleField.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -8),
      // The buttons' hover background may extend past the column.
      buttons.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor, constant: 6),
      buttons.centerYAnchor.constraint(equalTo: titleRow.topAnchor, constant: firstLine / 2),
    ])

    backlinks.orientation = .vertical
    backlinks.alignment = .leading
    backlinks.spacing = 10
    setUpUnlinked()

    document.onClickEmptySpace = { [weak self] in self?.editor?.focus() }
    document.onDropImages = { [weak self] pasteboard, _ in
      guard let text = self?.editor?.textView, let images = text.imageMarkdown(from: pasteboard) else { return false }
      text.insertImages(images, at: (text.string as NSString).length)
      return true
    }
    NotificationCenter.default.addObserver(self, selector: #selector(notesChanged(_:)), name: .notesDidChange, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(_ ref: NoteRef) {
    if ref == self.ref, editor != nil { return }
    editor?.flush()
    self.ref = ref
    clearColumn()

    titleField.stringValue = ref.kind == .journal ? ref.displayTitle : ref.name
    titleField.isEditable = ref.kind == .note
    addToColumn(titleRow, spacingAfter: 4)
    addToColumn(metaLabel, spacingAfter: 20)

    let editor = MarkdownEditorView(ref: ref)
    editor.onOpenLink = { [weak self] url in self?.navigator?.openLink(url) }
    editor.onTextChange = { [weak self] in self?.refreshToc() }
    self.editor = editor
    addToColumn(editor, spacingAfter: 56)
    addToColumn(backlinks)
    addToColumn(unlinked)
    refreshMeta()
    refreshBacklinks()
    refreshUnlinked()
    refreshToc()
    scrollToTop()
    revealContent()
  }

  func focusEditor() { editor?.focus() }

  /// The note's title, then its headings.
  private func refreshToc() {
    guard let ref, let editor else { return }
    let headings = markdownHeadings(in: editor.content)
    // A leading "# Title" that repeats the note name adds nothing.
    let shown = headings.enumerated().filter { index, heading in
      !(index == 0 && heading.level == 1 && heading.title.caseInsensitiveCompare(ref.displayTitle) == .orderedSame)
    }.map(\.element)
    guard !shown.isEmpty else {
      setTocTargets([])
      return
    }
    let depths = tocDepths(forHeadingLevels: [0] + shown.map(\.level))
    var targets = [TocTarget(entry: TocEntry(depth: 0, title: ref.kind == .journal ? ref.displayTitle : ref.name)) { [weak self] in
      guard let self else { return nil }
      return self.titleField.convert(self.titleField.bounds, to: self.document)
    }]
    for (i, heading) in shown.enumerated() {
      targets.append(TocTarget(entry: TocEntry(depth: depths[i + 1], title: heading.title),
                               reveal: { [weak editor] in editor?.reveal(heading.offset) }) { [weak self, weak editor] in
        guard let self, let editor, let rect = editor.lineRect(forCharacterAt: heading.offset) else { return nil }
        return editor.convert(rect, to: self.document)
      })
    }
    setTocTargets(targets)
  }

  func focusTitle() {
    window?.makeFirstResponder(titleField)
    titleField.currentEditor()?.selectAll(nil)
  }

  private func refreshMeta() {
    guard let ref else { return }
    let words = NoteStore.shared.content(of: ref).split { $0.isWhitespace || $0.isNewline }.count
    var parts = ["\(words) word\(words == 1 ? "" : "s")"]
    if let modified = NoteStore.shared.modified(ref) {
      let formatter = RelativeDateTimeFormatter()
      parts.append("edited " + formatter.localizedString(for: modified, relativeTo: Date()))
    }
    metaLabel.stringValue = parts.joined(separator: " · ")
  }

  private func refreshBacklinks() {
    for view in backlinks.arrangedSubviews { view.removeFromSuperview() }
    guard let ref else { return }
    let links = NoteStore.shared.backlinks(to: ref)
    guard !links.isEmpty else { return }

    let header = NSTextField.label("\(links.count) linked reference\(links.count == 1 ? "" : "s")".uppercased(), size: 11, weight: .semibold, color: Theme.tertiaryText)
    backlinks.addArrangedSubview(header)
    backlinks.setCustomSpacing(14, after: header)
    for link in links {
      let source = LinkLabel(link.ref.displayTitle, size: 14, weight: .semibold, color: Theme.accent)
      source.onClick = { [weak self] in self?.navigator?.openNote(link.ref) }
      backlinks.addArrangedSubview(source)
      backlinks.setCustomSpacing(4, after: source)
      for line in link.lines.prefix(4) {
        let text = NSTextField(wrappingLabelWithString: "")
        text.attributedStringValue = MarkdownPreview.render(line)
        text.translatesAutoresizingMaskIntoConstraints = false
        backlinks.addArrangedSubview(text)
        text.widthAnchor.constraint(equalTo: backlinks.widthAnchor).isActive = true
        backlinks.setCustomSpacing(4, after: text)
      }
      if let last = backlinks.arrangedSubviews.last { backlinks.setCustomSpacing(18, after: last) }
    }
    column.setCustomSpacing(backlinks.arrangedSubviews.isEmpty ? 0 : 22, after: backlinks)
  }

  private func setUpUnlinked() {
    unlinked.orientation = .vertical
    unlinked.alignment = .leading
    unlinked.spacing = 10

    unlinkedHeader.onToggle = { [weak self] in self?.toggleUnlinked() }
    unlinkedLinkAll.onClick = { [weak self] in
      guard let self, let ref = self.ref else { return }
      MarkdownEditorView.flushAll()
      for source in NoteStore.shared.unlinkedReferences(to: ref) {
        NoteStore.shared.link(source.mentions, in: source.ref, to: ref)
      }
    }
    unlinkedLinkAll.alphaValue = 0
    unlinkedLinkAll.isHidden = true
    let headerRow = HoverView()
    headerRow.onHover = { [weak self] hovering in self?.unlinkedLinkAll.fade(in: hovering) }
    headerRow.translatesAutoresizingMaskIntoConstraints = false
    headerRow.addSubview(unlinkedHeader)
    headerRow.addSubview(unlinkedLinkAll)
    NSLayoutConstraint.activate([
      unlinkedHeader.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
      unlinkedHeader.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
      headerRow.heightAnchor.constraint(equalToConstant: 24),
      unlinkedLinkAll.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: 4),
      unlinkedLinkAll.firstBaselineAnchor.constraint(equalTo: unlinkedHeader.firstBaselineAnchor),
    ])

    unlinkedBody.orientation = .vertical
    unlinkedBody.alignment = .leading
    unlinkedBody.spacing = 10
    unlinkedBody.translatesAutoresizingMaskIntoConstraints = false
    unlinkedClip.wantsLayer = true
    unlinkedClip.layer?.masksToBounds = true
    unlinkedClip.translatesAutoresizingMaskIntoConstraints = false
    unlinkedClip.addSubview(unlinkedBody)
    unlinkedClipHeight = unlinkedClip.heightAnchor.constraint(equalToConstant: 0)
    unlinkedClipFollowsBody = unlinkedClip.bottomAnchor.constraint(equalTo: unlinkedBody.bottomAnchor)
    NSLayoutConstraint.activate([
      unlinkedBody.topAnchor.constraint(equalTo: unlinkedClip.topAnchor),
      unlinkedBody.leadingAnchor.constraint(equalTo: unlinkedClip.leadingAnchor),
      unlinkedBody.trailingAnchor.constraint(equalTo: unlinkedClip.trailingAnchor),
    ])

    unlinked.addArrangedSubview(headerRow)
    unlinked.addArrangedSubview(unlinkedClip)
    unlinked.setCustomSpacing(10, after: headerRow)
    for view in [headerRow, unlinkedClip] {
      view.widthAnchor.constraint(equalTo: unlinked.widthAnchor).isActive = true
    }
    applyUnlinkedShown(showsUnlinked ? 1 : 0)
  }

  /// Where the note's name appears in other notes without a link, each with
  /// a button that makes it one (Beam's unlinked references).
  private func refreshUnlinked() {
    for view in unlinkedBody.arrangedSubviews { view.removeFromSuperview() }
    let sources = ref.map { NoteStore.shared.unlinkedReferences(to: $0) } ?? []
    unlinked.isHidden = sources.isEmpty
    guard !sources.isEmpty else { return }

    let count = sources.reduce(0) { $0 + $1.mentions.count }
    unlinkedHeader.title = "\(count) unlinked reference\(count == 1 ? "" : "s")".uppercased()
    for source in sources {
      let title = LinkLabel(source.ref.displayTitle, size: 14, weight: .semibold, color: Theme.accent)
      title.onClick = { [weak self] in self?.navigator?.openNote(source.ref) }
      unlinkedBody.addArrangedSubview(title)
      unlinkedBody.setCustomSpacing(4, after: title)
      let shown = source.mentions.prefix(5)
      for mention in shown {
        let row = mentionRow(mention) { [weak self] in
          guard let ref = self?.ref else { return }
          MarkdownEditorView.flushAll()
          NoteStore.shared.link([mention], in: source.ref, to: ref)
        }
        unlinkedBody.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: unlinkedBody.widthAnchor).isActive = true
        unlinkedBody.setCustomSpacing(4, after: row)
      }
      if source.mentions.count > shown.count {
        let more = NSTextField.label("\(source.mentions.count - shown.count) more", size: 12, color: Theme.tertiaryText)
        unlinkedBody.addArrangedSubview(more)
      }
      if let last = unlinkedBody.arrangedSubviews.last { unlinkedBody.setCustomSpacing(18, after: last) }
    }
    if let last = unlinkedBody.arrangedSubviews.last { unlinkedBody.setCustomSpacing(0, after: last) }
    // A fold under way keeps going, to the body's new height.
    if unlinkedFold != nil { applyUnlinkedShown(unlinkedShown) }
  }

  /// Folds or unfolds the unlinked references like a note section: the
  /// height eases, the mentions fade, the chevron turns. Toggling mid-way
  /// turns back from where it is.
  private func toggleUnlinked() {
    showsUnlinked.toggle()
    unlinkedFold?.timer.invalidate()
    unlinkedFold = nil
    let target: CGFloat = showsUnlinked ? 1 : 0
    guard !Motion.reduceMotion else { return applyUnlinkedShown(target) }
    let duration = Motion.foldDuration * Double(abs(target - unlinkedShown))
    let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.stepUnlinkedFold() }
    }
    unlinkedFold = (unlinkedShown, CACurrentMediaTime(), duration, timer)
    RunLoop.main.add(timer, forMode: .common)
    stepUnlinkedFold()
  }

  private func stepUnlinkedFold() {
    guard let fold = unlinkedFold else { return }
    let t = fold.duration > 0 ? min(1, (CACurrentMediaTime() - fold.began) / fold.duration) : 1
    let eased = CGFloat(1 - pow(1 - t, 3))
    let target: CGFloat = showsUnlinked ? 1 : 0
    if t >= 1 {
      fold.timer.invalidate()
      unlinkedFold = nil
    }
    applyUnlinkedShown(fold.from + (target - fold.from) * eased)
  }

  private func applyUnlinkedShown(_ shown: CGFloat) {
    unlinkedShown = shown
    unlinkedHeader.openness = shown
    unlinkedClip.alphaValue = shown
    unlinkedClip.isHidden = shown == 0
    let open = shown == 1 && unlinkedFold == nil
    if open {
      unlinkedClipHeight.isActive = false
      unlinkedClipFollowsBody.isActive = true
    } else {
      unlinkedClipFollowsBody.isActive = false
      unlinkedClip.layoutSubtreeIfNeeded()
      unlinkedClipHeight.constant = (unlinkedBody.frame.height * shown).rounded()
      unlinkedClipHeight.isActive = true
    }
  }

  /// The mention's line (around it, when long), the name in bold, and a
  /// Link button on the right while it's hovered.
  private func mentionRow(_ mention: NoteStore.Mention, onLink: @escaping () -> Void) -> NSView {
    var line = mention.line as NSString
    var match = mention.rangeInLine
    if line.length > 240 {
      let start = max(0, match.location - 80)
      let end = min(line.length, match.upperBound + 140)
      let window = line.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
      line = ((window.location > 0 ? "…" : "") + line.substring(with: window) + (window.upperBound < line.length ? "…" : "")) as NSString
      match.location += (window.location > 0 ? 1 : 0) - window.location
    }
    let leading = line.length - (line as String).drop(while: { $0 == " " || $0 == "\t" }).utf16.count
    line = line.substring(from: leading) as NSString
    match.location -= leading

    let text = MarkdownPreview.render(line as String, highlight: match, highlightAttributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.text,
    ])
    let label = NSTextField(wrappingLabelWithString: "")
    label.attributedStringValue = text
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let button = QuietButton(title: "Link")
    button.onClick = onLink
    // Shows while the pointer is over its mention.
    button.alphaValue = 0
    button.isHidden = true
    let row = HoverView()
    row.onHover = { [weak button] hovering in button?.fade(in: hovering) }
    row.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(label)
    row.addSubview(button)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      label.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
      label.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -3),
      label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
      button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: 4),
      button.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
    ])
    return row
  }

  @objc private func notesChanged(_ notification: Notification) {
    guard !isHidden, let ref else { return }
    refreshMeta()
    refreshBacklinks()
    // Typing in this note doesn't change where others mention it.
    let ids = notification.userInfo?["ids"] as? Set<String> ?? []
    if ids != [ref.id] { refreshUnlinked() }
  }

  // MARK: Title editing

  func controlTextDidEndEditing(_ obj: Notification) {
    commitTitle()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:)) {
      commitTitle()
      editor?.focus(atEnd: false)
      return true
    }
    if selector == #selector(NSResponder.cancelOperation(_:)), let ref {
      titleField.stringValue = ref.name
      editor?.focus(atEnd: false)
      return true
    }
    return false
  }

  /// Applies a title still being typed; the note as it now is.
  func commitEdits() -> NoteRef? {
    commitTitle()
    return ref
  }

  private func commitTitle() {
    guard let ref, ref.kind == .note else { return }
    let wanted = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard wanted != ref.name else { return }
    editor?.flush()
    switch NoteStore.shared.rename(ref, to: wanted) {
    case .success(let newRef):
      self.ref = newRef
      editor?.rebind(to: newRef)
      titleField.stringValue = newRef.name
      refreshToc()
    case .failure(let error):
      NSSound.beep()
      titleField.stringValue = ref.name
      if error == .alreadyExists {
        let alert = NSAlert()
        alert.messageText = "A note named “\(wanted)” already exists."
        alert.beginSheetModal(for: window!)
      }
    }
  }
}

// MARK: - All notes

final class NotesListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  weak var navigator: NoteNavigator?
  var onNewNote: (() -> Void)?
  /// A note's ⋮ menu (or right click): export it, move it to the Trash; the
  /// trash button moves the checked notes.
  var onExport: ((NoteRef) -> Void)?
  var onDelete: (([NoteRef]) -> Void)?

  private let tableView = NotesTableView()
  private let header = NSStackView()
  /// Rows span the window so the scroller sits at its edge; their content is
  /// inset to line up with the header column.
  private var rowInset: CGFloat = 0
  private let searchField = BorderlessSearchField()
  private let countLabel = NSTextField.label("", size: 13, color: Theme.tertiaryText)
  private var refs: [NoteRef] = []
  /// Notes checked with their row's checkbox.
  private(set) var checkedNotes: Set<NoteRef> = [] {
    didSet { if checkedNotes.isEmpty != oldValue.isEmpty { updateTrashButton() } }
  }
  /// Moves the checked notes to the Trash; shown while there are some.
  private lazy var trashButton = IconButton(symbol: "trash", size: 12, tooltip: "Move Checked Notes to Trash", target: self,
                                            action: #selector(trashChecked))
  private let controls = NSStackView()
  /// Holds the trash button at the end of the controls: it opens as the
  /// button grows, pushing the search and + over (the button, pinned to its
  /// end, doesn't move).
  private let trashSlot = NSView()
  private lazy var trashSlotWidth = trashSlot.widthAnchor.constraint(equalToConstant: 0)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    let title = NSTextField.label("Notes", size: 30, weight: .semibold)
    searchField.placeholderString = "Filter notes"
    searchField.delegate = self
    searchField.focusRingType = .none
    searchField.isBezeled = false
    searchField.drawsBackground = false
    searchField.translatesAutoresizingMaskIntoConstraints = false
    let searchPill = SearchPill(field: searchField)
    let newButton = IconButton(symbol: "plus", tooltip: "New Note (⌥⌘N)", target: self, action: #selector(newNote))

    let titleGroup = NSStackView(views: [title, countLabel])
    titleGroup.alignment = .firstBaseline
    titleGroup.spacing = 12
    header.setViews([titleGroup, NSView()], in: .leading)
    header.translatesAutoresizingMaskIntoConstraints = false
    // The controls center on the title's capitals, outside the stack so they
    // can't fight that.
    trashButton.isHidden = true
    trashButton.alphaValue = 0
    trashButton.translatesAutoresizingMaskIntoConstraints = false
    trashSlot.translatesAutoresizingMaskIntoConstraints = false
    trashSlot.addSubview(trashButton)
    NSLayoutConstraint.activate([
      trashSlotWidth,
      trashSlot.heightAnchor.constraint(equalToConstant: 28),
      trashButton.trailingAnchor.constraint(equalTo: trashSlot.trailingAnchor),
      trashButton.centerYAnchor.constraint(equalTo: trashSlot.centerYAnchor),
    ])
    controls.setViews([searchPill, newButton, trashSlot], in: .leading)
    // (The slot has the gap before the button.)
    controls.setCustomSpacing(0, after: newButton)
    controls.spacing = 12
    controls.alignment = .centerY
    controls.translatesAutoresizingMaskIntoConstraints = false

    let column = NSTableColumn(identifier: .init("note"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = 58
    tableView.intercellSpacing = NSSize(width: 0, height: 2)
    tableView.backgroundColor = .clear
    tableView.style = .plain
    tableView.selectionHighlightStyle = .regular
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(rowClicked)
    // Right click: the same menu as a row's ⋮ button.
    tableView.menuForRow = { [weak self] row in
      guard let self, self.refs.indices.contains(row) else { return nil }
      let menu = NSMenu()
      self.addNoteItems(for: self.refs[row], to: menu)
      return menu
    }
    let scroll = NSScrollView()
    scroll.documentView = tableView
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.translatesAutoresizingMaskIntoConstraints = false

    addSubview(header)
    addSubview(controls)
    addSubview(scroll)
    let preferred = header.widthAnchor.constraint(equalTo: widthAnchor, constant: -112)
    preferred.priority = NSLayoutConstraint.Priority(490)  // below the window size (500)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor, constant: 48),
      header.centerXAnchor.constraint(equalTo: centerXAnchor),
      header.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.columnWidth + 100),
      header.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      preferred,
      searchPill.widthAnchor.constraint(equalToConstant: 200),
      controls.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      controls.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -((title.font?.capHeight ?? 21) / 2).rounded()),
      controls.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 12),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(notesChanged), name: .notesDidChange, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let inset = max(0, header.frame.minX - 12)
    guard inset != rowInset else { return }
    rowInset = inset
    tableView.enumerateAvailableRowViews { rowView, _ in (rowView as? RoundedRowView)?.inset = inset }
  }

  func reload() {
    let filter = searchField.stringValue.trimmingCharacters(in: .whitespaces)
    let fresh: [NoteRef]
    if filter.isEmpty {
      fresh = NoteStore.shared.notes
    } else {
      fresh = NoteStore.shared.search(filter, limit: 200).map(\.ref).filter { $0.kind == .note }
    }
    let total = NoteStore.shared.notes.count
    countLabel.stringValue = "\(total)"
    // Notes gone (moved to the Trash) fade out as their rows close up;
    // notes back (put back from it) open up and fade in.
    if window?.isVisible == true, !isHidden {
      if let removed = Self.removedRows(from: refs, to: fresh) {
        refs = fresh
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.3
          tableView.removeRows(at: removed, withAnimation: Motion.reduceMotion ? [] : [.effectFade, .slideUp])
        }
        return
      }
      if let added = Self.removedRows(from: fresh, to: refs) {
        refs = fresh
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.3
          tableView.insertRows(at: added, withAnimation: Motion.reduceMotion ? [] : [.effectFade, .slideDown])
        }
        return
      }
    }
    refs = fresh
    tableView.reloadData()
  }

  /// The rows to remove when `new` is `old` less some notes (same order),
  /// else nil (anything else reloads). Reversed: the rows added.
  private static func removedRows(from old: [NoteRef], to new: [NoteRef]) -> IndexSet? {
    guard new.count < old.count else { return nil }
    var removed = IndexSet()
    var next = new.makeIterator()
    var wanted = next.next()
    for (index, ref) in old.enumerated() {
      if ref == wanted { wanted = next.next() } else { removed.insert(index) }
    }
    return wanted == nil ? removed : nil
  }

  func focusSearch() {
    window?.makeFirstResponder(searchField)
  }

  @objc private func notesChanged() {
    // Notes moved to the Trash are no longer checked.
    checkedNotes = checkedNotes.filter { NoteStore.shared.exists($0) }
    if !isHidden { reload() }
  }

  func controlTextDidChange(_ obj: Notification) { reload() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)), let first = refs.first {
      navigator?.openNote(first)
      return true
    }
    return false
  }

  @objc private func newNote() { onNewNote?() }

  @objc private func trashChecked() {
    // In the list's order.
    onDelete?(NoteStore.shared.notes.filter { checkedNotes.contains($0) })
  }

  /// Brings the trash button in (or out) where it ends up, at the end: it
  /// grows and fades in place as the search and + slide over, all on one
  /// soft spring (so the slide keeps pace with the button, and going out is
  /// the same in reverse).
  private func updateTrashButton() {
    let show = !checkedNotes.isEmpty
    if show { trashButton.isHidden = false }
    let target: CGFloat = show ? 1 : 0
    trashTimer?.invalidate()
    trashTimer = nil
    guard window?.isVisible == true, !Motion.reduceMotion else {
      trashProgress = target
      trashVelocity = 0
      applyTrashProgress()
      return
    }
    var last = CACurrentMediaTime()
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self else { return timer.invalidate() }
        let now = CACurrentMediaTime()
        var remaining = min(now - last, 1.0 / 30)
        last = now
        while remaining > 0 {
          let step = min(remaining, 1.0 / 480)
          let acceleration = -Self.springStiffness * (self.trashProgress - target) - Self.springDamping * self.trashVelocity
          self.trashVelocity += acceleration * step
          self.trashProgress += self.trashVelocity * step
          remaining -= step
        }
        if abs(self.trashProgress - target) < 0.002 && abs(self.trashVelocity) < 0.02 {
          self.trashProgress = target
          self.trashVelocity = 0
          timer.invalidate()
          self.trashTimer = nil
        }
        self.applyTrashProgress()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    trashTimer = timer
  }

  /// A soft spring: it settles with a touch of overshoot.
  private static let springStiffness: CGFloat = 350
  private static let springDamping: CGFloat = 23.8
  /// How far in the trash button is, from 0 (gone) to 1 (it overshoots a little).
  private var trashProgress: CGFloat = 0
  private var trashVelocity: CGFloat = 0
  private var trashTimer: Timer?

  private func applyTrashProgress() {
    let progress = max(0, trashProgress)
    trashSlotWidth.constant = (4 + 28) * progress
    layoutSubtreeIfNeeded()
    // After layout (AppKit resets the transform when it moves the button).
    Motion.withoutAnimation { trashButton.layer?.transform = trashButton.centeredScale(max(0.01, progress)) }
    trashButton.alphaValue = min(1, progress * 1.5)
    // Gone: hidden, so its tooltip can't show.
    if progress == 0 && checkedNotes.isEmpty { trashButton.isHidden = true }
  }

  /// For automated checks: checks or unchecks the note in `row`.
  func debugToggleCheck(_ row: Int) {
    guard refs.indices.contains(row) else { return }
    let ref = refs[row]
    if checkedNotes.contains(ref) { checkedNotes.remove(ref) } else { checkedNotes.insert(ref) }
    (tableView.rowView(atRow: row, makeIfNecessary: false) as? NoteRowView)?.isChecked = checkedNotes.contains(ref)
  }

  @objc private func rowClicked() {
    let row = tableView.clickedRow
    guard row >= 0, row < refs.count else { return }
    navigator?.openNote(refs[row])
  }

  /// Export and Move to Trash for `ref`.
  private func addNoteItems(for ref: NoteRef, to menu: NSMenu) {
    menu.addItem(ClosureMenuItem(title: "Export as Markdown…") { [weak self] in self?.onExport?(ref) })
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: "Move to Trash…") { [weak self] in self?.onDelete?([ref]) })
  }

  func numberOfRows(in tableView: NSTableView) -> Int { refs.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = (tableView.makeView(withIdentifier: NoteCell.identifier, owner: self) as? NoteCell) ?? NoteCell()
    let ref = refs[row]
    cell.configure(title: ref.name, excerpt: NoteStore.shared.excerpt(of: ref), date: NoteStore.shared.modified(ref))
    cell.onMore = { [weak self] button in
      guard let self else { return }
      let menu = NSMenu()
      self.addNoteItems(for: ref, to: menu)
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let rowView = NoteRowView()
    rowView.inset = rowInset
    let ref = refs[row]
    rowView.isChecked = checkedNotes.contains(ref)
    rowView.onCheck = { [weak self] checked in
      if checked { self?.checkedNotes.insert(ref) } else { self?.checkedNotes.remove(ref) }
    }
    return rowView
  }
}

/// The notes list: its rows' ⋮ buttons and checkboxes take their clicks (a table otherwise
/// keeps clicks on custom controls, selecting the row and opening the note),
/// and the pointer is an arrow over it.
private final class NotesTableView: NSTableView {
  /// The menu a right click (or ⌃-click) anywhere on a row opens.
  var menuForRow: ((Int) -> NSMenu?)?

  /// Without NSTableView's own handling, which outlines the clicked row.
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    return row >= 0 ? menuForRow?(row) : nil
  }

  override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
    responder is IconButton || responder is SelectionCheckbox || super.validateProposedFirstResponder(responder, for: event)
  }

  override func resetCursorRects() {
    addCursorRect(visibleRect, cursor: .arrow)
  }
}

/// Rounded, theme-tinted backdrop for a borderless search field, so it sits on
/// the page like the rest of the chrome instead of the system's grey bezel.
private final class BorderlessSearchField: NSSearchField {
  override class var cellClass: AnyClass? {
    get { BorderlessSearchFieldCell.self }
    set {}
  }
}

/// Without a bezel, the search cell edits across its full width, over the
/// magnifier; keep the field editor in the same rect as the placeholder.
private final class BorderlessSearchFieldCell: NSSearchFieldCell {
  override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
    super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
  }

  override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
    super.select(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
  }
}

private final class SearchPill: NSView {
  init(field: NSSearchField) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      field.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 28),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    Theme.searchFill.setFill()
    path.fill()
    Theme.searchStroke.setStroke()
    path.stroke()
  }
}

private final class NoteCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("NoteCell")
  private let titleLabel = NSTextField.label("", size: 14, weight: .semibold)
  private let excerptLabel = NSTextField.label("", size: 12.5, color: Theme.secondaryText)
  private let dateLabel = NSTextField.label("", size: 12, color: Theme.tertiaryText)
  /// ⋮: the note's menu (export, move to the Trash).
  private let moreButton = IconButton(symbol: "ellipsis", size: 13, tooltip: "More", target: nil, action: nil)
  var onMore: ((NSView) -> Void)?
  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.doesRelativeDateFormatting = true
    return f
  }()

  init() {
    super.init(frame: .zero)
    identifier = NoteCell.identifier
    for view in [titleLabel, excerptLabel, dateLabel, moreButton] { addSubview(view) }
    dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    // Vertical: the horizontal ellipsis, turned.
    moreButton.setSymbolImage(Self.verticalEllipsis)
    // Like the date beside it until hovered.
    moreButton.restingTint = Theme.tertiaryText
    moreButton.target = self
    moreButton.action = #selector(showMore)
    // The title and excerpt truncate before the date (vertically centered,
    // like the ⋮ button), never running under it.
    for label in [titleLabel, excerptLabel] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -16),
      moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      dateLabel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -4),
      dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      excerptLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      excerptLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -16),
      excerptLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
    ])
  }

  @objc private func showMore() { onMore?(moreButton) }

  private static let verticalEllipsis: NSImage? = {
    guard let symbol = Theme.symbol("ellipsis", size: 13) else { return nil }
    let size = NSSize(width: symbol.size.height, height: symbol.size.width)
    let image = NSImage(size: size, flipped: false) { rect in
      let transform = NSAffineTransform()
      transform.translateX(by: rect.midX, yBy: rect.midY)
      transform.rotate(byDegrees: 90)
      transform.concat()
      symbol.draw(in: NSRect(x: -symbol.size.width / 2, y: -symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
      return true
    }
    image.isTemplate = true
    return image
  }()

  required init?(coder: NSCoder) { fatalError() }

  func configure(title: String, excerpt: String, date: Date?) {
    titleLabel.stringValue = title
    excerptLabel.stringValue = excerpt.isEmpty ? "Empty note" : excerpt
    dateLabel.stringValue = date.map { NoteCell.dateFormatter.string(from: $0) } ?? ""
  }
}

/// Row with a soft rounded selection instead of the system highlight.
class RoundedRowView: NSTableRowView {
  /// Horizontal inset for the cells and selection, for rows wider than their content.
  var inset: CGFloat = 0 {
    didSet {
      needsLayout = true
      needsDisplay = true
    }
  }

  override func layout() {
    super.layout()
    guard inset > 0 else { return }
    for view in subviews { view.frame = bounds.insetBy(dx: inset, dy: 0) }
  }

  override func drawSelection(in dirtyRect: NSRect) {
    Theme.accentWash.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: inset + 4, dy: 1), xRadius: 8, yRadius: 8).fill()
  }

  override var isEmphasized: Bool {
    get { false }
    set {}
  }
}

/// A note's row, with a checkbox in the gutter on its left to check the
/// note: it comes in while the row is hovered, and stays while checked.
private final class NoteRowView: RoundedRowView {
  private let checkbox = SelectionCheckbox()
  private var tracking: NSTrackingArea?
  private var hovering = false {
    didSet { if hovering != oldValue { updateCheckbox(animated: true) } }
  }
  var onCheck: ((Bool) -> Void)?
  var isChecked: Bool {
    get { checkbox.isChecked }
    set {
      checkbox.isChecked = newValue
      updateCheckbox(animated: false)
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(checkbox)
    checkbox.onToggle = { [weak self] in
      guard let self else { return }
      self.onCheck?(self.checkbox.isChecked)
      self.updateCheckbox(animated: true)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The checkbox stays on top of the row's content (the table adds it
  /// later), so its click area wins where they overlap.
  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    if subview !== checkbox { addSubview(checkbox, positioned: .above, relativeTo: nil) }
  }

  override func layout() {
    super.layout()
    // Centered in the gutter, clear of the row's rounded background. (The
    // view is larger than the box it draws: easier to hit.)
    let size = SelectionCheckbox.hitSize
    let center = max(4 + SelectionCheckbox.boxSize / 2, inset - 12)
    checkbox.frame = NSRect(x: (center - size / 2).rounded(), y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  private func updateCheckbox(animated: Bool) {
    checkbox.setShown(hovering || checkbox.isChecked, animated: animated)
  }
}

/// A round-cornered checkbox drawn like a note's tasks, which scales and
/// fades in and out (reversing from wherever it is).
private final class SelectionCheckbox: NSView {
  /// The box drawn, and the area around it that takes clicks.
  static let boxSize: CGFloat = 14
  static let hitSize: CGFloat = 36
  var isChecked = false {
    didSet { needsDisplay = true }
  }
  var onToggle: (() -> Void)?
  private var isShown = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    alphaValue = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  func setShown(_ shown: Bool, animated: Bool) {
    guard shown != isShown else { return }
    isShown = shown
    guard let layer else { return }
    let current = layer.presentation()
    let hidden = centeredScale(0.6)
    // (Coming in from nothing: from small, whatever the model transform is.)
    let fromTransform = current.map { $0.opacity < 0.01 ? hidden : $0.transform } ?? hidden
    let fromOpacity = current?.opacity ?? Float(alphaValue)
    layer.removeAnimation(forKey: "glea.check.transform")
    alphaValue = shown ? 1 : 0
    guard animated, !Motion.reduceMotion else {
      layer.removeAnimation(forKey: "glea.check.opacity")
      return
    }
    let fade = Motion.basic("opacity", duration: 0.16, timing: Motion.easeOut)
    fade.fromValue = fromOpacity
    fade.toValue = shown ? 1 : 0
    let scale = Motion.basic("transform", duration: 0.2, timing: Motion.easeOut)
    scale.fromValue = fromTransform
    scale.toValue = shown ? CATransform3DIdentity : hidden
    // Going out, it stays small (AppKit resets the model transform).
    scale.fillMode = .forwards
    scale.isRemovedOnCompletion = shown
    layer.add(fade, forKey: "glea.check.opacity")
    layer.add(scale, forKey: "glea.check.transform")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    isShown ? super.hitTest(point) : nil
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    isChecked.toggle()
    onToggle?()
  }

  override func draw(_ dirtyRect: NSRect) {
    let size = Self.boxSize
    let box = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
    let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
    if isChecked {
      Theme.accent.setFill()
      path.fill()
      let check = NSBezierPath()
      check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
      check.line(to: NSPoint(x: box.minX + 6, y: isFlipped ? box.maxY - 3.5 : box.minY + 3.5))
      check.line(to: NSPoint(x: box.maxX - 3, y: isFlipped ? box.minY + 3.5 : box.maxY - 3.5))
      check.lineWidth = 1.8
      check.lineCapStyle = .round
      check.lineJoinStyle = .round
      NSColor.white.setStroke()
      check.stroke()
    } else {
      Theme.tertiaryText.setStroke()
      path.lineWidth = 1.3
      path.stroke()
    }
  }
}
