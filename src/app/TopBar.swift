import AppKit

@MainActor
protocol TopBarDelegate: AnyObject {
  func topBarSelectTab(at index: Int)
  func topBarCloseTab(at index: Int)
  func topBarEditActiveTabAddress()
  func topBarNewTab()
  func topBarToggleMute(at index: Int)
  func topBarShowJournal()
  func topBarShowNotes()
  func topBarGoBack()
  func topBarGoForward()
  func topBarReload()
  func topBarSearch()
  func topBarToggleMode()
  func topBarShowExtensions(from anchor: NSRect)
  /// A pinned extension's button: open its popup under it.
  func topBarOpenExtension(_ id: String, from anchor: NSRect)
  func topBarUnpinExtension(_ id: String)
  func topBarMenu(forTabAt index: Int) -> NSMenu?
  func topBarMenu(forGroup id: UUID) -> NSMenu?
  func topBarToggleGroup(_ id: UUID)
  /// Drag & drop: the tab goes to `toIndex` among all tabs (without it).
  func topBarMoveTab(at index: Int, toIndex: Int, pinned: Bool, group: UUID?)
  /// Drag & drop: the group's tabs go to `toIndex` among the other tabs.
  func topBarMoveGroup(_ id: UUID, toIndex: Int)
  /// ⌥-drag onto a tab: group the two (or join the target's group).
  func topBarGroupTab(at index: Int, withTabAt target: Int)
}

/// What a tab does with sound, the camera and the microphone.
struct TabMedia: Equatable {
  var audible = false
  var muted = false
  var camera = false
  var microphone = false

  /// Sound (playing, or muted: the tab can be unmuted).
  var sound: Bool { audible || muted }
  /// How many of sound, camera and microphone it uses.
  var count: Int { [sound, camera, microphone].filter { $0 }.count }
}

/// Borderless icon button: its background fades in on hover and darkens
/// while pressed; the icon dips slightly on press.
final class IconButton: NSControl {
  private let background = HighlightLayer()
  private let icon = NSImageView()
  private var tracking: NSTrackingArea?
  private var hovering = false { didSet { refresh() } }
  private var pressed = false { didSet { refresh() } }

  init(symbol: String, size: CGFloat = 13, tooltip: String? = nil, target: AnyObject?, action: Selector?) {
    super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    wantsLayer = true
    layer?.addSublayer(background)
    icon.image = Theme.symbol(symbol, size: size)
    symbolName = symbol
    icon.imageScaling = .scaleNone
    icon.contentTintColor = Theme.secondaryText
    icon.wantsLayer = true
    addSubview(icon)
    toolTip = tooltip
    self.target = target
    self.action = action
    translatesAutoresizingMaskIntoConstraints = false
    let width = widthAnchor.constraint(equalToConstant: 28)
    let height = heightAnchor.constraint(equalToConstant: 28)
    width.priority = .defaultHigh
    height.priority = .defaultHigh
    NSLayoutConstraint.activate([width, height])
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }

  override func layout() {
    super.layout()
    Motion.withoutAnimation { background.frame = bounds }
    icon.frame = bounds
  }

  var isActive = false { didSet { refresh() } }
  /// Off: just an icon (no hover or press highlight).
  var isInteractive = true { didSet { refresh() } }
  /// The icon's color at rest (hovered or active, it's the text color).
  var restingTint = Theme.secondaryText {
    didSet { refresh() }
  }
  /// Right-click menu.
  var onMenu: (() -> NSMenu?)?

  private var symbolName = ""

  /// Swaps the symbol with the favicon's pop-in.
  func popSymbol(_ name: String, size: CGFloat) {
    guard name != symbolName else { return }
    symbolName = name
    icon.image = Theme.symbol(name, size: size)
    icon.popIn()
  }

  /// A template image drawn like the symbols (tinted, at its own size).
  func setSymbolImage(_ image: NSImage?) {
    symbolName = ""
    icon.image = image
  }

  /// A full-color image (an extension's icon) instead of a symbol, at 16pt.
  func setImage(_ image: NSImage?) {
    symbolName = ""
    let sized = image?.copy() as? NSImage
    sized?.size = NSSize(width: 16, height: 16)
    icon.image = sized ?? Theme.symbol("puzzlepiece.extension", size: 13)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let menu = onMenu?() else { return super.rightMouseDown(with: event) }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  /// Swaps the icon, cross-fading when animated.
  func setSymbol(_ name: String, size: CGFloat = 14, animated: Bool) {
    guard name != symbolName else { return }
    symbolName = name
    if animated, let layer = icon.layer, !Motion.reduceMotion {
      let fade = CATransition()
      fade.type = .fade
      fade.duration = 0.18
      fade.timingFunction = Motion.easeInOut
      layer.add(fade, forKey: "symbol")
      let pop = Motion.spring("transform", stiffness: 380, damping: 18)
      pop.fromValue = icon.centeredScale(0.7)
      pop.toValue = CATransform3DIdentity
      layer.add(pop, forKey: "pop")
    }
    icon.image = Theme.symbol(name, size: size)
  }

  override var isEnabled: Bool {
    didSet {
      icon.alphaValue = isEnabled ? 1 : 0.35
      refresh()
    }
  }

  private func refresh() {
    let color: NSColor
    if pressed && isEnabled && isInteractive {
      color = Theme.selected
    } else if isActive || (hovering && isEnabled && isInteractive) {
      color = isActive ? Theme.selected : Theme.hover
    } else {
      color = .clear
    }
    background.backgroundColor = resolvedCGColor(color)
    icon.contentTintColor = isActive || (hovering && isEnabled && isInteractive) ? Theme.text : restingTint
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refresh()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                              owner: self)
    addTrackingArea(area)
    tracking = area
  }

  // A button: the arrow, whatever was set before (an I-beam from text).
  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

  /// Clicks are the button's, not its icon's (a table checks which view
  /// takes a click, and keeps those not on a control).
  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point) == nil ? nil : self
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  /// Tabs that move under a still pointer (scrolling the strip) get no
  /// enter/exit events: match the hover to where the pointer is now.
  func syncHoverWithPointer() {
    guard let window, !isHidden else { return }
    let point = window.mouseLocationOutsideOfEventStream
    let inside = bounds.contains(convert(point, from: nil))
      && (superview.map { $0.bounds.contains($0.convert(point, from: nil)) } ?? true)
    if inside != hovering { hovering = inside }
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    pressed = true
    press(true)
    // Track until mouse up, like a button.
    while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      let inside = bounds.contains(convert(next.locationInWindow, from: nil))
      if next.type == .leftMouseUp {
        pressed = false
        press(false)
        if inside { sendAction(action, to: target) }
        break
      }
      pressed = inside
    }
  }

  private func press(_ down: Bool) {
    guard let layer = icon.layer else { return }
    let animation: CAAnimation
    if down {
      let basic = Motion.basic("transform", duration: 0.08, timing: Motion.easeInOut)
      basic.toValue = icon.centeredScale(0.86)
      animation = basic
    } else {
      let spring = Motion.spring("transform", stiffness: 480, damping: 20)
      spring.fromValue = layer.presentation()?.transform ?? icon.centeredScale(0.86)
      spring.toValue = CATransform3DIdentity
      animation = spring
    }
    animation.fillMode = .forwards
    animation.isRemovedOnCompletion = !down
    layer.add(animation, forKey: "press")
  }
}

