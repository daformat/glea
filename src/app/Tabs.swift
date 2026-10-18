import AppKit

// MARK: - Tabs

/// Where the tabs go: along the top bar (the default), or down a sidebar
/// that runs the window's height (View > Vertical Tabs).
@MainActor
enum TabLayout {
  static let didChange = Notification.Name("app.glea.tabLayoutDidChange")

  private static var defaults: UserDefaults { AppDefaults.store }

  static var isVertical: Bool {
    get { defaults.bool(forKey: "verticalTabs") }
    set {
      guard newValue != isVertical else { return }
      defaults.set(newValue, forKey: "verticalTabs")
      NotificationCenter.default.post(name: didChange, object: nil)
    }
  }

  static let minSidebarWidth: CGFloat = 180
  static let maxSidebarWidth: CGFloat = 400

  /// The sidebar's width (dragged at its edge, remembered).
  static var sidebarWidth: CGFloat {
    get {
      let width = defaults.double(forKey: "sidebarWidth")
      return width > 0 ? min(max(width, minSidebarWidth), maxSidebarWidth) : 240
    }
    set { defaults.set(Double(min(max(newValue, minSidebarWidth), maxSidebarWidth).rounded()), forKey: "sidebarWidth") }
  }

  /// With vertical tabs, the page is a card on the sidebar's color: this
  /// far from the window's top, right and bottom, its corners this round.
  static let cardInset: CGFloat = 8
  static let cardRadius: CGFloat = 10

  /// Where a page starts in the window: below the top bar, or (the card's
  /// inset) at the top when the sidebar takes its place.
  static var pageTop: CGFloat { isVertical ? cardInset : Theme.topBarHeight }
}

/// The direction tabs run in: along the top bar, or down a sidebar. The
/// tabs' views are flipped, so "along" is x, or y from the top.
enum TabAxis {
  case horizontal, vertical

  /// A point's position along the axis.
  func main(_ point: NSPoint) -> CGFloat { self == .horizontal ? point.x : point.y }
  /// Its position across.
  func cross(_ point: NSPoint) -> CGFloat { self == .horizontal ? point.y : point.x }
  func minMain(_ rect: NSRect) -> CGFloat { self == .horizontal ? rect.minX : rect.minY }
  func maxMain(_ rect: NSRect) -> CGFloat { self == .horizontal ? rect.maxX : rect.maxY }
  func midMain(_ rect: NSRect) -> CGFloat { self == .horizontal ? rect.midX : rect.midY }
  /// A rect's extent along the axis.
  func length(_ rect: NSRect) -> CGFloat { self == .horizontal ? rect.width : rect.height }
  /// Its extent across.
  func thickness(_ rect: NSRect) -> CGFloat { self == .horizontal ? rect.height : rect.width }

  /// `length` long from `main` along the axis, `thickness` wide from `cross` across it.
  func rect(main: CGFloat, length: CGFloat, cross: CGFloat, thickness: CGFloat) -> NSRect {
    self == .horizontal
      ? NSRect(x: main, y: cross, width: length, height: thickness)
      : NSRect(x: cross, y: main, width: thickness, height: length)
  }

  /// `rect` moved along the axis to start at `main`, `length` long.
  func rect(_ rect: NSRect, main: CGFloat, length: CGFloat) -> NSRect {
    self.rect(main: main, length: length, cross: cross(rect.origin), thickness: thickness(rect))
  }
}

/// The web's tabs: pinned ones, then the others with their groups' capsules,
/// and the + button after them. Spans the bar it's in: draws nothing itself,
/// and lets clicks on empty space through to the bar.
final class TabsView: NSView {
  typealias TabInfo = TopBarView.TabInfo
  typealias GroupInfo = TopBarView.GroupInfo

  weak var delegate: TopBarDelegate?

  fileprivate lazy var newTabButton = IconButton(symbol: "plus", tooltip: "New Tab (⌘T)", target: self, action: #selector(newTab))
  private var pills: [ObjectIdentifier: TabPill] = [:]
  /// Clips and scrolls the tabs when they don't all fit (no scroll bar).
  private let tabStrip = TabStripView()
  /// Pinned tabs: icon-only, before the others, never scrolled away.
  private let pinnedStrip = PinnedStripView()
  /// Beam's line between the pinned tabs and the others.
  private let pinnedSeparator = PinnedSeparatorView()
  fileprivate var pinnedSeparatorHasPins = false
  /// Hairlines between neighboring tabs of the strip, keyed by the tab on
  /// their left, with the tab on their right.
  fileprivate var tabSeparators: [ObjectIdentifier: (view: PinnedSeparatorView, right: ObjectIdentifier)] = [:]
  private var order: [ObjectIdentifier] = []
  private var tabInfos: [ObjectIdentifier: TabInfo] = [:]
  private var groupInfos: [GroupInfo] = []
  private var capsules: [UUID: GroupCapsule] = [:]
  private var underlines: [UUID: GroupLineView] = [:]
  private var drag: TabDrag?
  private var lastDragEventTime: CFTimeInterval = 0
  /// How far the strip just scrolled, while laying out after it (mid-drag).
  private var scrollShift: CGFloat = 0
  /// Views just dropped (back in the strip): their spring starts where they are.
  private var releasedViews: [NSView] = []
  /// The width of unpinned tabs at the last layout.
  /// The widest a tab may be in the strip now (tabs are narrower when their
  /// title is short).
  private var stripTabWidth: CGFloat = 0
  /// Each strip tab's length in the last layout.
  private var stripTabLengths: [ObjectIdentifier: CGFloat] = [:]

  /// A tab's width for its title: never wider than its content (the icon,
  /// the title, a margin). The active tab, whose close button always shows,
  /// makes room for it; elsewhere the button, on hover, takes from the title.
  private func naturalTabWidth(_ id: ObjectIdentifier) -> CGFloat {
    let title = tabInfos[id]?.title ?? ""
    let text = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 4
    // The active tab has room for its close button, in notes mode too: the
    // (hidden) strip keeps its web layout, so switching back doesn't resize it.
    let trailing: CGFloat = id == activeID ? 24 : 9
    let natural = min(Theme.tabMaxWidth, 31 + text + trailing)
    return id == activeID ? max(Self.activeTabMinWidth, natural) : natural
  }

  /// The active tab is never narrower (room for its address on hover).
  static let activeTabMinWidth: CGFloat = 200

  /// The largest width tabs may take so they share `room` (water-filling:
  /// tabs narrower than their share leave the rest to the others).
  private static func sharedTabWidth(naturals: [CGFloat], room: CGFloat) -> CGFloat {
    var remaining = room
    var count = CGFloat(naturals.count)
    for natural in naturals.sorted() {
      let share = remaining / count
      if natural > share { return share }
      remaining -= natural
      count -= 1
    }
    return Theme.tabMaxWidth
  }
  /// Color the next new group gets (for the ⌥-drag preview).
  var nextGroupColor: NSColor = .systemBlue
  /// The capsule and underline previewing a group about to be created.
  private var previewCapsule: GroupCapsule?
  private var previewTarget: ObjectIdentifier?
  private let previewLine = CALayer()
  /// The bar's mode: tabs only drag, highlight and separate in the web.
  fileprivate var isWeb = false
  private(set) var activeID: ObjectIdentifier?
  private var activeTabShown: ObjectIdentifier?
  /// Where the tabs go in the bar, at the last layout.
  private var tabsStart: CGFloat = 0
  private var tabsEnd: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    pinnedStrip.wantsLayer = true
    for view in [pinnedStrip, pinnedSeparator, tabStrip, newTabButton] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(view)
    }
    tabStrip.onScroll = { [weak self] in
      guard let self else { return }
      self.relayout(animated: false)
      for pill in self.pills.values { pill.syncHoverWithPointer() }
      for capsule in self.capsules.values { capsule.syncHoverWithPointer() }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  /// Along the bar, or down a sidebar.
  var axis = TabAxis.horizontal {
    didSet {
      guard axis != oldValue else { return }
      tabStrip.axis = axis
      for pill in pills.values {
        pill.dragAxis = axis
        pill.sidebarStyle = axis == .vertical
      }
      for capsule in capsules.values { capsule.dragAxis = axis }
    }
  }

  /// Down a sidebar, tabs are rows this far from its sides.
  static let rowInset: CGFloat = 8

  /// Its extent across the axis (the bar's height, the sidebar's width).
  fileprivate var crossExtent: CGFloat { axis.thickness(bounds) }

  /// Where something `thickness` thick goes across the axis: centered in the
  /// bar; in a sidebar, from the inset, filling it when it's a row.
  fileprivate func across(_ thickness: CGFloat, fills: Bool = false) -> (cross: CGFloat, thickness: CGFloat) {
    switch axis {
    case .horizontal: return ((crossExtent - thickness) / 2, thickness)
    case .vertical: return (Self.rowInset, fills ? max(0, crossExtent - 2 * Self.rowInset) : thickness)
    }
  }

  /// A rect along the axis, placed across it by `across`.
  fileprivate func rect(main: CGFloat, length: CGFloat, across span: (cross: CGFloat, thickness: CGFloat)) -> NSRect {
    axis.rect(main: main, length: length, cross: span.cross, thickness: span.thickness)
  }

  /// Only its tabs and buttons take clicks.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  /// Shown in the web only (faded in and out by the bar).
  var webOnlyViews: [NSView] { [newTabButton, tabStrip, pinnedStrip, pinnedSeparator] }
  /// Faded while the window isn't focused.
  var dimmedViews: [NSView] { [tabStrip, pinnedStrip] }

  var isDragging: Bool { drag != nil }

  @objc private func newTab() { delegate?.topBarNewTab() }

  /// The tabs to show. Returns the tabs just added, and the tab to scroll
  /// into view (the active one when it changed or tabs were added).
  func update(tabs: [TabInfo], groups: [GroupInfo], activeID: ObjectIdentifier?, isWeb: Bool)
    -> (added: Set<ObjectIdentifier>, reveal: ObjectIdentifier?) {
    self.isWeb = isWeb
    self.activeID = activeID
    // Tabs keep their view across updates so they can animate.
    let ids = tabs.map(\.id)
    var added: Set<ObjectIdentifier> = []
    for info in tabs where pills[info.id] == nil {
      let pill = TabPill()
      let id = info.id
      pill.onSelect = { [weak self] in
        guard let self, let index = self.order.firstIndex(of: id) else { return }
        if id == self.activeID && self.isWeb {
          self.delegate?.topBarEditActiveTabAddress()
        } else {
          self.delegate?.topBarSelectTab(at: index)
        }
      }
      pill.onClose = { [weak self] in
        guard let self, let index = self.order.firstIndex(of: id) else { return }
        self.delegate?.topBarCloseTab(at: index)
      }
      pill.onMenu = { [weak self] in
        guard let self, let index = self.order.firstIndex(of: id) else { return nil }
        return self.delegate?.topBarMenu(forTabAt: index)
      }
      pill.onDrag = { [weak self] phase, event in self?.dragTab(id, phase: phase, event: event) }
      pill.onToggleMute = { [weak self] in
        guard let self, let index = self.order.firstIndex(of: id) else { return }
        self.delegate?.topBarToggleMute(at: index)
      }
      pill.onHoverChange = { [weak self] in self?.updatePinnedSeparator(animated: true) }
      pill.dragAxis = axis
      pill.sidebarStyle = axis == .vertical
      pills[info.id] = pill

      (info.isPinned ? pinnedStrip : tabStrip).addSubview(pill)
      added.insert(info.id)
    }
    for (id, pill) in pills where !ids.contains(id) {
      pills[id] = nil
      pill.animateOut(scale: 0.86, duration: 0.18) { pill.removeFromSuperview() }
    }
    let activeChanged = activeID != self.activeTabShown
    activeTabShown = activeID
    order = ids
    tabInfos = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    for info in tabs {
      guard let pill = pills[info.id] else { continue }
      // Pinning moves a pill between the two strips. (What's being dragged
      // stays over the bar until it's dropped.)
      let strip: NSView = info.isPinned ? pinnedStrip : tabStrip
      if pill.superview !== strip, !isDragged(info.id) {
        // Pinned ↔ not: a different shape, so it appears in place (the
        // layout sets its frame) rather than morphing across the bar.
        strip.addSubview(pill)
        pill.frame = .zero
        pill.needsAppear = true
      }
      pill.configure(title: info.title, url: info.url, favicon: info.favicon, isLoading: info.isLoading,
                     isActive: info.id == activeID, inWebMode: isWeb, pinned: info.isPinned, media: info.media)
    }
    updateGroups(groups)
    return (added, activeChanged || !added.isEmpty ? activeID : nil)
  }

  /// Lays the tabs out again where they were (mid-drag, scrolled).
  fileprivate func relayout(animated: Bool) {
    layoutTabs(from: tabsStart, to: tabsEnd, animated: animated, added: [], reveal: nil)
  }

  fileprivate func place(_ view: NSView, _ frame: NSRect, animated: Bool) {
    guard view.frame != frame else { return }
    if animated && !view.frame.isEmpty {
      let released = releasedViews.contains { $0 === view }
      // Scrolled mid-drag: what's in the strip moves with it at once (lagging
      // springs drift out of the strip's bounds, where AppKit stops drawing
      // their titles).
      let shift = view.superview !== tabStrip ? .zero
        : axis == .horizontal ? CGSize(width: -scrollShift, height: 0) : CGSize(width: 0, height: -scrollShift)
      view.springFrame(to: frame, stiffness: 420, damping: 34, fromCurrentFrame: released, shift: shift)
      if released { releasedViews.removeAll { $0 === view } }
    } else {
      // A spring still running would end on its old target, then jump.
      view.layer?.removeAnimation(forKey: "glea.spring.position")
      view.layer?.removeAnimation(forKey: "glea.spring.bounds")
      view.frame = frame
    }
  }
}

/// One tab in the strip: favicon, title and a close button on hover.
/// Holds the tab pills (and a sidebar's pinned extensions): clips them,
/// scrolls along its axis with the wheel or trackpad when they overflow, and
/// fades the clipped edges.
final class TabStripView: NSView {
  /// The bar sits in the window's title bar, where macOS drags the window
  /// from any view that doesn't claim its area (controls do, plain views
  /// don't), before the app even sees the press. Claim it: tabs drag tabs,
  /// and the bar drags the window from its empty space itself (mouseDown).
  @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

