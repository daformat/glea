import AppKit

/// Full-window layer that hosts a floating card and dismisses it when the
/// user clicks outside.
/// Opaque rounded card. (A vibrancy view can't sample Chromium's layers and
/// turns muddy grey over web pages.)
final class CardView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    Theme.background.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    Theme.separator.setStroke()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()
  }
}

class OverlayView: NSView {
  let card = CardView()
  var onDismiss: (() -> Void)?
  /// Flipped so the card hangs from its top edge: when the results change
  /// the height, only the bottom edge moves (a non-flipped host lays the
  /// card out from its bottom, which shifts the top while the height eases).
  private let shadowHost = FlippedView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]
    // Never fully transparent: where a transparent window is clear, macOS
    // skips it when recompositing a page animating beneath, which erased the
    // card's shadow over the page (static cards; a blinking caret hid it).
    // 1/255 black is invisible.
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0, alpha: 1.0 / 255).cgColor
    shadowHost.wantsLayer = true
    shadowHost.shadow = NSShadow()
    shadowHost.layer?.shadowColor = NSColor.black.cgColor
    updateShadow()
    addSubview(shadowHost)

    shadowHost.addSubview(card)
    card.pinEdges(to: shadowHost)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// A softer shadow in light mode: the card rests on a page (the start
  /// pages) rather than floating over one.
  var softLightShadow = false {
    didSet { updateShadow() }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateShadow()
  }

  private func updateShadow() {
    let soft = softLightShadow && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua
    shadowHost.layer?.shadowOpacity = soft ? 0.09 : 0.22
    shadowHost.layer?.shadowRadius = soft ? 18 : 24
    // (Its layer is flipped: positive is down.)
    shadowHost.layer?.shadowOffset = CGSize(width: 0, height: soft ? 6 : 8)
  }

  private var appeared = false

  /// The card's frame in this view's (flipped) coordinates. Changes after the
  /// card appeared spring into place.
  var cardFrame: NSRect {
    get { shadowHost.frame }
    set {
      guard newValue != shadowHost.frame else { return }
      if appeared && !shadowHost.frame.isEmpty {
        // Height follows the results: ease, no overshoot.
        Motion.animate(0.14, timing: Motion.easeOut) { shadowHost.animator().frame = newValue }
      } else {
        shadowHost.frame = newValue
      }
    }
  }

  /// Beam's omnibox entrance: a quick fade while scaling up from 96%.
  func animateAppear() {
    layoutSubtreeIfNeeded()
    shadowHost.animateIn(scale: appearScale, fade: 0.08, duration: 0.14, timing: Motion.easeOut)
    DispatchQueue.main.async { self.appeared = true }
  }

  /// Fades out while shrinking to 90%, then removes the overlay.
  func animateDismiss() {
    isDismissing = true
    shadowHost.animateOut(scale: dismissScale, fade: 0.1, duration: 0.25) { [weak self] in self?.removeFromSuperview() }
  }

  /// How much the card scales in and out (1: fade only).
  var appearScale: CGFloat { 0.96 }
  var dismissScale: CGFloat { 0.9 }

  /// Keeps the card (and its shadow) invisible until `animateAppear()`.
  func hideCardUntilAppear() {
    shadowHost.wantsLayer = true
    shadowHost.alphaValue = 0
  }

  func showCard() { shadowHost.alphaValue = 1 }

  private(set) var isDismissing = false

  override func hitTest(_ point: NSPoint) -> NSView? {
    isDismissing ? nil : super.hitTest(point)
  }

  override var isFlipped: Bool { true }

  override func mouseDown(with event: NSEvent) {
    if !shadowHost.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
  }

  // Swallow scrolling so pages underneath don't move.
  override func scrollWheel(with event: NSEvent) {}
}

/// A row in the omnibox or the capture panel.
struct PickerItem {
  enum Action {
    case open(url: String)
    case note(NoteRef)
    case tab(Int)
    case createNote(String)
  }

  var icon: String
  var title: String
  var subtitle: String
  var action: Action
  var image: NSImage? = nil
  /// Shows a pin toggle at the end of the row (extensions): pinned or not.
  var pinned: Bool? = nil
  /// A keyboard shortcut shown right-aligned at the end of the row ("⇧⌘↩").
  var shortcut: String? = nil
  /// A divider above the row (Beam's, before "Create Note").
  var dividerAbove = false
}

