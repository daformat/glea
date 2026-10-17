import AppKit
import GleaBridge

/// A web link from a note, previewed without a tab (like Arc's Peek): the
/// page floats in a card over the dimmed notes, with its address and a few
/// buttons above it. The page is a real tab's browser, kept out of the tab
/// bar until "Open as Tab" moves it there as it is.
final class PeekView: NSView {
  static let cornerRadius: CGFloat = 12
  /// The page sits a hairline inside the card, whose border shows around it
  /// (the page is a window of its own, over anything drawn on the card).
  static let pageInset: CGFloat = 1
  static var pageCornerRadius: CGFloat { cornerRadius - pageInset }

  var onClose: (() -> Void)?
  var onOpenAsTab: (() -> Void)?
  var onCollect: (() -> Void)?
  var onCopyLink: (() -> Void)?

  /// Where the page's browser view goes (it fills it).
  let pageHost = NSView()
  private let dim = NSView()
  private let shadowHost = NSView()
  private let card = NSView()
  private let addressPill = PeekPill()
  private let buttonsPill = PeekPill()
  private let favicon = NSImageView()
  private let titleLabel = NSTextField.label("", size: 12.5, weight: .medium)
  private let hostLabel = NSTextField.label("", size: 12.5, color: Theme.secondaryText)
  private var isClosing = false
  private let address: NSStackView

  override init(frame frameRect: NSRect) {
    address = NSStackView()
    super.init(frame: frameRect)
    wantsLayer = true
    // Over everything else in the window, layers raised for their own
    // animations included (the top bar's, the note's buttons).
    layer?.zPosition = 1000
    autoresizingMask = [.width, .height]

    dim.wantsLayer = true
    addSubview(dim)

    shadowHost.wantsLayer = true
    shadowHost.shadow = NSShadow()
    shadowHost.layer?.shadowColor = NSColor.black.cgColor
    shadowHost.layer?.shadowOpacity = 0.28
    shadowHost.layer?.shadowRadius = 30
    shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -10)
    addSubview(shadowHost)
    card.wantsLayer = true
    card.layer?.cornerRadius = Self.cornerRadius
    card.layer?.cornerCurve = .continuous
    card.layer?.masksToBounds = true
    card.layer?.borderWidth = Self.pageInset
    card.autoresizingMask = [.width, .height]
    shadowHost.addSubview(card)
    pageHost.autoresizingMask = [.width, .height]
    card.addSubview(pageHost)

    favicon.imageScaling = .scaleProportionallyUpOrDown
    favicon.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.lineBreakMode = .byTruncatingTail
    hostLabel.lineBreakMode = .byTruncatingMiddle
    for label in [titleLabel, hostLabel] {
      label.translatesAutoresizingMaskIntoConstraints = false
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    hostLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(260), for: .horizontal)
    for view in [favicon, titleLabel, hostLabel] { address.addArrangedSubview(view) }
    address.orientation = .horizontal
    address.spacing = 7
    address.setCustomSpacing(8, after: favicon)
    address.translatesAutoresizingMaskIntoConstraints = false
    addressPill.addSubview(address)
    NSLayoutConstraint.activate([
      favicon.widthAnchor.constraint(equalToConstant: 16),
      favicon.heightAnchor.constraint(equalToConstant: 16),
      address.leadingAnchor.constraint(equalTo: addressPill.leadingAnchor, constant: 10),
      address.trailingAnchor.constraint(lessThanOrEqualTo: addressPill.trailingAnchor, constant: -12),
      address.centerYAnchor.constraint(equalTo: addressPill.centerYAnchor),
    ])
    addSubview(addressPill)

    let buttons = [
      IconButton(symbol: "macwindow.badge.plus", tooltip: "Open as Tab (⌘↩)", target: self, action: #selector(openAsTab)),
      IconButton(symbol: "tray.and.arrow.down", tooltip: "Collect Page (⌘S)", target: self, action: #selector(collect)),
      IconButton(symbol: "link", tooltip: "Copy Link", target: self, action: #selector(copyLink)),
      IconButton(symbol: "xmark", tooltip: "Close (esc)", target: self, action: #selector(close)),
    ]
    let row = NSStackView(views: buttons)
    row.orientation = .horizontal
    row.spacing = 2
    row.translatesAutoresizingMaskIntoConstraints = false
    buttonsPill.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: buttonsPill.leadingAnchor, constant: 3),
      row.trailingAnchor.constraint(equalTo: buttonsPill.trailingAnchor, constant: -3),
      row.centerYAnchor.constraint(equalTo: buttonsPill.centerYAnchor),
    ])
    addSubview(buttonsPill)
    updateColors()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  // MARK: Layout

  private static let pillHeight: CGFloat = 34
  private static let buttonsWidth: CGFloat = 4 * 28 + 3 * 2 + 6

  /// The pills' top: the card and its pills start under the top bar (which
  /// is dimmed with the rest).
  private static let pillTop: CGFloat = Theme.topBarHeight + 4

  /// Under the card: as much space as above the pills in a tall window,
  /// shrinking smoothly as the window gets shorter (down to its minimum
  /// height), so the page keeps its room.
  private var bottomGap: CGFloat {
    let (shortest, tall): (CGFloat, CGFloat) = (420, 800)
    let progress = min(max((bounds.height - shortest) / (tall - shortest), 0), 1)
    return 12 + (Self.pillTop - 12) * progress
  }

  /// The card: centered, at most 1100 points wide (the pills above it line
  /// up with its edges).
  private var cardRect: NSRect {
    let side = max(40, (bounds.width - 1100) / 2)
    let top: CGFloat = Self.pillTop + Self.pillHeight + 8
    return NSRect(x: side, y: top, width: max(320, bounds.width - 2 * side), height: max(0, bounds.height - top - bottomGap))
  }

  private func layoutPieces() {
    let rect = cardRect
    dim.frame = bounds
    shadowHost.frame = rect
    card.frame = shadowHost.bounds
    pageHost.frame = card.bounds.insetBy(dx: Self.pageInset, dy: Self.pageInset)
    buttonsPill.frame = NSRect(x: rect.maxX - Self.buttonsWidth, y: Self.pillTop, width: Self.buttonsWidth, height: Self.pillHeight)
    // As wide as the title and address, within what's left of the card's width.
    let addressWidth = min(address.fittingSize.width + 24, 560, max(120, rect.width - Self.buttonsWidth - 12))
    addressPill.frame = NSRect(x: rect.minX, y: Self.pillTop, width: addressWidth, height: Self.pillHeight)
    // The page is a window of its own over this view: follow the card when
    // only its origin changed (a wider window recenters it).
    for page in pageHost.subviews { page.setFrameOrigin(page.frame.origin) }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layoutPieces()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.25).cgColor
    card.layer?.backgroundColor = resolvedCGColor(Theme.background)
    card.layer?.borderColor = resolvedCGColor(Theme.separator)
  }

