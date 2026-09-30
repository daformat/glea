import AppKit

// The slash menu: typing "/" at the start of a line or after a space offers
// the blocks a note can have. Typing on filters it, ↑/↓ move through it,
// Return or Tab (or a click) turns what was typed into the chosen block, and
// Esc closes it, leaving the text as it is.
//
// The same menu, opened by "[[", offers the notes to link to.

struct SlashItem {
  let title: String
  /// Other words it's found by.
  let keywords: [String]
  let symbol: String
  /// Its Markdown, shown faded.
  let hint: String
  let apply: @MainActor (MarkdownTextView) -> Void

  @MainActor static let all: [SlashItem] = [
    lineItem("Heading 1", ["h1", "title"], "textformat.size.larger", "# "),
    lineItem("Heading 2", ["h2", "subtitle"], "textformat.size", "## "),
    lineItem("Heading 3", ["h3"], "textformat.size.smaller", "### "),
    lineItem("Bulleted List", ["ul", "bullet", "unordered"], "list.bullet", "- "),
    lineItem("Numbered List", ["ol", "ordered", "number"], "list.number", "1. "),
    lineItem("To-do List", ["todo", "task", "checkbox", "check"], "checklist", "- [ ] "),
    lineItem("Quote", ["blockquote", "citation"], "text.quote", "> "),
    SlashItem(title: "Code Block", keywords: ["code", "snippet", "fence"], symbol: "chevron.left.forwardslash.chevron.right",
              hint: "```", apply: { $0.insertCodeBlock() }),
    SlashItem(title: "Table", keywords: ["grid"], symbol: "tablecells", hint: "| |", apply: { $0.insertTable() }),
    SlashItem(title: "Divider", keywords: ["hr", "rule", "line", "separator"], symbol: "minus", hint: "---",
              apply: { $0.insertDivider() }),
    SlashItem(title: "Link", keywords: ["url", "web"], symbol: "link", hint: "[ ]( )", apply: { $0.insertLink() }),
    SlashItem(title: "Link to Note", keywords: ["note", "wiki", "page", "mention"], symbol: "doc.text", hint: "[[ ]]",
              apply: { $0.insertText("[[", replacementRange: $0.selectedRange()) }),
  ]

  /// Turns the line into a `prefix` line (whatever prefix it had before).
  @MainActor private static func lineItem(_ title: String, _ keywords: [String], _ symbol: String, _ prefix: String) -> SlashItem {
    SlashItem(title: title, keywords: keywords, symbol: symbol, hint: prefix.trimmingCharacters(in: .whitespaces)) { textView in
      let s = textView.string as NSString
      let line = s.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
      if s.substring(with: line).trimmingCharacters(in: .newlines).isEmpty {
        // (Toggling counts an empty line as already having the prefix.)
        textView.replace(NSRange(location: line.location, length: 0), with: prefix,
                         select: NSRange(location: line.location + (prefix as NSString).length, length: 0))
        return
      }
      if !textView.linePrefixActive(prefix) { textView.toggleLinePrefix(prefix) }
      let changed = (textView.string as NSString).lineRange(for: NSRange(location: line.location, length: 0))
      let text = (textView.string as NSString).substring(with: changed)
      textView.setSelectedRange(NSRange(location: changed.location + (text.trimmingCharacters(in: .newlines) as NSString).length, length: 0))
    }
  }

  /// Notes whose name starts with `query` first, then those containing it,
  /// and a new note named `query` when none is called that. Choosing one
  /// completes the link ("[[query" → "[[Name]]").
  @MainActor static func notes(_ query: String, names: [String]) -> [SlashItem] {
    let wanted = query.trimmingCharacters(in: .whitespaces)
    let lower = wanted.lowercased()
    let starting = names.filter { lower.isEmpty || $0.lowercased().hasPrefix(lower) }
    let containing = lower.isEmpty ? [] : names.filter { !$0.lowercased().hasPrefix(lower) && $0.lowercased().contains(lower) }
    var items = (starting + containing).prefix(8).map { name in
      SlashItem(title: name, keywords: [], symbol: "doc.text", hint: "", apply: { $0.completeNoteLink(name) })
    }
    if !wanted.isEmpty, !NoteStore.shared.hasNote(named: wanted) {
      items.append(SlashItem(title: wanted, keywords: [], symbol: "plus", hint: "new note", apply: { $0.completeNoteLink(wanted) }))
    }
    return items
  }