/// Search field + result list used by the omnibox and the capture panel.
final class PickerList: NSView, NSTableViewDataSource, NSTableViewDelegate {
  var items: [PickerItem] = [] {
    didSet {
      tableView.reloadData()
      if !items.isEmpty { select(min(max(selectedIndex, 0), items.count - 1)) }
    }
  }
  var onChoose: ((PickerItem) -> Void)?
  /// A row's pin toggle was clicked (the row isn't chosen).
  var onTogglePin: ((Int) -> Void)?
  let rowHeight: CGFloat

  private let tableView = NSTableView()
  private let highlight = NSView()
  private(set) var selectedIndex = 0

  init(rowHeight: CGFloat) {
    self.rowHeight = rowHeight
    super.init(frame: .zero)
    let column = NSTableColumn(identifier: .init("item"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = rowHeight
    tableView.intercellSpacing = .zero
    tableView.backgroundColor = .clear
    tableView.style = .plain
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(clicked)
    tableView.refusesFirstResponder = true
    tableView.selectionHighlightStyle = .none
    let hover = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    tableView.addTrackingArea(hover)
    highlight.wantsLayer = true
    highlight.layer?.cornerRadius = 8
    highlight.layer?.cornerCurve = .continuous
    tableView.addSubview(highlight, positioned: .below, relativeTo: nil)
    tableView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(tableResized), name: NSView.frameDidChangeNotification, object: tableView)
    let scroll = NSScrollView()
    scroll.documentView = tableView
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    addSubview(scroll)
    scroll.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { fatalError() }

  var selectedItem: PickerItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

  func select(_ index: Int) {
    guard !items.isEmpty else {
      highlight.isHidden = true
      return
    }
    selectedIndex = (index + items.count) % items.count
    tableView.selectRowIndexes([selectedIndex], byExtendingSelection: false)
    tableView.scrollRowToVisible(selectedIndex)
    moveHighlight(animated: true)
  }

  private func moveHighlight(animated: Bool) {
    guard items.indices.contains(selectedIndex) else { return }
    tableView.layoutSubtreeIfNeeded()
    let target = tableView.rect(ofRow: selectedIndex).insetBy(dx: 4, dy: 1)
    updateCellHighlights()
    highlight.layer?.backgroundColor = resolvedCGColor(Theme.accentWash)
    let wasHidden = highlight.isHidden || highlight.frame.isEmpty
    highlight.isHidden = false
    guard let layer = highlight.layer, animated, !wasHidden, window != nil, !Motion.reduceMotion else {
      highlight.layer?.removeAnimation(forKey: "glea.highlight.y")
      highlight.frame = target
      return
    }
    // The wash always hugs its row: its size and x snap, only the vertical
    // move springs (so a list that's still settling never shows it resizing).
    let fromY = (layer.presentation() ?? layer).position.y
    highlight.frame = target
    guard abs(fromY - layer.position.y) > 0.5 else {
      // Already there: drop a move just started elsewhere (selected, then
      // re-selected at once), which would still carry it away.
      layer.removeAnimation(forKey: "glea.highlight.y")
      return
    }
    let move = Motion.spring("position.y", stiffness: 600, damping: 42)
    move.fromValue = fromY
    move.toValue = layer.position.y
    layer.add(move, forKey: "glea.highlight.y")
  }

  override func layout() {
    super.layout()
    moveHighlight(animated: false)
  }

  /// The table can still resize after this view's layout (its column follows
  /// the clip view): keep the wash on the row.
  @objc private func tableResized() {
    guard !highlight.isHidden, items.indices.contains(selectedIndex) else { return }
    let target = tableView.rect(ofRow: selectedIndex).insetBy(dx: 4, dy: 1)
    if highlight.layer?.animation(forKey: "glea.highlight.y") != nil {
      // Mid-move: fix the size and x, let the move finish.
      highlight.frame = NSRect(x: target.minX, y: highlight.frame.minY, width: target.width, height: target.height)
    } else {
      highlight.frame = target
    }
  }

  func moveSelection(by delta: Int) { select(selectedIndex + delta) }

  override func mouseMoved(with event: NSEvent) {
    let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
    guard items.indices.contains(row), row != selectedIndex else { return }
    selectedIndex = row
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    moveHighlight(animated: true)
  }

  @objc private func clicked() {
    let row = tableView.clickedRow
    guard items.indices.contains(row) else { return }
    selectedIndex = row
    onChoose?(items[row])
  }

  /// Unpinned rows show their pin only while highlighted.
  private func updateCellHighlights() {
    tableView.enumerateAvailableRowViews { rowView, row in
      (rowView.view(atColumn: 0) as? PickerCell)?.isHighlighted = row == selectedIndex
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = PickerCell()
    cell.configure(items[row], compact: rowHeight < 40)
    cell.isHighlighted = row == selectedIndex
    cell.onTogglePin = { [weak self] in self?.onTogglePin?(row) }
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClearRowView() }

  func tableViewSelectionDidChange(_ notification: Notification) {
    if tableView.selectedRow >= 0, tableView.selectedRow != selectedIndex {
      selectedIndex = tableView.selectedRow
      moveHighlight(animated: true)
    }
  }
}

/// Row without its own selection drawing (the list draws a moving highlight).
private final class ClearRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {}
  override func drawBackground(in dirtyRect: NSRect) {}
}

private final class PickerCell: NSView {
  private let icon = NSImageView()
  private let titleLabel = NSTextField.label("", size: 14)
  private let subtitleLabel = NSTextField.label("", size: 12, color: Theme.secondaryText)

  init() {
    super.init(frame: .zero)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.contentTintColor = Theme.secondaryText
    icon.imageScaling = .scaleProportionallyDown
    for view in [icon, titleLabel, subtitleLabel] as [NSView] { addSubview(view) }
    titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    pinButton.isBordered = false
    pinButton.imagePosition = .imageOnly
    pinButton.target = self
    pinButton.action = #selector(togglePin)
    pinButton.isHidden = true
    pinButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(pinButton)
    shortcutLabel.alignment = .right
    shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
    shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
    shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    shortcutLabel.isHidden = true
    addSubview(shortcutLabel)
    divider.boxType = .custom
    divider.borderWidth = 0
    divider.fillColor = Theme.separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.isHidden = true
    addSubview(divider)
    NSLayoutConstraint.activate([
      shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -10),
      divider.topAnchor.constraint(equalTo: topAnchor),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      divider.heightAnchor.constraint(equalToConstant: 1),
    ])
    NSLayoutConstraint.activate([
      pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      pinButton.widthAnchor.constraint(equalToConstant: 24),
      pinButton.heightAnchor.constraint(equalToConstant: 24),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),
    ])
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 16),
      icon.heightAnchor.constraint(equalToConstant: 16),
      titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
      subtitleLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
      subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  var onTogglePin: (() -> Void)?
  var isHighlighted = false { didSet { updatePin() } }
  private let pinButton = NSButton()
  private let shortcutLabel = NSTextField.label("", size: 12, color: Theme.tertiaryText)
  private let divider = NSBox()
  private var pinned: Bool?

