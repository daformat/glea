import AppKit

/// Callbacks shared by the note-related views.
@MainActor
protocol NoteNavigator: AnyObject {
  func openNote(_ ref: NoteRef)
  func openLink(_ url: URL)
  /// A web search from a note (⌘↩), shown in a new tab.
  func openSearch(_ url: URL)
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
    scrollView.updateTopFade(topFade, height: topFadeHeight)
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
      // In page order: past the first one below, the rest are too.
      guard rect.minY <= threshold else { break }
      active = index
    }
    toc.setActiveIndex(active)
  }

  private func scrollToTocEntry(_ index: Int) {
    guard tocTargets.indices.contains(index) else { return }
    tocTargets[index].reveal?()
    scroll(to: tocTargets[index].locate) { [weak self] in
      guard let self else { return }
      self.pinnedEntry = (index, self.scrollView.contentView.bounds.minY)
      self.toc.setActiveIndex(index)
    }
  }

  /// Scrolls a place in the page (a heading jumped to) near the top. It's
  /// found again as the page scrolls: blocks loading above it push it down,
  /// and the scroll and its highlight go along.
  func scroll(to locate: @escaping () -> NSRect?, completion: (() -> Void)? = nil) {
    guard let rect = locate() else { return }
    let clip = scrollView.contentView
    // The heading lights up at once and rides in with the page (the scroll
    // looks settled well before its end), fading once it has arrived.
    flash(rect, locate: locate, fadingAfter: 0.5)
    scrollTimer?.invalidate()
    scrollTimer = nil
    let duration: CFTimeInterval = Motion.reduceMotion ? 0 : 0.5
    let start = CACurrentMediaTime()
    var progress: CGFloat = 0
    // Each frame covers its share of what's left, from wherever the page is
    // (it may have scrolled to keep what's in view in place).
    let step = { [weak self] () -> Bool in
      guard let self, let rect = locate() else { return true }
      let y = min(max(0, rect.minY - 40), max(0, self.document.bounds.height - clip.bounds.height))
      let t = duration > 0 ? min(1, (CACurrentMediaTime() - start) / duration) : 1
      let next = CGFloat(CubicBezier.easeOut(t))
      let current = clip.bounds.minY
      let to = next >= 1 ? y : current + (y - current) * (next - progress) / (1 - progress)
      progress = next
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: to))
      self.scrollView.reflectScrolledClipView(clip)
      return next >= 1
    }
    if step() {
      completion?()
      return
    }
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard step() else { return }
        timer.invalidate()
        if self?.scrollTimer === timer { self?.scrollTimer = nil }
        completion?()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    scrollTimer = timer
  }

  private var scrollTimer: Timer?

  /// The heading last jumped to, highlighted, and how to find it.
  private var flashed: (view: NSView, locate: () -> NSRect?)?

  /// Briefly highlights a heading that was jumped to.
  private func flash(_ rect: NSRect, locate: @escaping () -> NSRect?, fadingAfter delay: CFTimeInterval) {
    flashed?.view.removeFromSuperview()
    let highlight = NSView(frame: rect.insetBy(dx: -8, dy: -2))
    highlight.wantsLayer = true
    highlight.layer?.cornerRadius = 8
    highlight.layer?.cornerCurve = .continuous
    highlight.layer?.backgroundColor = resolvedCGColor(Theme.accentWash)
    document.addSubview(highlight, positioned: .below, relativeTo: column)
    flashed = (highlight, locate)
    let fade = Motion.basic("opacity", duration: 1.1, timing: Motion.easeInOut)
    fade.fromValue = 1
    fade.toValue = 0
    fade.beginTime = CACurrentMediaTime() + delay
    fade.fillMode = .both
    fade.isRemovedOnCompletion = false
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      highlight.removeFromSuperview()
      if self?.flashed?.view === highlight { self?.flashed = nil }
    }
    highlight.layer?.add(fade, forKey: "flash")
    CATransaction.commit()
  }

  /// The page was laid out again: the highlight moves with its heading
  /// (before what follows a resizing block slides, so it slides along).
  func followFlash() {
    guard let flashed, let rect = flashed.locate() else { return }
    flashed.view.frame = rect.insetBy(dx: -8, dy: -2)
  }
}