  var onScroll: (() -> Void)?
  var axis = TabAxis.horizontal {
    didSet {
      // (At once: implicitly animated, the fade swept across the tabs.)
      Motion.withoutAnimation {
        fade.startPoint = axis == .horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        fade.endPoint = axis == .horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
      }
      clampOffset()
      updateFade()
    }
  }
  /// The tabs' extent along the axis.
  var contentLength: CGFloat = 0 {
    didSet {
      // (Set on every layout: only a real change ends an overscroll.)
      guard contentLength != oldValue else { return }
      clampOffset()
      updateFade()
    }
  }
  /// Past the ends while rubber-banding.
  private(set) var scrollOffset: CGFloat = 0
  /// Where the fingers put the content, before resistance past the ends.
  private var rawOffset: CGFloat = 0
  /// Springing back to the end, through `peak` first when bouncing off it.
  private var bounce: (start: CFTimeInterval, from: CGFloat, peak: CGFloat?, to: CGFloat)?
  private var bounceTimer: Timer?
  /// Springing back ends the gesture: its remaining momentum is ignored.
  private var ignoresMomentum = false
  private let fade = CAGradientLayer()
  private let fadeWidth: CGFloat = 20

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  // Empty strip space behaves like the rest of the bar (drag, zoom).
  override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }

  /// Its own extent along the axis.
  private var length: CGFloat { axis.length(bounds) }
  private var maxOffset: CGFloat { max(0, contentLength - length) }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    guard changed else { return }
    clampOffset()
    updateFade()
  }

  private func clampOffset() {
    stopBounce()
    scrollOffset = min(max(0, scrollOffset), maxOffset)
    rawOffset = scrollOffset
  }

  override func scrollWheel(with event: NSEvent) {
    guard maxOffset > 0 || scrollOffset != 0 else { return super.scrollWheel(with: event) }
    // Sideways or vertical: both scroll a bar's tabs (a sidebar's only go
    // up and down).
    let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
    var delta = axis == .horizontal && abs(dx) > abs(dy) ? -dx : -dy
    // A mouse wheel stops at the ends.
    guard event.hasPreciseScrollingDeltas else {
      delta *= 12
      let previous = scrollOffset
      scrollOffset += delta
      clampOffset()
      if scrollOffset != previous { updateFade(); onScroll?() }
      return
    }
    // A trackpad rubber-bands past them, and springs back when let go.
    if event.phase == .began || event.phase == .mayBegin {
      stopBounce()
      ignoresMomentum = false
      rawOffset = raw(forDisplayed: scrollOffset)
    }
    let momentum = !event.momentumPhase.isEmpty
    if momentum && ignoresMomentum { return }
    // Momentum reaching an end bounces off it: a short overshoot with the
    // speed (capped), then back, and the rest of the momentum is dropped.
    if momentum, delta != 0, rawOffset + delta < 0 || rawOffset + delta > maxOffset {
      let edge: CGFloat = rawOffset + delta < 0 ? 0 : maxOffset
      let overshoot = min(24, abs(delta) * 1.5) * (delta < 0 ? -1 : 1)
      startBounce(peak: edge + overshoot, to: edge)
      return
    }
    if delta != 0 {
      rawOffset += delta
      setOffset(displayed(forRaw: rawOffset))
    }
    let letGo = event.phase == .ended || event.phase == .cancelled
      || event.momentumPhase == .ended || event.momentumPhase == .cancelled
    if letGo, scrollOffset < 0 || scrollOffset > maxOffset { startBounce() }
  }

  private func setOffset(_ offset: CGFloat) {
    guard offset != scrollOffset else { return }
    scrollOffset = offset
    updateFade()
    onScroll?()
  }

  // MARK: Rubber band

  /// AppKit's resistance curve (the farther past the end, the less it
  /// moves), flattening out at a short distance.
  private var rubberDimension: CGFloat { max(1, min(length, 70)) }
  private func rubber(_ x: CGFloat) -> CGFloat {
    let d = rubberDimension
    return (1 - 1 / (x * 0.55 / d + 1)) * d
  }
  private func unrubber(_ y: CGFloat) -> CGFloat {
    let d = rubberDimension
    return d / 0.55 * (1 / (1 - min(y / d, 0.99)) - 1)
  }
  private func displayed(forRaw raw: CGFloat) -> CGFloat {
    if raw < 0 { return -rubber(-raw) }
    if raw > maxOffset { return maxOffset + rubber(raw - maxOffset) }
    return raw
  }
  private func raw(forDisplayed offset: CGFloat) -> CGFloat {
    if offset < 0 { return -unrubber(-offset) }
    if offset > maxOffset { return maxOffset + unrubber(offset - maxOffset) }
    return offset
  }

  /// Springs back to `to` (by default the nearest end).
  private func startBounce(peak: CGFloat? = nil, to: CGFloat? = nil) {
    let target = to ?? min(max(0, scrollOffset), maxOffset)
    ignoresMomentum = true
    guard !Motion.reduceMotion else {
      rawOffset = target
      setOffset(target)
      return
    }
    bounce = (CACurrentMediaTime(), scrollOffset, peak, target)
    if bounceTimer == nil {
      let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.stepBounce() }
      }
      RunLoop.main.add(timer, forMode: .common)
      bounceTimer = timer
    }
    stepBounce()
  }

  private func stepBounce() {
    guard let bounce else { return }
    let elapsed = CACurrentMediaTime() - bounce.start
    let t: Double
    if let peak = bounce.peak {
      // Out to the peak (ease out), then back (ease in-out).
      let out = 0.09, back = 0.22
      if elapsed < out {
        let u = elapsed / out
        setOffset(bounce.from + (peak - bounce.from) * CGFloat(1 - pow(1 - u, 2)))
        return
      }
      t = min(1, (elapsed - out) / back)
      let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
      setOffset(peak + (bounce.to - peak) * CGFloat(e))
    } else {
      t = min(1, elapsed / 0.3)
      let e = 1 - pow(1 - t, 3)  // ease out
      setOffset(bounce.from + (bounce.to - bounce.from) * CGFloat(e))
    }
    if t >= 1 {
      rawOffset = bounce.to
      stopBounce()
    }
  }

  private func stopBounce() {
    bounceTimer?.invalidate()
    bounceTimer = nil
    bounce = nil
  }

  /// Scrolls by `delta` (clamped); returns whether it moved.
  @discardableResult
  func scroll(by delta: CGFloat) -> Bool {
    let previous = scrollOffset
    scrollOffset += delta
    clampOffset()
    guard scrollOffset != previous else { return false }
    updateFade()
    return true
  }

  /// Scrolls just enough to show the span [start, end] of the content.
  func reveal(from start: CGFloat, to end: CGFloat, animated _: Bool) {
    let previous = scrollOffset
    if start - fadeWidth < scrollOffset { scrollOffset = start - fadeWidth }
    if end + fadeWidth > scrollOffset + length { scrollOffset = end + fadeWidth - length }
    clampOffset()
    if scrollOffset != previous { updateFade() }
  }

  /// Eased fades on the sides that have hidden tabs.
  private func updateFade() {
    guard let layer else { return }
    Motion.withoutAnimation {
      guard maxOffset > 0, length > fadeWidth * 2 else {
        layer.mask = nil
        return
      }
      fade.frame = layer.bounds
      let edge = Double(fadeWidth / length)
      let steps = 6
      var colors: [CGColor] = []
      var locations: [NSNumber] = []
      let startHidden = scrollOffset > 0.5, endHidden = scrollOffset < maxOffset - 0.5
      for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let eased = t * t * (3 - 2 * t)
        colors.append(NSColor.black.withAlphaComponent(startHidden ? eased : 1).cgColor)
        locations.append(NSNumber(value: edge * Double(t)))
      }
      for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let eased = t * t * (3 - 2 * t)
        colors.append(NSColor.black.withAlphaComponent(endHidden ? 1 - eased : 1).cgColor)
        locations.append(NSNumber(value: 1 - edge + edge * Double(t)))
      }
      fade.colors = colors
      fade.locations = locations
      if layer.mask !== fade { layer.mask = fade }
    }
  }
}

/// The line between the pinned tabs and the others, with Beam's style of
/// blend modes (multiplied in light mode, screened in dark mode).
private final class PinnedSeparatorView: NSView {
  /// Between tabs in the strip, which is masked when it scrolls (the fades
  /// at its edges): a masked layer is composited on its own, where the blend
  /// modes have no bar underneath to blend with and the line vanished. These
  /// use plain translucent colors that look the same over the bar.
  private let blends: Bool

