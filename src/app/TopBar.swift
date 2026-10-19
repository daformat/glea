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
  func topBarNewNote()
  func topBarToggleMode()
  func topBarShowExtensions(from anchor: NSRect)
  func topBarShowDownloads(from anchor: NSRect)
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
  /// The top bar's new note button.
  static func newNote(target: AnyObject?, action: Selector?) -> IconButton {
    let button = IconButton(symbol: "long.text.page.and.pencil", tooltip: "New Note (⌥⌘N)", target: target, action: action)
    // Its page sits high next to round icons (search, globe).
    button.iconDrop = 1.5
    return button
  }

  /// Moves the icon down, for symbols that look high next to the others.
  var iconDrop: CGFloat = 0 { didSet { needsLayout = true } }
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
    icon.frame = bounds.offsetBy(dx: 0, dy: isFlipped ? iconDrop : -iconDrop)
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

  override func mouseEntered(with event: NSEvent) { if tracksHover { hovering = true } }
  override func mouseExited(with event: NSEvent) { hovering = false }

  /// Off, it never hovers (its tab is being dragged).
  var tracksHover = true {
    didSet { if tracksHover != oldValue { syncHoverWithPointer() } }
  }

  // Hidden under the pointer (its page left, say), it gets no exit event;
  // shown again, the pointer may be anywhere.
  override func viewDidHide() {
    super.viewDidHide()
    hovering = false
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    syncHoverWithPointer()
  }

  /// Tabs that move under a still pointer (scrolling the strip) get no
  /// enter/exit events: match the hover to where the pointer is now.
  func syncHoverWithPointer() {
    guard let window, !isHiddenOrHasHiddenAncestor, tracksHover else {
      if hovering { hovering = false }
      return
    }
    let point = window.mouseLocationOutsideOfEventStream
    let inside = bounds.contains(convert(point, from: nil))
      && (superview.map { $0.bounds.contains($0.convert(point, from: nil)) } ?? true)
    if inside != hovering { hovering = inside }
  }

  /// Also in a scrolling page (a note's header buttons).
  private var scrollWatch: NSObjectProtocol?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scrollWatch = watchScrolling(replacing: scrollWatch) { [weak self] in self?.syncHoverWithPointer() }
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
    guard let window, !isHiddenOrHasHiddenAncestor else {
      if hovering { hovering = false }
      return
    }
    let point = window.mouseLocationOutsideOfEventStream
    let inside = bounds.contains(convert(point, from: nil))
      && (superview.map { $0.bounds.contains($0.convert(point, from: nil)) } ?? true)
    if inside != hovering { hovering = inside }
  }

  /// Also in a scrolling page (a note's header buttons).
  private var scrollWatch: NSObjectProtocol?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scrollWatch = watchScrolling(replacing: scrollWatch) { [weak self] in self?.syncHoverWithPointer() }
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
  private lazy var journalButton: TextButton = {
    let button = TextButton(title: "Journal", target: self, action: #selector(showJournal))
    button.toolTip = "Journal (⇧⌘J)"
    return button
  }()
  private lazy var notesButton: TextButton = {
    let button = TextButton(title: "All Notes", target: self, action: #selector(showNotes))
    button.toolTip = "All Notes (⇧⌘H)"
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
        addSubview(button, positioned: .below, relativeTo: tabsView)
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
    // (In the sidebar, the button is in its strip.)
    delegate?.topBarOpenExtension(entry.id, from: sender.convert(sender.bounds, to: self))
  }
  private lazy var searchButton = IconButton(symbol: "magnifyingglass", size: 13, tooltip: "Search (⌘T)", target: self, action: #selector(search))
  /// This session's downloads (see Downloads), once there are any: lists
  /// them. While they run its circle is a ring filling up.
  private lazy var downloadsButton = IconButton(symbol: "arrow.down.circle", size: 13, tooltip: "Downloads", target: self,
                                                action: #selector(showDownloads))
  private let downloadsTrack = CAShapeLayer()
  private let downloadsRing = CAShapeLayer()
  /// The button has its place (in the notes too, hidden: the tabs keep
  /// their layout).
  private var hasDownloads: Bool { !Downloads.shared.items.isEmpty }
  /// It had its place at the last update (hidden only for the notes).
  private var wasPlaced = false
  /// Notes only: a new note.
  private lazy var newNoteButton = IconButton.newNote(target: self, action: #selector(newNote))
  /// In the notes: sound plays somewhere in the app (a tab, a note's
  /// media); mutes or unmutes all of it.
  private lazy var soundButton = IconButton(symbol: "speaker.wave.2.fill", size: 12, tooltip: "Mute Sound", target: self,
                                            action: #selector(toggleSound))
  private lazy var modeButton = IconButton(symbol: "note.text", size: 14, tooltip: "Switch to Notes (⌘D)", target: self, action: #selector(toggleMode))
  /// An update downloaded and ready (see Updater): relaunches onto it.
  private lazy var updatePill = UpdatePill(target: self, action: #selector(installUpdate))
  /// Left of the search button in incognito windows.
  private lazy var incognitoBadge = IncognitoBadge()
  var isIncognito = false {
    didSet {
      if isIncognito && incognitoBadge.superview == nil { addSubview(incognitoBadge, positioned: .below, relativeTo: tabsView) }
      incognitoBadge.isHidden = !isIncognito
      needsLayout = true
    }
  }

  /// The tabs: pinned, then the others (and their groups), and +.
  private let tabsView = TabsView()
  /// The sidebar's right edge, dragged to resize it.
  private let resizeEdge = SidebarEdge()
  /// The sidebar's pinned extensions (see layoutSidebar).
  private let extensionStrip = TabStripView()
  /// A hairline just outside the page's card (the card covers the rest): its
  /// edge shows even on a page the sidebar's color.
  private let cardOutline = CALayer()
  /// Color the next new group gets (for the ⌥-drag preview).
  var nextGroupColor: NSColor {
    get { tabsView.nextGroupColor }
    set { tabsView.nextGroupColor = newValue }
  }
  private let backgroundLayer = HighlightLayer()
  private let separatorLayer = CALayer()
  private let progressLayer = CALayer()
  private var progress: Double = 0

  private(set) var section: Section = .journal
  /// Vertical at the last update (see update).
  private var wasVertical = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(appActiveChanged), name: name, object: nil)
    }
    backgroundLayer.cornerRadius = 0
    layer?.addSublayer(backgroundLayer)
    layer?.addSublayer(separatorLayer)
    cardOutline.borderWidth = 1
    cardOutline.cornerCurve = .continuous
    cardOutline.cornerRadius = TabLayout.cardRadius + 1
    cardOutline.isHidden = true
    layer?.addSublayer(cardOutline)
    progressLayer.anchorPoint = .zero
    progressLayer.cornerRadius = 1
    layer?.addSublayer(progressLayer)
    for view in [backButton, forwardButton, reloadButton, extensionsButton, journalButton, notesButton, searchButton, modeButton,
                 soundButton, newNoteButton] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(view)
    }
    soundButton.isHidden = true
    downloadsButton.translatesAutoresizingMaskIntoConstraints = true
    // Its circle sits low next to the other icons.
    downloadsButton.iconDrop = -1
    downloadsButton.isHidden = true
    addSubview(downloadsButton)
    for ring in [downloadsTrack, downloadsRing] {
      ring.fillColor = nil
      ring.lineWidth = 1.5
      ring.lineCap = .round
      ring.isHidden = true
      downloadsButton.layer?.addSublayer(ring)
    }
    Downloads.start()
    NotificationCenter.default.addObserver(forName: Downloads.didChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateDownloads() }
    }
    NotificationCenter.default.addObserver(forName: Downloads.didFinish, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.downloadsButton.isHidden else { return }
        self.downloadsButton.popIn()
      }
    }
    NotificationCenter.default.addObserver(forName: SoundMonitor.didChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateSoundButton() }
    }
    updatePill.translatesAutoresizingMaskIntoConstraints = true
    updatePill.isHidden = true
    addSubview(updatePill)
    NotificationCenter.default.addObserver(forName: .gleaUpdateReadyChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateUpdatePill() }
    }
    updateUpdatePill()
    // Above the buttons: a dragged tab passes over them.
    addSubview(tabsView)
    resizeEdge.isHidden = true
    addSubview(resizeEdge)
    extensionStrip.isHidden = true
    extensionStrip.onScroll = { [weak self] in
      guard let self else { return }
      self.layoutExtensionStrip(animated: false)
      // (They moved under a still pointer: no enter or exit events.)
      for entry in self.extensionButtons { entry.button.syncHoverWithPointer() }
    }
    addSubview(extensionStrip, positioned: .below, relativeTo: tabsView)
    for view in webOnlyViews { view.alphaValue = 0; view.isHidden = true }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // Keep the active tab in view as the window narrows.
    layoutItems(animated: false, added: [], reveal: tabsView.activeID)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var isWeb: Bool { section == .web }
  private var webOnlyViews: [NSView] {
    [reloadButton] + tabsView.webOnlyViews
      + (showsExtensions ? [extensionsButton] + extensionButtons.map(\.button) : [])
  }
  private var notesOnlyViews: [NSView] { [journalButton, notesButton, newNoteButton] }

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
  private var dimmedViews: [NSView] { tabsView.dimmedViews + [journalButton, notesButton] }

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
    cardOutline.borderColor = resolvedCGColor(Theme.separator)
    progressLayer.backgroundColor = resolvedCGColor(Theme.accent)
    downloadsTrack.strokeColor = resolvedCGColor(Theme.secondaryText.withAlphaComponent(0.3))
    downloadsRing.strokeColor = resolvedCGColor(Theme.accent)
  }

  func update(section: Section, tabs: [TabInfo], groups: [GroupInfo], activeID: ObjectIdentifier?, canGoBack: Bool, canGoForward: Bool,
              progress: Double) {
    let sectionChanged = section != self.section
    self.section = section
    journalButton.isActive = section == .journal
    notesButton.isActive = section == .notes
    backButton.isEnabled = canGoBack
    forwardButton.isEnabled = canGoForward
    modeButton.setSymbol(isWeb ? "note.text" : "globe", animated: sectionChanged && window != nil)
    modeButton.toolTip = isWeb ? "Switch to Notes (⌘D)" : "Switch to Web (⌘D)"

    tabsView.delegate = delegate
    let (added, reveal) = tabsView.update(tabs: tabs, groups: groups, activeID: activeID, isWeb: isWeb)

    self.progress = progress
    let animated = window != nil
    Motion.animate(animated ? 0.2 : 0, timing: Motion.easeInOut) {
      applyColors()
      separatorLayer.opacity = isWeb ? 1 : 0
    }
    // The web's sidebar ↔ the notes' bar: the other mode's views would
    // show in the new layout as they faded, so they go at once.
    let layoutChanged = isVertical != wasVertical
    wasVertical = isVertical
    if sectionChanged {
      setVisible(webOnlyViews, isWeb, animated: animated && !layoutChanged)
      setVisible(notesOnlyViews, !isWeb, animated: animated && !layoutChanged)
    }
    updateSoundButton()
    updateDownloads()
    layoutItems(animated: animated, added: isWeb ? added : [], reveal: reveal)
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
    layoutItems(animated: tabsView.isDragging, added: [])
  }

  private func layoutItems(animated: Bool, added: Set<ObjectIdentifier>, reveal: ObjectIdentifier? = nil) {
    Motion.withoutAnimation {
      backgroundLayer.frame = bounds
      // (The sidebar needs no line: the page's card has its own edge.)
      separatorLayer.frame = isVertical ? .zero : NSRect(x: 0, y: 0, width: bounds.width, height: 1)
      resizeEdge.frame = NSRect(x: sidebarWidth - 6, y: 0, width: 6, height: bounds.height)
      let inset = TabLayout.cardInset
      // (None beside the sidebar's own strip: zen mode, no card.)
      cardOutline.isHidden = !isVertical || bounds.width <= sidebarWidth + inset || !showsCardOutline
      cardOutline.frame = NSRect(x: sidebarWidth, y: inset, width: max(0, bounds.width - sidebarWidth - inset),
                                 height: max(0, bounds.height - 2 * inset)).insetBy(dx: -1, dy: -1)
    }
    if isVertical { return layoutSidebar(animated: animated, added: added, reveal: reveal) }
    // (Back from the sidebar's strip.)
    extensionStrip.isHidden = true
    for entry in extensionButtons where entry.button.superview !== self {
      addSubview(entry.button, positioned: .below, relativeTo: tabsView)
      entry.button.frame = .zero
    }
    Motion.withoutAnimation { tabsView.frame = bounds }
    let h = bounds.height
    let buttonY = (h - 28) / 2
    let left: CGFloat = 86  // clear of the traffic lights

    // Right: the incognito badge, search, then the web/notes toggle.
    place(modeButton, NSRect(x: bounds.width - 14 - 28, y: buttonY, width: 28, height: 28), animated: false)
    place(searchButton, NSRect(x: modeButton.frame.minX - 4 - 28, y: buttonY, width: 28, height: 28), animated: false)
    // (Notes: a new note, before search.)
    place(newNoteButton, NSRect(x: searchButton.frame.minX - 4 - 28, y: buttonY, width: 28, height: 28), animated: false)
    var buttonsLeft = isWeb ? searchButton.frame.minX : newNoteButton.frame.minX
    if !soundButton.isHidden {
      place(soundButton, NSRect(x: buttonsLeft - 4 - 28, y: buttonY, width: 28, height: 28), animated: false)
      buttonsLeft = soundButton.frame.minX
    }
    if isIncognito {
      let size = incognitoBadge.fittingSize
      place(incognitoBadge, NSRect(x: buttonsLeft - 6 - size.width, y: ((h - size.height) / 2).rounded(),
                                   width: size.width, height: size.height), animated: false)
      buttonsLeft = incognitoBadge.frame.minX
    }
    // The web's: downloads, then the extensions.
    var webLeft = searchButton.frame.minX
    if hasDownloads {
      place(downloadsButton, NSRect(x: webLeft - 4 - 28, y: buttonY, width: 28, height: 28), animated: animated)
      webLeft = downloadsButton.frame.minX
    }
    place(extensionsButton, NSRect(x: webLeft - 4 - 28, y: buttonY, width: 28, height: 28), animated: animated)
    // Pinned extensions, right to left from the puzzle button.
    var extensionX = extensionsButton.frame.minX
    for entry in extensionButtons.reversed() {
      extensionX -= 4 + 28
      place(entry.button, NSRect(x: extensionX, y: buttonY, width: 28, height: 28), animated: animated)
    }
    let webButtonsLeft = showsExtensions ? extensionX : min(buttonsLeft, webLeft)
    var rightEdge = (isWeb ? webButtonsLeft : buttonsLeft) - 12
    if !updatePill.isHidden {
      let size = updatePill.fittingSize
      place(updatePill, NSRect(x: rightEdge + 6 - size.width, y: ((h - size.height) / 2).rounded(),
                               width: size.width, height: size.height), animated: false)
      rightEdge = updatePill.frame.minX - 12
    }

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
    var tabsRightEdge = (showsExtensions ? extensionX : min(buttonsLeft, webLeft)) - 12
    if !updatePill.isHidden { tabsRightEdge = min(tabsRightEdge, updatePill.frame.minX - 12) }
    tabsView.layoutTabs(from: x, to: tabsRightEdge, animated: animated, added: added, reveal: reveal)
  }

  /// Vertical tabs (the web only): the bar is a sidebar, the window's
  /// height. At its top, beside the traffic lights, Back / Forward / Reload;
  /// at its bottom the bar's other buttons; the tabs in between.
  private func layoutSidebar(animated: Bool, added: Set<ObjectIdentifier>, reveal: ObjectIdentifier?) {
    let w = sidebarWidth, h = bounds.height
    let top = Theme.topBarHeight, bottom: CGFloat = 44
    /// A frame given from the top (the bar isn't flipped).
    func fromTop(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
      NSRect(x: x, y: h - y - height, width: width, height: height)
    }
    let topY = (top - 28) / 2
    // Top: navigation, at the right (the traffic lights are at the left).
    var x = w - 10 - 3 * 28
    for button in [backButton, forwardButton, reloadButton] {
      place(button, fromTop(x, topY, 28, 28), animated: false)
      x += 28
    }

    // Bottom: the extensions at the left, search and the web/notes toggle
    // (in the corner) at the right.
    let bottomY = (bottom - 28) / 2
    place(modeButton, NSRect(x: w - 10 - 28, y: bottomY, width: 28, height: 28), animated: false)
    place(searchButton, NSRect(x: modeButton.frame.minX - 4 - 28, y: bottomY, width: 28, height: 28), animated: false)
    var right = searchButton.frame.minX
    if hasDownloads {
      place(downloadsButton, NSRect(x: right - 4 - 28, y: bottomY, width: 28, height: 28), animated: animated)
      right = downloadsButton.frame.minX
    }
    var left: CGFloat = 10
    if isIncognito {
      let size = incognitoBadge.fittingSize
      place(incognitoBadge, NSRect(x: left, y: ((bottom - size.height) / 2).rounded(), width: size.width, height: size.height),
            animated: false)
      left = incognitoBadge.frame.maxX + 6
    }
    place(extensionsButton, NSRect(x: left, y: bottomY, width: 28, height: 28), animated: false)
    // The pinned extensions after it, scrolling (fading at the ends) when
    // they don't all fit before search, like the bar's tabs.
    let stripX = extensionsButton.frame.maxX + 4
    extensionStrip.isHidden = extensionButtons.isEmpty
    extensionStrip.frame = NSRect(x: stripX, y: bottomY - 2, width: max(0, right - 4 - stripX), height: 32)
    extensionStrip.contentLength = CGFloat(extensionButtons.count) * 32 - 4
    for entry in extensionButtons where entry.button.superview !== extensionStrip {
      extensionStrip.addSubview(entry.button)
      entry.button.frame = .zero
    }
    layoutExtensionStrip(animated: animated)
    // Over the bottom buttons: relaunch to update.
    var tabsBottom = bottom
    if !updatePill.isHidden {
      let size = updatePill.fittingSize
      place(updatePill, NSRect(x: 10, y: bottom, width: min(size.width, w - 20), height: size.height), animated: false)
      tabsBottom = updatePill.frame.maxY + 6
    }

    // The tabs, between the two.
    Motion.withoutAnimation { tabsView.frame = NSRect(x: 0, y: tabsBottom, width: w, height: max(0, h - top - tabsBottom)) }
    tabsView.layoutTabs(from: 4, to: tabsView.bounds.height - 4, animated: animated, added: added, reveal: reveal)
  }

  /// The sidebar's pinned extensions, in their strip as it's scrolled.
  private func layoutExtensionStrip(animated: Bool) {
    for (i, entry) in extensionButtons.enumerated() where entry.button.superview === extensionStrip {
      place(entry.button, NSRect(x: CGFloat(i) * 32 - extensionStrip.scrollOffset, y: 2, width: 28, height: 28),
            animated: animated && entry.button.frame != .zero)
    }
  }

  private func place(_ view: NSView, _ frame: NSRect, animated: Bool) {
    guard view.frame != frame else { return }
    if animated && !view.frame.isEmpty {
      view.springFrame(to: frame, stiffness: 420, damping: 34)
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
    // (In the sidebar: under the navigation, at the top.)
    let y = isVertical ? bounds.height - Theme.topBarHeight - 1 : 0
    if visible && progressLayer.opacity == 0 {
      // Restart from the left edge.
      Motion.withoutAnimation { progressLayer.frame = NSRect(x: 0, y: y, width: 0, height: 2) }
    }
    progressLayer.frame = NSRect(x: 0, y: y, width: (isVertical ? sidebarWidth : bounds.width) * (visible ? progress : 1), height: 2)
    progressLayer.opacity = visible ? 1 : 0
    CATransaction.commit()
  }

  @objc private func showJournal() { delegate?.topBarShowJournal() }
  @objc private func showNotes() { delegate?.topBarShowNotes() }
  @objc private func goBack() { delegate?.topBarGoBack() }
  @objc private func goForward() { delegate?.topBarGoForward() }
  @objc private func reload() { delegate?.topBarReload() }
  @objc private func search() { delegate?.topBarSearch() }
  @objc private func newNote() { delegate?.topBarNewNote() }
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

  @objc private func showDownloads() { delegate?.topBarShowDownloads(from: downloadsButton.frame) }

  /// Shown in the web once there are downloads; the ring while they run
  /// (turning while their size is unknown).
  private func updateDownloads() {
    let downloads = Downloads.shared
    let show = isWeb && hasDownloads
    if show == downloadsButton.isHidden {
      downloadsButton.isHidden = !show
      downloadsButton.alphaValue = show ? 1 : 0
      // No frame yet: the layout puts it in place (it pops in there rather
      // than springing from the bar's corner), the others make room.
      if show, !wasPlaced { downloadsButton.frame = .zero }
      layoutItems(animated: window != nil, added: [])
      if show, window != nil { downloadsButton.popIn() }
    }
    wasPlaced = hasDownloads
    let running = downloads.isDownloading
    downloadsButton.setSymbol(running ? "arrow.down" : "arrow.down.circle", size: running ? 10 : 13, animated: window != nil)
    Motion.withoutAnimation {
      let bounds = downloadsButton.bounds
      let path = CGMutablePath()
      // From the top, clockwise (the button isn't flipped), around the arrow.
      path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY - downloadsButton.iconDrop), radius: 7, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi,
                  clockwise: true)
      for ring in [downloadsTrack, downloadsRing] {
        ring.frame = bounds
        ring.path = path
        ring.isHidden = !running
      }
    }
    guard running else { return downloadsRing.removeAnimation(forKey: "spin") }
    if let progress = downloads.progress {
      downloadsRing.removeAnimation(forKey: "spin")
      downloadsRing.strokeEnd = max(0.03, progress)
    } else if downloadsRing.animation(forKey: "spin") == nil {
      Motion.withoutAnimation { downloadsRing.strokeEnd = 0.25 }
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0
      spin.toValue = -2 * CGFloat.pi
      spin.duration = 1
      spin.repeatCount = .infinity
      downloadsRing.add(spin, forKey: "spin")
    }
  }
  @objc private func toggleMode() { delegate?.topBarToggleMode() }

  /// ⌥ pressed or released mid-drag.
  func dragModifiersChanged(_ flags: NSEvent.ModifierFlags) { tabsView.dragModifiersChanged(flags) }

  /// Test hooks: the puzzle button, as if clicked.
  func clickExtensionsButtonForTesting() { showExtensions() }

  /// Where a starting download flies (in this view), when shown.
  var downloadsButtonFrame: NSRect? { downloadsButton.isHidden ? nil : downloadsButton.frame }

  /// A download reached the button.
  func popDownloadsButton() { downloadsButton.popIn() }

  /// Test hooks: the downloads button, as if clicked (its menu stays open).
  func clickDownloadsButtonForTesting() { showDownloads() }

  /// Test hooks: the tab at `index` as if hovered.
  func simulateHover(tabAt index: Int, _ on: Bool) { tabsView.simulateHover(tabAt: index, on) }

  /// Test hooks: a tab (or a group's capsule) dragged, see TabsView.
  func simulateDrag(tabAt index: Int?, group: Int?, from: NSPoint, to: NSPoint, option: Bool) {
    tabsView.simulateDrag(tabAt: index, group: group, from: from, to: to, option: option)
  }

  /// Vertical tabs: the bar is a sidebar, the window's height (see
  /// layoutSidebar). The window sets its frame.
  var isVertical = false {
    didSet {
      guard isVertical != oldValue else { return }
      tabsView.axis = isVertical ? .vertical : .horizontal
      resizeEdge.isHidden = !isVertical
      layoutItems(animated: false, added: [], reveal: tabsView.activeID)
      updateProgress()
    }
  }

  /// Vertical tabs: the bar spans the window (its color around the page's
  /// card); the sidebar is this wide at its left.
  /// The outline around the page's card (vertical tabs). Off while the
  /// card slides: the page draws its own then (see `chromeBorderColor`).
  var showsCardOutline = true {
    didSet { if showsCardOutline != oldValue { needsLayout = true } }
  }

  var sidebarWidth: CGFloat = 240 {
    didSet { if sidebarWidth != oldValue, isVertical { needsLayout = true } }
  }

  /// The sidebar's edge dragged to `width` (`ended`: let go).
  var onResize: ((_ width: CGFloat, _ ended: Bool) -> Void)? {
    get { resizeEdge.onResize }
    set { resizeEdge.onResize = newValue }
  }
}