extension NSScrollView {
  /// Content fades out under the top edge once scrolled (`fade` masks the
  /// scroll view's layer; call again as it scrolls or resizes).
  func updateTopFade(_ fade: CAGradientLayer, height: CGFloat) {
    guard let layer else { return }
    let offset = contentView.bounds.minY - contentView.contentInsets.top
    let strength = min(max(offset / height, 0), 1)
    Motion.withoutAnimation {
      fade.frame = layer.bounds
      // Top of the view is location 0 (the gradient runs top to bottom).
      fade.startPoint = CGPoint(x: 0.5, y: layer.isGeometryFlipped ? 0 : 1)
      fade.endPoint = CGPoint(x: 0.5, y: layer.isGeometryFlipped ? 1 : 0)
      // Eased (ease-in-out) rather than linear, so the fade has no hard edge.
      let top = 1 - strength
      let end = Double(height / max(layer.bounds.height, 1))
      let steps = 8
      fade.colors = (0...steps).map { i -> CGColor in
        let t = CGFloat(i) / CGFloat(steps)
        return NSColor.black.withAlphaComponent(top + (1 - top) * t * t * (3 - 2 * t)).cgColor
      }
      fade.locations = (0...steps).map { NSNumber(value: end * Double($0) / Double(steps)) }
      if layer.mask !== fade { layer.mask = fade }
    }
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

/// Content that folds and unfolds like a note section: the height eases,
/// the content fades, and turning back mid-way starts from where it is.
final class FoldView: NSView {
  let body = NSStackView()
  private(set) var unfolded = false
  /// How far unfolded, 0 to 1, as it moves.
  var onShownChange: ((CGFloat) -> Void)?
  private var shown: CGFloat = 0
  private var height: NSLayoutConstraint!
  private var followsBody: NSLayoutConstraint!
  private var fold: (from: CGFloat, began: CFTimeInterval, duration: CFTimeInterval, timer: Timer)?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = true
    body.orientation = .vertical
    body.alignment = .leading
    body.translatesAutoresizingMaskIntoConstraints = false
    addSubview(body)
    height = heightAnchor.constraint(equalToConstant: 0)
    followsBody = bottomAnchor.constraint(equalTo: body.bottomAnchor)
    NSLayoutConstraint.activate([
      body.topAnchor.constraint(equalTo: topAnchor),
      body.leadingAnchor.constraint(equalTo: leadingAnchor),
      body.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    apply(0)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(unfolded: Bool, animated: Bool) {
    self.unfolded = unfolded
    fold?.timer.invalidate()
    fold = nil
    let target: CGFloat = unfolded ? 1 : 0
    guard animated, !Motion.reduceMotion else { return apply(target) }
    let duration = Motion.foldDuration * Double(abs(target - shown))
    let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
    fold = (shown, CACurrentMediaTime(), duration, timer)
    RunLoop.main.add(timer, forMode: .common)
    step()
  }

  private func step() {
    guard let fold else { return }
    let t = fold.duration > 0 ? min(1, (CACurrentMediaTime() - fold.began) / fold.duration) : 1
    let eased = CGFloat(1 - pow(1 - t, 3))
    let target: CGFloat = unfolded ? 1 : 0
    if t >= 1 {
      fold.timer.invalidate()
      self.fold = nil
    }
    apply(fold.from + (target - fold.from) * eased)
  }

  private func apply(_ value: CGFloat) {
    shown = value
    alphaValue = value
    isHidden = value == 0
    if value == 1 && fold == nil {
      height.isActive = false
      followsBody.isActive = true
    } else {
      followsBody.isActive = false
      layoutSubtreeIfNeeded()
      height.constant = (body.frame.height * value).rounded()
      height.isActive = true
    }
    onShownChange?(value)
  }
}

/// A rendered line of a note (linked and unlinked references): wraps,
/// can be selected and copied, and its links open.
final class SnippetView: NSTextView, NSTextViewDelegate {
  var onOpenLink: ((URL) -> Void)?

  init(_ text: NSAttributedString) {
    let storage = NSTextStorage(attributedString: text)
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
    isEditable = false
    isSelectable = true
    drawsBackground = false
    textContainerInset = .zero
    isVerticallyResizable = false
    isHorizontallyResizable = false
    // Links keep their rendered look (no underline), with a hand.
    linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
    delegate = self
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
    layoutManager.ensureLayout(for: textContainer)
    return NSSize(width: NSView.noIntrinsicMetric, height: ceil(layoutManager.usedRect(for: textContainer).height))
  }

  override func setFrameSize(_ newSize: NSSize) {
    let rewraps = newSize.width != frame.width
    super.setFrameSize(newSize)
    if rewraps { invalidateIntrinsicContentSize() }
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
    // Once the click is over: opening a note may remove this view.
    DispatchQueue.main.async { [onOpenLink] in onOpenLink?(url) }
    return true
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

  /// Tracks the pointer over `view` from behind it, leaving its clicks to it.
  @discardableResult
  static func track(_ view: NSView, onHover: @escaping (Bool) -> Void) -> HoverView {
    let area = HoverView()
    area.passesClicks = true
    area.onHover = onHover
    view.addSubview(area, positioned: .below, relativeTo: nil)
    area.pinEdges(to: view)
    return area
  }

  private var passesClicks = false
  override func hitTest(_ point: NSPoint) -> NSView? { passesClicks ? nil : super.hitTest(point) }

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

  init(title: String) {
    label = NSTextField.label(title, size: 12, weight: .regular, color: Theme.tertiaryText)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    label.pinEdges(to: self, insets: NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4))
    // A hover view rather than its own tracking area: it also lets go when
    // the page scrolls out from under a still pointer.
    HoverView.track(self) { [weak label] hovering in label?.textColor = hovering ? Theme.text : Theme.tertiaryText }
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Its label's baseline, to line it up with the text it acts on.
  override var firstBaselineOffsetFromTop: CGFloat { 3 + label.firstBaselineOffsetFromTop }

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
      editor.onSearch = { [weak self] url in self?.navigator?.openSearch(url) }
      editors[day] = editor
      addToColumn(editor, spacingAfter: index == shownDays.count - 1 ? 32 : 48)
    }

    headers = [:]
    for view in column.arrangedSubviews {
      if let header = view as? DayHeaderView { headers[header.day] = header }
    }
    for editor in editors.values {
      editor.onTextChange = { [weak self] in self?.refreshToc() }
      editor.onLayout = { [weak self] in self?.followFlash() }
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
  /// Notes whose mentions past the first few are unfolded, for this note.
  private var unfoldedSources: Set<String> = []
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
    if ref != self.ref { unfoldedSources = [] }
    self.ref = ref
    clearColumn()

    titleField.stringValue = ref.kind == .journal ? ref.displayTitle : ref.name
    titleField.isEditable = ref.kind == .note
    addToColumn(titleRow, spacingAfter: 4)
    addToColumn(metaLabel, spacingAfter: 20)

    let editor = MarkdownEditorView(ref: ref)
    editor.onOpenLink = { [weak self] url in self?.navigator?.openLink(url) }
    editor.onSearch = { [weak self] url in self?.navigator?.openSearch(url) }
    editor.onTextChange = { [weak self] in self?.refreshToc() }
    editor.onLayout = { [weak self] in self?.followFlash() }
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

  /// Scrolls to a heading (`[[Note#Heading]]`) or a block (`[[Note#^id]]`)
  /// of the note shown. False if it has none by that name.
  @discardableResult
  func jump(to anchor: String) -> Bool {
    guard let editor else { return false }
    let target = WikiTarget("#" + anchor)
    let content = editor.content
    var offset: Int?
    if let heading = target.heading {
      offset = markdownHeadings(in: content).first { $0.title.caseInsensitiveCompare(heading) == .orderedSame }?.offset
    } else if anchor.hasPrefix("^") {
      let ns = content as NSString
      ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, _, stop in
        if line?.trimmingCharacters(in: .whitespaces).hasSuffix(" " + anchor) == true {
          offset = range.location
          stop.pointee = true
        }
      }
    }
    guard let offset else { return false }
    editor.reveal(offset)
    layoutSubtreeIfNeeded()
    guard editor.lineRect(forCharacterAt: offset) != nil else { return false }
    scroll(to: { [weak self, weak editor] in
      guard let self, let editor, let rect = editor.lineRect(forCharacterAt: offset) else { return nil }
      return editor.convert(rect, to: self.document)
    })
    return true
  }

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
      // Under a minute (or a hair ahead of the clock, just saved): "now".
      if Date().timeIntervalSince(modified) < 60 {
        parts.append("edited now")
      } else {
        parts.append("edited " + RelativeDateTimeFormatter().localizedString(for: modified, relativeTo: Date()))
      }
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
      let block = NSStackView()
      block.orientation = .vertical
      block.alignment = .leading
      block.spacing = 4
      block.translatesAutoresizingMaskIntoConstraints = false
      let source = LinkLabel(link.ref.displayTitle, size: 14, weight: .semibold, color: Theme.accent)
      source.onClick = { [weak self] in self?.navigator?.openNote(link.ref) }
      block.addArrangedSubview(source)
      let lines = link.lines.map { line -> NSView in
        let text = SnippetView(MarkdownPreview.render(line))
        text.onOpenLink = { [weak self] url in self?.navigator?.openLink(url) }
        return text
      }
      addRows(lines, visible: 4, to: block, key: "linked \(link.ref.kind.rawValue)/\(link.ref.name)")
      backlinks.addArrangedSubview(block)
      block.widthAnchor.constraint(equalTo: backlinks.widthAnchor).isActive = true
      backlinks.setCustomSpacing(18, after: block)
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
    // Shows while the pointer is anywhere over the section.
    HoverView.track(unlinked) { [weak self] hovering in self?.unlinkedLinkAll.fade(in: hovering) }
    let headerRow = NSView()
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
    unlinkedBody.spacing = 18
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
      let block = unlinkedSource(source)
      unlinkedBody.addArrangedSubview(block)
      block.widthAnchor.constraint(equalTo: unlinkedBody.widthAnchor).isActive = true
    }
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

  /// One note's unlinked mentions under its title, with a button on the
  /// title line that links them all, shown while the pointer is over the block.
  private func unlinkedSource(_ source: (ref: NoteRef, mentions: [NoteStore.Mention])) -> NSView {
    let block = NSStackView()
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 4
    block.translatesAutoresizingMaskIntoConstraints = false

    let title = LinkLabel(source.ref.displayTitle, size: 14, weight: .semibold, color: Theme.accent)
    title.onClick = { [weak self] in self?.navigator?.openNote(source.ref) }
    let button = QuietButton(title: "Link")
    button.onClick = { [weak self] in
      guard let ref = self?.ref else { return }
      MarkdownEditorView.flushAll()
      NoteStore.shared.link(source.mentions, in: source.ref, to: ref)
    }
    button.alphaValue = 0
    button.isHidden = true
    let titleRow = NSView()
    titleRow.translatesAutoresizingMaskIntoConstraints = false
    titleRow.addSubview(title)
    titleRow.addSubview(button)
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
      title.topAnchor.constraint(equalTo: titleRow.topAnchor),
      title.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),
      title.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
      button.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor, constant: 4),
      button.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
    ])
    block.addArrangedSubview(titleRow)
    titleRow.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true