  init(blends: Bool = true) {
    self.blends = blends
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 0.5
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    guard blends else {
      layer?.compositingFilter = nil
      layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.06)).cgColor
      return
    }
    layer?.backgroundColor = dark
      ? NSColor(srgbRed: 0x24 / 255, green: 0x24 / 255, blue: 0x27 / 255, alpha: 0.75).cgColor
      : NSColor(srgbRed: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF3 / 255, alpha: 1).cgColor
    layer?.compositingFilter = dark ? "screenBlendMode" : "multiplyBlendMode"
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TabPill: NSView {
  /// The bar sits in the window's title bar, where macOS drags the window
  /// from any view that doesn't claim its area (controls do, plain views
  /// don't), before the app even sees the press. Claim it: tabs drag tabs,
  /// and the bar drags the window from its empty space itself (mouseDown).
  @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

  var onSelect: (() -> Void)?
  var onClose: (() -> Void)?
  var onMenu: (() -> NSMenu?)?
  var onDrag: ((DragPhase, NSEvent) -> Void)?
  /// Drags start once the pointer moves this way (along the tabs).
  var dragAxis = TabAxis.horizontal
  var onToggleMute: (() -> Void)?
  /// Hidden inside its collapsed group's capsule: not clickable.
  var isCollapsedAway = false
  /// In a sidebar: the title starts after the icon rather than centered,
  /// and pinned, it's a tile (lightly filled at rest).
  var sidebarStyle = false {
    didSet {
      guard sidebarStyle != oldValue else { return }
      needsLayout = true
      refresh(animated: false)
    }
  }

  /// Just moved between the pinned and regular strips.
  var needsAppear = false
  private var isPinned = false
  /// Where the press started, in window coordinates.
  private(set) var pressStart: NSPoint?
  private var dragging = false

  private let background = HighlightLayer()
  private let icon = NSImageView()
  private let titleLabel = NSTextField.label("", size: 12)
  /// The outgoing text while the title and the URL swap (Beam's transition).
  private let outgoingLabel = NSTextField.label("", size: 12)
  /// Before the address, when it's https.
  private let lock = NSImageView(image: Theme.symbol("lock.fill", size: 10) ?? NSImage())
  private var showsLock = false
  private let spinner = NSProgressIndicator()
  private lazy var closeButton = IconButton(symbol: "xmark", size: 9, target: self, action: #selector(close))
  private lazy var copyButton = IconButton(symbol: "doc.on.doc", size: 9, tooltip: "Copy Link", target: self, action: #selector(copyLink))
  /// Sound, camera, microphone, or several: what the page is doing. Sound
  /// toggles muting; several list what's in use.
  private lazy var mediaButton = IconButton(symbol: "speaker.wave.2.fill", size: 10, target: self, action: #selector(mediaClicked))
  private var media = TabMedia()
  /// The media indicator takes the favicon's place (pinned or narrow tabs).
  private var mediaReplacesIcon: Bool { media.count > 0 && (isPinned || bounds.width < 110) }
  private var tracking: NSTrackingArea?
  private var hovering = false {
    didSet {
      refresh(animated: true)
      if hovering != oldValue { onHoverChange?() }
      // Leaving the tab leaves its buttons (which may miss their own exit).
      if !hovering {
        closeButton.syncHoverWithPointer()
        copyButton.syncHoverWithPointer()
      }
    }
  }
  var isHovering: Bool { hovering }
  /// The bar hides the pinned tabs' separator next to a hovered tab.
  var onHoverChange: (() -> Void)?
  private var pressed = false { didSet { if pressed != oldValue { refresh(animated: false) } } }
  /// The close and copy buttons are shown (hidden, they only fade out: not
  /// clickable).
  private var closeShown = false
  private var copyShown = false
  /// "Link Copied" shows in place of the title for a moment.
  private var showsCopied = false
  private var copiedIconWork: DispatchWorkItem?
  private var isActive = false
  private var inWebMode = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    // Clip to the pill so the title ↔ URL transition stays inside it.
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.addSublayer(background)
    icon.imageScaling = .scaleProportionallyDown
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    background.borderWidth = 0.5
    closeButton.translatesAutoresizingMaskIntoConstraints = true
    closeButton.alphaValue = 0
    copyButton.translatesAutoresizingMaskIntoConstraints = true
    copyButton.alphaValue = 0
    titleLabel.wantsLayer = true
    lock.contentTintColor = Theme.secondaryText
    lock.toolTip = "Secure connection"
    lock.alphaValue = 0
    lock.wantsLayer = true
    lock.imageScaling = .scaleNone
    mediaButton.translatesAutoresizingMaskIntoConstraints = true
    mediaButton.isHidden = true
    for view in [icon, spinner, lock, titleLabel, mediaButton, copyButton, closeButton] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(view)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }

  private var title = ""
  private var url = ""
  private var favicon: NSImage?
  /// Shows the spinner once a load has lasted a moment.
  private var spinnerDelay: DispatchWorkItem?
  /// The favicon last shown (not behind the spinner).
  private var shownFavicon: NSImage?

  func configure(title: String, url: String, favicon: NSImage?, isLoading: Bool, isActive: Bool, inWebMode: Bool,
                 pinned: Bool = false, media: TabMedia = TabMedia()) {
    if media != self.media {
      let appeared = self.media.count == 0 && media.count > 0
      self.media = media
      updateMediaButton()
      if appeared, window != nil { mediaButton.popIn() }
      needsLayout = true
    }
    if pinned != isPinned {
      isPinned = pinned
      titleLabel.alphaValue = pinned ? 0 : 1
      needsLayout = true
    }
    toolTip = pinned ? title : nil
    self.title = title
    self.url = url
    self.favicon = favicon
    updateText(animated: false)
    // The spinner only replaces the favicon for loads that last: single-page
    // apps (x.com) start and stop loading many times a second, which would
    // make the icon blink.
    let iconWasShown = !icon.isHidden
    if isLoading {
      if iconWasShown, spinnerDelay == nil {
        let work = DispatchWorkItem { [weak self] in
          guard let self else { return }
          self.spinnerDelay = nil
          self.spinner.startAnimation(nil)
          self.icon.isHidden = true
        }
        spinnerDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
      }
    } else {
      spinnerDelay?.cancel()
      spinnerDelay = nil
      spinner.stopAnimation(nil)
      icon.isHidden = false
    }
    // The favicon pops in when the spinner gives way to it (a load, a
    // reload) or when a new one arrives while it's shown.
    if !isLoading, let favicon, !iconWasShown || favicon !== shownFavicon {
      if window != nil { popInIcon() }
    }
    if !isLoading { shownFavicon = favicon }
    let changed = isActive != self.isActive || inWebMode != self.inWebMode
    self.isActive = isActive
    self.inWebMode = inWebMode
    refresh(animated: changed)
  }

  private var showsSelection: Bool { isActive && inWebMode }

  private func updateMediaButton() {
    mediaButton.isHidden = media.count == 0
    guard media.count > 0 else { return }
    let symbol: String
    let tint: NSColor
    let tooltip: String
    if media.count > 1 {
      symbol = "dot.radiowaves.left.and.right"
      tint = Theme.secondaryText
      tooltip = "Using " + [media.sound ? "sound" : nil, media.camera ? "your camera" : nil, media.microphone ? "your microphone" : nil]
        .compactMap { $0 }.joined(separator: ", ")
    } else if media.camera {
      (symbol, tint, tooltip) = ("video.fill", Theme.secondaryText, "Using your camera")
    } else if media.microphone {
      (symbol, tint, tooltip) = ("mic.fill", Theme.secondaryText, "Using your microphone")
    } else {
      (symbol, tint, tooltip) = (media.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", Theme.secondaryText,
                                 media.muted ? "Unmute Tab" : "Mute Tab")
    }
    mediaButton.setSymbol(symbol, size: 10, animated: window != nil)
    mediaButton.restingTint = tint
    mediaButton.toolTip = tooltip
    // The camera or microphone alone is just shown (clicks go to the tab).
    mediaButton.isInteractive = mediaIsButton
  }

  /// Sound (mute or unmute), or several (what's in use): the indicator
  /// takes clicks.
  private var mediaIsButton: Bool { media.count > 1 || (media.count == 1 && media.sound) }

  /// Sound alone: mute or unmute. Several: what's in use, and muting.
  @objc private func mediaClicked() {
    if media.count > 1 {
      let menu = NSMenu()
      menu.autoenablesItems = false
      func info(_ title: String, _ symbol: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = Theme.symbol(symbol, size: 12)
        item.isEnabled = false
        menu.addItem(item)
      }
      if media.sound { info(media.muted ? "Sound Muted" : "Playing Sound", media.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
      if media.camera { info("Using Your Camera", "video.fill") }
      if media.microphone { info("Using Your Microphone", "mic.fill") }
      if media.sound {
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: media.muted ? "Unmute Tab" : "Mute Tab") { [weak self] in self?.onToggleMute?() })
      }
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: mediaButton.bounds.height + 4), in: mediaButton)
    } else if media.sound {
      onToggleMute?()
    }
  }

  /// A new favicon scales in from 60% with a short spring as it fades in.
  private func popInIcon() { icon.popIn() }

  /// While dragged: looks like a pinned tab (icon only) or not.
  func setPinnedLook(_ pinned: Bool) {
    guard pinned != isPinned else { return }
    isPinned = pinned
    Motion.animate(0.15, timing: Motion.easeInOut) { titleLabel.animator().alphaValue = pinned ? 0 : contentFade }
    refresh(animated: true)
    needsLayout = true
  }

  /// How visible the title, padlock and buttons are (the icon stays): they
  /// fade as a dragged tab compresses toward its pinned size.
  var contentFade: CGFloat = 1 {
    didSet {
      guard contentFade != oldValue else { return }
      Motion.withoutAnimation {
        titleLabel.alphaValue = isPinned ? 0 : contentFade
        lock.alphaValue = showsLock ? contentFade : 0
        closeButton.alphaValue = closeShown ? contentFade : 0
        copyButton.alphaValue = copyShown ? contentFade : 0
      }
    }
  }

  /// Hovering a tab reveals its address in place of its title, after a
  /// padlock when it's https.
  private func updateText(animated: Bool) {
    icon.image = favicon ?? Theme.symbol("globe", size: 12)
    icon.contentTintColor = Theme.tertiaryText
    let shortURL = TabPill.shortURL(url)
    // Only the active tab reveals its address (and copy button) on hover;
    // the others just show their close button.
    let showsURL = hovering && showsSelection && !shortURL.isEmpty && !isPinned && !showsCopied
    let secure = showsURL && url.hasPrefix("https://")
    if secure != showsLock {
      showsLock = secure
      needsLayout = true
      lock.alphaValue = secure ? contentFade : 0
      // Moves with the URL (Beam's swap): rises in from below, and rises
      // out when the title comes back.
      if animated, let layer = lock.layer, !Motion.reduceMotion {
        let slide = Motion.spring("transform", stiffness: 380, damping: 20)
        slide.fromValue = secure ? CATransform3DMakeTranslation(0, -8, 0) : CATransform3DIdentity
        slide.toValue = secure ? CATransform3DIdentity : CATransform3DMakeTranslation(0, 8, 0)
        let fade = Motion.basic("opacity", duration: 0.08, timing: Motion.easeInOut)
        fade.fromValue = secure ? 0 : contentFade
        fade.toValue = secure ? contentFade : 0
        if secure {
          fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.03
          fade.fillMode = .backwards
        }
        layer.add(slide, forKey: "slide")
        layer.add(fade, forKey: "fade")
      }
    }
    let text = showsCopied ? "Link Copied" : (showsURL ? shortURL : title)
    guard text != titleLabel.stringValue else { return }
    if animated, window != nil, !Motion.reduceMotion {
      // Beam's swap: revealing the URL (or "Link Copied"), the title sinks
      // and fades as the new text rises from below; going back, the reverse.
      swapText(revealing: showsURL || showsCopied)
    }
    titleLabel.lineBreakMode = text == shortURL ? .byTruncatingMiddle : .byTruncatingTail
    titleLabel.stringValue = text
    needsLayout = true  // recenter
  }

  /// Beam's transition between the title and the URL: 8pt of travel on a
  /// spring (380 / 20) with quick fades, the incoming text slightly delayed
  /// when the URL comes in.
  private func swapText(revealing: Bool) {
    if outgoingLabel.superview == nil {
      outgoingLabel.wantsLayer = true
      // Sized by its frame (a copy of the title's), not Auto Layout: it
      // would take the whole text's width and run past the tab's padding.
      outgoingLabel.translatesAutoresizingMaskIntoConstraints = true
      addSubview(outgoingLabel, positioned: .below, relativeTo: titleLabel)
    }
    outgoingLabel.stringValue = titleLabel.stringValue
    outgoingLabel.font = titleLabel.font
    outgoingLabel.textColor = titleLabel.textColor
    outgoingLabel.lineBreakMode = titleLabel.lineBreakMode
    outgoingLabel.frame = titleLabel.frame
    outgoingLabel.alphaValue = titleLabel.alphaValue
    outgoingLabel.isHidden = false
    // Not flipped: down is negative.
    let travel: CGFloat = revealing ? -8 : 8
    if let layer = outgoingLabel.layer {
      layer.removeAllAnimations()
      let move = Motion.spring("transform", stiffness: 380, damping: 20)
      move.fromValue = CATransform3DIdentity
      move.toValue = CATransform3DMakeTranslation(0, travel, 0)
      move.fillMode = .forwards
      move.isRemovedOnCompletion = false
      let fade = Motion.basic("opacity", duration: 0.08, timing: Motion.easeInOut)
      fade.fromValue = 1
      fade.toValue = 0
      fade.fillMode = .forwards
      fade.isRemovedOnCompletion = false
      layer.add(move, forKey: "glea.swap.move")
      layer.add(fade, forKey: "glea.swap.fade")
    }
    let token = UUID()
    swapToken = token
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.swapToken == token else { return }
      self.outgoingLabel.isHidden = true
      self.outgoingLabel.layer?.removeAllAnimations()
    }
    if let layer = titleLabel.layer {
      let delay: CFTimeInterval = revealing ? 0.03 : 0
      let move = Motion.spring("transform", stiffness: 380, damping: 20)
      move.fromValue = CATransform3DMakeTranslation(0, travel, 0)
      move.toValue = CATransform3DIdentity
      let fade = Motion.basic("opacity", duration: 0.08, timing: Motion.easeInOut)
      fade.fromValue = 0
      fade.toValue = layer.opacity
      if delay > 0 {
        fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        fade.fillMode = .backwards
      }
      layer.add(move, forKey: "glea.swap.move")
      layer.add(fade, forKey: "glea.swap.fade")
    }
  }

  private var swapToken = UUID()

  static func shortURL(_ url: String) -> String {
    var s = url
    for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
    if s.hasSuffix("/") { s.removeLast() }
    return s
  }

  private func refresh(animated: Bool) {
    if animated { updateText(animated: true) }
    let resting: NSColor = sidebarStyle && isPinned ? Theme.pinnedTile : .clear
    let color: NSColor = showsSelection ? Theme.activeTab : (hovering ? Theme.hover : resting)

    background.backgroundColor = resolvedCGColor(color)
    // Beam's hairline around the active and hovered tabs.
    let stroke: NSColor = pressed ? Theme.pressedTabStroke : showsSelection ? Theme.activeTabStroke : hovering ? Theme.tabStroke : .clear
    background.borderColor = resolvedCGColor(stroke)
    let showClose = (hovering || showsSelection) && bounds.width >= 70 && !isPinned
    let showCopy = hovering && showsSelection && bounds.width >= 70 && !isPinned && !url.isEmpty
    if showCopy != copyShown || showClose != closeShown { needsLayout = true }  // the title makes room
    closeShown = showClose
    if showCopy != copyShown, animated, !Motion.reduceMotion, let layer = copyButton.layer {
      // The copy button scales in (and out) as it fades.
      let scale = Motion.basic("transform", duration: 0.15, timing: Motion.easeOut)
      scale.fromValue = copyButton.centeredScale(showCopy ? 0.5 : 1)
      scale.toValue = copyButton.centeredScale(showCopy ? 1 : 0.5)
      if !showCopy {
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
      }
      layer.removeAnimation(forKey: "glea.copy.scale")
      layer.add(scale, forKey: "glea.copy.scale")
    }
    copyShown = showCopy
    Motion.animate(animated ? 0.12 : 0, timing: Motion.easeInOut) {
      closeButton.animator().alphaValue = showClose ? contentFade : 0
      copyButton.animator().alphaValue = showCopy ? contentFade : 0
      titleLabel.animator().textColor = showsSelection || hovering ? Theme.text : Theme.secondaryText
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refresh(animated: false)
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    Motion.withoutAnimation { background.frame = bounds }
    // Pinned: just the icon, centered. Otherwise the icon stays at the left
    // and the title (after its padlock, when shown) is centered in the tab
    // when it fits, else it fills the room after the icon (a sidebar's rows
    // keep it after the icon).
    // Room on the right only for the buttons shown (the text shrinks).
    // The media indicator: in the favicon's place (pinned, narrow), else
    // just before the close button (making room for it as it appears), with
    // the copy button before it.
    let replacesIcon = mediaReplacesIcon
    let mediaOnRight = media.count > 0 && !replacesIcon
    let closeRoom: CGFloat = closeShown ? 24 : 9
    let reserved = closeRoom + (mediaOnRight ? 20 : 0) + (copyShown ? 21 : 0)
    let lockWidth: CGFloat = showsLock ? 15 : 0
    let maxText = max(0, bounds.width - 31 - reserved - lockWidth)
    // The text's own width (+ the field's 2pt padding each side).
    let textWidth = min(ceil(titleLabel.attributedStringValue.size().width) + 4, maxText)
    let groupWidth = lockWidth + textWidth
    let groupX = sidebarStyle ? 31 : max(31, min((bounds.width - groupWidth) / 2, bounds.width - reserved - groupWidth))
    let iconFrame = NSRect(x: isPinned ? (bounds.width - 16) / 2 : 9, y: (h - 16) / 2, width: 16, height: 16)
    let lockFrame = NSRect(x: groupX - 1, y: (h - 16) / 2, width: 12, height: 16)
    let titleFrame = NSRect(x: groupX + lockWidth, y: (h - 16) / 2, width: textWidth, height: 16)
    icon.frame = iconFrame
    spinner.frame = iconFrame
    icon.alphaValue = replacesIcon ? 0 : 1
    spinner.alphaValue = replacesIcon ? 0 : 1
    mediaButton.frame = replacesIcon
      ? NSRect(x: iconFrame.midX - 11, y: (h - 22) / 2, width: 22, height: 22)
      : NSRect(x: bounds.width - closeRoom - 20, y: (h - 22) / 2, width: 22, height: 22)
    // A hiding padlock leaves (fading) from where it was.
    if showsLock { lock.frame = lockFrame }
    titleLabel.frame = titleFrame
    closeButton.frame = NSRect(x: bounds.width - 25, y: (h - 22) / 2, width: 22, height: 22)
    // Copy: just before the close button (or the indicator), at the end of the tab.
    copyButton.frame = (mediaOnRight ? mediaButton.frame : closeButton.frame).offsetBy(dx: -21, dy: 0)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  // (Not while hidden in its collapsed group's capsule, under the pointer
  // that collapsed it.)
  override func mouseEntered(with event: NSEvent) { if !isCollapsedAway, !hoverSuspended { hovering = true } }
  override func mouseExited(with event: NSEvent) { hovering = false }

  /// Tabs that move under a still pointer (scrolling the strip) get no
  /// enter/exit events: match the hover to where the pointer is now.
  func syncHoverWithPointer() {
    guard let window, !isHidden else { return }
    let point = window.mouseLocationOutsideOfEventStream
    let inside = hoverSuspended ? isDragged : bounds.contains(convert(point, from: nil))
      && (superview.map { $0.bounds.contains($0.convert(point, from: nil)) } ?? true)
    if inside != hovering { hovering = inside }
    // Its buttons moved under the pointer too (the copy button would stay
    // highlighted after being scrolled past).
    closeButton.syncHoverWithPointer()
    copyButton.syncHoverWithPointer()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isCollapsedAway, let hit = super.hitTest(point) else { return nil }
    // Muting or listing what's in use never selects the tab. (By its frame:
    // the faded-out copy button may lie over it.)
    if !mediaButton.isHidden, mediaIsButton, mediaButton.frame.contains(convert(point, from: superview)) { return mediaButton }
    // Only the close and copy buttons, when shown, handle their own clicks:
    // the icon's image view would swallow presses and drags (a pinned tab
    // is all icon).
    if closeShown, hit.isDescendant(of: closeButton) { return hit }
    if copyShown, hit.isDescendant(of: copyButton) { return hit }
    return self
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let menu = onMenu?() else { return }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = pressStart else { return }
    if !dragging, abs(dragAxis.main(event.locationInWindow) - dragAxis.main(start)) > 4 {
      dragging = true
      layer?.removeAnimation(forKey: "press")
      onDrag?(.began, event)
    }
    if dragging { onDrag?(.moved, event) }
  }

  override func mouseDown(with event: NSEvent) {
    pressStart = event.locationInWindow
    pressed = true
    dragging = false
    // The bar is the window's title bar: a drag here moves tabs, never the
    // window (macOS would otherwise start moving it itself).
    window?.isMovable = false
    guard let layer else { return }
    let down = Motion.basic("transform", duration: 0.08, timing: Motion.easeInOut)
    down.toValue = centeredScale(0.97)
    down.fillMode = .forwards
    down.isRemovedOnCompletion = false
    layer.add(down, forKey: "press")
  }

  override func mouseUp(with event: NSEvent) {
    window?.isMovable = true
    pressed = false
    defer { pressStart = nil }
    if dragging {
      dragging = false
      onDrag?(.ended, event)
      return
    }
    if let layer {
      let up = Motion.spring("transform", stiffness: 480, damping: 22)
      up.fromValue = layer.presentation()?.transform ?? centeredScale(0.97)
      up.toValue = CATransform3DIdentity
      layer.add(up, forKey: "press")
    }
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
  }

  override func otherMouseUp(with event: NSEvent) {
    if event.buttonNumber == 2 { onClose?() }
  }

  @objc private func close() { onClose?() }

  /// Test hooks: hover without the pointer.
  func simulateHover(_ on: Bool) { hovering = on }

  /// Dragged, the tab is under the pointer: hovered (Beam), even though no
  /// enter / exit events come during the drag.
  var isDragged = false {
    didSet {
      guard isDragged != oldValue else { return }
      if isDragged { hovering = true } else { syncHoverWithPointer() }
    }
  }

  /// While a tab is dragged nothing else hovers, and neither do its buttons:
  /// tabs slide under the pointer (and the dragged one) with no enter or
  /// exit events, and would keep a hover they caught on the way.
  var hoverSuspended = false {
    didSet {
      guard hoverSuspended != oldValue else { return }
      closeButton.tracksHover = !hoverSuspended
      copyButton.tracksHover = !hoverSuspended
      syncHoverWithPointer()
    }
  }

  /// The close / copy buttons depend on the width: follow it as it changes
  /// (a tab growing out of the pinned tabs).
  override func setFrameSize(_ newSize: NSSize) {
    let old = frame.size.width
    super.setFrameSize(newSize)
    let crossed = [70, 120].contains { (old >= $0) != (newSize.width >= $0) }
    if crossed { refresh(animated: true) }
  }

  @objc private func copyLink() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url, forType: .string)
    // The clipboard turns into a checkmark for a second.
    copyButton.popSymbol("checkmark", size: 9)
    copiedIconWork?.cancel()
    let revert = DispatchWorkItem { [weak self] in self?.copyButton.popSymbol("doc.on.doc", size: 9) }
    copiedIconWork = revert
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: revert)
    showsCopied = true
    updateText(animated: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      guard let self, self.showsCopied else { return }
      self.showsCopied = false
      self.updateText(animated: true)
    }
  }
}