  @objc private func togglePin() { onTogglePin?() }

  private func updatePin() {
    guard let pinned else { pinButton.isHidden = true; return }
    pinButton.isHidden = false
    pinButton.image = Theme.symbol(pinned ? "pin.fill" : "pin", size: 12)
    pinButton.contentTintColor = pinned ? Theme.text : Theme.secondaryText
    pinButton.alphaValue = pinned || isHighlighted ? 1 : 0
    pinButton.toolTip = pinned ? "Unpin from the Toolbar" : "Pin to the Toolbar"
  }

  func configure(_ item: PickerItem, compact: Bool) {
    pinned = item.pinned
    updatePin()
    shortcutLabel.stringValue = item.shortcut ?? ""
    shortcutLabel.isHidden = item.shortcut == nil
    divider.isHidden = !item.dividerAbove
    icon.image = item.image ?? Theme.symbol(item.icon, size: 13)
    titleLabel.stringValue = item.title
    titleLabel.font = .systemFont(ofSize: compact ? 13 : 14, weight: .regular)
    subtitleLabel.stringValue = item.subtitle
  }
}

// MARK: - Omnibox

/// The central command bar: open URLs, search the web, jump to tabs, open or
/// create notes.
final class OmniboxView: OverlayView, NSTextFieldDelegate {
  enum Target {
    case newTab, currentTab
  }