    addRows(source.mentions.map(mentionRow), visible: 5, to: block, key: "unlinked \(source.ref.kind.rawValue)/\(source.ref.name)")
    HoverView.track(block) { [weak button] hovering in button?.fade(in: hovering) }
    return block
  }

  /// Adds `rows` to `block`: the first `visible`, then the rest folded under
  /// an "N more" label that unfolds them like a note section. `key` keeps
  /// them unfolded while this note is open.
  private func addRows(_ rows: [NSView], visible: Int, to block: NSStackView, key: String) {
    for row in rows.prefix(visible) {
      block.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
    }
    guard rows.count > visible else { return }
    let rest = FoldView()
    rest.body.spacing = block.spacing
    for row in rows.dropFirst(visible) {
      rest.body.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: rest.body.widthAnchor).isActive = true
    }
    block.addArrangedSubview(rest)
    rest.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
    let count = rows.count - visible
    let more = LinkLabel("", size: 12, weight: .regular, color: Theme.tertiaryText)
    let unfolded = unfoldedSources.contains(key)
    more.stringValue = unfolded ? "Show less" : "\(count) more"
    // Its gap to the label grows with it, so nothing jumps as it starts.
    rest.onShownChange = { [weak block, weak rest] shown in
      guard let block, let rest else { return }
      block.setCustomSpacing(block.spacing * shown, after: rest)
    }
    rest.set(unfolded: unfolded, animated: false)
    more.onClick = { [weak self, weak rest, weak more] in
      guard let self, let rest, let more else { return }
      let unfold = !rest.unfolded
      if unfold { self.unfoldedSources.insert(key) } else { self.unfoldedSources.remove(key) }
      more.stringValue = unfold ? "Show less" : "\(count) more"
      rest.set(unfolded: unfold, animated: true)
    }
    block.addArrangedSubview(more)
  }

  /// The mention's line (around it, when long), the name in bold.
  private func mentionRow(_ mention: NoteStore.Mention) -> NSView {
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
    let label = SnippetView(text)
    label.onOpenLink = { [weak self] url in self?.navigator?.openLink(url) }
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      label.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
      label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3),
      label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
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

/// A row of the notes list: a note or, once there are groups, a group's
/// header (nil: the notes in none) and the line an empty group shows.
private enum NotesListItem: Hashable {
  case note(NoteRef)
  case header(String?)
  case placeholder(String?)
}

