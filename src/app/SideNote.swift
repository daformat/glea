import AppKit

/// A note beside the page (View › Note Beside Page), for reading while
/// writing: a slim header, whose title picks another note and whose ×
/// closes it, over the note. Its left edge drags to resize it.
///
/// The note is laid out at `contentWidth` from its left edge, which may be
/// wider than the view for a moment: while it slides in or out, or its edge
/// is dragged, only the page beside it reflows on every frame.
final class SideNoteView: NSView {
  static let defaultWidth: CGFloat = 440
  static let minWidth: CGFloat = 320
  static let headerHeight: CGFloat = 38

  let noteView = NoteView()
  var onPick: (() -> Void)?
  var onClose: (() -> Void)?
  /// The left edge dragged by `delta` points since it was pressed (`ended`:
  /// let go).
  var onResize: ((_ delta: CGFloat, _ ended: Bool) -> Void)?

  /// How wide the note is laid out.
  var contentWidth: CGFloat {
    get { contentWidthConstraint.constant }
    set {
      guard contentWidthConstraint.constant != newValue else { return }
      // (Reflowed now, the text at the top of the view staying there.)
      noteView.keepingTopLine {
        contentWidthConstraint.constant = newValue
        layoutSubtreeIfNeeded()
      }
    }
  }

  private let content = NSView()
  private lazy var contentWidthConstraint = content.widthAnchor.constraint(equalToConstant: Self.defaultWidth)
  private let header = NSView()
  private let titleButton = SideNoteTitleButton()
  private lazy var closeButton = IconButton(symbol: "xmark", size: 11, tooltip: "Close Note (⇧⌘D)", target: self, action: #selector(close))
  private let edge = SideNoteEdge()
  private let separator = NSView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    for view in [header, noteView] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    for view in [separator, edge] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(titleButton)
    header.addSubview(closeButton)
    titleButton.onClick = { [weak self] in self?.onPick?() }
    separator.wantsLayer = true
    edge.onDrag = { [weak self] delta, ended in self?.onResize?(delta, ended) }
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentWidthConstraint,
      header.topAnchor.constraint(equalTo: content.topAnchor),
      header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
      titleButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
      titleButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      titleButton.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
      closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
      closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      noteView.topAnchor.constraint(equalTo: header.bottomAnchor),
      noteView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      noteView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      noteView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      separator.topAnchor.constraint(equalTo: topAnchor),
      separator.bottomAnchor.constraint(equalTo: bottomAnchor),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.widthAnchor.constraint(equalToConstant: 1),
      edge.topAnchor.constraint(equalTo: topAnchor),
      edge.bottomAnchor.constraint(equalTo: bottomAnchor),
      edge.leadingAnchor.constraint(equalTo: leadingAnchor),
      edge.widthAnchor.constraint(equalToConstant: 6),
    ])
    updateColors()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The hairline on its left: none when the page is a card beside it.
  var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }

  func show(_ ref: NoteRef) {
    noteView.show(ref)
    titleButton.title = ref.kind == .journal ? ref.displayTitle : ref.name
  }

  @objc private func close() { onClose?() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = Theme.background.cgColor
      separator.layer?.backgroundColor = Theme.separator.cgColor
    }
  }
}

/// The side note's title, with a chevron: a click picks another note.
private final class SideNoteTitleButton: NSView {
  var onClick: (() -> Void)?
  var title: String {
    get { label.stringValue }
    set {
      label.stringValue = newValue
      setAccessibilityLabel("\(newValue), choose another note")
    }
  }

  private let label = NSTextField.label("", size: 13, weight: .semibold, color: Theme.secondaryText)
  private let chevron = NSImageView(image: Theme.symbol("chevron.down", size: 9, weight: .semibold) ?? NSImage())

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    chevron.contentTintColor = Theme.tertiaryText
    for view in [label, chevron] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
      chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
      chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor, constant: 1),
      chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
    ])
    HoverView.track(self) { [weak self] hovering in
      self?.label.textColor = hovering ? Theme.text : Theme.secondaryText
      self?.chevron.contentTintColor = hovering ? Theme.secondaryText : Theme.tertiaryText
    }
    setAccessibilityRole(.popUpButton)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)), let onClick { DispatchQueue.main.async { onClick() } }
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}

/// The side note's left edge: drags to resize it, and lights up while the
/// pointer is on it (like the vertical tabs' sidebar edge).
private final class SideNoteEdge: NSView {
  /// How far the pointer moved since the press, and whether it let go.
  var onDrag: ((CGFloat, Bool) -> Void)?
  private var startX: CGFloat = 0
  /// Pressed here (a release alone resizes nothing).
  private var resizing = false
  private var hovering = false
  private let line = CALayer()
  private var tracking: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    line.opacity = 0
    layer?.addSublayer(line)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }

  // The resize cursor from the tracking area (cursor rects aren't
  // refreshed reliably over the page's window), kept while dragging.
  override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

  override func layout() {
    super.layout()
    Motion.withoutAnimation {
      line.frame = NSRect(x: 0, y: 0, width: 2, height: bounds.height)
      line.cornerRadius = 1
      line.backgroundColor = resolvedCGColor(Theme.tertiaryText)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsLayout = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                              owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    NSCursor.resizeLeftRight.set()
    showLine(true)
    // Coming from the page: its cursor (set by Chromium, after a delay) may
    // still land once the pointer is here.
    for delay in [0.05, 0.15, 0.3] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, self.hovering || self.resizing else { return }
        NSCursor.resizeLeftRight.set()
      }
    }
  }

  override func mouseMoved(with event: NSEvent) {
    if hovering { NSCursor.resizeLeftRight.set() }
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    guard !resizing else { return }
    NSCursor.arrow.set()
    showLine(false)
  }

  private func showLine(_ shown: Bool) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.15)
    line.opacity = shown ? 1 : 0
    CATransaction.commit()
  }

  override func mouseDown(with event: NSEvent) {
    resizing = true
    startX = event.locationInWindow.x
  }

  override func mouseDragged(with event: NSEvent) {
    guard resizing else { return }
    NSCursor.resizeLeftRight.set()
    onDrag?(event.locationInWindow.x - startX, false)
  }

  override func mouseUp(with event: NSEvent) {
    guard resizing else { return }
    resizing = false
    onDrag?(event.locationInWindow.x - startX, true)
    // (The edge moved with the drag: under the pointer or not now.)
    if !bounds.contains(convert(event.locationInWindow, from: nil)) {
      hovering = false
      NSCursor.arrow.set()
      showLine(false)
    }
  }
}