  var onChoose: ((PickerItem, Target) -> Void)?
  var tabsProvider: () -> [Tab] = { [] }
  /// Incognito: no history (no completion, no visited pages) and nothing
  /// typed is sent for suggestions. Notes and tabs are there as usual.
  var isIncognito = false

  let target: Target
  /// Part of a page (the incognito window's) rather than floating over the
  /// window: the card stays at the top of this view and results drop down
  /// from it; clicks elsewhere go through, and Esc clears it.
  let isInline: Bool
  private let field = NSTextField()
  /// Between the field and the results: hidden without results (it would
  /// sit on the card's bottom edge).
  private let divider = NSBox()
  private let list = PickerList(rowHeight: 42)
  private var suggestionToken = 0
  private var suggestions: [String] = []
  private var suggestionWork: DispatchWorkItem?

  init(target: Target, initialText: String, inline: Bool = false) {
    self.target = target
    self.isInline = inline
    super.init(frame: .zero)
    softLightShadow = inline

    let searchIcon = NSImageView(image: Theme.symbol("magnifyingglass", size: 16) ?? NSImage())
    searchIcon.contentTintColor = Theme.tertiaryText
    searchIcon.translatesAutoresizingMaskIntoConstraints = false
    field.font = .systemFont(ofSize: 20)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.placeholderString = "Search the web, your notes and tabs, or type a URL"
    field.stringValue = initialText
    field.delegate = self
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.translatesAutoresizingMaskIntoConstraints = false
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    list.translatesAutoresizingMaskIntoConstraints = false
    list.onChoose = { [weak self] item in self?.choose(item) }

    for view in [searchIcon, field, divider, list] as [NSView] { card.addSubview(view) }
    NSLayoutConstraint.activate([
      searchIcon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
      searchIcon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
      field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12),
      field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
      field.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
      divider.topAnchor.constraint(equalTo: card.topAnchor, constant: 56),
      divider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      list.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
      list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
      list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
      list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  func activate() {
    lastTyped = field.stringValue
    rebuild()
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  /// Something is typed in the field.
  var hasText: Bool { !field.stringValue.isEmpty }

  /// Back to an empty field.
  func clear() {
    suggestionWork?.cancel()
    suggestionToken += 1
    suggestions = []
    completion = nil
    completionTitle.isHidden = true
    field.stringValue = ""
    lastTyped = ""
    rebuild()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if isInline, !cardFrame.contains(convert(point, from: superview)) { return nil }
    return super.hitTest(point)
  }

  override func layout() {
    super.layout()
    layoutCard()
    // The field's width follows the card's (window resizes): keep the
    // completion's title after the text and within the card.
    card.layoutSubtreeIfNeeded()
    updateCompletionTitle()
  }

  /// The result rows shown at most.
  static let visibleRows = 9

  /// Kept clear between the card and the window's bottom edge.
  static let bottomMargin: CGFloat = 24

  private func layoutCard() {
    let width = min(isInline ? 560 : 640, bounds.width - 48)
    let y = isInline ? 0 : min(110, bounds.height * 0.15)
    // Only whole rows, as many as fit above the margin (the list scrolls
    // to the others).
    let room = bounds.height - y - Self.bottomMargin - 57 - 12
    let fitting = max(0, Int((room / list.rowHeight).rounded(.down)))
    let rows = CGFloat(min(list.items.count, Self.visibleRows, fitting))
    let height = 57 + (rows > 0 ? rows * list.rowHeight + 12 : 0)
    divider.isHidden = rows == 0
    cardFrame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: y, width: width, height: height)
  }

  // MARK: Results

  /// What was typed: the field minus an inline completion.
  private var query: String {
    let text = completion.map { String(field.stringValue.dropLast($0.suffix.count)) } ?? field.stringValue
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The history address completing what was typed, shown selected after it.
  private var completion: (suffix: String, url: String, title: String)?
  /// Beam's " – Title" after the completed text, on the selection.
  private let completionTitle = NSTextField.label("", size: 20)
  /// The field's text (without completion) at the last change: shorter now
  /// means a deletion, which never completes.
  private var lastTyped = ""

  private func updateCompletion() {
    let typed = field.stringValue
    let isDeletion = typed.count <= lastTyped.count && lastTyped.lowercased().hasPrefix(typed.lowercased())
    lastTyped = typed
    completion = nil
    // All in this keystroke's pass, before anything draws (no flash of the
    // bare text or the title): the suggestion is appended to the editor's
    // text, selected, and its title placed.
    defer { updateCompletionTitle() }
    guard !isDeletion, !isIncognito, let editor = field.currentEditor() as? NSTextView, let storage = editor.textStorage,
          editor.selectedRange().location == (typed as NSString).length,
          let found = HistoryStore.shared.completion(for: typed) else { return }
    completion = found
    let start = storage.length
    storage.append(NSAttributedString(string: found.suffix, attributes: editor.typingAttributes))
    editor.setSelectedRange(NSRange(location: start, length: storage.length - start))
  }

  /// Shows " – Title" right after the text while a completion is selected.
  private func updateCompletionTitle() {
    guard let completion, !completion.title.isEmpty, let editor = field.currentEditor() as? NSTextView,
          editor.selectedRange().length > 0 else {
      completionTitle.isHidden = true
      return
    }
    if completionTitle.superview == nil {
      // Placed by frame (below), clipped to the field: not by Auto Layout,
      // which would size it to its whole text and run past the card.
      completionTitle.translatesAutoresizingMaskIntoConstraints = true
      completionTitle.wantsLayer = true
      completionTitle.lineBreakMode = .byTruncatingTail
      completionTitle.usesSingleLineMode = true
      completionTitle.cell?.truncatesLastVisibleLine = true
      card.addSubview(completionTitle)
    }
    completionTitle.stringValue = " – " + completion.title
    completionTitle.textColor = Theme.accent
    completionTitle.drawsBackground = true
    completionTitle.backgroundColor = editor.selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor
    // Right after the text's last glyph, on its baseline.
    guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container)
    let end = editor.convert(NSPoint(x: used.maxX + editor.textContainerOrigin.x, y: 0), to: card)
    let height = completionTitle.intrinsicContentSize.height
    let fieldFrame = field.frame
    // (Less the label's own 2pt text inset, so it joins the selection.)
    let x = end.x - 2
    let right = min(fieldFrame.maxX, card.bounds.maxX - 18)
    // As wide as its text, never past the field (it truncates there).
    let width = min(ceil(completionTitle.intrinsicContentSize.width), right - x)
    completionTitle.frame = NSRect(x: x, y: fieldFrame.midY - height / 2, width: max(0, width), height: height)
    completionTitle.isHidden = completionTitle.frame.width < 20
  }

  /// Keeps the completed text as typed (→, End, a click in the field).
  private func acceptCompletion() {
    guard completion != nil else { return }
    completion = nil
    completionTitle.isHidden = true
    lastTyped = field.stringValue
    rebuild()
  }

  /// ⌘ is held (not ⇧⌘): ↩ opens the result in a new tab.
  private var commandHeld = false
  private var openHint: String { commandHeld ? "Open in a new tab" : "Open" }
  private var modifierMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, modifierMonitor == nil {
      modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
        self?.modifiersChanged(event.modifierFlags)
        return event
      }
    } else if window == nil, let monitor = modifierMonitor {
      NSEvent.removeMonitor(monitor)
      modifierMonitor = nil
    }
  }