final class NotesListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  weak var navigator: NoteNavigator?
  var onNewNote: (() -> Void)?
  /// A note's ⋮ menu (or right click): export it, move it to the Trash; the
  /// trash button moves the checked notes.
  var onExport: ((NoteRef) -> Void)?
  var onDelete: (([NoteRef]) -> Void)?

  /// The name the notes in no group go under, once there are groups.
  static let ungroupedTitle = "Ungrouped"

  private let tableView = NotesTableView()
  private let scroll = NSScrollView()
  private let header = NSStackView()
  /// Rows span the window so the scroller sits at its edge; their content is
  /// inset to line up with the header column.
  private var rowInset: CGFloat = 0
  /// The groups, in the left margin like a note's headings.
  private let toc = TableOfContentsView()
  /// Set after a click so the chosen group stays active even when the list
  /// can't scroll it to the top; cleared when the reader scrolls.
  private var pinnedGroup: (index: Int, origin: CGFloat)?
  private let searchField = BorderlessSearchField()
  private let countLabel = NSTextField.label("", size: 13, color: Theme.tertiaryText)
  private var items: [NotesListItem] = []
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

  /// Collapsed groups, by name ("" for the notes in none).
  private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsedNoteGroups") ?? []) {
    didSet { UserDefaults.standard.set(Array(collapsed).sorted(), forKey: "collapsedNoteGroups") }
  }
  /// While several changes are made at once: they show as one.
  private var batching = false
  /// A group's name being edited: the list waits to show changes (as it
  /// does while a note is dragged).
  private var renaming: String?
  private var pendingReload = false
  /// Where a note dragged over the list would go, and what shows it.
  private var dropTarget: DropTarget?
  private let dropHighlight = DropHighlightView()

  private enum DropTarget: Equatable {
    /// Into a new group with this note (dropped on it).
    case newGroup(with: NoteRef)
    /// Into this group (nil: out of its group).
    case group(String?)
  }

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
    // A click opens a note (or opens or closes a group); a drag lifts a
    // note out to move it into a group or out of one.
    tableView.onRowClick = { [weak self] row in self?.rowClicked(row) }
    tableView.canLift = { [weak self] row in self?.canLift(row) ?? false }
    tableView.onLift = { [weak self] row, point in self?.beginNoteDrag(row: row, at: point) }
    tableView.onDragMove = { [weak self] point in self?.moveNoteDrag(to: point) }
    tableView.onDragEnd = { [weak self] drop in self?.endNoteDrag(drop: drop) }
    dropHighlight.isHidden = true
    tableView.addSubview(dropHighlight)
    // Right click: the same menu as a row's ⋮ button.
    tableView.menuForRow = { [weak self] row in
      guard let self, self.items.indices.contains(row) else { return nil }
      let menu = NSMenu()
      switch self.items[row] {
      case .note(let ref): self.addNoteItems(for: ref, to: menu)
      case .header(let group?): self.addGroupItems(for: group, to: menu)
      default: return nil
      }
      return menu
    }
    scroll.documentView = tableView
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    // Room under the last note when scrolled to the end; the scroller still
    // runs to the window's edge.
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 48, right: 0)
    scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -48, right: 0)
    scroll.wantsLayer = true
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
    toc.translatesAutoresizingMaskIntoConstraints = false
    toc.isHidden = true
    toc.dashLevel = 1
    toc.animatesAllChanges = true
    toc.onSelect = { [weak self] index in self?.scrollToGroup(index) }
    addSubview(toc)
    NSLayoutConstraint.activate([
      toc.leadingAnchor.constraint(equalTo: leadingAnchor),
      toc.topAnchor.constraint(equalTo: topAnchor),
      toc.bottomAnchor.constraint(equalTo: bottomAnchor),
      toc.widthAnchor.constraint(equalToConstant: 320),
    ])
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification,
                                           object: scroll.contentView)
    NotificationCenter.default.addObserver(self, selector: #selector(notesChanged), name: .notesDidChange, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    scroll.updateTopFade(topFade, height: 14)
    // Labels may use the margin up to the column; the dashes step aside
    // when they'd run under the notes' checkboxes.
    toc.labelRoom = header.frame.minX - 26 - 28
    toc.setTucked(header.frame.minX - 40 < toc.dashesExtent + 8, animated: window?.isVisible == true)
    let inset = max(0, header.frame.minX - 12)
    guard inset != rowInset else { return }
    rowInset = inset
    tableView.enumerateAvailableRowViews { rowView, _ in (rowView as? RoundedRowView)?.inset = inset }
  }

  // MARK: Table of contents

  /// Briefly highlights a group's header, the width of the column.
  private func flashHeader(_ row: Int) {
    guard let text = textBounds(ofRow: row, making: true) else { return }
    let left = rowInset + 12
    let highlight = NSView(frame: NSRect(x: left, y: text.minY, width: tableView.bounds.width - 2 * left, height: text.height)
      .insetBy(dx: -8, dy: -2))
    highlight.wantsLayer = true
    highlight.layer?.cornerRadius = 8
    highlight.layer?.cornerCurve = .continuous
    highlight.layer?.backgroundColor = resolvedCGColor(Theme.accentWash)
    highlight.layer?.zPosition = -1
    tableView.addSubview(highlight)
    let fade = Motion.basic("opacity", duration: 1.1, timing: Motion.easeInOut)
    fade.fromValue = 1
    fade.toValue = 0
    fade.beginTime = CACurrentMediaTime() + 0.5
    fade.fillMode = .both
    fade.isRemovedOnCompletion = false
    CATransaction.begin()
    CATransaction.setCompletionBlock { highlight.removeFromSuperview() }
    highlight.layer?.add(fade, forKey: "flash")
    CATransaction.commit()
  }

  /// The groups' headers, in order (the notes in none last).
  private var groupHeaders: [String?] {
    items.compactMap { if case .header(let group) = $0 { group } else { nil } }
  }

  private func updateToc() {
    toc.setEntries(groupHeaders.map { TocEntry(depth: 0, title: $0 ?? Self.ungroupedTitle) })
    updateActiveGroup()
  }

  @objc private func listScrolled() {
    scroll.updateTopFade(topFade, height: 14)
    updateActiveGroup()
  }

  /// The list fades out under its top edge once scrolled, like a page.
  private let topFade = CAGradientLayer()

  /// The active group is the last one whose header has reached the top.
  private func updateActiveGroup() {
    let headers = groupHeaders
    guard !headers.isEmpty else { return }
    let visible = scroll.contentView.bounds
    if let pinned = pinnedGroup {
      if abs(pinned.origin - visible.minY) < 1 {
        toc.setActiveIndex(pinned.index)
        return
      }
      pinnedGroup = nil
    }
    var active = 0
    for (index, group) in headers.enumerated() {
      guard let row = items.firstIndex(of: .header(group)) else { continue }
      if tableView.rect(ofRow: row).minY <= visible.minY + 24 { active = index }
    }
    toc.setActiveIndex(active)
  }

  private func scrollToGroup(_ index: Int) {
    let headers = groupHeaders
    guard headers.indices.contains(index), let row = items.firstIndex(of: .header(headers[index])) else { return }
    let clip = scroll.contentView
    let maxY = max(0, tableView.frame.height + scroll.contentInsets.bottom - clip.bounds.height)
    let y = min(max(0, tableView.rect(ofRow: row).minY), maxY)
    // Its header lights up at once and rides in with the list, fading once
    // it has arrived (like a note's heading).
    flashHeader(row)
    Motion.animate(0.5, timing: Motion.easeOut, {
      clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
    }, completion: { [weak self] in
      guard let self else { return }
      self.scroll.reflectScrolledClipView(clip)
      self.pinnedGroup = (index, clip.bounds.minY)
      self.toc.setActiveIndex(index)
    })
  }

  private var filter: String { searchField.stringValue.trimmingCharacters(in: .whitespaces) }

  func reload() {
    if renaming != nil || noteDrag != nil {
      pendingReload = true
      return
    }
    let store = NoteStore.shared
    countLabel.stringValue = "\(store.notes.count)"
    var fresh: [NotesListItem] = []
    let groups = store.groups
    if !filter.isEmpty {
      fresh = store.search(filter, limit: 200).map(\.ref).filter { $0.kind == .note }.map { .note($0) }
    } else if groups.isEmpty {
      fresh = store.notes.map { .note($0) }
    } else {
      // Each group, then the notes in none.
      var byGroup: [String: [NoteRef]] = [:]
      for ref in store.notes { byGroup[store.group(of: ref) ?? "", default: []].append(ref) }
      for group in groups.map(Optional.some) + [nil] {
        fresh.append(.header(group))
        guard !collapsed.contains(group ?? "") else { continue }
        let refs = byGroup[group ?? ""] ?? []
        fresh += refs.isEmpty ? [.placeholder(group)] : refs.map { .note($0) }
      }
    }
    show(fresh)
  }

  /// Shows the notes matching `query` (a "#tag" from a note).
  func search(_ query: String) {
    searchField.stringValue = query
    reload()
  }

  func focusSearch() {
    window?.makeFirstResponder(searchField)
  }

  @objc private func notesChanged() {
    // Notes moved to the Trash are no longer checked.
    checkedNotes = checkedNotes.filter { NoteStore.shared.exists($0) }
    if !isHidden && !batching { reload() }
  }

  func controlTextDidChange(_ obj: Notification) { reload() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)), let first = notes.first {
      navigator?.openNote(first)
      return true
    }
    return false
  }

  /// The notes shown, in order.
  private var notes: [NoteRef] {
    items.compactMap { if case .note(let ref) = $0 { ref } else { nil } }
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
    guard items.indices.contains(row), case .note(let ref) = items[row] else { return }
    if checkedNotes.contains(ref) { checkedNotes.remove(ref) } else { checkedNotes.insert(ref) }
    (tableView.rowView(atRow: row, makeIfNecessary: false) as? NoteRowView)?.isChecked = checkedNotes.contains(ref)
  }

  private func rowClicked(_ row: Int) {
    guard items.indices.contains(row) else { return }
    switch items[row] {
    case .note(let ref): navigator?.openNote(ref)
    case .header(let group): toggleGroup(group)
    case .placeholder: break
    }
  }

  /// Export, Move to Group and Move to Trash for `ref`.
  private func addNoteItems(for ref: NoteRef, to menu: NSMenu) {
    menu.addItem(ClosureMenuItem(title: "Export as Markdown…") { [weak self] in self?.onExport?(ref) })
    let groups = NSMenu()
    let current = NoteStore.shared.group(of: ref)
    for group in NoteStore.shared.groups {
      let item = ClosureMenuItem(title: group) { [weak self] in self?.move([ref], to: group) }
      if group == current {
        item.state = .on
        item.isEnabled = false
      }
      groups.addItem(item)
    }
    if !groups.items.isEmpty { groups.addItem(.separator()) }
    groups.addItem(ClosureMenuItem(title: "New Group") { [weak self] in self?.makeGroup(with: [ref]) })
    if current != nil {
      groups.addItem(ClosureMenuItem(title: "Remove from Group") { [weak self] in self?.move([ref], to: nil) })
    }
    let groupsItem = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
    groupsItem.submenu = groups
    menu.addItem(groupsItem)
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: "Move to Trash…") { [weak self] in self?.onDelete?([ref]) })
  }

  /// Rename and Delete for `group`.
  private func addGroupItems(for group: String, to menu: NSMenu) {
    menu.addItem(ClosureMenuItem(title: "Rename Group") { [weak self] in self?.beginRenaming(group) })
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: "Delete Group") { [weak self] in self?.deleteGroup(group) })
  }

  // MARK: Groups

  private func toggleGroup(_ group: String?) {
    let key = group ?? ""
    if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    turning = group
    reload()
    turning = nil
  }

  /// The group whose chevron turns as the list changes.
  private var turning: String??
  /// Rows of a group being renamed, by what they become: the same rows.
  private var renamedItems: [NotesListItem: NotesListItem] = [:]

  private func move(_ refs: [NoteRef], to group: String?) {
    place(refs.map { ($0, group) }, actionName: group == nil ? "Remove from Group" : "Move to Group")
  }

  /// Puts `refs` in a new group, and starts naming it.
  private func makeGroup(with refs: [NoteRef]) {
    let name = NoteStore.shared.uniqueGroupName()
    place(refs.map { ($0, name) }, making: [name], actionName: "New Group")
    beginRenaming(name)
  }

  /// Moves its notes out and removes it.
  private func deleteGroup(_ group: String) {
    let refs = NoteStore.shared.notes.filter { NoteStore.shared.group(of: $0) == group }
    place(refs.map { ($0, nil) }, removing: [group], actionName: "Delete Group")
  }

  /// Makes the `making` groups, puts each note in its group, and removes the
  /// `removing` groups (once empty), as one step: Undo puts it all back
  /// (Redo does it again).
  private func place(_ placements: [(ref: NoteRef, group: String?)], making: [String] = [], removing: [String] = [],
                     actionName: String) {
    // (Undone while a new group is being named: the naming stops.)
    cancelRenaming()
    let store = NoteStore.shared
    let before = placements.map { (ref: $0.ref, group: store.group(of: $0.ref)) }
    batching = true
    let made = making.filter { store.createGroup(named: $0) != nil }
    for (group, moving) in Dictionary(grouping: placements, by: \.group) { store.move(moving.map(\.ref), toGroup: group) }
    let removed = removing.filter { group in store.hasGroup(named: group) && !store.notes.contains { store.group(of: $0) == group } }
    for group in removed {
      store.deleteGroup(group)
      collapsed.remove(group)
    }
    batching = false
    reload()
    guard let undo = window?.undoManager else { return }
    undo.registerUndo(withTarget: self) { list in
      list.place(before, making: removed, removing: made, actionName: actionName)
    }
    undo.setActionName(actionName)
  }

  private func renameGroup(_ group: String, to name: String) {
    cancelRenaming()
    // (Shown below, once: the store's own notice would show it without the
    // slide.)
    batching = true
    let result = NoteStore.shared.renameGroup(group, to: name)
    batching = false
    guard let renamed = result else {
      reload()
      return NSSound.beep()
    }
    if collapsed.remove(group) != nil { collapsed.insert(renamed) }
    // Its rows slide to where its new name puts it.
    renamedItems = [.header(group): .header(renamed), .placeholder(group): .placeholder(renamed)]
    reload()
    renamedItems = [:]
    guard renamed != group, let undo = window?.undoManager else { return }
    undo.registerUndo(withTarget: self) { $0.renameGroup(renamed, to: group) }
    undo.setActionName("Rename Group")
  }

  private func beginRenaming(_ group: String) {
    guard let row = items.firstIndex(of: .header(group)) else { return }
    tableView.scrollRowToVisible(row)
    guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? GroupHeaderCell else { return }
    renaming = group
    cell.beginRenaming()
  }

  /// Stops naming a group, keeping its name. Typing in the name is undone
  /// first, then what came before (making the group).
  private func cancelRenaming() {
    guard let group = renaming else { return }
    if let row = items.firstIndex(of: .header(group)),
       let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? GroupHeaderCell, cell.isRenaming {
      cell.cancelRenaming()
    }
    // (Ending the edit calls finishRenaming.)
    if renaming != nil { finishRenaming(group, to: nil) }
  }

  private func finishRenaming(_ group: String, to name: String?) {
    renaming = nil
    pendingReload = false
    if let name, name != group, NoteStore.shared.hasGroup(named: group) {
      renameGroup(group, to: name)
    } else {
      reload()
    }
  }

  // MARK: Dragging notes

  /// A note being dragged: a copy of its row lifts out of the list and
  /// follows the pointer (like a block in a note), its place staying blank
  /// until it's dropped.
  private final class NoteDrag {
    let ref: NoteRef
    let preview: NSView
    let lifted: CALayer
    let blank: NSView
    /// From the copy's top to the pointer.
    let grab: CGFloat

    init(ref: NoteRef, preview: NSView, lifted: CALayer, blank: NSView, grab: CGFloat) {
      self.ref = ref
      self.preview = preview
      self.lifted = lifted
      self.blank = blank
      self.grab = grab
    }
  }

  private var noteDrag: NoteDrag?

  private func canLift(_ row: Int) -> Bool {
    guard filter.isEmpty, renaming == nil, noteDrag == nil, items.indices.contains(row), case .note = items[row] else { return false }
    return true
  }

  private func beginNoteDrag(row: Int, at point: NSPoint) {
    guard canLift(row), case .note(let ref) = items[row], let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return }
    endSlide()
    // The row's content, with its checkbox's gutter.
    let side = max(0, rowInset - 36)
    let rect = NSRect(x: side, y: rowView.frame.minY, width: rowView.frame.width - 2 * side, height: rowView.frame.height)
    let picture = rowView.picture(of: NSRect(x: side, y: 0, width: rect.width, height: rect.height))
    let blank = SlideOverlayView(frame: rect)
    blank.wantsLayer = true
    blank.layer?.backgroundColor = resolvedCGColor(Theme.background)
    blank.layer?.zPosition = 2
    tableView.addSubview(blank)
    let preview = NSView(frame: rect)
    preview.wantsLayer = true
    preview.layer?.zPosition = 3
    let lifted = CALayer()
    // Grows from its left edge, at the pointer.
    let grabbed = min(max(0, point.y - rect.minY), rect.height)
    lifted.anchorPoint = CGPoint(x: 0, y: 1 - grabbed / max(1, rect.height))
    lifted.frame = preview.bounds
    lifted.masksToBounds = true
    let content = CALayer()
    content.contents = picture
    content.contentsScale = window?.backingScaleFactor ?? 2
    content.frame = CGRect(origin: .zero, size: rect.size)
    lifted.addSublayer(content)
    preview.layer?.addSublayer(lifted)
    tableView.addSubview(preview)
    let scale = CATransform3DMakeScale(1.06, 1.06, 1)
    let grow = CABasicAnimation(keyPath: "transform")
    grow.fromValue = CATransform3DIdentity
    grow.toValue = scale
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0.5
    for animation in [grow, fade] {
      animation.duration = BlockDragDebug.liftDuration
      animation.timingFunction = Motion.standard
    }
    lifted.transform = scale
    lifted.opacity = 0.5
    lifted.add(grow, forKey: "grow")
    lifted.add(fade, forKey: "fade")
    noteDrag = NoteDrag(ref: ref, preview: preview, lifted: lifted, blank: blank, grab: point.y - rect.minY)
    moveNoteDrag(to: point)
  }

  private func moveNoteDrag(to point: NSPoint) {
    guard let drag = noteDrag else { return }
    drag.preview.setFrameOrigin(NSPoint(x: drag.preview.frame.minX, y: point.y - drag.grab))
    let (row, operation) = dropPosition(at: point)
    setDropTarget(target(for: drag.ref, row: row, operation: operation))
  }

  /// Where the pointer would drop a note: on a row, or between two (a
  /// note's top and bottom quarters; without groups, notes are only dropped
  /// on).
  private func dropPosition(at point: NSPoint) -> (row: Int, operation: NSTableView.DropOperation) {
    let row = tableView.row(at: point)
    guard row >= 0 else { return (point.y < 0 ? 0 : items.count, .above) }
    guard case .note = items[row], !NoteStore.shared.groups.isEmpty else { return (row, .on) }
    let rect = tableView.rect(ofRow: row)
    let t = (point.y - rect.minY) / max(1, rect.height)
    if t < 0.25 { return (row, .above) }
    if t > 0.75 { return (row + 1, .above) }
    return (row, .on)
  }

  /// Drops the note (or puts it back): the list changes, and the copy
  /// glides to the note's place, turning back into it.
  private func endNoteDrag(drop: Bool) {
    guard let drag = noteDrag else { return }
    noteDrag = nil
    let target = drop ? dropTarget : nil
    setDropTarget(nil)
    if let target {
      // (What moves slides; its old place is taken by what follows.)
      drag.blank.removeFromSuperview()
      pendingReload = false
      perform(target, with: drag.ref)
    } else if pendingReload {
      pendingReload = false
      reload()
    }
    var destination: NSPoint?
    var landing: NSView?
    if let row = items.firstIndex(of: .note(drag.ref)) {
      let rect = tableView.rect(ofRow: row)
      destination = NSPoint(x: drag.preview.frame.minX, y: rect.minY)
      // Its row shows when the copy gets there.
      landing = tableView.rowView(atRow: row, makeIfNecessary: false)
      landing?.alphaValue = 0
    }
    let duration = BlockDragDebug.liftDuration * 1.25
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = duration
      context.timingFunction = Motion.standard
      if let destination { drag.preview.animator().setFrameOrigin(destination) }
    }, completionHandler: {
      landing?.alphaValue = 1
      drag.preview.removeFromSuperview()
      drag.blank.removeFromSuperview()
    })
    // Into a closed group: it fades away there.
    let lifted = drag.lifted
    let shrink = CABasicAnimation(keyPath: "transform")
    shrink.fromValue = lifted.presentation()?.transform ?? lifted.transform
    shrink.toValue = CATransform3DIdentity
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = lifted.presentation()?.opacity ?? lifted.opacity
    fade.toValue = destination == nil ? 0 : 1
    for animation in [shrink, fade] {
      animation.duration = duration
      animation.timingFunction = Motion.standard
    }
    lifted.transform = CATransform3DIdentity
    lifted.opacity = destination == nil ? 0 : 1
    lifted.add(shrink, forKey: "grow")
    lifted.add(fade, forKey: "fade")
  }

  /// For automated checks: lifts the note in `row`, drags it to `y` (in the
  /// list), and drops it (or puts it back).
  func debugLift(_ row: Int) {
    let rect = tableView.rect(ofRow: row)
    beginNoteDrag(row: row, at: NSPoint(x: rect.midX, y: rect.midY))
  }
  func debugDragTo(_ y: CGFloat) { moveNoteDrag(to: NSPoint(x: tableView.bounds.midX, y: y)) }
  func debugEndDrag(drop: Bool) { endNoteDrag(drop: drop) }

  /// Where `ref` dropped at `row` goes: on a note in no group, into a new
  /// group with it; on a group's header, empty line or one of its notes, or
  /// between its rows, into that group (the notes in none: out of its
  /// group). Nil where it wouldn't move.
  private func target(for ref: NoteRef, row: Int, operation: NSTableView.DropOperation) -> DropTarget? {
    guard filter.isEmpty else { return nil }
    let store = NoteStore.shared
    let from = store.group(of: ref)
    if operation == .on, items.indices.contains(row) {
      switch items[row] {
      case .note(let other):
        guard other != ref else { return nil }
        guard let group = store.group(of: other) else { return .newGroup(with: other) }
        return group != from ? .group(group) : nil
      case .header(let group), .placeholder(let group):
        return group != from ? .group(group) : nil
      }
    }
    // Between rows: the group of the row above (below the last, the notes
    // in none). Without groups, the order is the notes' own.
    guard !store.groups.isEmpty, row > 0, row <= items.count else { return nil }
    let group: String?
    switch items[row - 1] {
    case .note(let other): group = store.group(of: other)
    case .header(let g), .placeholder(let g): group = g
    }
    return group != from ? .group(group) : nil
  }

  private func perform(_ target: DropTarget, with ref: NoteRef) {
    switch target {
    case .newGroup(let other): makeGroup(with: [other, ref])
    case .group(let group): move([ref], to: group)
    }
  }

  /// For automated checks: drops the note named `name` at `row`, on it or
  /// above it, as if dragged there.
  func debugDrop(_ name: String, row: Int, on: Bool) {
    let ref = NoteRef(kind: .note, name: name)
    guard NoteStore.shared.exists(ref), let target = target(for: ref, row: row, operation: on ? .on : .above) else { return }
    perform(target, with: ref)
  }

  /// For automated checks: collapses or expands a group ("" for the notes in
  /// none), or deletes it.
  func debugToggleGroup(_ name: String) { toggleGroup(name.isEmpty ? nil : name) }
  func debugDeleteGroup(_ name: String) { deleteGroup(name) }
  func debugScroll(to y: CGFloat) {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
  }
  /// For automated checks: clicks a group in the table of contents.
  func debugSelectTocEntry(_ index: Int) { scrollToGroup(index) }
  func debugRenameGroup(_ name: String, to newName: String) { renameGroup(name, to: newName) }

  /// The rows a drop target covers: the note it's on, or the group's header
  /// and rows.
  private func rows(of target: DropTarget) -> ClosedRange<Int>? {
    switch target {
    case .newGroup(let ref):
      return items.firstIndex(of: .note(ref)).map { $0...$0 }
    case .group(let group):
      guard let start = items.firstIndex(of: .header(group)) else { return nil }
      var end = start
      while end + 1 < items.count, !{ if case .header = items[end + 1] { true } else { false } }() { end += 1 }
      return start...end
    }
  }

  /// Shows where a dragged note would go: a soft wash over the note it'd
  /// make a group with, or the group it'd go in, gliding between them.
  private func setDropTarget(_ target: DropTarget?) {
    guard target != dropTarget else { return }
    dropTarget = target
    guard let target, let rows = rows(of: target) else {
      dropHighlight.hide()
      return
    }
    // As much room above the first row's text as below the last one's.
    let pad: CGFloat = 12
    let top = (textBounds(ofRow: rows.lowerBound)?.minY).map { $0 - pad } ?? tableView.rect(ofRow: rows.lowerBound).minY + 1
    let bottom = (textBounds(ofRow: rows.upperBound)?.maxY).map { $0 + pad } ?? tableView.rect(ofRow: rows.upperBound).maxY - 1
    let frame = NSRect(x: rowInset + 4, y: top, width: tableView.bounds.width - 2 * (rowInset + 4), height: bottom - top)
    dropHighlight.show(in: frame)
  }

  /// Where a row's text is (in the table), if it's showing.
  private func textBounds(ofRow row: Int, making: Bool = false) -> NSRect? {
    guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: making) else { return nil }
    cell.layoutSubtreeIfNeeded()
    let texts = cell.subviews.filter { $0 is NSTextField && !$0.isHidden && !($0 as! NSTextField).stringValue.isEmpty }
    guard !texts.isEmpty else { return nil }
    return texts.map { tableView.convert($0.frame, from: cell) }.reduce(NSRect.null) { $0.union($1) }
  }

  // MARK: Animating changes

  /// The list changes in one go, then animates there the way a note's
  /// sections fold: run by the render server, rows that stay slide from where
  /// they were (opaque, over the rest), rows that come fade in under them,
  /// and rows that go stay as pictures fading where they were until what
  /// follows slides over them.
  private func show(_ fresh: [NotesListItem]) {
    let animated = window?.isVisible == true && !isHidden && !Motion.reduceMotion && !items.isEmpty && fresh != items
    endSlide()
    defer { updateToc() }
    guard animated else {
      items = fresh
      tableView.reloadData()
      return
    }
    let clip = scroll.contentView
    let oldOrigin = clip.bounds.minY
    // Where each row was on screen, and pictures of those showing.
    let renamed = renamedItems
    var oldTops: [NotesListItem: CGFloat] = [:]
    for (row, item) in items.enumerated() { oldTops[renamed[item] ?? item] = tableView.rect(ofRow: row).minY - oldOrigin }
    var pictures: [(item: NotesListItem, frame: NSRect, image: NSImage)] = []
    let before = tableView.rows(in: tableView.visibleRect)
    for row in before.lowerBound..<before.upperBound {
      guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { continue }
      pictures.append((renamed[items[row]] ?? items[row], rowView.frame, rowView.picture()))
    }
    let turning = self.turning
    items = fresh
    tableView.reloadData()
    tableView.layoutSubtreeIfNeeded()

    let newOrigin = clip.bounds.minY
    let background = resolvedCGColor(Theme.background)
    var shown = Set<NotesListItem>()
    let after = tableView.rows(in: tableView.visibleRect)
    for row in after.lowerBound..<after.upperBound {
      guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: true) else { continue }
      rowView.wantsLayer = true
      guard let layer = rowView.layer else { continue }
      let item = items[row]
      shown.insert(item)
      if case .header(let group) = item, let turning, turning == group {
        (rowView as? GroupRowView)?.turnChevron()
      }
      if let old = oldTops[item] {
        let offset = old - (rowView.frame.minY - newOrigin)
        guard abs(offset) > 0.5 else { continue }
        slideLayer(layer, by: offset)
        layer.zPosition = 1
        layer.backgroundColor = background
        slideMoved.append(rowView)
      } else {
        fadeLayer(layer, in: true)
      }
    }
    for picture in pictures where !shown.contains(picture.item) {
      let overlay = SlideOverlayView(frame: picture.frame.offsetBy(dx: 0, dy: newOrigin - oldOrigin))
      overlay.wantsLayer = true
      let image = NSImageView(frame: overlay.bounds)
      image.imageScaling = .scaleAxesIndependently
      image.image = picture.image
      overlay.addSubview(image)
      tableView.addSubview(overlay)
      slideOverlays.append(overlay)
      guard let layer = overlay.layer else { continue }
      if let row = items.firstIndex(of: picture.item) {
        // Moved out of sight: it goes there.
        let target = tableView.rect(ofRow: row)
        overlay.frame.origin.y = target.minY
        layer.zPosition = 1
        layer.backgroundColor = background
        slideLayer(layer, by: (picture.frame.minY - oldOrigin) - (target.minY - newOrigin))
      } else {
        overlay.alphaValue = 0
        fadeLayer(layer, in: false)
      }
    }
    slideGeneration += 1
    let generation = slideGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.foldDuration + 0.05) { [weak self] in
      guard let self, self.slideGeneration == generation else { return }
      self.endSlide()
    }
  }

  /// Pictures over the list and rows sliding, put back at the end.
  private var slideOverlays: [NSView] = []
  private var slideMoved: [NSView] = []
  private var slideGeneration = 0

  private func endSlide() {
    slideOverlays.forEach { $0.removeFromSuperview() }
    for view in slideMoved {
      view.layer?.removeAnimation(forKey: "glea.list.slide")
      view.layer?.zPosition = 0
      view.layer?.backgroundColor = nil
    }
    slideOverlays = []
    slideMoved = []
  }

  private func slideLayer(_ layer: CALayer, by offset: CGFloat) {
    let animation = CABasicAnimation(keyPath: "position")
    animation.isAdditive = true
    animation.fromValue = NSValue(point: NSPoint(x: 0, y: offset))
    animation.toValue = NSValue(point: .zero)
    animation.duration = Motion.foldDuration
    animation.timingFunction = CubicBezier.fold.timingFunction
    layer.add(animation, forKey: "glea.list.slide")
  }

  private func fadeLayer(_ layer: CALayer, in fadingIn: Bool) {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = fadingIn ? 0 : 1
    fade.toValue = fadingIn ? 1 : 0
    fade.duration = Motion.foldDuration
    fade.timingFunction = CubicBezier.fold.timingFunction
    layer.add(fade, forKey: "glea.list.fade")
  }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch items[row] {
    case .note: 58
    case .header: GroupRowView.height
    case .placeholder: 40
    }
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    if case .note = items[row] { true } else { false }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch items[row] {
    case .note(let ref):
      let cell = (tableView.makeView(withIdentifier: NoteCell.identifier, owner: self) as? NoteCell) ?? NoteCell()
      cell.configure(title: ref.name, excerpt: NoteStore.shared.excerpt(of: ref), date: NoteStore.shared.modified(ref))
      cell.onMore = { [weak self] button in
        guard let self else { return }
        let menu = NSMenu()
        self.addNoteItems(for: ref, to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
      }
      return cell
    case .header(let group):
      let cell = (tableView.makeView(withIdentifier: GroupHeaderCell.identifier, owner: self) as? GroupHeaderCell) ?? GroupHeaderCell()
      let count = NoteStore.shared.notes.filter { NoteStore.shared.group(of: $0) == group }.count
      cell.configure(name: group ?? Self.ungroupedTitle, count: count, hasMenu: group != nil)
      cell.onMore = { [weak self] button in
        guard let self, let group else { return }
        let menu = NSMenu()
        self.addGroupItems(for: group, to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
      }
      cell.onRename = { [weak self] name in
        guard let group else { return }
        self?.finishRenaming(group, to: name)
      }
      return cell
    case .placeholder:
      return (tableView.makeView(withIdentifier: GroupPlaceholderCell.identifier, owner: self) as? GroupPlaceholderCell)
        ?? GroupPlaceholderCell()
    }
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    switch items[row] {
    case .note(let ref):
      let rowView = NoteRowView()
      rowView.inset = rowInset
      rowView.isChecked = checkedNotes.contains(ref)
      rowView.onCheck = { [weak self] checked in
        if checked { self?.checkedNotes.insert(ref) } else { self?.checkedNotes.remove(ref) }
      }
      return rowView
    case .header(let group):
      let rowView = GroupRowView()
      rowView.inset = rowInset
      rowView.isCollapsed = collapsed.contains(group ?? "")
      return rowView
    case .placeholder:
      let rowView = RoundedRowView()
      rowView.inset = rowInset
      return rowView
    }
  }
}