  /// The items `query` finds: those whose title or a keyword starts with it
  /// first, then those containing it.
  @MainActor static func matching(_ query: String) -> [SlashItem] {
    let query = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return all }
    func words(_ item: SlashItem) -> [String] {
      [item.title.lowercased()] + item.title.lowercased().split(separator: " ").map(String.init) + item.keywords
    }
    let starting = all.filter { words($0).contains { $0.hasPrefix(query) } }
    let containing = all.filter { item in !starting.contains { $0.title == item.title } && words(item).contains { $0.contains(query) } }
    return starting + containing
  }
}

extension MarkdownTextView {
  /// Writes `name` at the cursor (just after "[["), and closes the link:
  /// the cursor goes after "]]", which is added unless it's already there.
  func completeNoteLink(_ name: String) {
    let location = selectedRange().location
    let s = string as NSString
    let closed = location + 2 <= s.length && s.substring(with: NSRange(location: location, length: 2)) == "]]"
    let text = closed ? name : name + "]]"
    replace(NSRange(location: location, length: 0), with: text,
            select: NSRange(location: location + (name as NSString).length + 2, length: 0))
  }

  /// A fenced code block at the cursor, with the cursor inside it.
  func insertCodeBlock() {
    let s = string as NSString
    let location = selectedRange().location
    let lineStart = s.lineRange(for: NSRange(location: location, length: 0)).location
    let before = location == lineStart ? "" : "\n"
    let after = location < s.length && s.character(at: location) != 0x0A ? "\n" : ""
    let block = before + "```\n\n```" + after
    replace(NSRange(location: location, length: 0), with: block,
            select: NSRange(location: location + (before as NSString).length + 4, length: 0))
  }

  /// A horizontal rule on its own line, below a blank line (otherwise the
  /// text above would become a heading), and the cursor on the line after it.
  func insertDivider() {
    let s = string as NSString
    let location = selectedRange().location
    let lineStart = s.lineRange(for: NSRange(location: location, length: 0)).location
    var before = ""
    if location > lineStart {
      before = "\n\n"
    } else if lineStart > 0 {
      let above = s.lineRange(for: NSRange(location: lineStart - 1, length: 0))
      if !s.substring(with: above).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { before = "\n" }
    }
    let after = location < s.length && s.character(at: location) == 0x0A ? "" : "\n"
    let caret = location + (before as NSString).length + 4
    replace(NSRange(location: location, length: 0), with: before + "---" + after, select: NSRange(location: caret, length: 0))
  }
}

/// The menu's state for one text view: where the "/" (or "[[") is, what it
/// matches, and the panel showing it.
@MainActor
final class SlashMenu {
  enum Kind {
    /// "/": the blocks a note can have.
    case blocks
    /// "[[": the notes to link to.
    case noteLink
  }

  private unowned let textView: MarkdownTextView
  private let kind: Kind
  /// What opens it.
  private var trigger: String { kind == .blocks ? "/" : "[[" }
  /// Where the trigger is, while the menu is open (it may have no matches,
  /// and then shows nothing until typing finds some again).
  private var start: Int?
  private var items: [SlashItem] = []
  private var selected = 0
  private var panel: SlashMenuPanel?
  private var observers: [NSObjectProtocol] = []

  init(textView: MarkdownTextView, kind: Kind) {
    self.textView = textView
    self.kind = kind
  }

  var isOpen: Bool { start != nil }

  func textDidChange() {
    if isOpen {
      update()
      return
    }
    let caret = textView.selectedRange()
    let s = textView.string as NSString
    let length = (trigger as NSString).length
    guard caret.length == 0, caret.location >= length, caret.location <= s.length,
          s.substring(with: NSRange(location: caret.location - length, length: length)) == trigger else { return }
    // A "/" at the start of a line or after a space (not in a URL); "[["
    // anywhere. Neither in a code block.
    if kind == .blocks, caret.location >= 2 {
      let before = s.character(at: caret.location - 2)
      guard before == 0x20 || before == 0x09 || before == 0x0A else { return }
    }
    guard !isInCodeBlock(caret.location - length) else { return }
    start = caret.location - length
    update()
  }

  /// Opens it on a trigger typed earlier (Esc inside "[[…").
  func open(at location: Int) {
    close()
    start = location
    update()
  }

  func selectionDidChange() {
    if isOpen { update() }
  }