// MARK: - Pinned tabs, groups and drag & drop

/// A tab bar item, left to right: a group's capsule, or a tab.
private enum BarItem: Hashable {
  case tab(ObjectIdentifier)
  case capsule(UUID)
}

/// A tab (or a whole group) being dragged along the tab bar.
private struct TabDrag {
  enum Kind { case tab(ObjectIdentifier), group(UUID) }
  var kind: Kind
  /// Where it was grabbed, as a fraction of its length (kept as a tab
  /// shrinks to or grows from its pinned look).
  var grabFraction: CGFloat
  /// The pointer along the axis, in the tabs' view.
  var pointer: CGFloat
  /// Its length where it would land (the room the layout makes for it).
  var length: CGFloat
  /// Its length as drawn: eases to `length`.
  var shownLength: CGFloat
  /// The pointer minus its start, as drawn (it stays under the pointer as
  /// it shrinks to or grows from its pinned look).
  var grab: CGFloat { grabFraction * shownLength }
  /// Where it would land the last time the pointer was over the bar: a
  /// release anywhere else snaps it there.
  var lastTarget: DropTarget?
  /// ⌥ held over another tab: the tab to group with.
  var groupWith: ObjectIdentifier?
  /// A pinned tab being dragged (it unpins past the separator).
  var startedPinned = false
  /// The pointer in the tabs' view at the last drag event (for ⌥ pressed
  /// while still, and a sidebar's pinned tiles).
  var point: NSPoint = .zero
  /// Down a sidebar: where it was grabbed across, as a fraction of its
  /// thickness (a tile follows the pointer sideways from there).
  var crossFraction: CGFloat = 0.5
  /// Down a sidebar: where it would be across (a row's inset, or a tile's
  /// place under the pointer) and how thick, and both as drawn, easing there.
  var cross: CGFloat = 0
  var thickness: CGFloat = 0
  var shownCross: CGFloat = 0
  var shownThickness: CGFloat = 0
}

/// A slot among the pinned tabs, or among the other items (and for a tab,
/// the group it lands in).
private enum DropTarget { case pinned(Int), strip(Int, group: UUID?) }

enum DragPhase { case began, moved, ended }

/// The pinned tabs' strip. It never clips (so pinned tabs can be dragged out).
private final class PinnedStripView: NSView {
  /// The bar sits in the window's title bar, where macOS drags the window
  /// from any view that doesn't claim its area (controls do, plain views
  /// don't), before the app even sees the press. Claim it: tabs drag tabs,
  /// and the bar drags the window from its empty space itself (mouseDown).
  @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
}

extension TabsView {
  private var pinnedWidth: CGFloat { 32 }
  private var spacing: CGFloat { 4 }

  // MARK: Groups

  fileprivate func updateGroups(_ groups: [GroupInfo]) {
    groupInfos = groups
    let ids = Set(groups.map(\.id))
    for info in groups {
      let capsule = capsules[info.id] ?? {
        let capsule = GroupCapsule()
        let id = info.id
        capsule.onToggle = { [weak self] in self?.delegate?.topBarToggleGroup(id) }
        capsule.onMenu = { [weak self] in self?.delegate?.topBarMenu(forGroup: id) }
        capsule.onDrag = { [weak self] phase, event in self?.dragGroup(id, phase: phase, event: event) }
        capsule.dragAxis = axis
        capsules[id] = capsule
        tabStrip.addSubview(capsule)
        if window != nil { capsule.animateIn(scale: 0.8, duration: 0.2) }
        return capsule
      }()
      capsule.configure(label: info.label, color: info.color)
      if underlines[info.id] == nil {
        let line = GroupLineView()
        tabStrip.addSubview(line, positioned: .below, relativeTo: nil)
        underlines[info.id] = line
      }
      underlines[info.id]?.color = info.color
    }
    for (id, capsule) in capsules where !ids.contains(id) {
      capsules[id] = nil
      capsule.animateOut(scale: 0.8, duration: 0.15) { capsule.removeFromSuperview() }
    }
    for (id, line) in underlines where !ids.contains(id) {
      underlines[id] = nil
      line.removeFromSuperview()
    }
  }

  private func group(_ id: UUID?) -> GroupInfo? { groupInfos.first { $0.id == id } }