  private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
    let held = flags.contains(.command) && !flags.contains(.shift)
    guard held != commandHeld else { return }
    commandHeld = held
    // Same results and selection, other hints.
    rebuild(keepingSelection: true)
  }

  private func rebuild(keepingSelection: Bool = false) {
    let q = query
    var items: [PickerItem] = []
    let store = NoteStore.shared
    let tabs = tabsProvider()

    if q.isEmpty {
      for (index, tab) in tabs.enumerated().reversed().prefix(4) {
        items.append(PickerItem(icon: "square.on.square", title: tab.displayTitle, subtitle: "Switch to tab", action: .tab(index), image: tab.favicon))
      }
      items.append(PickerItem(icon: "calendar", title: "Today", subtitle: "Journal", action: .note(store.today)))
      for ref in store.notes.prefix(4) {
        items.append(PickerItem(icon: "doc.text", title: ref.name, subtitle: "Note", action: .note(ref)))
      }
    } else {
      // The inline completion comes first (and is selected).
      if let completion {
        let address = q + completion.suffix
        items.append(PickerItem(icon: "clock", title: completion.title.isEmpty ? address : completion.title,
                                subtitle: completion.title.isEmpty ? openHint : "\(openHint) · \(address)", action: .open(url: completion.url)))
      }
      // (While ⌘ is held, they say they open in a new tab.)
      let newTab = commandHeld ? " in a new tab" : ""
      if let url = OmniboxView.url(from: q) {
        items.append(PickerItem(icon: "globe", title: q, subtitle: openHint, action: .open(url: url)))
      } else {
        let engine = SearchEngine.current
        items.append(PickerItem(icon: "magnifyingglass", title: q, subtitle: "Search \(engine.name)\(newTab)", action: .open(url: engine.searchURL(q))))
      }
      for result in store.search(q, limit: 5) {
        let isJournal = result.ref.kind == .journal
        items.append(PickerItem(icon: isJournal ? "calendar" : "doc.text", title: result.ref.displayTitle,
                                subtitle: result.snippet, action: .note(result.ref)))
      }
      let lower = q.lowercased()
      for (index, tab) in tabs.enumerated() where tab.displayTitle.lowercased().contains(lower) || tab.url.lowercased().contains(lower) {
        items.append(PickerItem(icon: "square.on.square", title: tab.displayTitle, subtitle: "Switch to tab", action: .tab(index), image: tab.favicon))
      }
      let tabURLs = Set(tabs.map(\.url))
      for entry in isIncognito ? [] : HistoryStore.shared.search(q, limit: 5) where !tabURLs.contains(entry.url) && entry.url != completion?.url {
        items.append(PickerItem(icon: "clock", title: entry.title.isEmpty ? entry.url : entry.title,
                                subtitle: "\(openHint) · \(OmniboxView.shortURL(entry.url))", action: .open(url: entry.url)))
      }
      for suggestion in suggestions.filter({ $0.lowercased() != lower }).prefix(4) {
        items.append(PickerItem(icon: "magnifyingglass", title: suggestion, subtitle: "",
                                action: .open(url: SearchEngine.current.searchURL(suggestion))))
      }
      // Beam's "Create Note:" row, after a divider, kept visible at the
      // bottom (other results make room for it); not for an existing note.
      if !store.hasNote(named: q) {
        items = Array(items.prefix(Self.visibleRows - 1))
        items.append(PickerItem(icon: "plus.circle", title: "Create Note:", subtitle: q, action: .createNote(q),
                                shortcut: "⇧⌘↩", dividerAbove: true))
      }
    }
    let selected = list.selectedIndex
    list.items = items
    list.select(keepingSelection ? selected : 0)
    needsLayout = true
  }

  private func fetchSuggestions() {
    suggestionWork?.cancel()
    let q = query
    guard !q.isEmpty, !isIncognito, OmniboxView.url(from: q) == nil else {
      suggestions = []
      return
    }
    suggestionToken += 1
    let token = suggestionToken
    let work = DispatchWorkItem { [weak self] in
      SearchEngine.suggestions(for: q) { list in
        guard let self, token == self.suggestionToken else { return }
        self.suggestions = list
        let selected = self.list.selectedIndex
        self.rebuild()
        self.list.select(selected)
      }
    }
    suggestionWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
  }

  /// ⌘ held (⌘↩, ⌘-click): in a new tab, even when editing the current
  /// tab's address.
  private func choose(_ item: PickerItem) {
    let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
    onChoose?(item, command ? .newTab : target)
  }

  func controlTextDidChange(_ obj: Notification) {
    // Keep the previous suggestions until fresh ones arrive, so the list
    // (and the card's height) doesn't collapse and regrow on every key.
    updateCompletion()
    let q = query.lowercased()
    if q.isEmpty || OmniboxView.url(from: q) != nil { suggestions = [] }
    rebuild()
    fetchSuggestions()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    // The text system has no command for ⌘↩ or ⇧⌘↩: they arrive as noop.
    if selector == Selector(("noop:")), Self.isReturnKey(NSApp.currentEvent) {
      pressReturn()
      return true
    }
    switch selector {
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
      list.moveSelection(by: 1)
      return true
    case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
      list.moveSelection(by: -1)
      return true
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      // (⌥↩ is insertNewlineIgnoringFieldEditor in a text field: just Return.)
      pressReturn()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      // Esc first drops a completion, then closes (inline: clears, then
      // leaves the new tab page).
      if let completion {
        field.stringValue = String(field.stringValue.dropLast(completion.suffix.count))
        self.completion = nil
        completionTitle.isHidden = true
        lastTyped = field.stringValue
        rebuild()
      } else if isInline, hasText {
        clear()
      } else {
        onDismiss?()
      }
      return true
    case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
         #selector(NSResponder.moveToEndOfDocument(_:)):
      acceptCompletion()
      return false  // the caret still moves
    default:
      return false
    }
  }

  /// ↩ chooses the selected result (⌘↩: in a new tab); ⇧⌘↩ creates a note.
  private func pressReturn() {
    let flags = NSApp.currentEvent?.modifierFlags ?? []
    if flags.contains(.command), flags.contains(.shift), !query.isEmpty {
      choose(PickerItem(icon: "", title: "", subtitle: "", action: .createNote(query)))
    } else if let item = list.selectedItem {
      choose(item)
    }
  }

  /// Return or keypad Enter.
  private static func isReturnKey(_ event: NSEvent?) -> Bool {
    guard let event, event.type == .keyDown else { return false }
    return event.keyCode == 36 || event.keyCode == 76
  }

  // MARK: URL heuristics

  /// Returns a navigable URL if the text looks like one.
  static func url(from text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, !t.contains(" ") else { return nil }
    let lower = t.lowercased()
    for scheme in ["http://", "https://", "file://", "about:", "data:", "chrome://", "view-source:"] where lower.hasPrefix(scheme) {
      return t
    }
    if lower.hasPrefix("localhost") || lower.range(of: "^\\d{1,3}(\\.\\d{1,3}){3}(:\\d+)?(/.*)?$", options: .regularExpression) != nil {
      return "http://" + t
    }
    if lower.range(of: "^[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,}(:\\d+)?([/?#].*)?$", options: .regularExpression) != nil {
      return "https://" + t
    }
    return nil
  }

  static func shortURL(_ url: String) -> String {
    var s = url
    for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
    return s.count > 60 ? String(s.prefix(60)) + "…" : s
  }
}