/// Shows where a dragged note would go: a rounded wash behind the rows that
/// fades in, glides from target to target, and fades out.
private final class DropHighlightView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.zPosition = -1
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateLayer() {
    layer?.backgroundColor = Theme.accentWash.cgColor
  }

  override var wantsUpdateLayer: Bool { true }

  private var showing = false

  func show(in frame: NSRect) {
    if showing {
      springFrame(to: frame, stiffness: 520, damping: 36)
      return
    }
    showing = true
    isHidden = false
    self.frame = frame
    alphaValue = 1
    animateIn(scale: 0.98, fade: 0.12, duration: 0.18)
  }

  func hide() {
    guard showing else { return }
    showing = false
    animateOut(scale: 0.98, fade: 0.12, duration: 0.16) { [weak self] in
      guard let self, !self.showing else { return }
      self.isHidden = true
    }
  }
}

/// The notes list: its rows' ⋮ buttons and checkboxes take their clicks (a table otherwise
/// keeps clicks on custom controls, selecting the row and opening the note),
/// and the pointer is an arrow over it.
private final class NotesTableView: NSTableView {
  /// The menu a right click (or ⌃-click) anywhere on a row opens.
  var menuForRow: ((Int) -> NSMenu?)?
  /// A click on a row (not on one of its controls).
  var onRowClick: ((Int) -> Void)?
  /// Dragging a row: whether it lifts, then where the pointer goes (in the
  /// table), and whether it's dropped (not canceled with Escape).
  var canLift: ((Int) -> Bool)?
  var onLift: ((Int, NSPoint) -> Void)?
  var onDragMove: ((NSPoint) -> Void)?
  var onDragEnd: ((Bool) -> Void)?