  private func members(_ group: UUID) -> [ObjectIdentifier] {
    order.filter { tabInfos[$0]?.groupID == group && tabInfos[$0]?.isPinned == false }
  }

  /// Unpinned items in order: each group's capsule before its tabs (hidden
  /// when collapsed), without whatever is being dragged.
  private func unpinnedItems(excludingDrag: Bool) -> [BarItem] {
    var items: [BarItem] = []
    var seen = Set<UUID>()
    for id in order {
      guard let info = tabInfos[id], !info.isPinned else { continue }
      if let g = info.groupID, let group = group(g) {
        if seen.insert(g).inserted { items.append(.capsule(g)) }
        if group.collapsed { continue }
      }
      items.append(.tab(id))
    }
    guard excludingDrag, let drag else { return items }
    switch drag.kind {
    case .tab(let id): return items.filter { $0 != .tab(id) }
    case .group(let g): return items.filter { item in
        if case .capsule(g) = item { return false }
        if case .tab(let id) = item, tabInfos[id]?.groupID == g { return false }
        return true
      }
    }
  }

  private func pinnedItems(excludingDrag: Bool) -> [ObjectIdentifier] {
    let pinned = order.filter { tabInfos[$0]?.isPinned == true }
    if excludingDrag, let drag, case .tab(let id) = drag.kind { return pinned.filter { $0 != id } }
    return pinned
  }

  private func capsuleWidth(_ group: UUID) -> CGFloat {
    if group == Self.previewID { return 16 + 2 * GroupCapsule.ring }  // an unnamed new group
    return capsules[group]?.fittingWidth ?? GroupCapsule.height
  }

  // MARK: Layout

  /// Shown when there are pinned tabs, except (as in Beam) next to the
  /// first other tab when it's active or hovered: its highlight takes over.
  fileprivate func updatePinnedSeparator(animated: Bool) {
    // (Web only: in notes mode the bar has no tabs.)
    var shown = pinnedSeparatorHasPins && isWeb
    if shown, drag == nil, case .tab(let id)? = unpinnedItems(excludingDrag: true).first {
      if (id == activeID && isWeb) || pills[id]?.isHovering == true { shown = false }
    }
    Motion.animate(animated ? 0.15 : 0, timing: Motion.easeInOut) {
      pinnedSeparator.layer?.opacity = shown ? 1 : 0
    }
    updateTabSeparators(animated: animated)
  }

  /// The hairlines between tabs hide next to the active and hovered tabs
  /// (their highlight takes over), like the pinned tabs' separator.
  fileprivate func updateTabSeparators(animated: Bool) {
    func highlighted(_ id: ObjectIdentifier) -> Bool { (id == activeID && isWeb) || pills[id]?.isHovering == true }
    Motion.animate(animated ? 0.15 : 0, timing: Motion.easeInOut) {
      for (left, separator) in tabSeparators {
        let shown = isWeb && !highlighted(left) && !highlighted(separator.right)
        separator.view.layer?.opacity = shown ? 1 : 0
      }
    }
  }

  /// Places a hairline in the gap after each tab followed by another tab
  /// (not next to a group's capsule or a drop gap).
  fileprivate func layoutTabSeparators(items: [BarItem?], frames: [BarItem: NSRect], animated: Bool) {
    var placed: Set<ObjectIdentifier> = []
    // (A sidebar's rows have none.)
    for (item, next) in zip(items, items.dropFirst()) where axis == .horizontal {
      guard case .tab(let left)? = item, case .tab(let right)? = next, let frame = frames[.tab(left)],
            pills[left]?.superview === tabStrip, pills[right]?.superview === tabStrip else { continue }
      let separatorFrame = rect(main: (axis.maxMain(frame) + spacing / 2 - 0.5).rounded(), length: 1, across: separatorSpan)
      if let existing = tabSeparators[left] {
        tabSeparators[left] = (existing.view, right)
        place(existing.view, separatorFrame, animated: animated && isWeb)
      } else {
        let view = PinnedSeparatorView(blends: false)
        tabStrip.addSubview(view, positioned: .below, relativeTo: nil)
        view.frame = separatorFrame
        view.layer?.opacity = 0
        tabSeparators[left] = (view, right)
      }
      placed.insert(left)
    }
    for (left, separator) in tabSeparators where !placed.contains(left) {
      separator.view.removeFromSuperview()
      tabSeparators[left] = nil
    }
    updateTabSeparators(animated: animated)
  }

  /// Across the axis: separators are 16pt lines in the bar, and span a
  /// sidebar's rows (short of their ends).
  private var separatorSpan: (cross: CGFloat, thickness: CGFloat) {
    switch axis {
    case .horizontal: return (((crossExtent - 16) / 2).rounded(), 16)
    case .vertical:
      let row = across(0, fills: true)
      return (row.cross + 8, max(0, row.thickness - 16))
    }
  }

  /// A group's line (and the ⌥-drag preview's): under its tabs in the bar,
  /// along their left in a sidebar.
  private var groupLineSpan: (cross: CGFloat, thickness: CGFloat) {
    switch axis {
    case .horizontal:
      let pill = across(Theme.tabHeight)
      return (pill.cross + pill.thickness + 2.5, 1.5)
    case .vertical: return (Self.rowInset - 4, 1.5)
    }
  }

  /// A tab's length in the strip: a bar's tabs share its width, a
  /// sidebar's rows are all the same height.
  private var rowLength: CGFloat { Theme.tabHeight }

  // MARK: Pinned tiles

  /// Down a sidebar, pinned tabs are tiles, as many to a row as fit.
  private var tileHeight: CGFloat { 34 }
  private var tileGap: CGFloat { 4 }
  private var rowWidth: CGFloat { across(0, fills: true).thickness }
  /// A fixed size: resizing the sidebar changes how many fit in a row.
  private var tileWidth: CGFloat { 52 }
  private var tileColumns: Int { max(1, Int((rowWidth + tileGap) / (tileWidth + tileGap))) }

  /// A pinned tile's frame in the pinned strip.
  private func tileFrame(_ index: Int) -> NSRect {
    let row = index / tileColumns, column = index % tileColumns
    return NSRect(x: Self.rowInset + CGFloat(column) * (tileWidth + tileGap), y: CGFloat(row) * (tileHeight + tileGap),
                  width: tileWidth, height: tileHeight)
  }

  /// The pinned strip's length for `count` tabs.
  private func pinnedLength(_ count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    switch axis {
    case .horizontal: return CGFloat(count) * pinnedWidth + CGFloat(count - 1) * 2
    case .vertical:
      let rows = (count + tileColumns - 1) / tileColumns
      return CGFloat(rows) * (tileHeight + tileGap) - tileGap
    }
  }

  /// Down a sidebar: the slot among `count` tiles for a tile dropped at
  /// `point` (in this view), in reading order.
  private func tileSlot(at point: NSPoint, count: Int) -> Int {
    let p = pinnedStrip.convert(point, from: self)
    let row = Int(max(0, p.y) / (tileHeight + tileGap))
    return (0..<count).filter { i in
      let frame = tileFrame(i)
      let tileRow = i / tileColumns
      return tileRow < row || (tileRow == row && frame.midX < p.x)
    }.count
  }

  /// A group's capsule's length along the axis (a sidebar's are rows).
  private func capsuleLength(_ group: UUID) -> CGFloat {
    axis == .horizontal ? capsuleWidth(group) : GroupCapsule.height
  }

  /// Lays the tabs out from `start` to `end` along the axis (+ included).
  func layoutTabs(from start: CGFloat, to end: CGFloat, animated: Bool, added: Set<ObjectIdentifier>,
                  reveal: ObjectIdentifier?) {
    tabsStart = start
    tabsEnd = end
    let pillSpan = across(Theme.tabHeight, fills: true)
    /// A capsule across the axis: centered in the bar; a sidebar's sit at
    /// the start of their row, as wide as their name.
    func capsuleSpan(_ g: UUID) -> (cross: CGFloat, thickness: CGFloat) {
      axis == .horizontal ? across(GroupCapsule.height) : across(0, fills: true)
    }
    // A sidebar's capsules are drawn at their name's width.
    for (g, capsule) in capsules { capsule.markerWidth = axis == .vertical ? min(capsuleWidth(g), rowWidth) : nil }
    previewCapsule?.markerWidth = axis == .vertical ? min(capsuleWidth(Self.previewID), rowWidth) : nil
    let plusSize: CGFloat = axis == .vertical ? rowLength : 28
    let plusLength = plusSize + 6
    let target = dropTarget()
    updateDraggedTabLook()

    // Pinned tabs, with a gap where a dragged tab would land.
    var pinned: [ObjectIdentifier?] = pinnedItems(excludingDrag: true).map { $0 }
    if drag?.groupWith == nil, case .pinned(let slot) = target { pinned.insert(nil, at: min(slot, pinned.count)) }
    let pinnedStripLength = pinnedLength(pinned.count)
    pinnedStrip.frame = axis.rect(main: start, length: max(pinnedStripLength, 1), cross: 0, thickness: crossExtent)
    for (i, id) in pinned.enumerated() {
      guard let id, let pill = pills[id], pill.superview === pinnedStrip else { continue }
      let frame = axis == .vertical ? tileFrame(i)
        : rect(main: CGFloat(i) * (pinnedWidth + 2), length: pinnedWidth, across: across(Theme.tabHeight))
      if pill.needsAppear || added.contains(id) {
        appear(pill, at: frame, animated: animated)
      } else {
        place(pill, frame, animated: animated && isWeb)
      }
    }
    // Beam's separator after the pinned tabs: 1×16, 7.5 after the last one
    // and 5.5 before the next.
    let x = start + pinnedStripLength + (pinned.isEmpty ? 0 : 14) - 4
    let separatorFrame = rect(main: start + pinnedStripLength + 7.5, length: 1, across: separatorSpan)
    place(pinnedSeparator, separatorFrame, animated: animated && isWeb && !pinnedSeparator.frame.isEmpty)
    pinnedSeparatorHasPins = !pinned.isEmpty
    updatePinnedSeparator(animated: animated)

    // The rest: capsules and tabs sharing the room, scrolling past it.
    var items: [BarItem?] = unpinnedItems(excludingDrag: true).map { $0 }
    let grouping = drag?.groupWith != nil
    if !grouping, case .strip(let slot, _) = target { items.insert(nil, at: min(slot, items.count)) }
    // ⌥-dragging onto a loose tab: room for the new group's capsule before it.
    let previewFor = drag?.groupWith.flatMap { tabInfos[$0]?.groupID == nil ? $0 : nil }
    if let previewFor, let index = items.firstIndex(of: .tab(previewFor)) { items.insert(.capsule(Self.previewID), at: index) }
    let available = max(0, end - plusLength - x)
    let tabCount = CGFloat(items.filter { if case .tab = $0 { return true }; return $0 == nil && isDraggingTab }.count)
    let capsulesLength = items.reduce(CGFloat(0)) { sum, item in
      if case .capsule(let g) = item { return sum + capsuleLength(g) }
      // (A dragged group's gap: all of it, capsule and tabs, so the others
      // keep their widths.)
      if item == nil, case .group(let g)? = drag?.kind { return sum + (drag?.length ?? capsuleLength(g)) }
      return sum
    }
    let gaps = CGFloat(max(0, items.count - 1)) * spacing + 8
    // Tabs share the room up to the max width, each no wider than its
    // content; past the min width the strip scrolls.
    let draggedID: ObjectIdentifier? = { if case .tab(let id)? = drag?.kind { return id }; return nil }()
    // (The dragged tab's slot counts as that tab.)
    let slots: [(id: ObjectIdentifier?, natural: CGFloat)] = items.compactMap { item in
      switch item {
      case .tab(let id): return (id, naturalTabWidth(id))
      case nil where isDraggingTab: return (draggedID, draggedID.map(naturalTabWidth) ?? Theme.tabMinWidth)
      default: return nil
      }
    }
    let room = available - capsulesLength - gaps
    var shared = Self.sharedTabWidth(naturals: slots.map(\.natural), room: room)
    // Crowded: the active tab keeps its minimum, the others share the rest.
    if shared < Self.activeTabMinWidth, let activeID, slots.contains(where: { $0.id == activeID }) {
      shared = Self.sharedTabWidth(naturals: slots.filter { $0.id != activeID }.map(\.natural),
                                   room: room - Self.activeTabMinWidth)
    }
    let tabWidth = tabCount > 0 ? min(Theme.tabMaxWidth, max(Theme.tabMinWidth, shared)) : 0
    /// A tab's length in the strip: in the bar, its natural width up to the
    /// shared one (never below the active tab's minimum).
    func stripLength(_ id: ObjectIdentifier) -> CGFloat {
      guard axis == .horizontal else { return rowLength }
      let width = min(naturalTabWidth(id), tabWidth)
      return id == activeID ? max(Self.activeTabMinWidth, width) : width
    }
    if tabCount > 0 { stripTabWidth = tabWidth }
    // A tab dragged over the strip takes (and leaves room for) its length in
    // the strip, as laid out now.
    if isDraggingTab, !grouping, case .strip? = target, tabCount > 0, let draggedID {
      drag?.length = stripLength(draggedID)
    }
    func length(_ item: BarItem?) -> CGFloat {
      switch item {
      case .capsule(let g): return capsuleLength(g)
      case .tab(let id): return stripLength(id)
      case nil: return drag?.length ?? (axis == .horizontal ? tabWidth : rowLength)
      }
    }
    stripTabLengths = [:]
    for case .tab(let id)? in items { stripTabLengths[id] = length(.tab(id)) }
    // Inset from the strip's ends (room for a capsule's bounce).
    let inset: CGFloat = 4
    var offsets: [CGFloat] = []
    var cursor: CGFloat = inset
    for item in items {
      offsets.append(cursor)
      cursor += length(item) + spacing
    }
    let contentLength = items.isEmpty ? 0 : cursor - spacing + inset
    // The strip spans all the room for tabs (drops land anywhere in it);
    // the + button follows the last tab.
    let stripLength = min(available, contentLength)
    tabStrip.frame = axis.rect(main: x, length: available, cross: 0, thickness: crossExtent)
    tabStrip.contentLength = contentLength
    if drag == nil, let reveal, let index = items.firstIndex(of: .tab(reveal)) {
      tabStrip.reveal(from: offsets[index], to: offsets[index] + length(.tab(reveal)), animated: animated)
    }
    let scroll = tabStrip.scrollOffset
    var frames: [BarItem: NSRect] = [:]
    var gapFrame: NSRect?
    for (i, item) in items.enumerated() {
      guard let item else {
        gapFrame = rect(main: offsets[i] - scroll, length: length(nil), across: pillSpan)
        continue
      }
      let frame = rect(main: offsets[i] - scroll, length: length(item), across: pillSpan)
      frames[item] = frame
      switch item {
      case .tab(let id):
        guard let pill = pills[id], pill.superview === tabStrip else { continue }
        let expanding = pill.isCollapsedAway
        pill.isCollapsedAway = false
        if added.contains(id) || pill.needsAppear {
          appear(pill, at: frame, animated: animated)
        } else {
          place(pill, frame, animated: animated && isWeb)
        }
        // Out of its expanding group's capsule: hovered only if the pointer
        // is where it lands.
        if expanding { pill.syncHoverWithPointer() }
        if pill.alphaValue < 1 { Motion.animate(animated ? 0.2 : 0) { pill.animator().alphaValue = 1 } }
      case .capsule(let g):
        let capsuleFrame = rect(main: offsets[i] - scroll, length: length(item), across: capsuleSpan(g))
        if g == Self.previewID {
          showPreview(at: capsuleFrame)
          continue
        }
        guard let capsule = capsules[g], capsule.superview === tabStrip else { continue }
        place(capsule, capsuleFrame, animated: animated && isWeb && !capsule.frame.isEmpty)
      }
    }

    layoutTabSeparators(items: items, frames: frames, animated: animated)

    // The ⌥-drag preview: its line spans the capsule and target tab.
    if let previewFor, let capsuleFrame = frames[.capsule(Self.previewID)], let tabFrame = frames[.tab(previewFor)] {
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.25)
      CATransaction.setAnimationTimingFunction(Motion.easeOut)
      previewLine.backgroundColor = resolvedCGColor(nextGroupColor)
      if previewLine.superlayer == nil {
        tabStrip.layer?.addSublayer(previewLine)
        previewLine.cornerRadius = 0.75
        Motion.withoutAnimation {
          previewLine.frame = rect(main: axis.minMain(capsuleFrame) + 2, length: 0, across: groupLineSpan)
        }
      }
      previewLine.frame = rect(main: axis.minMain(capsuleFrame) + 2, length: axis.maxMain(tabFrame) - axis.minMain(capsuleFrame) - 4,
                               across: groupLineSpan)
      CATransaction.commit()
    } else {
      hidePreview()
    }