/// Text button used in the bar in notes mode ("Journal", "All Notes").
final class TextButton: NSControl {
  private let background = HighlightLayer()
  private let label: NSTextField
  private var tracking: NSTrackingArea?
  private var hovering = false { didSet { refresh() } }

  var isActive = false { didSet { refresh() } }

  init(title: String, target: AnyObject?, action: Selector?) {
    label = NSTextField.label(title, size: 13, weight: .medium, color: Theme.secondaryText)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(background)
    label.translatesAutoresizingMaskIntoConstraints = true
    addSubview(label)
    self.target = target
    self.action = action
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }

  var fittingWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 24 }

  override func layout() {
    super.layout()
    Motion.withoutAnimation { background.frame = bounds }
    let height = label.intrinsicContentSize.height
    label.frame = NSRect(x: 10, y: (bounds.height - height) / 2, width: bounds.width - 16, height: height)
  }

  private func refresh() {
    background.backgroundColor = resolvedCGColor(isActive ? Theme.selected : (hovering ? Theme.hover : .clear))
    label.textColor = isActive || hovering ? Theme.text : Theme.secondaryText
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refresh()
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

  /// Tabs that move under a still pointer (scrolling the strip) get no
  /// enter/exit events: match the hover to where the pointer is now.
  func syncHoverWithPointer() {
    guard let window, !isHidden else { return }
    let point = window.mouseLocationOutsideOfEventStream
    let inside = bounds.contains(convert(point, from: nil))
      && (superview.map { $0.bounds.contains($0.convert(point, from: nil)) } ?? true)
    if inside != hovering { hovering = inside }
  }

  override func mouseDown(with event: NSEvent) {
    guard let layer else { return }
    let down = Motion.basic("transform", duration: 0.08, timing: Motion.easeInOut)
    down.toValue = centeredScale(0.96)
    down.fillMode = .forwards
    down.isRemovedOnCompletion = false
    layer.add(down, forKey: "press")
  }

  override func mouseUp(with event: NSEvent) {
    if let layer {
      let up = Motion.spring("transform", stiffness: 480, damping: 22)
      up.fromValue = layer.presentation()?.transform ?? centeredScale(0.96)
      up.toValue = CATransform3DIdentity
      layer.add(up, forKey: "press")
    }
    if bounds.contains(convert(event.locationInWindow, from: nil)) { sendAction(action, to: target) }
  }
}

/// The single bar at the top of the window, which doubles as the title bar.
///
/// - Web: back/forward/reload, the tabs and a new-tab button.
/// - Notes: "Journal" and "All Notes"; the tabs step aside.
/// - Always on the right: search, and one button toggling web ↔ notes.
final class TopBarView: NSView {
  /// The bar sits in the window's title bar, where macOS drags the window
  /// from any view that doesn't claim its area (controls do, plain views
  /// don't), before the app even sees the press. Claim it: tabs drag tabs,
  /// and the bar drags the window from its empty space itself (mouseDown).
  @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

  struct TabInfo {
    var id: ObjectIdentifier
    var title: String
    var url: String
    var favicon: NSImage?
    var isLoading: Bool
    var isPinned = false
    var groupID: UUID?
    var media = TabMedia()
  }

  struct GroupInfo {
    var id: UUID
    var label: String
    var color: NSColor
    var collapsed: Bool
  }

  enum Section {
    case journal, notes, web, other
  }

  weak var delegate: TopBarDelegate?