/// The sidebar's right edge (vertical tabs): drag it to resize the sidebar.
private final class SidebarEdge: NSView {
  var onResize: ((_ width: CGFloat, _ ended: Bool) -> Void)?
  private var startWidth: CGFloat = 0
  private var startX: CGFloat = 0

  /// Lights up along the card's edge while the pointer is on it.
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
  // refreshed reliably here), kept while dragging.
  override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

  override func layout() {
    super.layout()
    Motion.withoutAnimation {
      line.frame = NSRect(x: bounds.width - 2, y: TabLayout.cardInset + TabLayout.cardRadius, width: 2,
                          height: max(0, bounds.height - 2 * (TabLayout.cardInset + TabLayout.cardRadius)))
      line.cornerRadius = 1
      line.backgroundColor = resolvedCGColor(Theme.tertiaryText)
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                              owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    NSCursor.resizeLeftRight.set()
    showLine(true)
  }

  override func mouseExited(with event: NSEvent) {
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

  /// Pressed here (a release alone resizes nothing).
  private var resizing = false

  override func mouseDown(with event: NSEvent) {
    resizing = true
    startWidth = (superview as? TopBarView)?.sidebarWidth ?? 0
    startX = event.locationInWindow.x
  }

  override func mouseDragged(with event: NSEvent) {
    guard resizing else { return }
    NSCursor.resizeLeftRight.set()
    onResize?(startWidth + event.locationInWindow.x - startX, false)
  }

  override func mouseUp(with event: NSEvent) {
    guard resizing else { return }
    resizing = false
    onResize?(startWidth + event.locationInWindow.x - startX, true)
    if !bounds.contains(convert(event.locationInWindow, from: nil)) {
      NSCursor.arrow.set()
      showLine(false)
    }
  }
}

/// "Incognito", with its glasses, at the right of an incognito window's bar.

extension TopBarView {
  /// Shows the pill once an update is ready (popping in), hides it otherwise.
  fileprivate func updateUpdatePill() {
    let version = Updater.shared.readyVersion
    let show = version != nil
    updatePill.toolTip = version.map { "Glea \($0) is ready: relaunch to install it" }
    guard show == updatePill.isHidden else { return }
    updatePill.isHidden = !show
    needsLayout = true
    layoutSubtreeIfNeeded()
    if show && window != nil { updatePill.popIn() }
  }

  @objc fileprivate func installUpdate() {
    Updater.shared.installAndRelaunch()
  }
}

/// "Relaunch to Update" once an update is downloaded: a light wash of the
/// accent color, edged and written in it.
private final class UpdatePill: NSControl {
  private let stack: NSStackView
  private var hovering = false { didSet { needsDisplay = true } }
  private var pressed = false { didSet { needsDisplay = true } }

  init(target: AnyObject, action: Selector) {
    let icon = NSImageView(image: Theme.symbol("arrow.down.circle.fill", size: 12, weight: .semibold) ?? NSImage())
    icon.contentTintColor = Theme.accent
    let label = NSTextField.label("Relaunch to Update", size: 12, weight: .semibold, color: Theme.accent)
    stack = NSStackView(views: [icon, label])
    stack.spacing = 5
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 11)
    super.init(frame: .zero)
    self.target = target
    self.action = action
    addSubview(stack)
    stack.pinEdges(to: self)
    stack.heightAnchor.constraint(equalToConstant: 26).isActive = true
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    Theme.accent.withAlphaComponent(pressed ? 0.26 : hovering ? 0.18 : 0.12).setFill()
    path.fill()
    Theme.accent.setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  override func mouseDown(with event: NSEvent) {
    pressed = true
    // Tracks the press until release, like a button.
    while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      let inside = bounds.contains(convert(next.locationInWindow, from: nil))
      if next.type == .leftMouseUp {
        pressed = false
        if inside { sendAction(action, to: target) }
        return
      }
      pressed = inside
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

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
// MARK: - Find bar

final class FindBar: NSView, NSSearchFieldDelegate {
  var onSearch: ((String, Bool, Bool) -> Void)?  // text, forward, findNext
  var onClose: (() -> Void)?

  let field = NSSearchField()
  private let countLabel = NSTextField.label("", size: 11, color: Theme.secondaryText)
  private lazy var previousButton = IconButton(symbol: "chevron.up", size: 11, target: self, action: #selector(previous))
  private lazy var nextButton = IconButton(symbol: "chevron.down", size: 11, target: self, action: #selector(next))
  private lazy var doneButton = IconButton(symbol: "xmark", size: 10, target: self, action: #selector(done))
  /// The pointer is over it: the window it floats in takes clicks only
  /// then, and the page under the rest of it stays usable.
  private(set) var isHovered = false {
    didSet { if isHovered != oldValue { onHoverChange?(isHovered) } }
  }
  var onHoverChange: ((Bool) -> Void)?
  private var hoverTimer: Timer?

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

  // Polled: the window ignores the mouse while it isn't over the bar.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    hoverTimer?.invalidate()
    hoverTimer = nil
    guard window != nil else {
      isHovered = false
      return
    }
    let timer = Timer(timeInterval: 1 / 20, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let window = self.window else { return }
        self.isHovered = self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    hoverTimer = timer
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
  /// A note's name after the message, clickable.
  private let link = NSTextField.label("", size: 12, weight: .semibold, color: NSColor(srgbRed: 0.68, green: 0.7, blue: 1, alpha: 1))
  private let stack = NSStackView()
  private var hideWork: DispatchWorkItem?
  private var action: (() -> Void)?
  private var hoverTimer: Timer?
  /// The pointer is over it (only tracked while it has a link).
  private(set) var isHovered = false {
    didSet {
      guard isHovered != oldValue else { return }
      onHoverChange?(isHovered)
      if isHovered {
        hideWork?.cancel()
        NSCursor.pointingHand.set()
      } else {
        NSCursor.arrow.set()
        scheduleHide(after: ToastView.lingerAfterHover)
      }
    }
  }
  /// Called as the pointer comes over it and leaves (the window then takes
  /// clicks there, or lets them through again).
  var onHoverChange: ((Bool) -> Void)?

  private static let plainDuration: TimeInterval = 2.2
  private static let linkDuration: TimeInterval = 5
  private static let lingerAfterHover: TimeInterval = 1.5

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
    layer?.cornerRadius = 9
    stack.orientation = .horizontal
    stack.spacing = 4
    stack.alignment = .firstBaseline
    stack.addArrangedSubview(label)
    stack.addArrangedSubview(link)
    addSubview(stack)
    stack.pinEdges(to: self, insets: NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14))
    alphaValue = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Clickable only while it shows a link.
  override func hitTest(_ point: NSPoint) -> NSView? {
    action != nil && alphaValue > 0 && frame.contains(point) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    guard let action else { return }
    // After the click (opening the note changes what's on screen), and the
    // toast goes at once.
    DispatchQueue.main.async { action() }
    stopTracking()
    scheduleHide(after: 0)
  }

  /// `message`, then `linkTitle` in the link color when there's an action:
  /// clicking the toast runs it. A toast with a link stays longer, and as
  /// long as the pointer is over it.
  func show(_ message: String, linkTitle: String? = nil, action: (() -> Void)? = nil) {
    label.stringValue = message
    link.stringValue = linkTitle ?? ""
    link.isHidden = linkTitle == nil
    self.action = action
    hideWork?.cancel()
    layer?.removeAllAnimations()
    alphaValue = 1
    // Rise from just below its resting place.
    animateIn(scale: 0.92, offsetY: -10, fade: 0.12, duration: 0.42, timing: Motion.easeOut)
    stopTracking()
    if action != nil { startTracking() }
    scheduleHide(after: action == nil ? ToastView.plainDuration : ToastView.linkDuration)
  }

  private func scheduleHide(after delay: TimeInterval) {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isHovered else { return }
      self.stopTracking()
      self.action = nil
      self.animateOut(scale: 0.96, offsetY: -4, fade: 0.2, duration: 0.2) { [weak self] in
        self?.alphaValue = 0
        self?.layer?.removeAllAnimations()
      }
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  // The window it's in lets clicks through to the page below, so it gets no
  // mouse events of its own until the pointer is over it: watch the pointer.
  private func startTracking() {
    let timer = Timer(timeInterval: 1 / 20, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let window = self.window else { return }
        let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        self.isHovered = self.bounds.contains(point)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    hoverTimer = timer
  }

  private func stopTracking() {
    hoverTimer?.invalidate()
    hoverTimer = nil
    isHovered = false
  }
}