    // Collapsed groups: their tabs shrink into the capsule and fade.
    for info in groupInfos where info.collapsed {
      guard let capsuleFrame = frames[.capsule(info.id)] else { continue }
      for id in members(info.id) {
        guard let pill = pills[id], pill.superview === tabStrip else { continue }
        pill.isCollapsedAway = true
        // (Into what's drawn of it.)
        let into = axis == .vertical ? NSRect(x: capsuleFrame.minX, y: capsuleFrame.minY,
                                              width: min(capsuleWidth(info.id), capsuleFrame.width), height: capsuleFrame.height)
          : rect(main: axis.minMain(capsuleFrame), length: axis.length(capsuleFrame), across: pillSpan)
        place(pill, into, animated: animated)
        Motion.animate(animated ? 0.18 : 0) { pill.animator().alphaValue = 0 }
      }
    }

    // Group lines: along a group's capsule and tabs, moving with them.
    for info in groupInfos {
      guard let line = underlines[info.id] else { continue }
      // (A dragged group's follows it, below.)
      if case .group(info.id)? = drag?.kind { continue }
      if line.superview !== tabStrip {
        // Dropped: back in the strip, springing from where it was like its
        // capsule and tabs.
        let frame = line.convert(line.bounds, to: tabStrip)
        tabStrip.addSubview(line, positioned: .below, relativeTo: nil)
        line.frame = frame
        releasedViews.append(line)
      }
      var parts = ([BarItem.capsule(info.id)] + members(info.id).map { BarItem.tab($0) }).compactMap { frames[$0] }
      // The gap where a dragged tab would join the group.
      if !grouping, case .strip(_, let g)? = target, g == info.id, let gapFrame { parts.append(gapFrame) }
      guard let first = parts.first, let last = parts.max(by: { axis.maxMain($0) < axis.maxMain($1) }) else {
        Motion.animate(animated ? 0.2 : 0) { line.animator().alphaValue = 0 }
        continue
      }
      if line.alphaValue < 1 { Motion.animate(animated ? 0.2 : 0) { line.animator().alphaValue = 1 } }
      place(line, rect(main: axis.minMain(first) + 2, length: max(0, axis.maxMain(last) - axis.minMain(first) - 4), across: groupLineSpan),
            animated: animated)
    }

    // What's being dragged follows the pointer (above everything).
    if let drag {
      let left = drag.pointer - drag.grab
      switch drag.kind {
      case .tab(let id):
        let frame = draggedTabFrame(drag)
        if let pill = pills[id] {
          if axis == .vertical {
            // A row keeps to the sidebar's inset; over the pinned tabs it's
            // a tile, following the pointer sideways too.
            let pinnedLook: Bool = { if case .pinned? = drag.lastTarget { return drag.groupWith == nil }; return false }()
            let thickness = pinnedLook ? tileWidth : rowWidth
            let cross = pinnedLook
              ? min(max(drag.point.x - drag.crossFraction * thickness, 0), crossExtent - thickness)
              : Self.rowInset
            self.drag?.cross = cross
            self.drag?.thickness = thickness
            if Motion.reduceMotion || drag.shownThickness == 0 {
              self.drag?.shownCross = cross
              self.drag?.shownThickness = thickness
            }
            let shown = self.drag ?? drag
            pill.frame = axis.rect(main: frame.start, length: frame.length, cross: shown.shownCross, thickness: shown.shownThickness)
          } else {
            pill.frame = rect(main: frame.start, length: frame.length, across: pillSpan)
            // Its content fades as it compresses toward its pinned size.
            let range = drag.shownLength - pinnedWidth
            pill.contentFade = range > 1 ? max(0, min(1, (frame.length - pinnedWidth) / range)) : 1
          }
        }
      case .group(let g):
        var offset = left
        if let capsule = capsules[g] {
          let length = axis.length(capsule.frame)
          capsule.frame = rect(main: offset, length: length, across: capsuleSpan(g))
          offset += length + spacing
        }
        let collapsed = group(g)?.collapsed ?? false
        for id in members(g) where !collapsed {
          guard let pill = pills[id] else { continue }
          let length = axis.length(pill.frame)
          pill.frame = rect(main: offset, length: length, across: pillSpan)
          offset += length + spacing
        }
        // Its line follows it, above the strip while it's carried.
        if let line = underlines[g] {
          if line.superview !== self {
            let frame = line.convert(line.bounds, to: self)
            addSubview(line)
            line.frame = frame
          }
          line.alphaValue = 1
          place(line, rect(main: left + 2, length: max(0, offset - spacing - left - 4), across: groupLineSpan), animated: false)
        }
      }
    }