  // MARK: Content

  func setPage(title: String, host: String, favicon image: NSImage?) {
    let showsTitle = !title.isEmpty && title != host
    titleLabel.stringValue = title
    titleLabel.isHidden = !showsTitle
    hostLabel.stringValue = host
    layoutPieces()
    favicon.image = image ?? Theme.symbol("globe", size: 13)
    favicon.contentTintColor = image == nil ? Theme.secondaryText : nil
  }

  // MARK: Showing and hiding

  /// Springs the card out of `origin` (where the link was clicked, in this
  /// view's coordinates); `revealPage` runs once it has landed (the page
  /// is a window of its own, which can't follow the card's animation).
  func animateIn(from origin: NSPoint?, revealPage: @escaping () -> Void) {
    layoutPieces()
    guard !Motion.reduceMotion else { return revealPage() }
    let final = cardRect
    let start = origin ?? NSPoint(x: final.midX, y: final.midY)
    // From a small card around the click to its place: scaled about its
    // center, and moved there (layers of views in a flipped one have y
    // going down, like it).
    if let layer = shadowHost.layer {
      let dy = (start.y - final.midY) * (layer.superlayer?.isGeometryFlipped == true || isFlipped ? 1 : -1)
      let from = CATransform3DConcat(shadowHost.centeredScale(0.18), CATransform3DMakeTranslation(start.x - final.midX, dy, 0))
      let grow = Motion.spring("transform", stiffness: 340, damping: 30)
      grow.fromValue = from
      grow.toValue = CATransform3DIdentity
      layer.add(grow, forKey: "glea.peek.grow")
      let fade = Motion.basic("opacity", duration: 0.12, timing: Motion.easeOut)
      fade.fromValue = 0
      fade.toValue = 1
      layer.add(fade, forKey: "glea.peek.fade")
    }
    fadeIn(dim, duration: 0.18)
    for pill in [addressPill, buttonsPill] { pill.animateIn(scale: 0.96, offsetY: 4, fade: 0.16, duration: 0.24) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
      guard let self, !self.isClosing else { return }
      revealPage()
    }
  }

  /// Shrinks and fades the card away (the page already hidden), then
  /// removes the view.
  func animateOut(completion: @escaping () -> Void) {
    isClosing = true
    let finish = { [weak self] in
      self?.removeFromSuperview()
      completion()
    }
    guard !Motion.reduceMotion else { return finish() }
    for pill in [addressPill, buttonsPill] { pill.animateOut(scale: 0.96, offsetY: 4, fade: 0.1, duration: 0.16) {} }
    Motion.animate(0.18, timing: Motion.easeInOut) { dim.animator().alphaValue = 0 }
    shadowHost.animateOut(scale: 0.94, fade: 0.14, duration: 0.2, completion: finish)
  }

  private func fadeIn(_ view: NSView, duration: CFTimeInterval) {
    guard let layer = view.layer else { return }
    let fade = Motion.basic("opacity", duration: duration, timing: Motion.easeOut)
    fade.fromValue = 0
    fade.toValue = 1
    layer.add(fade, forKey: "glea.peek.fade")
  }

  // MARK: Events

  /// A click anywhere outside the card and its pills closes the peek.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isClosing else { return nil }
    return super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if !shadowHost.frame.contains(point) { onClose?() }
  }

  // Scrolling over the dimmed notes doesn't move them.
  override func scrollWheel(with event: NSEvent) {}

  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

  @objc private func openAsTab() { onOpenAsTab?() }
  @objc private func collect() { onCollect?() }
  @objc private func copyLink() { onCopyLink?() }
  @objc private func close() { onClose?() }
}

/// The rounded, page-colored backing of the peek's address and buttons.
private final class PeekPill: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    shadow = NSShadow()
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.12
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    updateColors()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    layer?.backgroundColor = resolvedCGColor(Theme.background)
    layer?.borderColor = resolvedCGColor(Theme.separator)
  }

  // Clicks between the buttons stay in the pill (they don't close the peek).
  override func mouseDown(with event: NSEvent) {}
}