  /// Keys while the menu shows: ↑/↓ move, Return/Tab choose, Esc closes.
  func handle(_ selector: Selector) -> Bool {
    guard isOpen else { return false }
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      close()
      return true
    }
    guard !items.isEmpty else { return false }
    switch selector {
    case #selector(NSResponder.moveDown(_:)):
      select((selected + 1) % items.count)
    case #selector(NSResponder.moveUp(_:)):
      select((selected - 1 + items.count) % items.count)
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
      choose(selected)
    default:
      return false
    }
    return true
  }

  func close() {
    start = nil
    items = []
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let panel {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
  }

  private func update() {
    guard let start else { return }
    let s = textView.string as NSString
    let caret = textView.selectedRange()
    let length = (trigger as NSString).length
    guard caret.length == 0, caret.location >= start + length, start + length <= s.length,
          s.substring(with: NSRange(location: start, length: length)) == trigger else { return close() }
    let query = s.substring(with: NSRange(location: start + length, length: caret.location - start - length))
    switch kind {
    case .blocks:
      // Past a line, a space right after the "/", or a long run: just text.
      guard caret.location > start, !query.contains("\n"), !query.hasPrefix(" "), (query as NSString).length <= 24 else { return close() }
      let matches = SlashItem.matching(query)
      if matches.isEmpty && query.hasSuffix(" ") { return close() }
      items = matches
    case .noteLink:
      // Past the line or the link's end: done.
      guard !query.contains("\n"), !query.contains("]"), (query as NSString).length <= 120 else { return close() }
      items = SlashItem.notes(query, names: textView.noteNames())
    }
    selected = 0
    if items.isEmpty { hidePanel() } else { showPanel() }
  }

  private func select(_ index: Int) {
    selected = index
    panel?.menuView.selected = index
  }

  /// Replaces the "/" and what follows with the item's block, or what follows
  /// "[[" with the note's name, as one undo step.
  private func choose(_ index: Int) {
    guard let start, items.indices.contains(index) else { return }
    let item = items[index]
    // "/" goes with the query; "[[" stays.
    let from = kind == .blocks ? start : start + (trigger as NSString).length
    let range = NSRange(location: from, length: textView.selectedRange().location - from)
    close()
    textView.breakUndoCoalescing()
    let undo = textView.undoManager
    undo?.beginUndoGrouping()
    textView.replace(range, with: "", select: NSRange(location: from, length: 0))
    item.apply(textView)
    undo?.endUndoGrouping()
    undo?.setActionName(kind == .blocks ? item.title : "Link to Note")
  }

  private func isInCodeBlock(_ location: Int) -> Bool {
    let before = (textView.string as NSString).substring(to: location)
    let fences = before.components(separatedBy: "\n").filter {
      let line = $0.trimmingCharacters(in: .whitespaces)
      return line.hasPrefix("```") || line.hasPrefix("~~~")
    }
    return fences.count % 2 == 1
  }

  // MARK: Panel

  private func showPanel() {
    guard let window = textView.window, let start else { return }
    let panel = self.panel ?? SlashMenuPanel()
    self.panel = panel
    panel.appearance = window.effectiveAppearance
    panel.menuView.items = items
    panel.menuView.selected = selected
    panel.menuView.onHover = { [weak self] index in self?.select(index) }
    panel.menuView.onChoose = { [weak self] index in self?.choose(index) }
    let size = panel.menuView.fittingSize
    // Below the "/" or "[[" (above it when there's no room), its icons in line with it.
    let slash = textView.firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
    let screen = window.screen?.visibleFrame ?? .infinite
    var origin = NSPoint(x: slash.minX - SlashMenuView.padding - 6, y: slash.minY - 6 - size.height)
    if origin.y < screen.minY { origin.y = slash.maxY + 6 }
    origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
    let wasVisible = panel.isVisible
    // (The panel has room around the card for its shadow.)
    let margin = SlashMenuPanel.shadowMargin
    panel.setFrame(NSRect(x: origin.x - margin, y: origin.y - margin, width: size.width + margin * 2, height: size.height + margin * 2),
                   display: true)
    if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
    if !wasVisible {
      panel.orderFront(nil)
      panel.contentView?.animateIn(scale: 0.97, fade: 0.1, duration: 0.16, fromTopLeft: true)
    }
    guard observers.isEmpty else { return }
    // It follows the text as the page scrolls, and closes when the window
    // loses focus.
    let center = NotificationCenter.default
    if let clip = textView.enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { if self?.items.isEmpty == false { self?.showPanel() } }
      })
    }
    observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    })
  }

  private func hidePanel() {
    guard let panel else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }
}