// MARK: - Capture panel

/// Shown after a point-and-shoot click: pick the note that receives the capture.
final class CapturePanel: OverlayView, NSTextFieldDelegate {
  var onCollect: ((NoteRef) -> Void)?

  private let field = NSTextField()
  private let list = PickerList(rowHeight: 32)
  private let preview: NSTextField
  private let anchor: NSRect
  private let lastTarget: NoteRef?

  /// `anchor` is the captured element's rect in this view's coordinates.
  init(capture: Capture, anchor: NSRect, lastTarget: NoteRef?) {
    self.anchor = anchor
    self.lastTarget = lastTarget
    let text = capture.kind == .page ? capture.pageTitle : (capture.text.isEmpty ? capture.markdown : capture.text)
    preview = NSTextField(wrappingLabelWithString: Self.previewText(text))
    super.init(frame: .zero)

    let heading = NSTextField.label("Collect to", size: 11, weight: .semibold, color: Theme.tertiaryText)
    field.font = .systemFont(ofSize: 14)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.placeholderString = "Search notes…"
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    preview.font = .systemFont(ofSize: 12)
    preview.textColor = Theme.secondaryText
    preview.maximumNumberOfLines = 3
    preview.preferredMaxLayoutWidth = 312
    preview.lineBreakMode = .byTruncatingTail
    preview.translatesAutoresizingMaskIntoConstraints = false
    let hint = NSTextField.label("↩ Collect    esc Cancel", size: 11, color: Theme.tertiaryText)
    list.translatesAutoresizingMaskIntoConstraints = false
    list.onChoose = { [weak self] item in self?.choose(item) }

    for view in [heading, field, list, hint] as [NSView] { card.addSubview(view) }
    // Without words to preview, the list sits right above the hint.
    let hasPreview = !preview.stringValue.isEmpty
    if hasPreview {
      card.addSubview(preview)
      NSLayoutConstraint.activate([
        list.bottomAnchor.constraint(equalTo: preview.topAnchor, constant: -8),
        preview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
        preview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        preview.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxPreviewHeight),
        preview.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
      ])
    } else {
      list.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8).isActive = true
    }
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
      heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      field.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
      field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      list.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
      list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
      list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
      hint.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      hint.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  private static let maxPreviewHeight: CGFloat = 48

  /// The capture's words on flowing lines: Markdown list markers and line
  /// breaks go, and a capture without words (icons, images) shows none.
  private static func previewText(_ text: String) -> String {
    let words = text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .map { $0.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s*"#, with: "", options: .regularExpression) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return words.rangeOfCharacter(from: .alphanumerics) == nil ? "" : words
  }

  func activate() {
    rebuild()
    window?.makeFirstResponder(field)
  }

  override func layout() {
    super.layout()
    let rows = CGFloat(max(1, min(list.items.count, 6)))
    let previewHeight = preview.stringValue.isEmpty ? -8 : min(preview.intrinsicContentSize.height, Self.maxPreviewHeight)
    let size = NSSize(width: 340, height: 102 + rows * list.rowHeight + previewHeight)
    let margin: CGFloat = 12
    let top = Theme.topBarHeight + margin
    let fitsVertically = { (y: CGFloat) in y >= top && y + size.height <= self.bounds.height - margin }
    let clampY = { (y: CGFloat) in min(max(top, y), self.bounds.height - size.height - margin) }
    let clampX = { (x: CGFloat) in min(max(margin, x), self.bounds.width - size.width - margin) }
    var origin: NSPoint
    if fitsVertically(anchor.maxY + 10) {
      origin = NSPoint(x: clampX(anchor.minX), y: anchor.maxY + 10)
    } else if fitsVertically(anchor.minY - size.height - 10) {
      origin = NSPoint(x: clampX(anchor.minX), y: anchor.minY - size.height - 10)
    } else if anchor.maxX + 10 + size.width <= bounds.width - margin {
      origin = NSPoint(x: anchor.maxX + 10, y: clampY(anchor.minY))
    } else if anchor.minX - 10 - size.width >= margin {
      origin = NSPoint(x: anchor.minX - 10 - size.width, y: clampY(anchor.minY))
    } else {
      origin = NSPoint(x: bounds.width - size.width - margin * 2, y: top + margin)
    }
    cardFrame = NSRect(origin: origin, size: size)
  }

  private func rebuild() {
    let q = field.stringValue.trimmingCharacters(in: .whitespaces)
    let store = NoteStore.shared
    var refs: [NoteRef] = []
    if q.isEmpty {
      if let lastTarget, lastTarget != store.today, store.exists(lastTarget) { refs.append(lastTarget) }
      refs.insert(store.today, at: 0)
      refs += store.notes.filter { !refs.contains($0) }.prefix(4)
    } else {
      refs = store.search(q, limit: 5).map(\.ref)
      if "today".hasPrefix(q.lowercased()), !refs.contains(store.today) { refs.insert(store.today, at: 0) }
    }
    var items = refs.map { ref in
      PickerItem(icon: ref.kind == .journal ? "calendar" : "doc.text",
                 title: ref == store.today ? "Today’s journal" : ref.displayTitle,
                 subtitle: "", action: .note(ref))
    }
    if !q.isEmpty, store.resolve(linkName: q) == nil {
      items.append(PickerItem(icon: "plus.circle", title: "New note “\(q)”", subtitle: "", action: .createNote(q)))
    }
    list.items = items
    list.select(0)
    needsLayout = true
  }

  private func choose(_ item: PickerItem) {
    switch item.action {
    case .note(let ref): onCollect?(ref)
    case .createNote(let name): onCollect?(NoteStore.shared.createNote(named: name))
    default: break
    }
  }

  func controlTextDidChange(_ obj: Notification) { rebuild() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
      list.moveSelection(by: 1)
      return true
    case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
      list.moveSelection(by: -1)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      if let item = list.selectedItem { choose(item) }
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onDismiss?()
      return true
    default:
      return false
    }
  }
}