  /// The row under `point` as it shows: rows sliding into place are where
  /// they are on screen, not where they're going.
  private func rowShown(at point: NSPoint) -> Int {
    var found = -1
    enumerateAvailableRowViews { rowView, row in
      guard found < 0 else { return }
      var frame = rowView.frame
      if let layer = rowView.layer, let shown = layer.presentation() { frame.origin.y += shown.position.y - layer.position.y }
      if frame.contains(point) { found = row }
    }
    return found >= 0 ? found : row(at: point)
  }

  override func mouseDown(with event: NSEvent) {
    let start = convert(event.locationInWindow, from: nil)
    let row = rowShown(at: start)
    // Its controls (and a name being edited) take their own clicks.
    let hit = superview.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
    guard row >= 0, !(hit is IconButton), !(hit is SelectionCheckbox), !(hit is NSTextView) else {
      return super.mouseDown(with: event)
    }
    var lifted = false
    while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
      switch next.type {
      case .leftMouseDragged:
        let point = convert(next.locationInWindow, from: nil)
        if !lifted, hypot(point.x - start.x, point.y - start.y) > 4, canLift?(row) == true {
          lifted = true
          onLift?(row, start)
        }
        guard lifted else { continue }
        autoscroll(with: next)
        onDragMove?(convert(next.locationInWindow, from: nil))
      case .keyDown where next.keyCode == 53:  // Escape
        if lifted {
          onDragEnd?(false)
          return
        }
      case .leftMouseUp:
        if lifted { onDragEnd?(true) } else { onRowClick?(row) }
        return
      default:
        break
      }
    }
  }

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

  static let verticalEllipsis: NSImage? = {
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

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    if let clip = enclosingScrollView?.contentView {
      NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }
  }

  /// Scrolling sends no enter or exit events: rows moving away from a still
  /// pointer lose their hover (and those moving under it gain it).
  private var syncPending = false
  @objc private func listScrolled() {
    guard !syncPending else { return }
    syncPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.syncPending = false
      guard let window = self.window, !self.isHiddenOrHasHiddenAncestor else { return self.hovering = false }
      self.hovering = window.isKeyWindow && self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
  }

  private func updateCheckbox(animated: Bool) {
    checkbox.setShown(hovering || checkbox.isChecked, animated: animated)
  }
}