/// A borderless panel that never takes focus (typing stays in the note). It
/// draws the card's shadow itself, so the shadow is rounded like the card and
/// scales and fades with it.
final class SlashMenuPanel: NSPanel {
  static let shadowMargin: CGFloat = 24
  let menuView = SlashMenuView()

  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    let container = SlashMenuContainer()
    container.card.addSubview(menuView)
    menuView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      menuView.leadingAnchor.constraint(equalTo: container.card.leadingAnchor),
      menuView.trailingAnchor.constraint(equalTo: container.card.trailingAnchor),
      menuView.topAnchor.constraint(equalTo: container.card.topAnchor),
      menuView.bottomAnchor.constraint(equalTo: container.card.bottomAnchor),
    ])
    contentView = container
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The card, inset for its shadow, and the shadow behind it.
private final class SlashMenuContainer: NSView {
  let card = SlashMenuCard()
  private let shadowView = NSView()
  private static let radius: CGFloat = 10

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    shadowView.wantsLayer = true
    for view in [shadowView, card] { addSubview(view) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let rect = bounds.insetBy(dx: SlashMenuPanel.shadowMargin, dy: SlashMenuPanel.shadowMargin)
    card.frame = rect
    shadowView.frame = rect
    guard let layer = shadowView.layer else { return }
    Motion.withoutAnimation {
      layer.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }
    updateShadow()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateShadow()
  }

  private func updateShadow() {
    guard let layer = shadowView.layer else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    Motion.withoutAnimation {
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = dark ? 0.5 : 0.14
      layer.shadowRadius = 12
      layer.shadowOffset = CGSize(width: 0, height: -4)
    }
  }
}

/// The menu's card: white with a hairline border in light mode, the system
/// menu material in dark mode. Rounded, material included.
private final class SlashMenuCard: NSView {
  private let material = NSVisualEffectView()
  private static let radius: CGFloat = 10

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = Self.radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    material.material = .menu
    material.state = .active
    // The material ignores its layer's corners: a mask rounds it.
    material.maskImage = Self.roundedMask
    material.frame = bounds
    material.autoresizingMask = [.width, .height]
    addSubview(material)
  }

  required init?(coder: NSCoder) { fatalError() }

  private static let roundedMask: NSImage = {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }()

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    material.isHidden = !dark
    layer?.backgroundColor = dark ? NSColor.clear.cgColor : NSColor.white.cgColor
    layer?.borderColor = dark ? NSColor.white.withAlphaComponent(0.1).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

/// The menu's rows: icon, title, and the Markdown it inserts.
final class SlashMenuView: NSView {
  static let padding: CGFloat = 5
  private static let rowHeight: CGFloat = 30
  private static let width: CGFloat = 250

  var items: [SlashItem] = [] {
    didSet {
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }
  var selected = 0 {
    didSet { needsDisplay = true }
  }
  var onHover: ((Int) -> Void)?
  var onChoose: ((Int) -> Void)?
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(width: Self.width, height: CGFloat(items.count) * Self.rowHeight + Self.padding * 2)
  }

  override var fittingSize: NSSize { intrinsicContentSize }

  private func rowRect(_ index: Int) -> NSRect {
    NSRect(x: Self.padding, y: Self.padding + CGFloat(index) * Self.rowHeight, width: bounds.width - Self.padding * 2, height: Self.rowHeight)
  }

  private func row(at point: NSPoint) -> Int? {
    items.indices.first { rowRect($0).contains(point) }
  }

  override func draw(_ dirtyRect: NSRect) {
    for (index, item) in items.enumerated() {
      let rect = rowRect(index)
      if index == selected {
        Theme.selected.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
      }
      let color = index == selected ? Theme.text : Theme.secondaryText
      if let icon = Theme.symbol(item.symbol, size: 13) {
        let tinted = icon.withSymbolConfiguration(.init(paletteColors: [color])) ?? icon
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.minX + 8 + (18 - size.width) / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      }
      let hint = NSAttributedString(string: item.hint, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
        .foregroundColor: index == selected ? Theme.secondaryText : Theme.tertiaryText,
      ])
      let hintSize = hint.size()
      hint.draw(at: NSPoint(x: rect.maxX - 10 - hintSize.width, y: rect.midY - hintSize.height / 2))
      // Long titles (note names) end in "…" before the hint.
      let truncating = NSMutableParagraphStyle()
      truncating.lineBreakMode = .byTruncatingTail
      let title = NSAttributedString(string: item.title, attributes: [
        .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: Theme.text, .paragraphStyle: truncating,
      ])
      let titleHeight = title.size().height
      let titleWidth = rect.maxX - 10 - (hintSize.width > 0 ? hintSize.width + 12 : 0) - (rect.minX + 34)
      title.draw(with: NSRect(x: rect.minX + 34, y: rect.midY - titleHeight / 2, width: max(0, titleWidth), height: titleHeight),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseMoved(with event: NSEvent) {
    if let index = row(at: convert(event.locationInWindow, from: nil)), index != selected { onHover?(index) }
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if let index = row(at: convert(event.locationInWindow, from: nil)) { onChoose?(index) }
  }
}