  private lazy var backButton = IconButton(symbol: "chevron.left", tooltip: "Back (⌘[)", target: self, action: #selector(goBack))
  private lazy var forwardButton = IconButton(symbol: "chevron.right", tooltip: "Forward (⌘])", target: self, action: #selector(goForward))
  private lazy var reloadButton = IconButton(symbol: "arrow.clockwise", size: 12, tooltip: "Reload (⌘R)", target: self, action: #selector(reload))
  private lazy var newTabButton = IconButton(symbol: "plus", tooltip: "New Tab (⌘T)", target: self, action: #selector(newTab))
  private lazy var journalButton: TextButton = {
    let button = TextButton(title: "Journal", target: self, action: #selector(showJournal))
    button.toolTip = "Journal (⇧⌘J)"
    return button
  }()
  private lazy var notesButton: TextButton = {
    let button = TextButton(title: "All Notes", target: self, action: #selector(showNotes))
    button.toolTip = "All Notes (⌥⇧⌘N)"
    return button
  }()
  private lazy var extensionsButton = IconButton(symbol: "puzzlepiece.extension", size: 13, tooltip: "Extensions", target: self, action: #selector(showExtensions))
  /// Hidden where tabs can't run extensions (Alloy-style fallback).
  var showsExtensions = true
  /// Pinned extensions, left of the puzzle button (in pin order).
  private var extensionButtons: [(id: String, button: IconButton)] = []

  struct PinnedExtension {
    let id: String
    let name: String
    let icon: NSImage?
  }

  func setPinnedExtensions(_ extensions: [PinnedExtension]) {
    let old = Dictionary(uniqueKeysWithValues: extensionButtons.map { ($0.id, $0.button) })
    var buttons: [(id: String, button: IconButton)] = []
    var added: [IconButton] = []
    for ext in extensions {
      let button = old[ext.id] ?? {
        let button = IconButton(symbol: "puzzlepiece.extension", size: 13, target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.target = self
        button.action = #selector(openPinnedExtension(_:))
        button.onMenu = { [weak self] in
          let menu = NSMenu()
          menu.addItem(ClosureMenuItem(title: "Unpin \(ext.name)") { self?.delegate?.topBarUnpinExtension(ext.id) })
          return menu
        }
        addSubview(button)
        // No frame yet: the layout puts it in place (it pops in there
        // rather than springing from the bar's corner).
        button.frame = .zero
        if !isWeb { button.alphaValue = 0; button.isHidden = true }
        added.append(button)
        return button
      }()
      button.setImage(ext.icon)
      button.toolTip = ext.name
      buttons.append((ext.id, button))
    }
    // Unpinned: shrinks and fades out where it was.
    let animated = window != nil && isWeb
    for (id, button) in old where !buttons.contains(where: { $0.id == id }) {
      if animated {
        button.animateOut(scale: 0.6, fade: 0.12, duration: 0.18) { button.removeFromSuperview() }
      } else {
        button.removeFromSuperview()
      }
    }
    extensionButtons = buttons
    // The others slide over and the tabs make or take the room, springing.
    layoutItems(animated: animated, added: [])
    // Pinned: pops in like a favicon.
    if animated { for button in added { button.popIn() } }
  }

  @objc private func openPinnedExtension(_ sender: IconButton) {
    guard let entry = extensionButtons.first(where: { $0.button === sender }) else { return }
    delegate?.topBarOpenExtension(entry.id, from: sender.frame)
  }
  private lazy var searchButton = IconButton(symbol: "magnifyingglass", size: 13, tooltip: "Search (⌘T)", target: self, action: #selector(search))
  /// In the notes: sound plays somewhere in the app (a tab, a note's
  /// media); mutes or unmutes all of it.
  private lazy var soundButton = IconButton(symbol: "speaker.wave.2.fill", size: 12, tooltip: "Mute Sound", target: self,
                                            action: #selector(toggleSound))
  private lazy var modeButton = IconButton(symbol: "note.text", size: 14, tooltip: "Switch to Notes (⌘D)", target: self, action: #selector(toggleMode))
  /// Left of the search button in incognito windows.
  private lazy var incognitoBadge = IncognitoBadge()
  var isIncognito = false {
    didSet {
      if isIncognito && incognitoBadge.superview == nil { addSubview(incognitoBadge) }
      incognitoBadge.isHidden = !isIncognito
      needsLayout = true
    }
  }

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
  private var underlines: [UUID: CALayer] = [:]
  private var drag: TabDrag?
  private var lastDragEventTime: CFTimeInterval = 0
  /// Views just dropped (back in the strip): their spring starts where they are.
  private var releasedViews: [NSView] = []
  /// The width of unpinned tabs at the last layout.
  /// The widest a tab may be in the strip now (tabs are narrower when their
  /// title is short).
  private var stripTabWidth: CGFloat = 0
  /// Each strip tab's width in the last layout.
  private var stripTabWidths: [ObjectIdentifier: CGFloat] = [:]

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
  private let backgroundLayer = HighlightLayer()
  private let separatorLayer = CALayer()
  private let progressLayer = CALayer()
  private var progress: Double = 0

  private(set) var section: Section = .journal
  private var activeID: ObjectIdentifier?
  private var activeTabShown: ObjectIdentifier?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(appActiveChanged), name: name, object: nil)
    }
    backgroundLayer.cornerRadius = 0
    layer?.addSublayer(backgroundLayer)
    layer?.addSublayer(separatorLayer)
    progressLayer.anchorPoint = .zero
    progressLayer.cornerRadius = 1
    layer?.addSublayer(progressLayer)
    for view in [backButton, forwardButton, reloadButton, newTabButton, extensionsButton, journalButton, notesButton, searchButton, modeButton,
                 soundButton] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(view)
    }
    soundButton.isHidden = true
    NotificationCenter.default.addObserver(forName: SoundMonitor.didChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateSoundButton() }
    }
    pinnedStrip.wantsLayer = true
    addSubview(pinnedStrip, positioned: .below, relativeTo: newTabButton)
    addSubview(pinnedSeparator, positioned: .below, relativeTo: newTabButton)
    tabStrip.onScroll = { [weak self] in
      guard let self else { return }
      self.layoutItems(animated: false, added: [])
      for pill in self.pills.values { pill.syncHoverWithPointer() }
    }
    addSubview(tabStrip, positioned: .below, relativeTo: newTabButton)
    for view in webOnlyViews { view.alphaValue = 0; view.isHidden = true }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // Keep the active tab in view as the window narrows.
    layoutItems(animated: false, added: [], reveal: activeID)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var isWeb: Bool { section == .web }
  private var webOnlyViews: [NSView] {
    [reloadButton, newTabButton, tabStrip, pinnedStrip, pinnedSeparator]
      + (showsExtensions ? [extensionsButton] + extensionButtons.map(\.button) : [])
  }
  private var notesOnlyViews: [NSView] { [journalButton, notesButton] }

  override var mouseDownCanMoveWindow: Bool { false }

  // Behave like a title bar: drag to move, double-click to zoom.
  override func mouseDown(with event: NSEvent) {
    window?.isMovable = true  // (in case a tab press never saw its release)
    if event.clickCount == 2 {
      window?.performZoom(nil)
    } else {
      window?.performDrag(with: event)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  /// Like Beam: while the window isn't focused (the app isn't active), the
  /// tabs fade, and the web bar turns gray (light mode).
  private var windowIsActive = NSApp.isActive {
    didSet {
      guard windowIsActive != oldValue else { return }
      Motion.animate(0.15, timing: Motion.easeInOut) {
        applyColors()
        for view in dimmedViews where !view.isHidden && view.alphaValue > 0 { view.animator().alphaValue = fullAlpha(view) }
      }
    }
  }

  @objc private func appActiveChanged() { windowIsActive = NSApp.isActive }

  func setWindowActiveForTesting(_ active: Bool) { windowIsActive = active }

  /// Web tabs, and the notes' Journal / All Notes tabs.
  private var dimmedViews: [NSView] { [tabStrip, pinnedStrip, journalButton, notesButton] }

  /// A shown view's opacity: the tabs fade while the window isn't focused.
  private func fullAlpha(_ view: NSView) -> CGFloat {
    guard !windowIsActive, dimmedViews.contains(view) else { return 1 }
    return effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.6 : 0.8
  }

  private func applyColors() {
    // Notes keep their bar the note's color (only the tabs fade).
    let bar = !isWeb ? Theme.background : windowIsActive ? Theme.webBar : Theme.inactiveWebBar
    backgroundLayer.backgroundColor = resolvedCGColor(bar)
    separatorLayer.backgroundColor = resolvedCGColor(Theme.separator)
    progressLayer.backgroundColor = resolvedCGColor(Theme.accent)
  }

  func update(section: Section, tabs: [TabInfo], groups: [GroupInfo], activeID: ObjectIdentifier?, canGoBack: Bool, canGoForward: Bool,
              progress: Double) {
    let sectionChanged = section != self.section
    self.section = section
    self.activeID = activeID
    journalButton.isActive = section == .journal
    notesButton.isActive = section == .notes
    backButton.isEnabled = canGoBack
    forwardButton.isEnabled = canGoForward
    modeButton.setSymbol(isWeb ? "note.text" : "globe", animated: sectionChanged && window != nil)
    modeButton.toolTip = isWeb ? "Switch to Notes (⌘D)" : "Switch to Web (⌘D)"

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

    self.progress = progress
    let animated = window != nil
    Motion.animate(animated ? 0.2 : 0, timing: Motion.easeInOut) {
      applyColors()
      separatorLayer.opacity = isWeb ? 1 : 0
    }
    if sectionChanged {
      setVisible(webOnlyViews, isWeb, animated: animated)
      setVisible(notesOnlyViews, !isWeb, animated: animated)
    }
    updateSoundButton()
    layoutItems(animated: animated, added: isWeb ? added : [], reveal: activeChanged || !added.isEmpty ? activeID : nil)
    updateProgress()
  }

  /// Fades views in or out (hidden once invisible so they can't be clicked).
  private func setVisible(_ views: [NSView], _ visible: Bool, animated: Bool) {
    // Only views that actually appear or disappear animate (journal → note
    // keeps Journal / All Notes on screen: no blink).
    let views = views.filter { visible ? ($0.isHidden || $0.alphaValue < fullAlpha($0)) : (!$0.isHidden && $0.alphaValue > 0) }
    guard !views.isEmpty else { return }
    for view in views where visible { view.isHidden = false }
    Motion.animate(animated ? (visible ? 0.22 : 0.14) : 0, timing: Motion.easeInOut, {
      for view in views { view.animator().alphaValue = visible ? self.fullAlpha(view) : 0 }
    }, completion: {
      // Only hide if nothing flipped them back meanwhile (showing them sets
      // their opacity back right away).
      for view in views where view.alphaValue == 0 { view.isHidden = true }
    })
    if animated && visible {
      for view in views { view.animateIn(scale: 0.96, fade: 0, duration: 0.3, timing: Motion.easeOut) }
    }
  }

  override func layout() {
    super.layout()
    // (Mid-drag, things are moving: keep them springing.)
    layoutItems(animated: drag != nil, added: [])
  }

  private func layoutItems(animated: Bool, added: Set<ObjectIdentifier>, reveal: ObjectIdentifier? = nil) {
    Motion.withoutAnimation {
      backgroundLayer.frame = bounds
      separatorLayer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }
    let h = bounds.height
    let buttonY = (h - 28) / 2
    let left: CGFloat = 86  // clear of the traffic lights

    // Right: the incognito badge, search, then the web/notes toggle.
    place(modeButton, NSRect(x: bounds.width - 14 - 28, y: buttonY, width: 28, height: 28), animated: false)
    place(searchButton, NSRect(x: modeButton.frame.minX - 4 - 28, y: buttonY, width: 28, height: 28), animated: false)
    var buttonsLeft = searchButton.frame.minX
    if !soundButton.isHidden {
      place(soundButton, NSRect(x: searchButton.frame.minX - 4 - 28, y: buttonY, width: 28, height: 28), animated: false)
      buttonsLeft = soundButton.frame.minX
    }
    if isIncognito {
      let size = incognitoBadge.fittingSize
      place(incognitoBadge, NSRect(x: buttonsLeft - 6 - size.width, y: ((h - size.height) / 2).rounded(),
                                   width: size.width, height: size.height), animated: false)
      buttonsLeft = incognitoBadge.frame.minX
    }
    place(extensionsButton, NSRect(x: searchButton.frame.minX - 4 - 28, y: buttonY, width: 28, height: 28), animated: false)
    // Pinned extensions, right to left from the puzzle button.
    var extensionX = extensionsButton.frame.minX
    for entry in extensionButtons.reversed() {
      extensionX -= 2 + 28
      place(entry.button, NSRect(x: extensionX, y: buttonY, width: 28, height: 28), animated: animated)
    }
    let rightEdge = (isWeb && showsExtensions ? extensionX : buttonsLeft) - 12

    // Notes: Journal / All Notes, centered over the page (but never under
    // Back / Forward or the right-hand buttons).
    let notesButtons = [journalButton, notesButton]
    let notesWidth = notesButtons.map(\.fittingWidth).reduce(0, +) + CGFloat(notesButtons.count - 1) * 2
    let notesLeft = left + 2 * 28 + 10
    var x = min(max(notesLeft, ((bounds.width - notesWidth) / 2).rounded()), max(notesLeft, rightEdge - notesWidth))
    for button in notesButtons {
      let width = button.fittingWidth
      place(button, NSRect(x: x, y: (h - Theme.modeButtonHeight) / 2, width: width, height: Theme.modeButtonHeight), animated: false)
      x += width + 2
    }

    // Navigation (Back / Forward in the notes too), then the web's tabs and +.
    x = left
    for button in [backButton, forwardButton, reloadButton] {
      place(button, NSRect(x: x, y: buttonY, width: 28, height: 28), animated: false)
      x += 28
    }
    x += 10
    // Tabs keep their web layout in notes mode (where the extensions are
    // hidden), so switching modes doesn't resize them.
    let tabsRightEdge = (showsExtensions ? extensionX : buttonsLeft) - 12
    layoutTabs(from: x, to: tabsRightEdge, animated: animated, added: added, reveal: reveal)
  }

  private func place(_ view: NSView, _ frame: NSRect, animated: Bool) {
    guard view.frame != frame else { return }
    if animated && !view.frame.isEmpty {
      let released = releasedViews.contains { $0 === view }
      view.springFrame(to: frame, stiffness: 420, damping: 34, fromCurrentFrame: released)
      if released { releasedViews.removeAll { $0 === view } }
    } else {
      // A spring still running would end on its old target, then jump.
      view.layer?.removeAnimation(forKey: "glea.spring.position")
      view.layer?.removeAnimation(forKey: "glea.spring.bounds")
      view.frame = frame
    }
  }

  private func updateProgress() {
    let visible = isWeb && progress > 0 && progress < 1
    CATransaction.begin()
    CATransaction.setAnimationDuration(Motion.reduceMotion ? 0 : 0.25)
    CATransaction.setAnimationTimingFunction(Motion.easeOut)
    if visible && progressLayer.opacity == 0 {
      // Restart from the left edge.
      Motion.withoutAnimation { progressLayer.frame = NSRect(x: 0, y: 0, width: 0, height: 2) }
    }
    progressLayer.frame = NSRect(x: 0, y: 0, width: bounds.width * (visible ? progress : 1), height: 2)
    progressLayer.opacity = visible ? 1 : 0
    CATransaction.commit()
  }

  @objc private func showJournal() { delegate?.topBarShowJournal() }
  @objc private func showNotes() { delegate?.topBarShowNotes() }
  @objc private func goBack() { delegate?.topBarGoBack() }
  @objc private func goForward() { delegate?.topBarGoForward() }
  @objc private func reload() { delegate?.topBarReload() }
  @objc private func newTab() { delegate?.topBarNewTab() }
  @objc private func search() { delegate?.topBarSearch() }
  @objc private func toggleSound() { SoundMonitor.shared.toggle() }

  /// Shown in the notes while sound plays (muted or not).
  private func updateSoundButton() {
    let monitor = SoundMonitor.shared
    let show = !isWeb && (monitor.isPlaying || monitor.isMuted)
    if show {
      soundButton.setSymbol(monitor.isPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill", size: 12, animated: window != nil)
      soundButton.toolTip = monitor.isPlaying ? "Mute Sound" : "Unmute Sound"
    }
    guard show == soundButton.isHidden else { return }
    soundButton.isHidden = !show
    if show, window != nil { soundButton.popIn() }
    layoutItems(animated: false, added: [])
  }
  @objc private func showExtensions() { delegate?.topBarShowExtensions(from: extensionsButton.frame) }
  @objc private func toggleMode() { delegate?.topBarToggleMode() }
}

/// "Incognito", with its glasses, at the right of an incognito window's bar.
private final class IncognitoBadge: NSView {
  private let stack: NSStackView

  init() {
    let icon = NSImageView(image: Theme.symbol("eyeglasses", size: 13) ?? NSImage())
    icon.contentTintColor = Theme.secondaryText
    let label = NSTextField.label("Incognito", size: 12, weight: .medium, color: Theme.secondaryText)
    stack = NSStackView(views: [icon, label])
    stack.spacing = 5
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 10)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = true
    toolTip = "Pages in this window stay out of your history, and their cookies are erased when it closes"
    addSubview(stack)
    stack.pinEdges(to: self)
    stack.heightAnchor.constraint(equalToConstant: 26).isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    Theme.selected.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
  }

  override var mouseDownCanMoveWindow: Bool { true }
}

/// One tab in the strip: favicon, title and a close button on hover.
/// Holds the tab pills: clips them, scrolls sideways with the wheel or
/// trackpad when they overflow, and fades the clipped edges.
private final class TabStripView: NSView {
  /// The bar sits in the window's title bar, where macOS drags the window
  /// from any view that doesn't claim its area (controls do, plain views
  /// don't), before the app even sees the press. Claim it: tabs drag tabs,
  /// and the bar drags the window from its empty space itself (mouseDown).
  @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

  var onScroll: (() -> Void)?
  var contentWidth: CGFloat = 0 {
    didSet {
      // (Set on every layout: only a real change ends an overscroll.)
      guard contentWidth != oldValue else { return }
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

  override var mouseDownCanMoveWindow: Bool { false }
  // Empty strip space behaves like the rest of the bar (drag, zoom).
  override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }

  private var maxOffset: CGFloat { max(0, contentWidth - bounds.width) }

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
    // Sideways or vertical: both scroll the tabs.
    let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
    var delta = abs(dx) > abs(dy) ? -dx : -dy
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
  private var rubberDimension: CGFloat { max(1, min(bounds.width, 70)) }
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

  /// Scrolls just enough to show the span [minX, maxX] of the content.
  func reveal(minX: CGFloat, maxX: CGFloat, animated _: Bool) {
    let previous = scrollOffset
    if minX - fadeWidth < scrollOffset { scrollOffset = minX - fadeWidth }
    if maxX + fadeWidth > scrollOffset + bounds.width { scrollOffset = maxX + fadeWidth - bounds.width }
    clampOffset()
    if scrollOffset != previous { updateFade() }
  }

  /// Eased fades on the sides that have hidden tabs.
  private func updateFade() {
    guard let layer else { return }
    Motion.withoutAnimation {
      guard maxOffset > 0, bounds.width > fadeWidth * 2 else {
        layer.mask = nil
        return
      }
      fade.frame = layer.bounds
      let edge = Double(fadeWidth / bounds.width)
      let steps = 6
      var colors: [CGColor] = []
      var locations: [NSNumber] = []
      let leftHidden = scrollOffset > 0.5, rightHidden = scrollOffset < maxOffset - 0.5
      for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let eased = t * t * (3 - 2 * t)
        colors.append(NSColor.black.withAlphaComponent(leftHidden ? eased : 1).cgColor)
        locations.append(NSNumber(value: edge * Double(t)))
      }
      for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let eased = t * t * (3 - 2 * t)
        colors.append(NSColor.black.withAlphaComponent(rightHidden ? 1 - eased : 1).cgColor)
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
  var onToggleMute: (() -> Void)?
  /// Hidden inside its collapsed group's capsule: not clickable.
  var isCollapsedAway = false
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
    let color: NSColor = showsSelection ? Theme.activeTab : (hovering ? Theme.hover : .clear)
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
    // when it fits, else it fills the room after the icon.
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
    let groupX = max(31, min((bounds.width - groupWidth) / 2, bounds.width - reserved - groupWidth))
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

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  /// Tabs that move under a still pointer (scrolling the strip) get no
  /// enter/exit events: match the hover to where the pointer is now.
  func syncHoverWithPointer() {
    guard let window, !isHidden else { return }
    let point = window.mouseLocationOutsideOfEventStream
    let inside = bounds.contains(convert(point, from: nil))
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
    if !dragging, abs(event.locationInWindow.x - start.x) > 4 {
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

// MARK: - Find bar

final class FindBar: NSView, NSSearchFieldDelegate {
  var onSearch: ((String, Bool, Bool) -> Void)?  // text, forward, findNext
  var onClose: (() -> Void)?

  let field = NSSearchField()
  private let countLabel = NSTextField.label("", size: 11, color: Theme.secondaryText)
  private lazy var previousButton = IconButton(symbol: "chevron.up", size: 11, target: self, action: #selector(previous))
  private lazy var nextButton = IconButton(symbol: "chevron.down", size: 11, target: self, action: #selector(next))
  private lazy var doneButton = IconButton(symbol: "xmark", size: 10, target: self, action: #selector(done))

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 10
    shadow = NSShadow()
    layer?.shadowOpacity = 0.15
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    field.placeholderString = "Find in page"
    field.delegate = self
    field.sendsSearchStringImmediately = true
    field.target = self
    field.action = #selector(search)
    field.focusRingType = .none
    field.translatesAutoresizingMaskIntoConstraints = false
    let stack = NSStackView(views: [field, countLabel, previousButton, nextButton, doneButton])
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
    addSubview(stack)
    stack.pinEdges(to: self)
    field.widthAnchor.constraint(equalToConstant: 200).isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    Theme.background.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    Theme.separator.setStroke()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
  }

  func setResult(count: Int, active: Int) {
    countLabel.stringValue = field.stringValue.isEmpty ? "" : (count == 0 ? "No matches" : "\(active) of \(count)")
  }

  @objc private func search() {
    onSearch?(field.stringValue, true, false)
    if field.stringValue.isEmpty { countLabel.stringValue = "" }
  }

  @objc func next() { onSearch?(field.stringValue, true, true) }
  @objc func previous() { onSearch?(field.stringValue, false, true) }
  @objc private func done() { onClose?() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? previous() : next()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true
    default:
      return false
    }
  }
}

// MARK: - Toast

final class ToastView: NSView {
  private let label = NSTextField.label("", size: 12, weight: .medium, color: .white)
  private var hideWork: DispatchWorkItem?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
    layer?.cornerRadius = 9
    addSubview(label)
    label.pinEdges(to: self, insets: NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14))
    alphaValue = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(_ message: String) {
    label.stringValue = message
    hideWork?.cancel()
    layer?.removeAllAnimations()
    alphaValue = 1
    // Rise from just below its resting place.
    animateIn(scale: 0.92, offsetY: -10, fade: 0.12, duration: 0.42, timing: Motion.easeOut)
    let work = DispatchWorkItem { [weak self] in
      self?.animateOut(scale: 0.96, offsetY: -4, fade: 0.2, duration: 0.2) {
        self?.alphaValue = 0
        self?.layer?.removeAllAnimations()
      }
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
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
  /// Where it was grabbed, as a fraction of its width (kept as a tab
  /// shrinks to or grows from its pinned look).
  var grabFraction: CGFloat
  /// Pointer x in the bar.
  var pointer: CGFloat
  /// Its width where it would land (the room the layout makes for it).
  var width: CGFloat
  /// Its width as drawn: eases to `width`.
  var shownWidth: CGFloat
  /// Pointer x minus its left edge, as drawn (it stays under the pointer as
  /// it shrinks to or grows from its pinned look).
  var grab: CGFloat { grabFraction * shownWidth }
  /// Where it would land the last time the pointer was over the bar: a
  /// release anywhere else snaps it there.
  var lastTarget: DropTarget?
  /// ⌥ held over another tab: the tab to group with.
  var groupWith: ObjectIdentifier?
  /// A pinned tab being dragged (it unpins past the separator).
  var startedPinned = false
  /// The pointer in the bar at the last drag event (for ⌥ pressed while still).
  var point: NSPoint = .zero
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

  override var mouseDownCanMoveWindow: Bool { false }
  override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
}

extension TopBarView {
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
        capsules[id] = capsule
        tabStrip.addSubview(capsule)
        if window != nil { capsule.animateIn(scale: 0.8, duration: 0.2) }
        return capsule
      }()
      capsule.configure(label: info.label, color: info.color)
      if underlines[info.id] == nil {
        let line = CALayer()
        line.cornerRadius = 0.75
        tabStrip.layer?.addSublayer(line)
        underlines[info.id] = line
      }
      underlines[info.id]?.backgroundColor = resolvedCGColor(info.color)
    }
    for (id, capsule) in capsules where !ids.contains(id) {
      capsules[id] = nil
      capsule.animateOut(scale: 0.8, duration: 0.15) { capsule.removeFromSuperview() }
    }
    for (id, line) in underlines where !ids.contains(id) {
      underlines[id] = nil
      line.removeFromSuperlayer()
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
    let h = bounds.height
    var placed: Set<ObjectIdentifier> = []
    for (item, next) in zip(items, items.dropFirst()) {
      guard case .tab(let left)? = item, case .tab(let right)? = next, let frame = frames[.tab(left)],
            pills[left]?.superview === tabStrip, pills[right]?.superview === tabStrip else { continue }
      let separatorFrame = NSRect(x: (frame.maxX + spacing / 2 - 0.5).rounded(), y: ((h - 16) / 2).rounded(), width: 1, height: 16)
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

  fileprivate func layoutTabs(from start: CGFloat, to rightEdge: CGFloat, animated: Bool, added: Set<ObjectIdentifier>,
                              reveal: ObjectIdentifier?) {
    let h = bounds.height
    let pillY = (h - Theme.tabHeight) / 2
    let buttonY = (h - 28) / 2
    let plusWidth: CGFloat = 28 + 6
    let target = dropTarget()
    updateDraggedTabLook()

    // Pinned tabs, with a gap where a dragged tab would land.
    var pinned: [ObjectIdentifier?] = pinnedItems(excludingDrag: true).map { $0 }
    if drag?.groupWith == nil, case .pinned(let slot) = target { pinned.insert(nil, at: min(slot, pinned.count)) }
    let pinnedStripWidth = pinned.isEmpty ? 0 : CGFloat(pinned.count) * pinnedWidth + CGFloat(pinned.count - 1) * 2
    pinnedStrip.frame = NSRect(x: start, y: 0, width: max(pinnedStripWidth, 1), height: h)
    for (i, id) in pinned.enumerated() {
      guard let id, let pill = pills[id], pill.superview === pinnedStrip else { continue }
      let frame = NSRect(x: CGFloat(i) * (pinnedWidth + 2), y: pillY, width: pinnedWidth, height: Theme.tabHeight)
      if pill.needsAppear || added.contains(id) {
        appear(pill, at: frame, animated: animated)
      } else {
        place(pill, frame, animated: animated && isWeb)
      }
    }
    // Beam's separator after the pinned tabs: 1×16, 7.5 after the last one
    // and 5.5 before the next.
    let x = start + pinnedStripWidth + (pinned.isEmpty ? 0 : 14) - 4
    let separatorFrame = NSRect(x: start + pinnedStripWidth + 7.5, y: ((h - 16) / 2).rounded(), width: 1, height: 16)
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
    let available = max(0, rightEdge - plusWidth - x)
    let tabCount = CGFloat(items.filter { if case .tab = $0 { return true }; return $0 == nil && isDraggingTab }.count)
    let capsulesWidth = items.reduce(CGFloat(0)) { sum, item in
      if case .capsule(let g) = item { return sum + capsuleWidth(g) }
      if item == nil, case .group(let g)? = drag?.kind { return sum + capsuleWidth(g) }
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
    let room = available - capsulesWidth - gaps
    var shared = Self.sharedTabWidth(naturals: slots.map(\.natural), room: room)
    // Crowded: the active tab keeps its minimum, the others share the rest.
    if shared < Self.activeTabMinWidth, let activeID, slots.contains(where: { $0.id == activeID }) {
      shared = Self.sharedTabWidth(naturals: slots.filter { $0.id != activeID }.map(\.natural),
                                   room: room - Self.activeTabMinWidth)
    }
    let tabWidth = tabCount > 0 ? min(Theme.tabMaxWidth, max(Theme.tabMinWidth, shared)) : 0
    /// A tab's width in the strip: its natural width up to the shared one
    /// (never below the active tab's minimum).
    func stripWidth(_ id: ObjectIdentifier) -> CGFloat {
      let width = min(naturalTabWidth(id), tabWidth)
      return id == activeID ? max(Self.activeTabMinWidth, width) : width
    }
    if tabCount > 0 { stripTabWidth = tabWidth }
    // A tab dragged over the strip takes (and leaves room for) its width in
    // the strip, as laid out now.
    if isDraggingTab, !grouping, case .strip? = target, tabCount > 0, let draggedID {
      drag?.width = stripWidth(draggedID)
    }
    func width(_ item: BarItem?) -> CGFloat {
      switch item {
      case .capsule(let g): return capsuleWidth(g)
      case .tab(let id): return stripWidth(id)
      case nil: return drag?.width ?? tabWidth
      }
    }
    stripTabWidths = [:]
    for case .tab(let id)? in items { stripTabWidths[id] = width(.tab(id)) }
    // Inset from the strip's edges (room for a capsule's bounce).
    let inset: CGFloat = 4
    var offsets: [CGFloat] = []
    var cursor: CGFloat = inset
    for item in items {
      offsets.append(cursor)
      cursor += width(item) + spacing
    }
    let contentWidth = items.isEmpty ? 0 : cursor - spacing + inset
    // The strip spans all the room for tabs (drops land anywhere in it);
    // the + button follows the last tab.
    let stripWidth = min(available, contentWidth)
    tabStrip.frame = NSRect(x: x, y: 0, width: available, height: h)
    tabStrip.contentWidth = contentWidth
    if drag == nil, let reveal, let index = items.firstIndex(of: .tab(reveal)) {
      tabStrip.reveal(minX: offsets[index], maxX: offsets[index] + width(.tab(reveal)), animated: animated)
    }
    let scroll = tabStrip.scrollOffset
    var frames: [BarItem: NSRect] = [:]
    var gapFrame: NSRect?
    for (i, item) in items.enumerated() {
      guard let item else {
        gapFrame = NSRect(x: offsets[i] - scroll, y: pillY, width: width(nil), height: Theme.tabHeight)
        continue
      }
      let frame = NSRect(x: offsets[i] - scroll, y: pillY, width: width(item), height: Theme.tabHeight)
      frames[item] = frame
      switch item {
      case .tab(let id):
        guard let pill = pills[id], pill.superview === tabStrip else { continue }
        pill.isCollapsedAway = false
        if added.contains(id) || pill.needsAppear {
          appear(pill, at: frame, animated: animated)
        } else {
          place(pill, frame, animated: animated && isWeb)
        }
        if pill.alphaValue < 1 { Motion.animate(animated ? 0.2 : 0) { pill.animator().alphaValue = 1 } }
      case .capsule(let g):
        let capsuleFrame = NSRect(x: frame.minX, y: (h - GroupCapsule.height) / 2, width: frame.width, height: GroupCapsule.height)
        if g == Self.previewID {
          showPreview(at: capsuleFrame)
          continue
        }
        guard let capsule = capsules[g], capsule.superview === tabStrip else { continue }
        place(capsule, capsuleFrame, animated: animated && isWeb && !capsule.frame.isEmpty)
      }
    }

    layoutTabSeparators(items: items, frames: frames, animated: animated)

    // The ⌥-drag preview: its underline spans the capsule and target tab.
    if let previewFor, let capsuleFrame = frames[.capsule(Self.previewID)], let tabFrame = frames[.tab(previewFor)] {
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.25)
      CATransaction.setAnimationTimingFunction(Motion.easeOut)
      previewLine.backgroundColor = resolvedCGColor(nextGroupColor)
      if previewLine.superlayer == nil {
        tabStrip.layer?.addSublayer(previewLine)
        previewLine.cornerRadius = 0.75
        Motion.withoutAnimation {
          previewLine.frame = NSRect(x: capsuleFrame.minX + 2, y: pillY - 4, width: 0, height: 1.5)
        }
      }
      previewLine.frame = NSRect(x: capsuleFrame.minX + 2, y: pillY - 4, width: tabFrame.maxX - capsuleFrame.minX - 4, height: 1.5)
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
        place(pill, NSRect(x: capsuleFrame.minX, y: pillY, width: capsuleFrame.width, height: Theme.tabHeight), animated: animated)
        Motion.animate(animated ? 0.18 : 0) { pill.animator().alphaValue = 0 }
      }
    }

    // Underlines: under a group's capsule and tabs.
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(0.25)
    CATransaction.setAnimationTimingFunction(Motion.easeOut)
    for info in groupInfos {
      guard let line = underlines[info.id] else { continue }
      var parts = ([BarItem.capsule(info.id)] + members(info.id).map { BarItem.tab($0) }).compactMap { frames[$0] }
      // The gap where a dragged tab would join the group.
      if !grouping, case .strip(_, let g)? = target, g == info.id, let gapFrame { parts.append(gapFrame) }
      guard let first = parts.first, let last = parts.max(by: { $0.maxX < $1.maxX }) else {
        line.opacity = 0
        continue
      }
      line.opacity = 1
      line.frame = NSRect(x: first.minX + 2, y: pillY - 4, width: max(0, last.maxX - first.minX - 4), height: 1.5)
    }
    CATransaction.commit()

    // What's being dragged follows the pointer (above everything).
    if let drag {
      let left = drag.pointer - drag.grab
      switch drag.kind {
      case .tab(let id):
        let frame = draggedTabFrame(drag)
        if let pill = pills[id] {
          pill.frame = NSRect(x: frame.minX, y: pillY, width: frame.width, height: Theme.tabHeight)
          // Its content fades as it compresses toward its pinned size.
          let range = drag.shownWidth - pinnedWidth
          pill.contentFade = range > 1 ? max(0, min(1, (frame.width - pinnedWidth) / range)) : 1
        }
      case .group(let g):
        var offset = left
        if let capsule = capsules[g] {
          capsule.frame = NSRect(x: offset, y: (h - GroupCapsule.height) / 2, width: capsule.frame.width, height: GroupCapsule.height)
          offset += capsule.frame.width + spacing
        }
        let collapsed = group(g)?.collapsed ?? false
        for id in members(g) where !collapsed {
          guard let pill = pills[id] else { continue }
          pill.frame = NSRect(x: offset, y: pillY, width: pill.frame.width, height: Theme.tabHeight)
          offset += pill.frame.width + spacing
        }
      }
    }

    let plusX = min(x + stripWidth + 6, rightEdge - 28)
    place(newTabButton, NSRect(x: plusX, y: buttonY, width: 28, height: 28), animated: animated && isWeb)
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
      line.frame = NSRect(x: line.frame.minX, y: line.frame.minY, width: 0, height: line.frame.height)
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
    layoutItems(animated: true, added: [])
  }

  /// Where a dragged tab is drawn: under the pointer (where it was grabbed).
  /// Past the tab area's left edge it compresses, its left edge held there,
  /// down to its pinned size, where it pins; a pinned tab dragged out
  /// expands the same way.
  private func draggedTabFrame(_ drag: TabDrag) -> (minX: CGFloat, width: CGFloat) {
    var width = drag.shownWidth
    if case .tab = drag.kind, drag.grabFraction > 0.01 {
      let room = (drag.pointer - (tabStrip.frame.minX + 4)) / drag.grabFraction
      width = min(width, max(pinnedWidth, room))
    }
    return (drag.pointer - drag.grabFraction * width, width)
  }

  /// ⌥ held and the pointer over another (unpinned) tab: that tab.
  private func groupingTarget(_ event: NSEvent, dragging id: ObjectIdentifier) -> ObjectIdentifier? {
    groupingTarget(at: convert(event.locationInWindow, from: nil), option: event.modifierFlags.contains(.option), dragging: id)
  }

  private func groupingTarget(at point: NSPoint, option: Bool, dragging id: ObjectIdentifier) -> ObjectIdentifier? {
    guard option, isValidDragPoint(point), let drag, let dragged = pills[id] else { return nil }
    // The dragged tab, where it's drawn (following the pointer).
    let drawn = draggedTabFrame(drag)
    let draggedSpan = (drawn.minX, drawn.minX + drawn.width)
    func overlap(_ other: ObjectIdentifier) -> CGFloat {
      guard let pill = pills[other], pill.superview === tabStrip, !pill.isCollapsedAway else { return 0 }
      let frame = pill.convert(pill.bounds, to: self)
      let width = min(draggedSpan.1, frame.maxX) - max(draggedSpan.0, frame.minX)
      return max(0, width) / max(1, min(frame.width, dragged.frame.width))
    }
    // Stay on the current target while it's still covered at all (its new
    // capsule pushes it right), so the preview doesn't flicker.
    if let current = drag.groupWith, overlap(current) > 0.05 { return current }
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
    let left = pinnedStrip.frame.minX - 40
    let right = max(newTabButton.frame.maxX, tabStrip.frame.maxX) + 40
    return point.x >= left && point.x <= right && point.y >= -24 && point.y <= bounds.height + 24
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
    if case .tab = drag.kind {
      let pinned = pinnedItems(excludingDrag: true)
      // The tab pins once the icon it would shrink to (under the pointer)
      // reaches the tab area's left edge, so it pins right where it shows;
      // or when the pointer itself is left of the strip. A little slack
      // keeps it from flickering at the edge.
      let leftEdge = pointer - drag.grabFraction * pinnedWidth
      let areaLeft = tabStrip.frame.minX + 4
      let wasPinned: Bool = { if case .pinned? = drag.lastTarget { return true }; return false }()
      let staysPinned: Bool
      if drag.startedPinned {
        // A pinned tab unpins as soon as its center passes the separator
        // (and pins back when it comes back over it).
        let center = leftEdge + pinnedWidth / 2
        staysPinned = center <= pinnedSeparator.frame.midX + (wasPinned ? 2 : -2)
      } else {
        staysPinned = leftEdge < areaLeft - 2 + (wasPinned ? 8 : 0) || pointer < tabStrip.frame.minX - 4
      }
      if staysPinned {
        // By where its icon is (its left end), not the pointer.
        let iconCenter = leftEdge + pinnedWidth / 2
        let slot = pinned.indices.filter { pinnedStrip.frame.minX + CGFloat($0) * (pinnedWidth + 2) + pinnedWidth / 2 < iconCenter }.count
        return .pinned(slot)
      }
    }
    let items = unpinnedItems(excludingDrag: true)
    // A neighbour moves aside once the dragged item's leading edge passes its
    // middle, with the gap where it is now (half-way over it: a tab can still
    // overlap its neighbour a little without pushing it, to ⌥-group them).
    func width(_ item: BarItem) -> CGFloat {
      switch item {
      case .capsule(let g): return capsuleWidth(g)
      case .tab(let id): return stripTabWidths[id] ?? pills[id]?.frame.width ?? Theme.tabMinWidth
      }
    }
    let start = tabStrip.frame.minX - tabStrip.scrollOffset + 4
    func center(of index: Int, gapAt gap: Int) -> CGFloat {
      var cursor = start
      for i in 0...index {
        if i == gap { cursor += drag.width + spacing }
        if i == index { return cursor + width(items[i]) / 2 }
        cursor += width(items[i]) + spacing
      }
      return cursor
    }
    let draggedCenter = pointer + (0.5 - drag.grabFraction) * drag.width
    var slot: Int
    if case .strip(let last, _)? = drag.lastTarget { slot = min(last, items.count) } else {
      // First evaluation: where it was.
      slot = items.indices.filter { center(of: $0, gapAt: items.count) < draggedCenter }.count
    }
    let draggedLeft = draggedCenter - drag.width / 2
    let draggedRight = draggedCenter + drag.width / 2
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
    func left(of index: Int, gapAt gap: Int) -> CGFloat { center(of: index, gapAt: gap) - width(items[index]) / 2 }
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
      let minX = left(of: c, gapAt: inside ? e + 1 : c)
      let maxX = left(of: e, gapAt: e + 1) + width(items[e]) + (inside ? spacing + drag.width : 0)
      if pointer >= minX, pointer <= maxX { return .strip(min(max(slot, c + 1), e + 1), group: g) }
      if slot > c, slot <= e { return .strip(pointer < minX ? c : e + 1, group: nil) }
    }
    return .strip(slot, group: nil)
  }

  /// The dragged item stays over the bar's tab area.
  private func clampedPointer(_ x: CGFloat) -> CGFloat {
    min(max(x, pinnedStrip.frame.minX - 20), max(newTabButton.frame.maxX, tabStrip.frame.maxX))
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
    let width = pinned ? pinnedWidth : min(naturalTabWidth(id), max(stripTabWidth, Theme.tabMinWidth))
    self.drag?.width = width
    if Motion.reduceMotion { self.drag?.shownWidth = width }
    pills[id]?.setPinnedLook(pinned)
  }

  private func autoScroll() {
    guard let drag else { return }
    // The dragged tab eases to its new width.
    if drag.shownWidth != drag.width {
      let delta = drag.width - drag.shownWidth
      self.drag?.shownWidth = abs(delta) < 0.5 ? drag.width : drag.shownWidth + delta * 0.3
      layoutItems(animated: true, added: [])
    }
    let edge: CGFloat = 48
    let strip = tabStrip.frame
    var speed: CGFloat = 0
    if drag.pointer >= strip.minX + 2, drag.pointer < strip.minX + edge { speed = -(strip.minX + edge - drag.pointer) / edge }
    if drag.pointer > strip.maxX - edge { speed = (drag.pointer - (strip.maxX - edge)) / edge }
    if speed != 0, tabStrip.scroll(by: min(1, max(-1, speed)) * 14) {
      // What's under the pointer changed.
      let target = computeDropTarget()
      if self.drag?.groupWith == nil { self.drag?.lastTarget = target }
      layoutItems(animated: true, added: [])
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
    let pointer = convert(event.locationInWindow, from: nil).x
    switch phase {
    case .began:
      // Where it is on screen: it may still be springing from a drop.
      var shown = pill.frame
      if let layer = pill.layer, layer.animation(forKey: "glea.spring.position") != nil, let presentation = layer.presentation() {
        shown.origin.x += presentation.position.x - layer.position.x
        shown.size.width = presentation.bounds.width
      }
      pill.layer?.removeAnimation(forKey: "glea.spring.position")
      pill.layer?.removeAnimation(forKey: "glea.spring.bounds")
      let frame = pill.superview.map { convert(shown, from: $0) } ?? pill.frame
      let width = tabInfos[id]?.isPinned == true ? pinnedWidth : frame.width
      // Held where it was pressed (the drag starts a few points later).
      let pressed = pill.pressStart.map { convert($0, from: nil).x } ?? pointer
      let fraction = min(1, max(0, (pressed - frame.minX) / max(1, frame.width)))
      drag = TabDrag(kind: .tab(id), grabFraction: fraction, pointer: pointer,
                     width: width, shownWidth: frame.width)
      drag?.startedPinned = tabInfos[id]?.isPinned == true
      // It starts where it is (the gap it leaves), then moves from there.
      if tabInfos[id]?.isPinned == true {
        drag?.lastTarget = pinnedItems(excludingDrag: false).firstIndex(of: id).map { .pinned($0) }
      } else if let index = unpinnedItems(excludingDrag: false).firstIndex(of: .tab(id)) {
        drag?.lastTarget = .strip(index, group: tabInfos[id]?.groupID)
      }
      addSubview(pill)  // above both strips while dragged
      pill.frame = frame
      pill.isDragged = true
      updateDropTarget(event)
      layoutItems(animated: true, added: [])
      watchForLostRelease { [weak self] in self?.dragTab(id, phase: .ended, event: event) }
      autoScroll()
    case .moved:
      guard drag != nil else { return }
      drag?.pointer = clampedPointer(pointer)
      drag?.point = convert(event.locationInWindow, from: nil)
      setGroupingTarget(groupingTarget(event, dragging: id))
      if drag?.groupWith == nil { updateDropTarget(event) }
      layoutItems(animated: true, added: [])
    case .ended:
      guard drag != nil else { return }
      window?.isMovable = true
      pill.contentFade = 1
      pill.isDragged = false
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
        layoutItems(animated: true, added: [])
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
      layoutItems(animated: true, added: [])
    }
  }

  fileprivate func dragGroup(_ g: UUID, phase: DragPhase, event: NSEvent) {
    guard let capsule = capsules[g], isWeb else { return }
    lastDragEventTime = CACurrentMediaTime()
    let pointer = convert(event.locationInWindow, from: nil).x
    switch phase {
    case .began:
      let frame = capsule.convert(capsule.bounds, to: self)
      let collapsed = group(g)?.collapsed ?? false
      let views: [NSView] = [capsule] + (collapsed ? [] : members(g).compactMap { pills[$0] })
      let right = views.map { $0.convert($0.bounds, to: self).maxX }.max() ?? frame.maxX
      let width = right - frame.minX
      drag = TabDrag(kind: .group(g), grabFraction: (pointer - frame.minX) / max(1, width), pointer: pointer, width: width,
                     shownWidth: width)
      for view in views {
        let f = view.convert(view.bounds, to: self)
        addSubview(view)
        view.frame = f
      }
      updateDropTarget(event)
      layoutItems(animated: true, added: [])
      watchForLostRelease { [weak self] in self?.dragGroup(g, phase: .ended, event: event) }
      autoScroll()
    case .moved:
      guard drag != nil else { return }
      drag?.pointer = clampedPointer(pointer)
      updateDropTarget(event)
      layoutItems(animated: true, added: [])
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
      layoutItems(animated: true, added: [])
    }
  }
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
    Motion.withoutAnimation {
      ring.frame = bounds
      fill.frame = bounds.insetBy(dx: Self.ring, dy: Self.ring)
    }
    let h = label.intrinsicContentSize.height
    label.frame = NSRect(x: Self.ring + 6, y: (bounds.height - h) / 2, width: max(0, bounds.width - 2 * Self.ring - 12), height: h)
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

  override func mouseDown(with event: NSEvent) {
    pressStart = event.locationInWindow
    dragging = false
    window?.isMovable = false  // drags move the group, never the window
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = pressStart else { return }
    if !dragging, abs(event.locationInWindow.x - start.x) > 4 {
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