/// A group's header row: a chevron in the gutter (where notes have their
/// checkbox), turned down while the group is open.
private final class GroupRowView: RoundedRowView {
  static let height: CGFloat = 50
  /// How far below the row's middle its content sits (room above it, from
  /// the group before).
  static let drop: CGFloat = 6

  private let chevron = ChevronView()
  var isCollapsed = false {
    didSet { chevron.isOpen = !isCollapsed }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    chevron.isOpen = true
    addSubview(chevron)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    if subview !== chevron { addSubview(chevron, positioned: .above, relativeTo: nil) }
  }

  override func layout() {
    super.layout()
    let size: CGFloat = 16
    let center = max(4 + SelectionCheckbox.boxSize / 2, inset - 12)
    chevron.frame = NSRect(x: (center - size / 2).rounded(), y: ((bounds.height - size) / 2 + Self.drop).rounded(), width: size, height: size)
  }

  /// Turns the chevron from where it was to where it is.
  func turnChevron() { chevron.turn(fromOpen: isCollapsed) }

  override func drawSelection(in dirtyRect: NSRect) {}
}

/// A chevron pointing right, turned down while open. It's drawn in a layer of
/// its own: AppKit leaves that one's transform alone.
private final class ChevronView: NSView {
  private let glyph = CALayer()
  var isOpen = false {
    didSet { needsLayout = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.addSublayer(glyph)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    guard let symbol = Theme.symbol("chevron.right", size: 10, weight: .semibold) else { return }
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
      symbol.draw(in: rect)
      Theme.tertiaryText.set()
      rect.fill(using: .sourceAtop)
      return true
    }
    glyph.contents = tinted.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
    glyph.contentsGravity = .center
    glyph.contentsScale = window?.backingScaleFactor ?? 2
  }