    let plusMain = min(x + stripLength + 6, end - plusSize)
    // (A sidebar's spans the row, like a tab.)
    let plusFrame = axis == .vertical ? rect(main: plusMain, length: rowLength, across: across(0, fills: true))
      : rect(main: plusMain, length: 28, across: across(28))
    place(newTabButton, plusFrame, animated: animated && isWeb)
  }

  private func appear(_ pill: TabPill, at frame: NSRect, animated: Bool) {
    pill.needsAppear = false
    pill.layer?.removeAllAnimations()
    pill.frame = frame
    pill.layoutSubtreeIfNeeded()
    if animated { pill.animateIn(scale: 0.86, duration: 0.22) }
  }

  fileprivate static let previewID = UUID()

  /// The would-be group's capsule: scales in before its target tab.
  private func showPreview(at frame: NSRect) {
    if previewCapsule == nil {
      let capsule = GroupCapsule()
      capsule.configure(label: "", color: nextGroupColor)
      tabStrip.addSubview(capsule)
      capsule.frame = frame
      capsule.animateIn(scale: 0.4, duration: 0.25)
      previewCapsule = capsule
    } else if let capsule = previewCapsule {
      place(capsule, frame, animated: true)
    }
  }

  /// Dropped: the real group takes the preview's place (its capsule appears
  /// where the preview was), so the preview just goes.
  private func hidePreviewInstantly() {
    previewCapsule?.removeFromSuperview()
    previewCapsule = nil
    previewLine.removeFromSuperlayer()
  }

  private func hidePreview() {
    if let capsule = previewCapsule {
      previewCapsule = nil
      capsule.animateOut(scale: 0.4, duration: 0.18) { capsule.removeFromSuperview() }
    }
    if previewLine.superlayer != nil {
      let line = previewLine
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.18)
      CATransaction.setCompletionBlock { if self.previewCapsule == nil { line.removeFromSuperlayer() } }
      line.frame = axis.rect(line.frame, main: axis.minMain(line.frame), length: 0)
      CATransaction.commit()
    }
  }

  private func setGroupingTarget(_ groupWith: ObjectIdentifier?) {
    guard groupWith != drag?.groupWith else { return }
    // A different target: the preview leaves the old one (animating out)
    // and forms around the new one.
    if drag?.groupWith != nil, groupWith != nil { hidePreview() }
    drag?.groupWith = groupWith
    if let groupWith, let g = tabInfos[groupWith]?.groupID { capsules[g]?.pulse() }
  }

  /// ⌥ pressed or released mid-drag, pointer still: switch between grouping
  /// with the tab under it and moving.
  func dragModifiersChanged(_ flags: NSEvent.ModifierFlags) {
    guard let drag, case .tab(let id) = drag.kind else { return }
    let point = drag.point
    setGroupingTarget(groupingTarget(at: point, option: flags.contains(.option), dragging: id))
    if self.drag?.groupWith == nil, isValidDragPoint(point) {
      let target = computeDropTarget()
      self.drag?.lastTarget = target
    }
    relayout(animated: true)
  }

  /// Where a dragged tab is drawn: under the pointer (where it was grabbed).
  /// Past the tab area's left edge it compresses, its left edge held there,
  /// down to its pinned size, where it pins; a pinned tab dragged out
  /// expands the same way.
  private func draggedTabFrame(_ drag: TabDrag) -> (start: CGFloat, length: CGFloat) {
    var length = drag.shownLength
    // (In the bar: down a sidebar, it becomes a tile over the pinned tabs instead.)
    if case .tab = drag.kind, drag.grabFraction > 0.01, axis == .horizontal {
      let room = (drag.pointer - (axis.minMain(tabStrip.frame) + 4)) / drag.grabFraction
      length = min(length, max(pinnedWidth, room))
    }
    return (drag.pointer - drag.grabFraction * length, length)
  }

  /// ⌥ held and the pointer over another (unpinned) tab: that tab.
  private func groupingTarget(_ event: NSEvent, dragging id: ObjectIdentifier) -> ObjectIdentifier? {
    groupingTarget(at: convert(event.locationInWindow, from: nil), option: event.modifierFlags.contains(.option), dragging: id)
  }

  private func groupingTarget(at point: NSPoint, option: Bool, dragging id: ObjectIdentifier) -> ObjectIdentifier? {
    guard option, isValidDragPoint(point), let drag, let dragged = pills[id] else { return nil }
    // The dragged tab, where it's drawn (following the pointer).
    let drawn = draggedTabFrame(drag)
    let draggedSpan = (drawn.start, drawn.start + drawn.length)
    func overlap(_ other: ObjectIdentifier) -> CGFloat {
      guard let pill = pills[other], pill.superview === tabStrip, !pill.isCollapsedAway else { return 0 }
      let frame = pill.convert(pill.bounds, to: self)
      let covered = min(draggedSpan.1, axis.maxMain(frame)) - max(draggedSpan.0, axis.minMain(frame))
      return max(0, covered) / max(1, min(axis.length(frame), axis.length(dragged.frame)))
    }
    // Stay on the current target while it's still covered at all (its new
    // capsule pushes it right), so the preview doesn't flicker. (Down a
    // sidebar the capsule is a row that pushes it out from under the tab:
    // covering the capsule counts too.)
    if let current = drag.groupWith, overlap(current) > 0.05 { return current }
    if axis == .vertical, let current = drag.groupWith, let preview = previewCapsule {
      let frame = preview.convert(preview.bounds, to: self)
      if min(draggedSpan.1, axis.maxMain(frame)) > max(draggedSpan.0, axis.minMain(frame)) { return current }
    }
    // Otherwise the tab it covers most, once it covers a quarter of it.
    let best = pills.keys.filter { $0 != id }.map { ($0, overlap($0)) }.max { $0.1 < $1.1 }
    guard let best, best.1 >= 0.25 else { return nil }
    return best.0
  }

  private var isDraggingTab: Bool {
    if case .tab? = drag?.kind { return true }
    return false
  }

  // MARK: Drag & drop

  /// Where the dragged item would land: a slot among the pinned tabs, or
  /// among the other items (a group only between groups and loose tabs).
  private func dropTarget() -> DropTarget? {
    drag?.lastTarget
  }

  /// Over the bar (with some slack): positions count. Elsewhere the drop
  /// target stays where it last was.
  private func isValidDragLocation(_ event: NSEvent) -> Bool {
    isValidDragPoint(convert(event.locationInWindow, from: nil))
  }

  private func isValidDragPoint(_ point: NSPoint) -> Bool {
    let start = axis.minMain(pinnedStrip.frame) - 40
    let end = max(axis.maxMain(newTabButton.frame), axis.maxMain(tabStrip.frame)) + 40
    let main = axis.main(point), cross = axis.cross(point)
    return main >= start && main <= end && cross >= -24 && cross <= crossExtent + 24
  }

  private func updateDropTarget(_ event: NSEvent) {
    guard drag != nil else { return }
    if drag?.lastTarget == nil || isValidDragLocation(event) {
      let target = computeDropTarget()  // (reads drag: not while writing it)
      drag?.lastTarget = target
    }
  }

  private func computeDropTarget() -> DropTarget? {
    guard let drag else { return nil }
    let pointer = drag.pointer
    if case .tab = drag.kind, axis == .vertical {
      // Down a sidebar, a tab pins over the pinned tiles (above their
      // separator), or above the first row when there are none yet; its
      // tile goes where the pointer is among them. A little slack keeps it
      // from flickering at the line.
      let pinned = pinnedItems(excludingDrag: true)
      let wasPinned: Bool = { if case .pinned? = drag.lastTarget { return true }; return false }()
      let line = pinned.isEmpty && !wasPinned ? axis.minMain(tabStrip.frame) + 6 : axis.midMain(pinnedSeparator.frame)
      if pointer < line + (wasPinned ? 8 : 0) { return .pinned(tileSlot(at: drag.point, count: pinned.count)) }
    } else if case .tab = drag.kind {
      let pinned = pinnedItems(excludingDrag: true)
      // The tab pins once the icon it would shrink to (under the pointer)
      // reaches the tab area's left edge, so it pins right where it shows;
      // or when the pointer itself is left of the strip. A little slack
      // keeps it from flickering at the edge.
      let leftEdge = pointer - drag.grabFraction * pinnedWidth
      let areaLeft = axis.minMain(tabStrip.frame) + 4
      let wasPinned: Bool = { if case .pinned? = drag.lastTarget { return true }; return false }()
      let staysPinned: Bool
      if drag.startedPinned {
        // A pinned tab unpins as soon as its center passes the separator
        // (and pins back when it comes back over it).
        let center = leftEdge + pinnedWidth / 2
        staysPinned = center <= axis.midMain(pinnedSeparator.frame) + (wasPinned ? 2 : -2)
      } else {
        staysPinned = leftEdge < areaLeft - 2 + (wasPinned ? 8 : 0) || pointer < axis.minMain(tabStrip.frame) - 4
      }
      if staysPinned {
        // By where its icon is (its left end), not the pointer.
        let iconCenter = leftEdge + pinnedWidth / 2
        let slot = pinned.indices.filter { axis.minMain(pinnedStrip.frame) + CGFloat($0) * (pinnedWidth + 2) + pinnedWidth / 2 < iconCenter }.count
        return .pinned(slot)
      }
    }
    let items = unpinnedItems(excludingDrag: true)
    // A neighbour moves aside once the dragged item's leading edge passes its
    // middle, with the gap where it is now (half-way over it: a tab can still
    // overlap its neighbour a little without pushing it, to ⌥-group them).
    func length(_ item: BarItem) -> CGFloat {
      switch item {
      case .capsule(let g): return capsuleLength(g)
      case .tab(let id): return stripTabLengths[id] ?? pills[id].map { axis.length($0.frame) } ?? Theme.tabMinWidth
      }
    }
    let start = axis.minMain(tabStrip.frame) - tabStrip.scrollOffset + 4
    func center(of index: Int, gapAt gap: Int) -> CGFloat {
      var cursor = start
      for i in 0...index {
        if i == gap { cursor += drag.length + spacing }
        if i == index { return cursor + length(items[i]) / 2 }
        cursor += length(items[i]) + spacing
      }
      return cursor
    }
    let draggedCenter = pointer + (0.5 - drag.grabFraction) * drag.length
    var slot: Int
    if case .strip(let last, _)? = drag.lastTarget { slot = min(last, items.count) } else {
      // First evaluation: where it was.
      slot = items.indices.filter { center(of: $0, gapAt: items.count) < draggedCenter }.count
    }
    let draggedLeft = draggedCenter - drag.length / 2
    let draggedRight = draggedCenter + drag.length / 2
    while slot < items.count, draggedRight > center(of: slot, gapAt: slot) { slot += 1 }
    while slot > 0, draggedLeft < center(of: slot - 1, gapAt: slot) { slot -= 1 }
    if case .group = drag.kind {
      // Never inside another group: move to that group's edge.
      while slot > 0, slot < items.count, case .tab(let right) = items[slot], let g = tabInfos[right]?.groupID,
            group(g) != nil {
        slot -= 1
      }
      return .strip(slot, group: nil)
    }
    // A group's ends go by the pointer, not the tab's center: the tab joins a
    // group as soon as the pointer is over it (its capsule coming from the
    // left, its last tab coming from the right), and leaves it once the
    // pointer is past its ends (with the gap, while it's in the group).
    func left(of index: Int, gapAt gap: Int) -> CGFloat { center(of: index, gapAt: gap) - length(items[index]) / 2 }
    var current: UUID?
    switch drag.lastTarget {
    case .strip(_, let g)?: current = g
    case nil: if case .tab(let id) = drag.kind { current = tabInfos[id]?.groupID }
    case .pinned?: break
    }
    for (c, item) in items.enumerated() {
      guard case .capsule(let g) = item, let info = group(g), !info.collapsed else { continue }
      var e = c
      while e + 1 < items.count, case .tab(let id) = items[e + 1], tabInfos[id]?.groupID == g { e += 1 }
      let inside = current == g
      let groupStart = left(of: c, gapAt: inside ? e + 1 : c)
      let groupEnd = left(of: e, gapAt: e + 1) + length(items[e]) + (inside ? spacing + drag.length : 0)
      if pointer >= groupStart, pointer <= groupEnd { return .strip(min(max(slot, c + 1), e + 1), group: g) }
      if slot > c, slot <= e { return .strip(pointer < groupStart ? c : e + 1, group: nil) }
    }
    return .strip(slot, group: nil)
  }

  /// The dragged item stays over the bar's tab area.
  private func clampedPointer(_ main: CGFloat) -> CGFloat {
    min(max(main, axis.minMain(pinnedStrip.frame) - 20), max(axis.maxMain(newTabButton.frame), axis.maxMain(tabStrip.frame)))
  }

  /// A drag always ends: if the release never reaches the tab (another
  /// window took it), finish as soon as the button is up.
  /// While a drag is near the strip's ends, scroll that way (faster closer
  /// to the edge), about 60 times a second.
  /// Test hooks: the tab at `index` as if hovered.
  func simulateHover(tabAt index: Int, _ on: Bool) {
    guard order.indices.contains(index) else { return }
    pills[order[index]]?.simulateHover(on)
  }

  /// Test hooks: drags the tab at `index` (or, with `group`, that group's
  /// capsule) from `from` to `to` (window points) as the mouse would, minus
  /// the window's event routing (which a locked screen stops).
  func simulateDrag(tabAt index: Int?, group: Int?, from: NSPoint, to: NSPoint, option: Bool) {
    guard let window else { return }
    let send: (DragPhase, NSEvent) -> Void
    if let group, groupInfos.indices.contains(group) {
      let g = groupInfos[group].id
      send = { [weak self] phase, event in self?.dragGroup(g, phase: phase, event: event) }
    } else if let index, order.indices.contains(index) {
      let id = order[index]
      send = { [weak self] phase, event in self?.dragTab(id, phase: phase, event: event) }
    } else {
      return
    }
    func event(_ t: CGFloat) -> NSEvent? {
      NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
                         modifierFlags: option ? [.option] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
    for step in 0...13 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.03 + (step == 13 ? 1.2 : 0)) {
        guard let e = event(CGFloat(min(step, 12)) / 12) else { return }
        send(step == 0 ? .began : step == 13 ? .ended : .moved, e)
      }
    }
  }

  private func isDragged(_ id: ObjectIdentifier) -> Bool {
    switch drag?.kind {
    case .tab(let dragged)?: return dragged == id
    case .group(let g)?: return tabInfos[id]?.groupID == g
    case nil: return false
    }
  }

  /// A dragged tab takes the look of where it would land: it shrinks to a
  /// pinned tab over the pinned tabs, and grows back over the strip.
  private func updateDraggedTabLook() {
    guard let drag, case .tab(let id) = drag.kind, drag.groupWith == nil else { return }
    let pinned: Bool
    switch drag.lastTarget {
    case .pinned?: pinned = true
    case .strip?: pinned = false
    case nil: pinned = tabInfos[id]?.isPinned == true
    }
    let length = axis == .vertical ? (pinned ? tileHeight : rowLength)
      : pinned ? pinnedWidth : min(naturalTabWidth(id), max(stripTabWidth, Theme.tabMinWidth))
    self.drag?.length = length
    if Motion.reduceMotion { self.drag?.shownLength = length }
    pills[id]?.setPinnedLook(pinned)
  }

  private func autoScroll() {
    guard let drag else { return }
    // The dragged tab eases to its new length (and down a sidebar, its place
    // and thickness across).
    func eased(_ shown: CGFloat, _ target: CGFloat) -> CGFloat { abs(target - shown) < 0.5 ? target : shown + (target - shown) * 0.3 }
    if axis == .vertical, drag.shownCross != drag.cross || drag.shownThickness != drag.thickness {
      self.drag?.shownCross = eased(drag.shownCross, drag.cross)
      self.drag?.shownThickness = eased(drag.shownThickness, drag.thickness)
      if drag.shownLength == drag.length { relayout(animated: true) }
    }
    if drag.shownLength != drag.length {
      self.drag?.shownLength = eased(drag.shownLength, drag.length)
      relayout(animated: true)
    }
    let edge: CGFloat = 48
    let stripStart = axis.minMain(tabStrip.frame), stripEnd = axis.maxMain(tabStrip.frame)
    var speed: CGFloat = 0
    if drag.pointer >= stripStart + 2, drag.pointer < stripStart + edge { speed = -(stripStart + edge - drag.pointer) / edge }
    if drag.pointer > stripEnd - edge { speed = (drag.pointer - (stripEnd - edge)) / edge }
    let before = tabStrip.scrollOffset
    if speed != 0, tabStrip.scroll(by: min(1, max(-1, speed)) * 14) {
      // What's under the pointer changed.
      let target = computeDropTarget()
      if self.drag?.groupWith == nil { self.drag?.lastTarget = target }
      scrollShift = tabStrip.scrollOffset - before
      relayout(animated: true)
      scrollShift = 0
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in self?.autoScroll() }
  }

  private func watchForLostRelease(_ finish: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, self.drag != nil else { return }
      // Button up and no drag events for a while: the release went elsewhere.
      // (Test hooks post events that don't press the real button.)
      let testing = ProcessInfo.processInfo.environment["GLEA_TEST_HOOKS"] != nil
      if !testing, NSEvent.pressedMouseButtons & 1 == 0, CACurrentMediaTime() - self.lastDragEventTime > 0.5 {
        finish()
      } else {
        self.watchForLostRelease(finish)
      }
    }
  }

  fileprivate func dragTab(_ id: ObjectIdentifier, phase: DragPhase, event: NSEvent) {
    guard let pill = pills[id], isWeb else { return }
    lastDragEventTime = CACurrentMediaTime()
    let pointer = axis.main(convert(event.locationInWindow, from: nil))
    switch phase {
    case .began:
      // Where it is on screen: it may still be springing from a drop.
      var shown = pill.frame
      if let layer = pill.layer, layer.animation(forKey: "glea.spring.position") != nil, let presentation = layer.presentation() {
        shown = axis.rect(shown, main: axis.minMain(shown) + axis.main(presentation.position) - axis.main(layer.position),
                          length: axis.length(presentation.bounds))
      }
      pill.layer?.removeAnimation(forKey: "glea.spring.position")
      pill.layer?.removeAnimation(forKey: "glea.spring.bounds")
      let frame = pill.superview.map { convert(shown, from: $0) } ?? pill.frame
      let length = tabInfos[id]?.isPinned == true ? pinnedWidth : axis.length(frame)
      // Held where it was pressed (the drag starts a few points later).
      let pressed = pill.pressStart.map { axis.main(convert($0, from: nil)) } ?? pointer
      let fraction = min(1, max(0, (pressed - axis.minMain(frame)) / max(1, axis.length(frame))))
      drag = TabDrag(kind: .tab(id), grabFraction: fraction, pointer: pointer,
                     length: length, shownLength: axis.length(frame))
      drag?.startedPinned = tabInfos[id]?.isPinned == true
      drag?.point = convert(event.locationInWindow, from: nil)
      if axis == .vertical {
        // Across, it starts where it is, held where it was pressed.
        let pressedAt = pill.pressStart.map { convert($0, from: nil) } ?? convert(event.locationInWindow, from: nil)
        drag?.crossFraction = min(1, max(0, (pressedAt.x - frame.minX) / max(1, frame.width)))
        drag?.shownCross = frame.minX
        drag?.shownThickness = frame.width
      }
      // It starts where it is (the gap it leaves), then moves from there.
      if tabInfos[id]?.isPinned == true {
        drag?.lastTarget = pinnedItems(excludingDrag: false).firstIndex(of: id).map { .pinned($0) }
      } else if let index = unpinnedItems(excludingDrag: false).firstIndex(of: .tab(id)) {
        drag?.lastTarget = .strip(index, group: tabInfos[id]?.groupID)
      }
      addSubview(pill)  // above both strips while dragged
      pill.frame = frame
      pill.isDragged = true
      setHoverSuspended(true)
      updateDropTarget(event)
      relayout(animated: true)
      watchForLostRelease { [weak self] in self?.dragTab(id, phase: .ended, event: event) }
      autoScroll()
    case .moved:
      guard drag != nil else { return }
      drag?.pointer = clampedPointer(pointer)
      drag?.point = convert(event.locationInWindow, from: nil)
      setGroupingTarget(groupingTarget(event, dragging: id))
      if drag?.groupWith == nil { updateDropTarget(event) }
      relayout(animated: true)
    case .ended:
      guard drag != nil else { return }
      window?.isMovable = true
      pill.contentFade = 1
      pill.isDragged = false
      // (Once it's put back in the strip and the others moved.)
      defer { setHoverSuspended(false) }
      let target = dropTarget()
      let items = unpinnedItems(excludingDrag: true)
      let groupWith = drag?.groupWith
      drag = nil
      // Into the strip it lands in, where it is, so it springs into place.
      var pinned = tabInfos[id]?.isPinned == true
      if groupWith != nil { pinned = false } else if case .pinned? = target { pinned = true } else if case .strip? = target { pinned = false }
      let strip: NSView = pinned ? pinnedStrip : tabStrip
      let frame = pill.convert(pill.bounds, to: strip)
      strip.addSubview(pill)
      pill.frame = frame
      releasedViews = [pill]
      defer { releasedViews = [] }
      guard let from = order.firstIndex(of: id) else { return }
      if let groupWith, let targetIndex = order.firstIndex(of: groupWith) {
        hidePreviewInstantly()
        delegate?.topBarGroupTab(at: from, withTabAt: targetIndex)
        relayout(animated: true)
        return
      }
      switch target {
      case .pinned(let slot):
        delegate?.topBarMoveTab(at: from, toIndex: slot, pinned: true, group: nil)
      case .strip(let slot, let joins):
        let pinnedCount = pinnedItems(excludingDrag: false).filter { $0 != id }.count
        let before = items.prefix(slot).reduce(0) { sum, item in
          switch item {
          case .tab: return sum + 1
          case .capsule(let g): return sum + ((group(g)?.collapsed ?? false) ? members(g).filter { $0 != id }.count : 0)
          }
        }
        delegate?.topBarMoveTab(at: from, toIndex: pinnedCount + before, pinned: false, group: joins)
      case nil:
        break
      }
      relayout(animated: true)
    }
  }

  /// Hover is off for the bar's tabs while one is dragged; back on, it's
  /// matched to the pointer, again once the tabs have sprung into place.
  private func setHoverSuspended(_ suspended: Bool) {
    for pill in pills.values { pill.hoverSuspended = suspended }
    guard !suspended else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
      guard let self, self.drag == nil else { return }
      for pill in self.pills.values { pill.syncHoverWithPointer() }
    }
  }

  fileprivate func dragGroup(_ g: UUID, phase: DragPhase, event: NSEvent) {
    guard let capsule = capsules[g], isWeb else { return }
    lastDragEventTime = CACurrentMediaTime()
    let pointer = axis.main(convert(event.locationInWindow, from: nil))
    switch phase {
    case .began:
      let frame = capsule.convert(capsule.bounds, to: self)
      let collapsed = group(g)?.collapsed ?? false
      let views: [NSView] = [capsule] + (collapsed ? [] : members(g).compactMap { pills[$0] })
      let end = views.map { axis.maxMain($0.convert($0.bounds, to: self)) }.max() ?? axis.maxMain(frame)
      let length = end - axis.minMain(frame)
      drag = TabDrag(kind: .group(g), grabFraction: (pointer - axis.minMain(frame)) / max(1, length), pointer: pointer,
                     length: length, shownLength: length)
      for view in views {
        let f = view.convert(view.bounds, to: self)
        addSubview(view)
        view.frame = f
      }
      updateDropTarget(event)
      relayout(animated: true)
      watchForLostRelease { [weak self] in self?.dragGroup(g, phase: .ended, event: event) }
      autoScroll()
    case .moved:
      guard drag != nil else { return }
      drag?.pointer = clampedPointer(pointer)
      updateDropTarget(event)
      relayout(animated: true)
    case .ended:
      guard drag != nil else { return }
      window?.isMovable = true
      let target = dropTarget()
      let items = unpinnedItems(excludingDrag: true)
      drag = nil
      // Back into the strip; the controller's update places them.
      releasedViews = [capsule] + members(g).compactMap({ pills[$0] })
      defer { releasedViews = [] }
      for view in releasedViews {
        let f = view.convert(view.bounds, to: tabStrip)
        tabStrip.addSubview(view)
        view.frame = f
      }
      if case .strip(let slot, _) = target {
        let pinnedCount = pinnedItems(excludingDrag: false).count
        let before = items.prefix(slot).reduce(0) { sum, item in
          switch item {
          case .tab: return sum + 1
          case .capsule(let other): return sum + ((group(other)?.collapsed ?? false) ? members(other).count : 0)
          }
        }
        delegate?.topBarMoveGroup(g, toIndex: pinnedCount + before)
      }
      relayout(animated: true)
    }
  }
}