  override func layout() {
    super.layout()
    Motion.withoutAnimation {
      glyph.bounds = bounds
      glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
      glyph.transform = rotation(open: isOpen)
    }
  }

  private func rotation(open: Bool) -> CATransform3D {
    // (Clockwise: y goes up in the layer.)
    CATransform3DMakeRotation(open ? -.pi / 2 : 0, 0, 0, 1)
  }

  func turn(fromOpen wasOpen: Bool) {
    layoutSubtreeIfNeeded()
    let animation = Motion.basic("transform", duration: Motion.foldDuration, timing: CubicBezier.fold.timingFunction)
    animation.fromValue = rotation(open: wasOpen)
    animation.toValue = rotation(open: isOpen)
    glyph.add(animation, forKey: "glea.chevron")
  }
}

/// A group's name (renamed in place) and how many notes it has, with a ⋮
/// menu.
private final class GroupHeaderCell: NSTableCellView, NSTextFieldDelegate {
  static let identifier = NSUserInterfaceItemIdentifier("GroupHeaderCell")
  private let nameField = NSTextField.label("", size: 15, weight: .semibold)
  private let countLabel = NSTextField.label("", size: 12, color: Theme.tertiaryText)
  private let moreButton = IconButton(symbol: "ellipsis", size: 13, tooltip: "More", target: nil, action: nil)
  private lazy var editingWidth = nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
  var onMore: ((NSView) -> Void)?
  /// Renaming ended: the new name, or nil if it was canceled.
  var onRename: ((String?) -> Void)?
  private var original = ""
  private var canceled = false

  init() {
    super.init(frame: .zero)
    identifier = GroupHeaderCell.identifier
    for view in [nameField, countLabel, moreButton] { addSubview(view) }
    nameField.delegate = self
    nameField.focusRingType = .none
    nameField.lineBreakMode = .byTruncatingTail
    nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    moreButton.setSymbolImage(NoteCell.verticalEllipsis)
    moreButton.restingTint = Theme.tertiaryText
    moreButton.target = self
    moreButton.action = #selector(showMore)
    NSLayoutConstraint.activate([
      nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      nameField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: GroupRowView.drop),
      nameField.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),
      countLabel.firstBaselineAnchor.constraint(equalTo: nameField.firstBaselineAnchor),
      countLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -16),
      moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      moreButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
    ])
    countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func showMore() { onMore?(moreButton) }

  func configure(name: String, count: Int, hasMenu: Bool) {
    nameField.stringValue = name
    countLabel.stringValue = "\(count)"
    moreButton.isHidden = !hasMenu
  }

  var isRenaming: Bool { nameField.isEditable }

  func cancelRenaming() {
    guard nameField.isEditable else { return }
    canceled = true
    nameField.stringValue = original
    window?.makeFirstResponder(nil)
  }

  func beginRenaming() {
    original = nameField.stringValue
    canceled = false
    nameField.isEditable = true
    nameField.isSelectable = true
    editingWidth.isActive = true
    window?.makeFirstResponder(nameField)
    nameField.currentEditor()?.selectAll(nil)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      canceled = true
      nameField.stringValue = original
      window?.makeFirstResponder(nil)
      return true
    }
    if selector == #selector(NSResponder.insertNewline(_:)) {
      window?.makeFirstResponder(nil)
      return true
    }
    return false
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard nameField.isEditable else { return }
    nameField.isEditable = false
    nameField.isSelectable = false
    editingWidth.isActive = false
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    onRename?(canceled || name.isEmpty ? nil : name)
  }
}

/// What an empty group shows: where to drag notes.
private final class GroupPlaceholderCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("GroupPlaceholderCell")

  init() {
    super.init(frame: .zero)
    identifier = GroupPlaceholderCell.identifier
    let label = NSTextField.label("Drag a note here", size: 12.5, color: Theme.tertiaryText)
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }
}

private extension NSView {
  /// What the view shows (in `rect`), as an image.
  func picture(of rect: NSRect? = nil) -> NSImage {
    let rect = rect ?? bounds
    let image = NSImage(size: rect.size)
    if let rep = bitmapImageRepForCachingDisplay(in: rect) {
      cacheDisplay(in: rect, to: rep)
      image.addRepresentation(rep)
    }
    return image
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