/// A group's line: under its capsule and tabs in the bar, along their left in
/// a sidebar. A view, so it moves (springs) exactly like them.
private final class GroupLineView: NSView {
  var color: NSColor = .gray {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 0.75
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = resolvedCGColor(color)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A group's capsule in the tab bar: its name (and count, when collapsed) on
/// its color. Click to collapse or expand, right-click for its menu, drag to
/// move the whole group.
private final class GroupCapsule: NSView {
  /// The bar sits in the window's title bar, where macOS drags the window
  /// from any view that doesn't claim its area (controls do, plain views
  /// don't), before the app even sees the press. Claim it: tabs drag tabs,
  /// and the bar drags the window from its empty space itself (mouseDown).
  @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

  var onToggle: (() -> Void)?
  var onMenu: (() -> NSMenu?)?
  var onDrag: ((DragPhase, NSEvent) -> Void)?
  /// Drags start once the pointer moves this way (along the tabs).
  var dragAxis = TabAxis.horizontal

  private let label = NSTextField.label("", size: 11, weight: .medium)
  private let fill = CALayer()
  private let ring = CALayer()
  /// The outline around the colored marker, part of the capsule's size.
  static let ring: CGFloat = 3
  static let height: CGFloat = 22 + 2 * ring
  private var color = NSColor.gray
  private var tracking: NSTrackingArea?
  private var hovering = false { didSet { refresh() } }
  private var pressStart: NSPoint?
  private var dragging = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    ring.cornerRadius = 7
    ring.cornerCurve = .continuous
    fill.cornerRadius = 5
    fill.cornerCurve = .continuous
    layer?.addSublayer(ring)
    layer?.addSublayer(fill)
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }

  /// Down a sidebar the capsule takes its whole row (it's grabbed anywhere
  /// on it) but is drawn this wide, at the row's start. Nil: as wide as it is.
  var markerWidth: CGFloat? {
    didSet { if markerWidth != oldValue { needsLayout = true } }
  }

  var fittingWidth: CGFloat {
    let text = label.stringValue
    let marker = text.isEmpty ? 16 : min(300, max(22, ceil(label.intrinsicContentSize.width) + 16))
    return marker + 2 * Self.ring
  }

  func configure(label text: String, color: NSColor) {
    self.color = color
    label.stringValue = text
    toolTip = text.isEmpty ? "Tab group" : text
    refresh()
    needsLayout = true
  }

  private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

  private func refresh() {
    Motion.withoutAnimation {
      fill.backgroundColor = resolvedCGColor(color)
      ring.backgroundColor = resolvedCGColor(color.withAlphaComponent(hovering ? (isDark ? 0.36 : 0.3) : (isDark ? 0.24 : 0.2)))
    }
    label.textColor = isDark ? NSColor.black.withAlphaComponent(0.94) : .white
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refresh()
  }

  override func layout() {
    super.layout()
    // (A sidebar's spans its row, drawn at its start.)
    let drawn = NSRect(x: 0, y: 0, width: markerWidth.map { min($0, bounds.width) } ?? bounds.width, height: bounds.height)
    Motion.withoutAnimation {
      ring.frame = drawn
      fill.frame = drawn.insetBy(dx: Self.ring, dy: Self.ring)
    }
    let h = label.intrinsicContentSize.height
    label.frame = NSRect(x: Self.ring + 6, y: (bounds.height - h) / 2, width: max(0, drawn.width - 2 * Self.ring - 12), height: h)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  /// The strip scrolled under a still pointer (no enter or exit events).
  func syncHoverWithPointer() {
    guard let window, !isHiddenOrHasHiddenAncestor else { return hovering = false }
    let point = window.mouseLocationOutsideOfEventStream
    hovering = bounds.contains(convert(point, from: nil))
      && (superview.map { $0.bounds.contains($0.convert(point, from: nil)) } ?? true)
  }

  override func mouseDown(with event: NSEvent) {
    pressStart = event.locationInWindow
    dragging = false
    window?.isMovable = false  // drags move the group, never the window
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = pressStart else { return }
    if !dragging, abs(dragAxis.main(event.locationInWindow) - dragAxis.main(start)) > 4 {
      dragging = true
      onDrag?(.began, event)
    }
    if dragging { onDrag?(.moved, event) }
  }

  override func mouseUp(with event: NSEvent) {
    window?.isMovable = true
    defer { pressStart = nil }
    if dragging {
      dragging = false
      onDrag?(.ended, event)
    } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
      onToggle?()
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let menu = onMenu?() else { return }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  /// A dragged tab is about to join: a small bounce.
  func pulse() {
    guard let layer, !Motion.reduceMotion else { return }
    let bounce = Motion.spring("transform", stiffness: 500, damping: 14)
    bounce.fromValue = centeredScale(1.15)
    bounce.toValue = CATransform3DIdentity
    layer.add(bounce, forKey: "pulse")
  }
}
