import AppKit
import GleaBridge

/// The app's root view: the page background, and clicks go through to
/// whatever is below wherever none of its subviews want them.
private final class RootView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    Theme.background.setFill()
    dirtyRect.fill()
  }
}

/// The content view of the overlay window: transparent, and says when its
/// last overlay went away.
private final class OverlayRootView: NSView {
  var onSubviewsChange: (() -> Void)?
  // The callback, not a weak self: subviews are also removed while this
  // view is deallocated (a closed incognito window), when a weak reference
  // to it can't be formed.
  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    let change = onSubviewsChange
    DispatchQueue.main.async { change?() }
  }
  override func willRemoveSubview(_ subview: NSView) {
    super.willRemoveSubview(subview)
    let change = onSubviewsChange
    DispatchQueue.main.async { change?() }
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

/// Transparent, borderless, above the windows Chrome-style pages are drawn in
/// (children of the main window): overlays, the find bar and toasts live here
/// so they float over the page. It takes mouse events only while an overlay
/// is shown, and can be key (text fields) but never main.
/// The main window. Pages are separate (child) windows that take keyboard
/// focus, so a click back on Glea's own UI arrives in a window that isn't
/// key: take focus and handle it in one go, not on a second click.
final class GleaMainWindow: NSWindow {
  // Pages are separate windows that take keyboard focus: from the user's
  // point of view they're part of this one, so it keeps its active look (the
  // traffic lights stay colored) while Glea is the active app, instead of
  // blinking as focus moves between it and a page.
  @objc func _hasActiveAppearance() -> Bool { NSApp.isActive }
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { NSApp.isActive }
  @objc func _hasKeyAppearance() -> Bool { NSApp.isActive }

  /// An embed in a note doesn't take the focus on its own as it loads
  /// (the note's selection would flicker, ⌘A would go to the embed): only
  /// when it's clicked.
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    if let view = responder as? NSView, MediaBlockView.takesFocusUnasked(view) { return false }
    return super.makeFirstResponder(responder)
  }

  /// AppKit resets the window buttons to their default place whenever the
  /// title changes (the title follows the active tab) or the window comes
  /// forward (Beam hit this too): put them back right away.
  var onTitleBarReset: (() -> Void)?

  override var title: String {
    didSet { onTitleBarReset?() }
  }

  override func orderFront(_ sender: Any?) {
    super.orderFront(sender)
    onTitleBarReset?()
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    super.makeKeyAndOrderFront(sender)
    onTitleBarReset?()
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown, !isKeyWindow, NSApp.isActive { makeKey() }
    super.sendEvent(event)
  }
}

private final class OverlayWindow: NSWindow {
  init() {
    super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    ignoresMouseEvents = true
  }
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown, !isKeyWindow, NSApp.isActive { makeKey() }
    super.sendEvent(event)
  }
}

/// An opaque page-colored view (the error page).
private final class BackgroundView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    Theme.background.setFill()
    dirtyRect.fill()
  }
}

/// What the web shows while a window has no tabs: a welcome (or, in
/// incognito windows, what incognito means) and an omnibox to start from.
private final class StartPageView: NSView {
  /// Loads in the new tab it's shown for (⌘: in another one).
  let omnibox = OmniboxView(target: .currentTab, initialText: "", inline: true)
  private let stack: NSStackView
  private let title: NSTextField
  private let isIncognito: Bool

  /// The regular start page's title, a different one each time it shows.
  private static let phrases = [
    "Shine a light", "Follow your curiosity", "Find the thread",
    "Chase a spark", "Collect the good bits", "Look a little closer", "Where to today?",
    "Start somewhere", "Read, then write", "Light the way", "Something worth keeping",
  ]
  private static var lastPhrase: String?

  init(incognito: Bool) {
    let icon: NSImageView
    let title: NSTextField
    let detail: NSTextField
    isIncognito = incognito
    if incognito {
      icon = NSImageView(image: Theme.symbol("eyeglasses", size: 40, weight: .regular) ?? NSImage())
      icon.contentTintColor = Theme.secondaryText
      title = NSTextField.label("You’re browsing privately", size: 24, weight: .semibold)
      detail = NSTextField(wrappingLabelWithString:
        "Pages you visit in this window stay out of your history, and their cookies and site data are erased when you close it. "
          + "Downloads, and anything you collect to your notes, are kept.")
    } else {
      let appIcon = NSApp.applicationIconImage.copy() as? NSImage ?? NSImage()
      appIcon.size = NSSize(width: 72, height: 72)
      icon = NSImageView(image: appIcon)
      title = NSTextField.label(Self.phrases[0], size: 24, weight: .semibold)
      // Opaque, like the label color over the page: its letters, animated as
      // snapshots, then look exactly like it (a translucent color comes out
      // darker in the snapshots).
      title.textColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.87, alpha: 1) : NSColor(white: 0.15, alpha: 1)
      }
      detail = NSTextField(wrappingLabelWithString:
        "Search the web, jump to a tab, or open a note. Hold ⌥ Option on a page to collect what you read into your notes.")
    }
    detail.font = .systemFont(ofSize: 14)
    detail.textColor = Theme.secondaryText
    detail.alignment = .center
    detail.preferredMaxLayoutWidth = 460
    self.title = title
    stack = NSStackView(views: [icon, title, detail])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.setCustomSpacing(incognito ? 18 : 14, after: icon)
    stack.translatesAutoresizingMaskIntoConstraints = false
    super.init(frame: .zero)
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
      detail.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
    ])
    // Above the text: its results drop down over it.
    omnibox.isIncognito = incognito
    omnibox.autoresizingMask = []
    addSubview(omnibox)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// A new phrase for the title (never the one shown last), gleaming once
  /// the page has faded in, and staying its full turn before rotating.
  func shufflePhrase() {
    guard !isIncognito else { return }
    finishSwap()
    let phrase = nextPhrase()
    title.stringValue = phrase
    startRotation()
    // Its letters rise in as the page fades in (then it gleams).
    guard !Motion.reduceMotion else { return }
    title.alphaValue = 0
    gleamGeneration += 1
    let generation = gleamGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self, generation == self.gleamGeneration else { return }
      guard self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else {
        self.title.alphaValue = 1
        return
      }
      self.swapPhrase(to: phrase, replacing: false)
    }
  }

  /// Only the latest phrase gleams (showing the page can pick one twice).
  private var gleamGeneration = 0

  private func nextPhrase() -> String {
    let phrase = Self.phrases.filter { $0 != Self.lastPhrase }.randomElement() ?? Self.phrases[0]
    Self.lastPhrase = phrase
    return phrase
  }

  // MARK: Rotating phrase

  private var rotation: Timer?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    startRotation()
  }

  /// (Re)starts the 5s turns, from now.
  private func startRotation() {
    rotation?.invalidate()
    rotation = nil
    guard window != nil, !isIncognito else { return }
    rotation = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.rotatePhrase() }
    }
  }

  /// The phrase rises out and the next one rises in from below; not while
  /// the page is out of sight or something is being typed.
  private func rotatePhrase() {
    guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor, !omnibox.hasText else { return }
    let phrase = nextPhrase()
    guard !Motion.reduceMotion else {
      title.stringValue = phrase
      return
    }
    swapPhrase(to: phrase)
  }

  /// Letter by letter, the phrase rises out and blurs away while the next
  /// one rises in from below, coming into focus (each letter a little after
  /// the one before). The letters are layers drawn where the title draws
  /// them; the title itself takes over once they've settled.
  private func swapPhrase(to phrase: String, replacing: Bool = true) {
    wantsLayer = true
    guard let host = layer else {
      title.stringValue = phrase
      return
    }
    finishSwap()
    let outgoing = replacing ? letterLayers() : []
    title.stringValue = phrase
    layoutSubtreeIfNeeded()
    let incoming = letterLayers()
    title.alphaValue = 0
    let rise = title.bounds.height * 0.55
    let stagger: CFTimeInterval = 0.028
    let now = CACurrentMediaTime()
    // The new letters start as the old ones are on their way out.
    let lead: CFTimeInterval = replacing ? 0.14 : 0
    for (index, letter) in outgoing.enumerated() {
      host.addSublayer(letter)
      animate(letter, delay: now + Double(index) * stagger, duration: 0.34,
              from: (0, 1, 0), to: (-rise, 0, 1), timing: Motion.standard)
    }
    for (index, letter) in incoming.enumerated() {
      host.addSublayer(letter)
      animate(letter, delay: now + lead + Double(index) * stagger, duration: 0.5,
              from: (rise, 0, 1), to: (0, 1, 0), timing: Motion.easeOut)
    }
    swapLetters = outgoing + incoming
    swapGeneration += 1
    let generation = swapGeneration
    let total = lead + Double(max(incoming.count - 1, 0)) * stagger + 0.5
    DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
      guard let self, generation == self.swapGeneration else { return }
      self.finishSwap()
      self.gleamGeneration += 1
      self.gleam()
    }
  }

  private var swapLetters: [CALayer] = []
  private var swapGeneration = 0

  /// Hands back to the title (a swap cut short, or done).
  private func finishSwap() {
    for letter in swapLetters { letter.removeFromSuperlayer() }
    swapLetters = []
    title.alphaValue = 1
  }

  /// Moves `letter` from one (rise, opacity, blur) to another, after `delay`;
  /// blur goes from 0 (sharp) to 1 (blurred), a crossfade between its sharp
  /// and blurred images.
  private func animate(_ letter: CALayer, delay: CFTimeInterval, duration: CFTimeInterval,
                       from: (CGFloat, Float, Float), to: (CGFloat, Float, Float), timing: CAMediaTimingFunction) {
    guard let images = letter.sublayers, images.count == 2 else { return }
    let move = Motion.basic("transform.translation.y", duration: duration, timing: timing)
    move.fromValue = from.0
    move.toValue = to.0
    let fade = Motion.basic("opacity", duration: duration * 0.8, timing: timing)
    fade.fromValue = from.1
    fade.toValue = to.1
    let sharp = Motion.basic("opacity", duration: duration * 0.7, timing: timing)
    sharp.fromValue = 1 - from.2
    sharp.toValue = 1 - to.2
    let blurred = Motion.basic("opacity", duration: duration * 0.7, timing: timing)
    blurred.fromValue = from.2
    blurred.toValue = to.2
    for (layer, animation) in [(letter, move), (letter, fade), (images[0], sharp), (images[1], blurred)] {
      animation.beginTime = delay
      animation.fillMode = .both
      animation.isRemovedOnCompletion = false
      layer.add(animation, forKey: animation.keyPath)
    }
  }

  /// A layer per letter of the title, where the title draws it: slices of
  /// a snapshot of the title itself (the same pixels as when it's shown, so
  /// handing over to it doesn't change a thing), each over a blurred copy.
  /// The slices tile the title.
  private func letterLayers() -> [CALayer] {
    guard let font = title.font, let cell = title.cell, title.bounds.width > 0, let image = titleSnapshot() else { return [] }
    let scale = CGFloat(image.width) / title.bounds.width
    let text = title.stringValue as NSString
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: title.stringValue, attributes: [.font: font]))
    // (A label draws its text 2pt in from its edge.)
    let textX = cell.titleRect(forBounds: title.bounds).minX + 2
    // Where each letter starts (spaces go with the letter before them).
    var starts: [CGFloat] = []
    var location = 0
    while location < text.length {
      let range = text.rangeOfComposedCharacterSequence(at: location)
      location = NSMaxRange(range)
      guard !text.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      starts.append(textX + CTLineGetOffsetForStringIndex(line, range.location, nil))
    }
    guard !starts.isEmpty else { return [] }
    starts[0] = 0
    let frame = convert(title.bounds, from: title)
    let pad: CGFloat = 12
    return starts.indices.compactMap { index in
      let minX = (starts[index] * scale).rounded()
      let maxX = index + 1 < starts.count ? (starts[index + 1] * scale).rounded() : CGFloat(image.width)
      guard maxX > minX, let slice = image.cropping(to: CGRect(x: minX, y: 0, width: maxX - minX, height: CGFloat(image.height)))
      else { return nil }
      let width = (maxX - minX) / scale
      let letter = CALayer()
      letter.frame = CGRect(x: frame.minX + minX / scale - pad, y: frame.minY - pad, width: width + pad * 2, height: frame.height + pad * 2)
      let sharp = CALayer()
      sharp.contents = slice
      sharp.contentsScale = scale
      sharp.frame = CGRect(x: pad, y: pad, width: width, height: frame.height)
      let blurred = CALayer()
      blurred.contents = Self.blurred(slice, radius: 6 * scale, pad: pad * scale)
      blurred.contentsScale = scale
      blurred.frame = letter.bounds
      blurred.opacity = 0
      letter.addSublayer(sharp)
      letter.addSublayer(blurred)
      return letter
    }
  }

  /// The title as it's shown: its layer's own pixels (redrawing it offscreen
  /// would smooth its letters differently).
  private func titleSnapshot() -> CGImage? {
    guard let layer = title.layer else { return nil }
    // The current phrase, drawn into the layer now.
    title.display()
    let scale = window?.backingScaleFactor ?? 2
    let width = Int((title.bounds.width * scale).rounded(.up)), height = Int((title.bounds.height * scale).rounded(.up))
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    if layer.contentsAreFlipped() {
      context.translateBy(x: 0, y: title.bounds.height)
      context.scaleBy(x: 1, y: -1)
    }
    layer.render(in: context)
    return context.makeImage()
  }

  /// Renders in sRGB, like the title (a layer filter works in linear light,
  /// which darkens the text's soft edges).
  private static let blurContext: CIContext = {
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    return CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
  }()

  /// `image` blurred, on a canvas `pad` larger on every side (pixels).
  private static func blurred(_ image: CGImage, radius: CGFloat, pad: CGFloat) -> CGImage? {
    let extent = CGRect(x: -pad, y: -pad, width: CGFloat(image.width) + pad * 2, height: CGFloat(image.height) + pad * 2)
    let output = CIImage(cgImage: image).applyingGaussianBlur(sigma: radius / 2).cropped(to: extent)
    return blurContext.createCGImage(output, from: extent)
  }

  /// A white band sweeps once across the title's letters.
  private func gleam() {
    guard let layer = title.layer, !Motion.reduceMotion else { return }
    title.layoutSubtreeIfNeeded()
    let bounds = title.bounds
    guard bounds.width > 0, let snapshot = title.bitmapImageRepForCachingDisplay(in: bounds) else { return }
    title.cacheDisplay(in: bounds, to: snapshot)
    // Clipped to the glyphs: the title's own pixels are the mask.
    let mask = CALayer()
    mask.frame = layer.bounds
    mask.contents = snapshot.cgImage
    let container = CALayer()
    container.frame = layer.bounds
    container.mask = mask
    let band = CAGradientLayer()
    // A wide, eased falloff: bright at the middle, fading smoothly to nothing.
    let alphas: [CGFloat] = [0, 0.05, 0.16, 0.38, 0.68, 1, 0.68, 0.38, 0.16, 0.05, 0]
    // How white its middle gets: softer on dark text (light mode), where
    // white stands out more.
    let peak: CGFloat = title.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.93 : 0.64
    band.colors = alphas.map { NSColor(white: 1, alpha: $0 * peak).cgColor }
    band.locations = alphas.indices.map { NSNumber(value: Double($0) / Double(alphas.count - 1)) }
    band.startPoint = CGPoint(x: 0, y: 0.5)
    band.endPoint = CGPoint(x: 1, y: 0.5)
    let width = max(240, layer.bounds.width * 0.7)
    band.frame = CGRect(x: -width, y: 0, width: width, height: layer.bounds.height)
    container.addSublayer(band)
    layer.addSublayer(container)
    CATransaction.begin()
    CATransaction.setCompletionBlock { container.removeFromSuperlayer() }
    let sweep = Motion.basic("position.x", duration: 1.2, timing: Motion.easeInOut)
    sweep.fromValue = -width / 2
    sweep.toValue = layer.bounds.width + width / 2
    // As the phrase settles; from off the left edge until then.
    sweep.beginTime = CACurrentMediaTime() + 0.15
    sweep.fillMode = .backwards
    band.add(sweep, forKey: "glea.gleam")
    CATransaction.commit()
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    Theme.background.setFill()
    dirtyRect.fill()
  }

  private var stackTop: NSLayoutConstraint?

  override func layout() {
    // The text and the omnibox under it, well above the middle (the results
    // drop below); higher up in short windows, so they have room for a few rows.
    let textHeight = stack.fittingSize.height
    let resultsRoom = 12 + 5 * 42 + OmniboxView.bottomMargin
    let centered = ((bounds.height - textHeight - 32 - 57) * 0.3).rounded()
    let top = max(32, min(centered, bounds.height - textHeight - 32 - 57 - resultsRoom))
    if stackTop?.constant != top {
      stackTop?.isActive = false
      stackTop = stack.topAnchor.constraint(equalTo: topAnchor, constant: top)
      stackTop?.isActive = true
    }
    super.layout()
    let omniboxTop = stack.frame.maxY + 32
    omnibox.frame = NSRect(x: 0, y: omniboxTop, width: bounds.width, height: max(0, bounds.height - omniboxTop))
  }
}

/// A container that never takes clicks itself (the page may be below it).
final class PassthroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

extension NSWindow {
  /// Where the app puts its own views (bars): the main window's root view.
  var appRootView: NSView? { (windowController as? BrowserWindowController)?.rootView ?? contentView }
}

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
  TabOwner, TopBarDelegate, NoteNavigator {
  enum Mode: Equatable {
    case journal, note(NoteRef), notes, web
  }

  private(set) var mode: Mode = .journal
  private(set) var tabs: [Tab] = []
  private(set) var activeTab: Tab?
  private(set) var groups: [TabGroup] = []
  private var lastNoteMode: Mode = .journal
  /// What ⇧⌘T reopens, last closed first: one tab, or all those one ⌥⌘W
  /// closed, with the one that was active.
  private struct ClosedTabs {
    var urls: [String]
    var active: Int
  }
  private var closedTabs: [ClosedTabs] = []
  private var lastCaptureTarget: NoteRef?

  private let root = RootView()
  var rootView: NSView { root }
  private let overlayWindow = OverlayWindow()
  private let overlayRoot = OverlayRootView()
  private(set) var topBar = TopBarView()
  private let contentArea = PassthroughView()
  private let journalView = JournalView()
  private let noteView = NoteView()
  private let notesView = NotesListView()
  private let webContainer = PassthroughView()
  private let toast = ToastView()
  private var errorView: NSView?
  private var findBar: FindBar?
  private var overlay: OverlayView?
  /// Incognito windows keep their tabs' cookies and storage in memory, and
  /// never record history or save their session.
  let isIncognito: Bool
  private let browsingSession: GleaBrowsingSession?
  private var startPage: StartPageView?
  /// Called once the window closed (incognito and extra windows: the main
  /// one quits, or hides).
  var onClose: (() -> Void)?
  /// A regular window besides the main one (⌘N on the web): its tabs are
  /// saved with the main window's, and closing it closes them.
  let isExtra: Bool

  /// Every regular window (not incognito), main first: saved together.
  private static var regularWindows: [BrowserWindowController] = []

  /// An extra window (`extra`) starts empty in `mode` (the front window's;
  /// else on the web), or on the web with `saved`'s tabs (at launch).
  init(incognito: Bool = false, extra: Bool = false, restoring saved: Session.SavedWindow? = nil, mode initialMode: Mode? = nil) {
    isIncognito = incognito
    isExtra = extra && !incognito
    browsingSession = incognito ? .incognito() : nil
    let window = GleaMainWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = incognito ? "Incognito" : "Glea"
    // Dark, like other browsers' private windows (pages keep their own look).
    if incognito { window.appearance = NSAppearance(named: .darkAqua) }
    window.minSize = NSSize(width: 640, height: 420)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    super.init(window: window)
    window.delegate = self
    buildLayout()
    buildStartPage()
    if incognito {
      setMode(.web)
      return
    }
    if isExtra {
      Self.regularWindows.append(self)
      if let saved {
        restore(tabs: saved.tabs, activeIndex: saved.activeIndex, groups: saved.groups)
        if let frame = saved.frame.map(NSRectFromString), !frame.isEmpty { window.setFrame(frame, display: false) }
      }
      updatePinnedExtensions()
      setMode(saved == nil ? initialMode ?? .web : .web)
      // Its current tab shows; the others load hidden.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if let active = self.activeTab { self.activate(active) }
        for tab in self.tabs { self.attach(tab) }
      }
      return
    }
    Self.regularWindows.insert(self, at: 0)
    if !window.setFrameUsingName("GleaMainWindow") { window.center() }
    window.setFrameAutosaveName("GleaMainWindow")
    if let session = Session.load() {
      restore(tabs: session.tabs, activeIndex: session.activeIndex, groups: session.groups)
    }
    updatePinnedExtensions()
    setMode(.journal)
    // Restored tabs load right away, hidden (the active one first), so they
    // are ready when shown instead of loading on first click.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let active = self.activeTab { self.attach(active) }
      for tab in self.tabs { self.attach(tab) }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  // MARK: Layout

  private func buildLayout() {
    window?.contentView = root
    topBar.delegate = self
    // Extensions don't run in incognito (Chrome's default).
    topBar.showsExtensions = GleaBrowserWindow.chromeTabsEnabled && !isIncognito
    topBar.isIncognito = isIncognito
    _ = knownExtensionIDs
    topBar.translatesAutoresizingMaskIntoConstraints = false
    contentArea.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(contentArea)
    root.addSubview(topBar)
    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: root.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      topBar.heightAnchor.constraint(equalToConstant: Theme.topBarHeight),
      contentArea.topAnchor.constraint(equalTo: topBar.bottomAnchor),
      contentArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      contentArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      contentArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    for view in [journalView, noteView, notesView, webContainer] {
      contentArea.addSubview(view)
      view.pinEdges(to: contentArea)
    }
    journalView.navigator = self
    noteView.navigator = self
    notesView.navigator = self
    notesView.onNewNote = { [weak self] in self?.newNote(nil) }
    notesView.onExport = { [weak self] ref in self?.export(ref) }
    notesView.onDelete = { [weak self] refs in self?.confirmDelete(refs) }

    buildOverlayWindow()
    (window as? GleaMainWindow)?.onTitleBarReset = { [weak self] in self?.positionTrafficLights() }
    positionTrafficLights()
    // After each event, in case AppKit re-laid out the title bar unseen.
    NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.positionTrafficLights() }
    }
    toast.translatesAutoresizingMaskIntoConstraints = false
    toast.onHoverChange = { [weak self] _ in self?.updateOverlayInteractivity() }
    overlayRoot.addSubview(toast)
    NSLayoutConstraint.activate([
      toast.centerXAnchor.constraint(equalTo: overlayRoot.centerXAnchor),
      toast.bottomAnchor.constraint(equalTo: overlayRoot.bottomAnchor, constant: -24),
    ])
  }

  func windowDidResize(_ notification: Notification) {
    if isExtra { scheduleSessionSave() }
    positionTrafficLights()
    syncOverlayWindow()
  }
  func windowWillStartLiveResize(_ notification: Notification) { positionTrafficLights() }
  func windowDidEndLiveResize(_ notification: Notification) { positionTrafficLights() }
  func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }
  func windowDidResignKey(_ notification: Notification) { positionTrafficLights() }
  func windowDidBecomeMain(_ notification: Notification) { positionTrafficLights() }
  func windowDidResignMain(_ notification: Notification) { positionTrafficLights() }
  func windowDidExitFullScreen(_ notification: Notification) {
    positionTrafficLights()
    syncOverlayWindow()
  }

  // MARK: Traffic lights

  /// The window buttons sit centered in the 52pt top bar. AppKit lays them
  /// out again (at its default height) when it rebuilds its title bar:
  /// watching their frames puts them back in the same layout pass, before
  /// anything is drawn, so they never visibly move.
  private var trafficLightViews: [NSView] = []
  private var positioningTrafficLights = false

  private func watchTrafficLights() {
    guard let window, let close = window.standardWindowButton(.closeButton), let bar = close.superview,
          let container = bar.superview else { return }
    let views: [NSView] = [container, bar] + [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    guard views.map(ObjectIdentifier.init) != trafficLightViews.map(ObjectIdentifier.init) else { return }
    for view in trafficLightViews { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view) }
    trafficLightViews = views
    for view in views {
      view.postsFrameChangedNotifications = true
      NotificationCenter.default.addObserver(self, selector: #selector(trafficLightMoved), name: NSView.frameDidChangeNotification, object: view)
    }
  }

  @objc private func trafficLightMoved() { positionTrafficLights() }

  private func positionTrafficLights() {
    watchTrafficLights()
    guard !positioningTrafficLights, let window, !window.styleMask.contains(.fullScreen),
          let close = window.standardWindowButton(.closeButton), let bar = close.superview,
          let container = bar.superview else { return }
    positioningTrafficLights = true
    defer { positioningTrafficLights = false }
    let height = Theme.topBarHeight
    let containerFrame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
    if container.frame != containerFrame { container.frame = containerFrame }
    if bar.frame != container.bounds { bar.frame = container.bounds }
    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for (index, type) in types.enumerated() {
      guard let button = window.standardWindowButton(type) else { continue }
      let origin = NSPoint(x: 18 + CGFloat(index) * 20, y: ((height - button.frame.height) / 2).rounded())
      if button.frame.origin != origin { button.setFrameOrigin(origin) }
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    dismissOverlay(restoreFocus: false)
    closeFindBar()
    MarkdownEditorView.flushAll()
    discardIfUntouched()
    // Its tabs close with it (⇧⌘T brings them back; incognito ones, never).
    if !isIncognito { handOffClosedTabs() }
    let closing = tabs
    tabs = []
    activeTab = nil
    for tab in closing { tab.close() }
    guard isIncognito || isExtra else {
      // The main window only goes away: Glea keeps running, and brings it
      // back (the Dock icon, ⌘N, ⇧⌘T).
      refreshTopBar()
      saveSession()
      sender.orderOut(nil)
      return false
    }
    return true
  }

  /// A closing window's tabs, for ⇧⌘T in the window left in front, or (none
  /// left) in the main one, which ⇧⌘T brings back with them. Not kept past
  /// quitting.
  private func handOffClosedTabs() {
    let reopenable = tabs.filter { $0.url.hasPrefix("http") }
    if !reopenable.isEmpty {
      closedTabs.append(ClosedTabs(urls: reopenable.map(\.url), active: reopenable.firstIndex { $0 === activeTab } ?? 0))
    }
    // Its whole ⇧⌘T stack goes along (this window's tabs on top).
    let heir = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
      .first { $0 !== self && !$0.isIncognito && $0.window?.isVisible == true }
      ?? Self.regularWindows.first { !$0.isExtra }
    guard let heir, heir !== self else { return }
    heir.closedTabs += closedTabs
    closedTabs = []
  }


  func windowWillClose(_ notification: Notification) {
    guard isIncognito || isExtra else { return }
    window?.removeChildWindow(overlayWindow)
    overlayWindow.orderOut(nil)
    if isExtra {
      // Not restored any more.
      Self.regularWindows.removeAll { $0 === self }
      saveSession()
    }
    onClose?()
  }

  // An alert on the window (moving a note to the Trash...): all its buttons
  // look disabled with the page dimmed behind it, not only close (AppKit's
  // default leaves minimize and zoom on).
  func windowWillBeginSheet(_ notification: Notification) { setWindowButtonsEnabled(false) }
  func windowDidEndSheet(_ notification: Notification) { setWindowButtonsEnabled(true) }

  private func setWindowButtonsEnabled(_ enabled: Bool) {
    for type in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] { window?.standardWindowButton(type)?.isEnabled = enabled }
  }

  func windowDidMove(_ notification: Notification) {
    if isExtra { scheduleSessionSave() }
  }

  /// Brings back the main window after ⌘W closed it (without tabs): in
  /// `mode` (that of a window already open), else in the notes.
  func reopen(in mode: Mode? = nil) {
    guard let window, !window.isVisible else { return }
    setMode(mode ?? lastNoteMode)
    showWindow(nil)
  }

  // MARK: Start page

  private func buildStartPage() {
    let start = StartPageView(incognito: isIncognito)
    start.omnibox.tabsProvider = { [weak self] in self?.tabs ?? [] }
    // Esc on an empty field: back from the new tab page.
    start.omnibox.onDismiss = { [weak self] in self?.leaveNewTab() }
    start.omnibox.onChoose = { [weak self, weak start] item, target in
      self?.perform(item, target: target)
      start?.omnibox.clear()
    }
    webContainer.addSubview(start)
    start.pinEdges(to: webContainer)
    startPage = start
  }

  /// ⌘T shows the start page in place of the current page; a tab appears
  /// only once something is chosen there. Leaving it (⌘W, Esc, another tab,
  /// the notes) goes back to where it was.
  private(set) var isShowingNewTab = false

  /// ⌘T: the new tab page (or, already on it, its field).
  func openNewTab() {
    guard !(isShowingNewTab && mode == .web) else {
      focusStartPage()
      return
    }
    dismissOverlay(restoreFocus: false)
    closeFindBar()
    isShowingNewTab = true
    activeTab?.browserView?.isHidden = true
    setMode(.web)
  }

  /// Back from the new tab page to the current tab, without opening anything.
  func leaveNewTab() {
    guard isShowingNewTab else { return }
    isShowingNewTab = false
    if mode == .web, let tab = activeTab {
      tab.browserView?.isHidden = false
      if tab.errorMessage == nil { tab.browserView?.focusPage() }
    }
    updateErrorView()
    refreshTopBar()
  }

  /// The start page shows on the web while the window has no tabs (the main
  /// window shows the notes instead once its last tab closes).
  private func updateStartPage() {
    guard let start = startPage else { return }
    let show = mode == .web && (tabs.isEmpty || isShowingNewTab)
    guard start.isHidden == show else { return }
    start.isHidden = !show
    if show {
      start.shufflePhrase()
      focusStartPage()
    }
  }

  private func focusStartPage() {
    guard let start = startPage, !start.isHidden, window?.isVisible == true else { return }
    // The field is in this window, not the overlay one (which can take key
    // status as the window comes forward).
    window?.makeKey()
    start.omnibox.activate()
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    presentStartPage()
  }

  private func presentStartPage() {
    guard let start = startPage, !start.isHidden else { return }
    start.omnibox.clear()
    start.shufflePhrase()
    start.layoutSubtreeIfNeeded()
    focusStartPage()
    start.omnibox.animateAppear()
    // Again once AppKit is done bringing the window (and its children) forward.
    DispatchQueue.main.async { [weak self] in self?.focusStartPage() }
  }

  // MARK: Overlay window

  private func buildOverlayWindow() {
    overlayRoot.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
    overlayWindow.contentView = overlayRoot
    overlayRoot.onSubviewsChange = { [weak self] in self?.updateOverlayInteractivity() }
    window?.addChildWindow(overlayWindow, ordered: .above)
    syncOverlayWindow()
    // Pages are drawn in child windows too: stay above them.
    NotificationCenter.default.addObserver(forName: Notification.Name("GleaChromeWindowShown"), object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.raiseOverlayWindow() }
    }
  }

  private func syncOverlayWindow() {
    guard let window else { return }
    overlayWindow.setFrame(window.frame, display: true)
  }

  private func raiseOverlayWindow() {
    guard let window else { return }
    window.removeChildWindow(overlayWindow)
    window.addChildWindow(overlayWindow, ordered: .above)
  }

  /// Clicks go through the overlay window unless an overlay wants them.
  private func updateOverlayInteractivity() {
    overlayWindow.ignoresMouseEvents = !overlayRoot.subviews.contains { $0 is OverlayView || $0 is FindBar } && !toast.isHovered
  }

  // MARK: Modes

  private var transitionGeneration = 0

  private func container(for mode: Mode) -> NSView {
    switch mode {
    case .journal: return journalView
    case .note: return noteView
    case .notes: return notesView
    case .web: return webContainer
    }
  }

  /// What had the keyboard focus in the notes when the web took over (a
  /// note's text, with its cursor), and where: coming back gives it back.
  private weak var notesFocusView: NSView?
  private var notesFocusMode: Mode?
  /// Whether the last mode change gave the notes' focus back.
  private var restoredNotesFocus = false

  func setMode(_ newMode: Mode) {
    let previousPlace = currentNotePlace
    if newMode == .web, mode != .web, let view = window?.firstResponder as? NSView, view.isDescendant(of: container(for: mode)) {
      notesFocusView = view
      notesFocusMode = mode
    }
    if case .note = mode, newMode != mode {
      MarkdownEditorView.flushAll()
      discardIfUntouched()
    }
    let outgoing = container(for: mode)
    let incoming = container(for: newMode)
    mode = newMode
    if newMode != .web { isShowingNewTab = false }
    if case .note(let ref) = newMode { noteView.show(ref) }
    switch newMode {
    case .journal: journalView.reloadIfNeeded()
    case .notes: notesView.reload()
    case .web: if !isShowingNewTab { activeTab?.browserView?.isHidden = false }
    case .note: break
    }
    crossfade(from: outgoing, to: incoming)
    restoredNotesFocus = false
    if newMode != .web, newMode == notesFocusMode, let view = notesFocusView, view.window === window, view.isDescendant(of: incoming) {
      restoredNotesFocus = window?.makeFirstResponder(view) == true
    }
    if newMode != .web {
      // A new place in the notes is a step back from the last one (the
      // window's first place isn't).
      if hasNotePlace, !isNavigatingNoteHistory, newMode != previousPlace {
        noteBackStack.append(previousPlace)
        noteForwardStack.removeAll()
      }
      hasNotePlace = true
      lastNoteMode = newMode
      closeFindBar()
    }
    updateErrorView()
    refreshTopBar()
    scheduleSessionSave()
  }

  /// Fades between the web and the journal/notes views: the new one rises
  /// in from 98.5% while the old one fades and grows slightly.
  private func crossfade(from outgoing: NSView, to incoming: NSView) {
    transitionGeneration += 1
    let generation = transitionGeneration
    for view in [journalView, noteView, notesView, webContainer] where view !== incoming && view !== outgoing {
      view.isHidden = true
    }
    incoming.isHidden = false
    incoming.layer?.removeAllAnimations()
    guard outgoing !== incoming else { return }
    let animate = window?.isVisible == true && !Motion.reduceMotion
    if !animate {
      finishTransition(hiding: outgoing)
      return
    }
    contentArea.addSubview(incoming, positioned: .above, relativeTo: outgoing)
    incoming.animateIn(scale: 0.985, fade: 0.18, duration: 0.32, timing: Motion.easeOut)
    outgoing.animateOut(scale: 1.01, fade: 0.14, duration: 0.2) { [weak self] in
      guard let self, generation == self.transitionGeneration else { return }
      self.finishTransition(hiding: outgoing)
    }
    // Chrome-style pages are drawn in their own window over webContainer:
    // fade it along.
    if let page = activeTab?.browserView?.chromeWindow, !isShowingNewTab {
      if incoming === webContainer {
        page.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.22
          context.timingFunction = Motion.easeOut
          page.animator().alphaValue = 1
        }
      } else if outgoing === webContainer {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.14
          page.animator().alphaValue = 0
        }
      }
    }
  }

  private func finishTransition(hiding view: NSView) {
    guard view !== container(for: mode) else { return }
    view.isHidden = true
    view.layer?.removeAllAnimations()
    if view === webContainer {
      activeTab?.browserView?.isHidden = true
      // Faded out and now hidden: opaque again for next time (unless the
      // page keeps running out of sight, its window transparent).
      if activeTab?.browserView?.isKeptRunning != true { activeTab?.browserView?.chromeWindow?.alphaValue = 1 }
    }
  }

  private func refreshTopBar() {
    let section: TopBarView.Section
    switch mode {
    case .journal: section = .journal
    case .notes: section = .notes
    case .web: section = .web
    case .note: section = .other
    }
    let infos = tabs.map {
      TopBarView.TabInfo(id: ObjectIdentifier($0), title: $0.displayTitle, url: $0.url, favicon: $0.favicon, isLoading: $0.isLoading,
                         isPinned: $0.isPinned, groupID: $0.groupID,
                         media: TabMedia(audible: $0.isAudible, muted: $0.isMuted, camera: $0.usesCamera, microphone: $0.usesMicrophone))
    }
    let groupInfos = groups.map { group in
      TopBarView.GroupInfo(id: group.id, label: group.label(count: tabs.filter { $0.groupID == group.id }.count),
                           color: group.color, collapsed: group.collapsed)
    }
    topBar.nextGroupColor = TabGroupPalette.color(TabGroupPalette.unused(besides: groups.map(\.colorIndex)))
    // On the new tab page, no tab is current.
    let shown = isShowingNewTab ? nil : activeTab
    // Back and Forward go through the tab's pages, or the notes' places.
    let web = mode == .web
    topBar.update(section: section, tabs: infos, groups: groupInfos, activeID: shown.map(ObjectIdentifier.init),
                  canGoBack: web ? shown?.canGoBack ?? false : canGoBackInNotes,
                  canGoForward: web ? shown?.canGoForward ?? false : canGoForwardInNotes,
                  progress: shown?.isLoading == true ? max(0.05, shown?.progress ?? 0) : 0)
    let appTitle = isIncognito ? "Incognito" : "Glea"
    window?.title = mode != .web ? appTitle : isShowingNewTab ? "New Tab" : (activeTab?.displayTitle ?? appTitle)
    updateStartPage()
  }

  // MARK: Notes history

  /// The places the notes have been in this window (the journal, All Notes,
  /// notes), for Back and Forward. Each window has its own.
  private var noteBackStack: [Mode] = []
  private var noteForwardStack: [Mode] = []
  /// Whether the window has shown the notes yet.
  private var hasNotePlace = false
  private var isNavigatingNoteHistory = false

  /// Where the notes are now (a note renamed since it opened, by its new name).
  private var currentNotePlace: Mode {
    if case .note = lastNoteMode, let ref = noteView.ref { return .note(ref) }
    return lastNoteMode
  }

  /// The nearest place in `stack` that can be shown and isn't where the
  /// notes already are (deleted notes are skipped).
  private func nextNotePlace(in stack: [Mode]) -> Int? {
    let current = currentNotePlace
    return stack.lastIndex { place in
      if case .note(let ref) = place, !NoteStore.shared.exists(ref) { return false }
      return place != current
    }
  }

  private var canGoBackInNotes: Bool { nextNotePlace(in: noteBackStack) != nil }
  private var canGoForwardInNotes: Bool { nextNotePlace(in: noteForwardStack) != nil }

  private func goBackInNotes() {
    guard let index = nextNotePlace(in: noteBackStack) else { return }
    let place = noteBackStack[index]
    noteBackStack.removeSubrange(index...)
    noteForwardStack.append(currentNotePlace)
    showNotePlace(place)
  }

  private func goForwardInNotes() {
    guard let index = nextNotePlace(in: noteForwardStack) else { return }
    let place = noteForwardStack[index]
    noteForwardStack.removeSubrange(index...)
    noteBackStack.append(currentNotePlace)
    showNotePlace(place)
  }

  private func showNotePlace(_ place: Mode) {
    isNavigatingNoteHistory = true
    setMode(place)
    isNavigatingNoteHistory = false
  }

  // MARK: Tabs

  @discardableResult
  func openTab(_ url: String, background: Bool = false) -> Tab {
    let tab = Tab(url: url, session: browsingSession)
    tab.owner = self
    // After the current tab, but never among pinned tabs; inside a group it
    // joins the group (opened from one of its pages).
    let pinnedCount = tabs.filter(\.isPinned).count
    if let active = activeTab, let index = tabs.firstIndex(where: { $0 === active }) {
      let at = max(index + 1, pinnedCount)
      if !active.isPinned, let group = active.groupID { tab.groupID = group }
      tabs.insert(tab, at: at)
    } else {
      tabs.append(tab)
    }
    normalizeTabOrder()
    if background {
      attach(tab)
      refreshTopBar()
    } else {
      activate(tab)
    }
    scheduleSessionSave()
    return tab
  }

  private func attach(_ tab: Tab) {
    let view = tab.ensureBrowserView()
    guard view.superview == nil else { return }
    view.frame = webContainer.bounds
    view.autoresizingMask = [.width, .height]
    view.isHidden = true
    webContainer.addSubview(view)
  }

  func activate(_ tab: Tab) {
    isShowingNewTab = false
    let previous = activeTab
    activeTab = tab
    attach(tab)
    closeFindBar()
    // Show (and focus) the new page before hiding the old one: its window
    // takes keyboard focus straight from the old page's, so the main window
    // never flickers between key and not (its traffic lights would).
    tab.browserView?.isHidden = false
    setMode(.web)
    if tab.errorMessage == nil { tab.browserView?.focusPage() }
    if previous !== tab { previous?.browserView?.isHidden = true }
  }

  /// ⌘W and the tab's × leave pinned tabs open (Beam's rule): only the
  /// menu's "Close Tab" (`force`) closes them.
  func closeTab(_ tab: Tab, force: Bool = false) {
    if tab.isPinned && !force {
      if let next = tabs.first(where: { !$0.isPinned }) { activate(next) }
      return
    }
    guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
    tabs.remove(at: index)
    if tab.url.hasPrefix("http") { closedTabs.append(ClosedTabs(urls: [tab.url], active: 0)) }
    if activeTab === tab {
      activeTab = nil
      if tabs.isEmpty {
        // Incognito: back to its start page. Otherwise the notes, in the
        // last window; any other window closes.
        if isIncognito {
          setMode(.web)
        } else if isLastWindow {
          setMode(lastNoteMode)
        } else {
          DispatchQueue.main.async { [weak self] in self?.window?.performClose(nil) }
        }
      } else {
        activate(tabs[min(index, tabs.count - 1)])
      }
    }
    tab.close()
    normalizeTabOrder()
    refreshTopBar()
    scheduleSessionSave()
  }

  func refreshTopBarForTests() { groupsChanged() }

  // MARK: Pinned tabs and groups

  /// Pinned tabs first; each group's tabs together (where its first one is);
  /// groups without tabs go away.
  private func normalizeTabOrder() {
    let pinned = tabs.filter(\.isPinned)
    for tab in pinned { tab.groupID = nil }
    var rest: [Tab] = []
    var placed = Set<UUID>()
    let known = Set(groups.map(\.id))
    for tab in tabs where !tab.isPinned {
      if let group = tab.groupID, !known.contains(group) { tab.groupID = nil }
      guard let group = tab.groupID else {
        rest.append(tab)
        continue
      }
      if placed.insert(group).inserted { rest += tabs.filter { !$0.isPinned && $0.groupID == group } }
    }
    tabs = pinned + rest
    groups.removeAll { group in !tabs.contains { $0.groupID == group.id } }
    // A collapsed group hides its tabs: never the one being shown.
    if let group = activeTab?.groupID, let g = groups.first(where: { $0.id == group }), g.collapsed { g.collapsed = false }
  }

  private func group(_ id: UUID?) -> TabGroup? { groups.first { $0.id == id } }

  private func tabs(in group: TabGroup) -> [Tab] { tabs.filter { $0.groupID == group.id } }

  private func groupsChanged() {
    normalizeTabOrder()
    refreshTopBar()
    scheduleSessionSave()
  }

  func setPinned(_ tab: Tab, _ pinned: Bool) {
    guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
    tabs.remove(at: index)
    tab.isPinned = pinned
    tab.groupID = nil
    // Pinned: last of the pinned tabs. Unpinned: first after them.
    tabs.insert(tab, at: tabs.filter(\.isPinned).count)
    groupsChanged()
  }

  @discardableResult
  func createGroup(with tab: Tab) -> TabGroup {
    let group = TabGroup(colorIndex: TabGroupPalette.unused(besides: groups.map(\.colorIndex)))
    groups.append(group)
    if tab.isPinned { setPinned(tab, false) }
    tab.groupID = group.id
    groupsChanged()
    return group
  }

  func move(_ tab: Tab, to group: TabGroup?) {
    if tab.isPinned { tab.isPinned = false }
    if let group, let last = tabs.last(where: { $0.groupID == group.id }), let index = tabs.firstIndex(where: { $0 === tab }) {
      // Next to the group's last tab.
      tabs.remove(at: index)
      let at = (tabs.firstIndex { $0 === last } ?? tabs.count - 1) + 1
      tabs.insert(tab, at: at)
    }
    tab.groupID = group?.id
    groupsChanged()
  }

  /// ⌥-drag: `tab` goes right after `target`, in the target's group, or in a
  /// new group made of the two.
  func group(_ tab: Tab, with target: Tab) {
    guard tab !== target, let from = tabs.firstIndex(where: { $0 === tab }) else { return }
    tabs.remove(at: from)
    tab.isPinned = false
    let at = (tabs.firstIndex { $0 === target } ?? tabs.count - 1) + 1
    tabs.insert(tab, at: at)
    if let existing = self.group(target.groupID) {
      tab.groupID = existing.id
    } else {
      let group = TabGroup(colorIndex: TabGroupPalette.unused(besides: groups.map(\.colorIndex)))
      groups.append(group)
      if target.isPinned { setPinned(target, false) }
      target.groupID = group.id
      tab.groupID = group.id
    }
    groupsChanged()
  }

  func toggleCollapsed(_ group: TabGroup) {
    group.collapsed.toggle()
    if group.collapsed, let active = activeTab, active.groupID == group.id {
      // Show something else: the nearest tab outside the group.
      let members = tabs(in: group)
      let others = tabs.filter { $0.groupID != group.id && !(self.group($0.groupID)?.collapsed ?? false) }
      let after = others.first { tab in (tabs.firstIndex { $0 === tab } ?? 0) > (tabs.firstIndex { $0 === members.last } ?? 0) }
      if let next = after ?? others.last {
        activate(next)
      } else {
        group.collapsed = false
      }
    }
    groupsChanged()
  }

  func ungroup(_ group: TabGroup) {
    for tab in tabs(in: group) { tab.groupID = nil }
    groupsChanged()
  }

  func closeGroup(_ group: TabGroup) {
    for tab in tabs(in: group) { closeTab(tab, force: true) }
  }

  func newTab(in group: TabGroup) {
    group.collapsed = false
    if let last = tabs(in: group).last { activate(last) }
    // New tabs join the group of the tab they're opened from.
    openNewTab()
  }

  func captureGroupToNote(_ group: TabGroup) {
    let members = tabs(in: group)
    let title = group.suggestedTitle(for: members)
    var lines = ["**\(title)**"]
    for tab in members {
      let name = tab.displayTitle.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
      lines.append("- [\(name)](\(tab.url))")
    }
    NoteStore.shared.append(lines.joined(separator: "\n"), to: NoteStore.shared.today)
    toast.show("Captured “\(title)” to", linkTitle: "Today") { [weak self] in self?.openCollected(NoteStore.shared.today) }
  }

  /// Drag & drop from the tab bar: `index` is the tab's new position among
  /// all tabs (with it removed), where it becomes pinned or joins `group`.
  func move(_ tab: Tab, toIndex index: Int, pinned: Bool, group: UUID?) {
    guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
    tabs.remove(at: from)
    tab.isPinned = pinned
    tab.groupID = pinned ? nil : group
    tabs.insert(tab, at: min(max(0, index), tabs.count))
    groupsChanged()
  }

  /// Drag & drop of a group capsule: its tabs move together to `index`
  /// (among the other tabs).
  func move(_ group: TabGroup, toIndex index: Int) {
    let members = tabs(in: group)
    tabs.removeAll { $0.groupID == group.id }
    tabs.insert(contentsOf: members, at: min(max(0, index), tabs.count))
    groupsChanged()
  }

  // MARK: Tab bar menus

  func tabMenu(for tab: Tab) -> NSMenu {
    let menu = NSMenu()
    func add(_ title: String, _ action: @escaping () -> Void) {
      menu.addItem(ClosureMenuItem(title: title, action: action))
    }
    add(tab.isPinned ? "Unpin Tab" : "Pin Tab") { [weak self] in self?.setPinned(tab, !tab.isPinned) }
    add("Duplicate Tab") { [weak self] in
      guard let self else { return }
      self.activate(tab)
      let copy = self.openTab(tab.url)
      if tab.isPinned { self.setPinned(copy, false) }
    }
    add("Reload Tab") { tab.browserView?.reload() }
    add(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.setMuted(!tab.isMuted) }
    if !tab.isPinned {
      menu.addItem(.separator())
      if let current = group(tab.groupID) {
        add("Remove from Group") { [weak self] in self?.move(tab, to: nil) }
        let others = groups.filter { $0 !== current }
        if !others.isEmpty { menu.addItem(groupsSubmenu("Move to Group", groups: others, tab: tab)) }
      } else {
        add("Add to New Group") { [weak self] in self?.createGroup(with: tab) }
        if !groups.isEmpty { menu.addItem(groupsSubmenu("Add to Group", groups: groups, tab: tab)) }
      }
    }
    menu.addItem(.separator())
    add("Copy Address") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(tab.url, forType: .string)
    }
    menu.addItem(.separator())
    add("Close Tab") { [weak self] in self?.closeTab(tab, force: true) }
    add("Close Other Tabs") { [weak self] in
      guard let self else { return }
      for other in self.tabs where other !== tab && !other.isPinned { self.closeTab(other) }
    }
    add("Close Tabs to the Right") { [weak self] in
      guard let self, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
      for other in self.tabs[(index + 1)...] where !other.isPinned { self.closeTab(other) }
    }
    return menu
  }

  private func groupsSubmenu(_ title: String, groups: [TabGroup], tab: Tab) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    for group in groups {
      let entry = ClosureMenuItem(title: group.suggestedTitle(for: tabs(in: group))) { [weak self] in self?.move(tab, to: group) }
      entry.image = TabGroupPalette.dot(group.colorIndex, size: 12)
      submenu.addItem(entry)
    }
    item.submenu = submenu
    return item
  }

  func groupMenu(for group: TabGroup) -> NSMenu {
    let menu = NSMenu()
    let editor = NSMenuItem()
    editor.view = GroupEditorView(group: group, onChange: { [weak self] in self?.groupsChanged() },
                                  onDone: { [weak menu] in menu?.cancelTracking() })
    menu.addItem(editor)
    menu.addItem(.separator())
    func add(_ title: String, _ action: @escaping () -> Void) {
      menu.addItem(ClosureMenuItem(title: title, action: action))
    }
    add("New Tab in Group") { [weak self] in self?.newTab(in: group) }
    add("Copy Links") { [weak self] in
      guard let self else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(self.tabs(in: group).map(\.url).joined(separator: "\n"), forType: .string)
    }
    add("Capture Group to Today") { [weak self] in self?.captureGroupToNote(group) }
    menu.addItem(.separator())
    add(group.collapsed ? "Expand Group" : "Collapse Group") { [weak self] in self?.toggleCollapsed(group) }
    add("Ungroup") { [weak self] in self?.ungroup(group) }
    add("Close Group") { [weak self] in self?.closeGroup(group) }
    return menu
  }

  // MARK: TabOwner

  func tabDidUpdate(_ tab: Tab) {
    refreshTopBar()
    if tab === activeTab { updateErrorView() }
    scheduleSessionSave()
  }

  func tab(_ tab: Tab, requestsNewTab url: String, background: Bool) {
    openTab(url, background: background)
  }

  func tab(_ tab: Tab, didReceiveMessage name: String, payload: [String: Any]) {
    if name == "testResult" {
      NSLog("Glea test result: \(payload["value"] ?? "")")
      return
    }
    guard tab === activeTab, mode == .web else { return }
    if name == "captureArea" {
      captureArea(payload, in: tab)
      return
    }
    guard name == "capture" else { return }
    let capture = Capture(
      kind: Capture.Kind(rawValue: payload["kind"] as? String ?? "") ?? .element,
      markdown: payload["markdown"] as? String ?? "",
      text: payload["text"] as? String ?? "",
      pageURL: payload["url"] as? String ?? tab.url,
      pageTitle: payload["title"] as? String ?? tab.title)
    showCapturePanel(capture, anchorInWindow: anchor(for: payload["rect"], in: tab), from: tab)
  }

  /// Converts a viewport rect (CSS pixels) from the page into window coordinates.
  private func anchor(for value: Any?, in tab: Tab) -> NSRect? {
    guard let rect = value as? [String: Double], let view = tab.browserView else { return nil }
    let zoom = pow(1.2, view.zoomLevel)
    let pageRect = NSRect(x: (rect["x"] ?? 0) * zoom, y: (rect["y"] ?? 0) * zoom,
                          width: (rect["width"] ?? 0) * zoom, height: (rect["height"] ?? 0) * zoom)
    return view.convert(pageRect, to: nil)
  }

  /// A dragged area: screenshot it through DevTools, then offer to collect it.
  private func captureArea(_ payload: [String: Any], in tab: Tab) {
    guard let area = payload["rect"] as? [String: Double], let view = tab.browserView else { return }
    let rect = NSRect(x: area["x"] ?? 0, y: area["y"] ?? 0, width: area["width"] ?? 0, height: area["height"] ?? 0)
    let viewportWidth = (payload["viewport"] as? [String: Double])?["width"] ?? Double(view.bounds.width / pow(1.2, view.zoomLevel))
    // The viewport as shown, cropped here (a clipped capture flashes the page).
    view.captureScreenshot(ofPageRect: .zero) { [weak self, weak tab] full in
      guard let self, let tab else { return }
      tab.browserView?.executeJavaScript("window.__gleaPNS && __gleaPNS.shotTaken()")
      let png = full.flatMap { Self.crop($0, to: rect, viewportWidth: viewportWidth) }
      guard let png else {
        tab.browserView?.executeJavaScript("window.__gleaPNS && __gleaPNS.cancel()")
        self.toast.show("Couldn’t capture that area")
        return
      }
      var capture = Capture(kind: .image, markdown: "", text: "Screenshot of \(tab.displayTitle)",
                            pageURL: payload["url"] as? String ?? tab.url,
                            pageTitle: payload["title"] as? String ?? tab.title)
      capture.imageData = png
      self.showCapturePanel(capture, anchorInWindow: self.anchor(for: payload["rect"], in: tab), from: tab)
    }
  }

  /// Crops a viewport screenshot to `rect`, given in the page's CSS pixels.
  private static func crop(_ png: Data, to rect: NSRect, viewportWidth: Double) -> Data? {
    guard let bitmap = NSBitmapImageRep(data: png), let image = bitmap.cgImage, viewportWidth > 0 else { return nil }
    let scale = CGFloat(image.width) / CGFloat(viewportWidth)
    let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
      .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !pixels.isEmpty, let cropped = image.cropping(to: pixels) else { return nil }
    return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
  }

  func tab(_ tab: Tab, contextCommand: GleaContextCommand, argument: String) {
    switch contextCommand {
    case .openLinkInNewTab, .openImageInNewTab:
      openTab(argument, background: true)
    case .copyLink:
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(argument, forType: .string)
    case .collectSelection:
      tab.browserView?.executeJavaScript("window.__gleaPNS && __gleaPNS.collectSelection()")
    case .searchSelection:
      openTab(SearchEngine.current.searchURL(argument))
    case .collectImage:
      tab.browserView?.executeJavaScript("window.__gleaPNS && __gleaPNS.collectImage(\(jsString(argument)))")
    case .collectPage:
      collectPage(nil)
    @unknown default:
      break
    }
  }

  func tab(_ tab: Tab, didFailWithError error: String, url: String) {
    if tab === activeTab { updateErrorView() }
  }

  func tab(_ tab: Tab, findResultCount count: Int, active: Int) {
    if tab === activeTab { findBar?.setResult(count: count, active: active) }
  }

  func tab(_ tab: Tab, didDownload path: String) {
    toast.show("Downloaded \((path as NSString).lastPathComponent)")
  }

  /// Answers to sites asking for the camera and microphone, until Glea quits
  /// (incognito windows keep theirs apart), by "incognito|origin|device".
  private static var mediaAnswers: [String: Bool] = [:]

  /// Asks whether the page may use the camera and/or microphone (a sheet over
  /// the tab, brought forward), unless this was answered already.
  func tab(_ tab: Tab, requestsMediaAccessFor origin: String, camera: Bool, microphone: Bool,
           completion: @escaping (Bool) -> Void) {
    let devices = [camera ? "camera" : nil, microphone ? "microphone" : nil].compactMap { $0 }
    let keys = devices.map { "\(isIncognito)|\(origin)|\($0)" }
    let answers = keys.map { Self.mediaAnswers[$0] }
    if answers.contains(false) { return completion(false) }
    if answers.allSatisfy({ $0 == true }) { return completion(true) }
    guard let window, tabs.contains(where: { $0 === tab }) else { return completion(false) }
    if activeTab !== tab || mode != .web || isShowingNewTab { activate(tab) }
    let site = URL(string: origin)?.host ?? origin
    let alert = NSAlert()
    alert.messageText = "Allow “\(site)” to use your \(devices.joined(separator: " and "))?"
    alert.informativeText = "Glea remembers your answer for this site until you quit."
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Don’t Allow")
    alert.beginSheetModal(for: window) { response in
      let allowed = response == .alertFirstButtonReturn
      for key in keys { Self.mediaAnswers[key] = allowed }
      completion(allowed)
    }
  }

  func tabDidClose(_ tab: Tab) {
    tab.browserView?.removeFromSuperview()
  }

  private func jsString(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
  }

  // MARK: Load errors

  /// What the error view currently shows, so frequent tab updates (loading
  /// state, progress, retries) don't rebuild it and replay its entrance.
  private var errorViewKey: String?

  private func updateErrorView() {
    let key = mode == .web && !isShowingNewTab ? activeTab.flatMap { tab in tab.errorMessage.map { "\(ObjectIdentifier(tab))|\(tab.url)|\($0)" } } : nil
    guard key != errorViewKey else { return }
    errorViewKey = key
    errorView?.removeFromSuperview()
    errorView = nil
    // A Chrome-style page is a window over webContainer: hide it for the error.
    if mode == .web && !isShowingNewTab { activeTab?.browserView?.isHidden = false }
    guard mode == .web, !isShowingNewTab, let tab = activeTab, let message = tab.errorMessage else { return }
    tab.browserView?.isHidden = true

    let view = BackgroundView()
    let title = NSTextField.label("This page couldn’t be loaded", size: 20, weight: .semibold)
    let detail = NSTextField(wrappingLabelWithString: "\(OmniboxView.shortURL(tab.url))\n\(message)")
    detail.textColor = Theme.secondaryText
    detail.alignment = .center
    let retry = NSButton(title: "Try Again", target: self, action: #selector(reload(_:)))
    retry.bezelStyle = .rounded
    let stack = NSStackView(views: [title, detail, retry])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
    ])
    webContainer.addSubview(view)
    view.pinEdges(to: webContainer)
    errorView = view
    stack.animateIn(scale: 0.97, fade: 0.2, duration: 0.35)
  }

  // MARK: Overlays

  /// The page waiting on the capture card, told to cancel if the card goes
  /// away without a choice (e.g. replaced by the omnibox).
  private weak var captureTab: Tab?

  private func present(_ newOverlay: OverlayView) {
    releasePendingCapture()
    dismissOverlay(restoreFocus: false)
    newOverlay.frame = overlayRoot.bounds
    newOverlay.autoresizingMask = [.width, .height]
    overlayRoot.addSubview(newOverlay)
    raiseOverlayWindow()
    overlayWindow.ignoresMouseEvents = false
    overlayWindow.makeKey()
    overlay = newOverlay
  }

  private func releasePendingCapture() {
    captureTab?.browserView?.executeJavaScript("window.__gleaPNS && __gleaPNS.cancel()")
    captureTab = nil
  }

  func dismissOverlayForTesting() { dismissOverlay() }

  /// Types into the overlay's focused field (the omnibox), or deletes
  /// backward for "\u{8}".
  func typeInOverlayForTesting(_ text: String) {
    guard let editor = overlayWindow.firstResponder as? NSTextView else { return }
    if text == "\u{8}" { editor.deleteBackward(nil) } else { editor.insertText(text, replacementRange: editor.selectedRange()) }
  }

  /// A key press in the overlay's field (Return, with modifiers).
  func pressReturnInOverlayForTesting(_ modifiers: NSEvent.ModifierFlags) {
    guard let editor = overlayWindow.firstResponder as? NSTextView,
          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: overlayWindow.windowNumber, context: nil, characters: "\r",
                                       charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return }
    // Through the event queue, as a real key press (the omnibox reads its
    // modifiers from the current event).
    _ = editor
    overlayWindow.makeKey()
    NSApp.postEvent(event, atStart: false)
  }

  func overlayFieldTextForTesting() -> String {
    guard let editor = overlayWindow.firstResponder as? NSTextView else { return "" }
    let range = editor.selectedRange()
    return "\(editor.string) [selected \(range.location)+\(range.length)]"
  }

  private func dismissOverlay(restoreFocus: Bool = true) {
    guard let current = overlay else { return }
    overlay = nil
    current.animateDismiss()
    if restoreFocus, mode == .web { activeTab?.browserView?.focusPage() }
  }

  // MARK: Extensions

  /// A top bar rect in overlay coordinates (the overlay window covers the
  /// main window; overlays are flipped).
  private func overlayAnchor(forTopBarRect rect: NSRect) -> NSRect? {
    guard let window else { return nil }
    let inWindow = topBar.convert(rect, to: nil)
    return NSRect(x: inWindow.minX, y: window.frame.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
  }

  func topBarShowExtensions(from anchor: NSRect) {
    guard let menuAnchor = overlayAnchor(forTopBarRect: anchor) else { return }
    let installed = ExtensionStore.installed()
    updatePinnedExtensions(installed)
    let menu = ExtensionsMenu(extensions: installed, anchor: menuAnchor)
    menu.onDismiss = { [weak self] in self?.dismissOverlay() }
    menu.onTogglePin = { [weak self] id in
      ExtensionPins.toggle(id)
      self?.updatePinnedExtensions()
    }
    menu.onChoose = { [weak self] item in
      guard let self, case .open(let target) = item.action else { return }
      self.dismissOverlay(restoreFocus: false)
      if let ext = ExtensionStore.installed().first(where: { $0.id == target }) {
        self.openExtension(ext, anchor: menuAnchor)
      } else {
        self.openTab(target)
      }
    }
    present(menu)
    menu.window?.makeFirstResponder(menu)
    menu.animateAppear()
  }

  func topBarOpenExtension(_ id: String, from anchor: NSRect) {
    guard let ext = ExtensionStore.installed().first(where: { $0.id == id }),
          let popupAnchor = overlayAnchor(forTopBarRect: anchor) else { return }
    dismissOverlay(restoreFocus: false)
    openExtension(ext, anchor: popupAnchor)
  }

  func topBarUnpinExtension(_ id: String) {
    if ExtensionPins.isPinned(id) { ExtensionPins.toggle(id) }
    updatePinnedExtensions()
  }

  /// Its popup under `anchor`, or its options page when it has none.
  private func openExtension(_ ext: InstalledExtension, anchor: NSRect) {
    if let popup = ext.popupURL {
      showExtensionPopup(popup, anchor: anchor)
    } else {
      openTab(ext.optionsURL)
    }
  }

  /// Shows the pinned extensions (still installed) in the top bar.
  func updatePinnedExtensions(_ installed: [InstalledExtension]? = nil) {
    guard topBar.showsExtensions else { return }
    let pinned = ExtensionPins.pinned(in: installed ?? ExtensionStore.installed())
    topBar.setPinnedExtensions(pinned.map { .init(id: $0.id, name: $0.name, icon: $0.icon) })
  }

  private func showExtensionPopup(_ url: String, anchor: NSRect) {
    let popup = ExtensionPopup(url: url, anchor: anchor)
    popup.onDismiss = { [weak self] in self?.dismissOverlay() }
    popup.onOpenTab = { [weak self] url, background in
      if !background { self?.dismissOverlay(restoreFocus: false) }
      self?.openTab(url, background: background)
    }
    present(popup)
    popup.animateAppear()
    // Not focused: the page's window must stay the last focused one for
    // extensions asking which tab is current (a click focuses the popup).
  }

  @objc func showExtensionsPage(_ sender: Any?) { openTab("chrome://extensions") }

  private lazy var knownExtensionIDs = Set(ExtensionStore.installed().map(\.id))

  /// Chrome opened (and Glea closed) a window of its own: open its page as
  /// a tab, and confirm a new extension (Chrome shows it with a New Tab page).
  func chromeOpenedWindow(showing url: String) {
    let isNewTabPage = url.hasPrefix("chrome://newtab") || url.hasPrefix("chrome://new-tab-page") || url.isEmpty
    // DevTools have their own (Glea) window or pane: never a tab.
    if !isNewTabPage, !url.hasPrefix("devtools://") {
      reopen()
      openTab(url)
    }
    let installed = ExtensionStore.installed()
    let added = installed.filter { !knownExtensionIDs.contains($0.id) }
    knownExtensionIDs = Set(installed.map(\.id))
    updatePinnedExtensions(installed)
    if let ext = added.first {
      toast.show("\(ext.name) added — it’s in the puzzle menu")
    }
  }

  func showOmnibox(target: OmniboxView.Target) {
    // The start page has its own.
    if let start = startPage, !start.isHidden {
      dismissOverlay(restoreFocus: false)
      focusStartPage()
      return
    }
    let initial = target == .currentTab ? (activeTab?.url ?? "") : ""
    let omnibox = OmniboxView(target: target, initialText: initial)
    omnibox.isIncognito = isIncognito
    omnibox.tabsProvider = { [weak self] in self?.tabs ?? [] }
    omnibox.onDismiss = { [weak self] in self?.dismissOverlay() }
    omnibox.onChoose = { [weak self] item, target in
      guard let self else { return }
      self.dismissOverlay(restoreFocus: false)
      self.perform(item, target: target)
    }
    present(omnibox)
    omnibox.activate()
    omnibox.animateAppear()
  }

  private func perform(_ item: PickerItem, target: OmniboxView.Target) {
    switch item.action {
    case .open(let url):
      // (From the new tab page: a tab of its own.)
      if target == .currentTab, !isShowingNewTab, let tab = activeTab {
        tab.load(url)
        activate(tab)
      } else {
        openTab(url)
      }
    case .note(let ref):
      openNote(ref)
    case .tab(let index):
      if tabs.indices.contains(index) { activate(tabs[index]) }
    case .createNote(let name):
      let ref = NoteStore.shared.createNote(named: name)
      openNote(ref)
      noteView.focusEditor()
    }
  }

  /// Where a capture went: today's journal, or the note.
  private func openCollected(_ ref: NoteRef) {
    if ref == NoteStore.shared.today { showJournal(nil) } else { openNote(ref) }
  }

  private func showCapturePanel(_ capture: Capture, anchorInWindow: NSRect?, from tab: Tab) {
    let root = rootView
    var anchor = NSRect(x: root.bounds.midX - 170, y: Theme.topBarHeight + 8, width: 0, height: 0)
    if let rect = anchorInWindow {
      // Window coordinates are bottom-up; the overlay is flipped.
      anchor = NSRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
    let panel = CapturePanel(capture: capture, anchor: anchor, lastTarget: lastCaptureTarget)
    panel.onDismiss = { [weak self] in
      self?.releasePendingCapture()
      self?.dismissOverlay()
    }
    panel.onCollect = { [weak self, weak tab] ref in
      guard let self else { return }
      self.captureTab = nil
      self.lastCaptureTarget = ref
      self.dismissOverlay()
      let name = ref == NoteStore.shared.today ? "Today" : ref.displayTitle
      // The page just lets go of the target; the toast is the only confirmation.
      tab?.browserView?.executeJavaScript("window.__gleaPNS && __gleaPNS.done()")
      NoteStore.shared.collect(capture, into: ref) {
        self.toast.show("Collected to", linkTitle: name) { [weak self] in self?.openCollected(ref) }
      }
    }
    present(panel)
    captureTab = tab
    panel.activate()
    panel.animateAppear()
  }

  private func closeFindBar() {
    guard let bar = findBar else { return }
    findBar = nil
    bar.animateOut(scale: 0.96, offsetY: 6, fade: 0.12, duration: 0.18) { bar.removeFromSuperview() }
    activeTab?.browserView?.stopFinding()
  }

  // MARK: Option key (point-and-shoot)

  private var pendingPointAndShoot: DispatchWorkItem?

  /// ⌥ alone, or ⌥⌘ (Caps Lock aside).
  private static func isPointAndShoot(_ flags: NSEvent.ModifierFlags) -> Bool {
    flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .command]) == .option
  }

  func modifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
    topBar.dragModifiersChanged(flags)
    // ⌥ with the mouse down is ⌥-dragging (tabs): not point-and-shoot.
    // ⌘ may join it: then posts and videos are collected as text, not embeds.
    let optionOnly = BrowserWindowController.isPointAndShoot(flags) && NSEvent.pressedMouseButtons == 0
    pendingPointAndShoot?.cancel()
    pendingPointAndShoot = nil
    guard mode == .web, let view = activeTab?.browserView else { return }
    guard optionOnly else {
      // Turning it off must always get through.
      view.executeJavaScript("window.__gleaPNS && __gleaPNS.setActive(false)")
      return
    }
    view.executeJavaScript("window.__gleaPNS && __gleaPNS.setTextOnly(\(flags.contains(.command)))")
    // Turning it on needs the page in front, and Option held on its own for a
    // moment: ⌥ on the way to ⌥⌘→ (switch tabs) never starts a capture.
    // The page has keyboard focus in its own window (Chrome style) or in ours.
    let focused = window?.isKeyWindow == true || activeTab?.browserView?.chromeWindow?.isKeyWindow == true
    let testing = ProcessInfo.processInfo.environment["GLEA_TEST_HOOKS"] != nil
    guard (NSApp.isActive && focused) || testing, overlay == nil, !isShowingNewTab else { return }
    let work = DispatchWorkItem { [weak self, weak view] in
      guard let self, let view, self.activeTab?.browserView === view else { return }
      guard BrowserWindowController.isPointAndShoot(NSEvent.modifierFlags)
              || ProcessInfo.processInfo.environment["GLEA_TEST_HOOKS"] != nil else { return }
      // Where the pointer is, in page (CSS) pixels, for pages that haven't seen it move.
      var args = "true"
      if let window = view.window {
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let zoom = pow(1.2, view.zoomLevel)
        if view.bounds.contains(point) {
          args += ", \(Int(point.x / zoom)), \(Int(point.y / zoom))"
        }
      }
      view.executeJavaScript("window.__gleaPNS && __gleaPNS.setActive(\(args))")
    }
    pendingPointAndShoot = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
  }

  // MARK: NoteNavigator

  func openNote(_ ref: NoteRef) {
    setMode(.note(ref))
  }

  func openSearch(_ url: URL) {
    openTab(url.absoluteString)
  }

  func openLink(_ url: URL) {
    if url.scheme == "glea-note" {
      let raw = url.absoluteString.dropFirst("glea-note:".count)
      let name = String(raw).removingPercentEncoding ?? String(raw)
      openNote(NoteStore.shared.resolve(linkName: name) ?? NoteStore.shared.createNote(named: name))
    } else if url.scheme == "http" || url.scheme == "https" {
      openTab(url.absoluteString, background: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    } else {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: TopBarDelegate

  func topBarSelectTab(at index: Int) { if tabs.indices.contains(index) { activate(tabs[index]) } }
  func topBarCloseTab(at index: Int) { if tabs.indices.contains(index) { closeTab(tabs[index]) } }
  func topBarEditActiveTabAddress() { showOmnibox(target: .currentTab) }
  func topBarMenu(forTabAt index: Int) -> NSMenu? { tabs.indices.contains(index) ? tabMenu(for: tabs[index]) : nil }
  func topBarMenu(forGroup id: UUID) -> NSMenu? { group(id).map(groupMenu(for:)) }
  func topBarToggleGroup(_ id: UUID) { if let group = group(id) { toggleCollapsed(group) } }
  func topBarMoveTab(at index: Int, toIndex: Int, pinned: Bool, group: UUID?) {
    if tabs.indices.contains(index) { move(tabs[index], toIndex: toIndex, pinned: pinned, group: group) }
  }
  func topBarMoveGroup(_ id: UUID, toIndex: Int) { if let group = group(id) { move(group, toIndex: toIndex) } }
  func topBarGroupTab(at index: Int, withTabAt target: Int) {
    guard tabs.indices.contains(index), tabs.indices.contains(target) else { return }
    group(tabs[index], with: tabs[target])
  }
  func topBarNewTab() { openNewTab() }
  func topBarToggleMute(at index: Int) { if tabs.indices.contains(index) { tabs[index].setMuted(!tabs[index].isMuted) } }
  func topBarShowJournal() { setMode(.journal) }
  func topBarShowNotes() { setMode(.notes) }
  func topBarGoBack() { goBack(nil) }
  func topBarGoForward() { goForward(nil) }
  func topBarReload() { reload(nil) }
  func topBarSearch() { showOmnibox(target: .newTab) }
  func topBarToggleMode() { toggleJournal(nil) }

  // MARK: Session

  private func restore(tabs savedTabs: [Session.SavedTab], activeIndex: Int?, groups savedGroups: [Session.SavedGroup]?) {
    groups = (savedGroups ?? []).map { TabGroup(id: $0.id, title: $0.title, colorIndex: $0.color, collapsed: $0.collapsed) }
    for saved in savedTabs {
      let tab = Tab(url: saved.url, title: saved.title)
      tab.owner = self
      tab.isPinned = saved.pinned ?? false
      tab.groupID = saved.group
      tabs.append(tab)
    }
    normalizeTabOrder()
    if let index = activeIndex, tabs.indices.contains(index) {
      activeTab = tabs[index]
    } else {
      activeTab = tabs.last
    }
  }

  private static var sessionSaveScheduled = false

  private func scheduleSessionSave() {
    guard !Self.sessionSaveScheduled, !isIncognito else { return }
    Self.sessionSaveScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.saveAll() }
  }

  /// Saves every regular window (incognito ones never are).
  func saveSession() {
    guard !isIncognito else { return }
    Self.saveAll()
  }

  private static func saveAll() {
    sessionSaveScheduled = false
    guard let main = regularWindows.first(where: { !$0.isExtra }) else { return }
    let state = main.savedState()
    // Front to back, as they're restored (the front one last, on top).
    // (Only those still registered: one closing is still on screen.)
    let extras = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
      .filter { $0.isExtra && regularWindows.contains($0) }
    let others = extras + regularWindows.filter { $0.isExtra && !extras.contains($0) }
    Session(tabs: state.tabs, activeIndex: state.activeIndex, groups: state.groups,
            windows: others.map { $0.savedState() }).save()
  }

  private func savedState() -> Session.SavedWindow {
    let index = activeTab.flatMap { tab in tabs.firstIndex { $0 === tab } }
    return Session.SavedWindow(
      tabs: tabs.map { .init(url: $0.url, title: $0.title, pinned: $0.isPinned, group: $0.groupID) }, activeIndex: index,
      groups: groups.map { .init(id: $0.id, title: $0.title, color: $0.colorIndex, collapsed: $0.collapsed) },
      frame: window.map { NSStringFromRect($0.frame) })
  }

  func prepareForQuit() {
    MarkdownEditorView.flushAll()
    discardIfUntouched()
    saveSession()
    HistoryStore.shared.save()
    ActivityLog.shared.save()
  }

  /// The page being read in this window, for the daily summary: none in the
  /// notes, in incognito, or on the start page.
  var pageInFront: (url: String, title: String)? {
    guard mode == .web, !isIncognito, !isShowingNewTab, let tab = activeTab, tab.url.hasPrefix("http") else { return nil }
    return (tab.url, tab.title)
  }

  func dayMayHaveChanged() {
    if mode == .journal { journalView.reloadIfNeeded() }
  }

  // MARK: Menu actions

  @objc func newTab(_ sender: Any?) { openNewTab() }

  @objc func openLocation(_ sender: Any?) {
    showOmnibox(target: mode == .web && activeTab != nil ? .currentTab : .newTab)
  }

  @objc func closeCurrentTab(_ sender: Any?) {
    if overlay != nil {
      dismissOverlay()
    } else if mode == .web, isShowingNewTab, !tabs.isEmpty {
      leaveNewTab()
    } else if mode == .web, let tab = activeTab {
      closeTab(tab)
    } else if mode == .web, tabs.isEmpty, !isIncognito {
      // The empty page: as when the last tab closes, back to the notes in
      // the last window (the next ⌘W closes it); any other window closes.
      if isLastWindow { setMode(lastNoteMode) } else { window?.performClose(nil) }
    } else if tabs.isEmpty {
      // Nothing left to close: the window (Glea keeps running).
      window?.performClose(nil)
    } else if case .note = mode {
      setMode(.journal)
    }
  }

  /// Leaving a new note never written in: it isn't kept (unless another
  /// window shows it).
  private func discardIfUntouched() {
    // (A title still being typed counts: applied first.)
    guard case .note = mode, let ref = noteView.commitEdits(), NoteStore.shared.isUntouched(ref) else { return }
    let shownElsewhere = NSApp.windows.contains { window in
      guard let other = window.windowController as? BrowserWindowController, other !== self, window.isVisible else { return false }
      return other.mode == .note(ref)
    }
    if !shownElsewhere { NoteStore.shared.discard(ref) }
  }

  /// No other Glea window is open.
  private var isLastWindow: Bool {
    !NSApp.windows.contains { window in
      guard let owner = window.windowController as? BrowserWindowController else { return false }
      return owner !== self && window.isVisible
    }
  }

  /// ⌥⌘W: closes every tab but the pinned ones, back to the notes (the
  /// start page in incognito).
  @objc func closeAllTabs(_ sender: Any?) {
    let closing = tabs.filter { !$0.isPinned }
    guard !closing.isEmpty else { return }
    dismissOverlay(restoreFocus: false)
    closeFindBar()
    let reopenable = closing.filter { $0.url.hasPrefix("http") }
    if !reopenable.isEmpty {
      closedTabs.append(ClosedTabs(urls: reopenable.map(\.url), active: reopenable.firstIndex { $0 === activeTab } ?? 0))
    }
    tabs.removeAll { !$0.isPinned }
    if let active = activeTab, !active.isPinned { activeTab = tabs.first }
    normalizeTabOrder()
    setMode(isIncognito ? .web : lastNoteMode)
    for tab in closing { tab.close() }
    refreshTopBar()
    scheduleSessionSave()
  }

  @objc func reopenClosedTab(_ sender: Any?) {
    guard let closed = closedTabs.popLast() else { return }
    // In order (each opens after the one before), then back to the active one.
    let reopened = closed.urls.map { openTab($0) }
    if reopened.indices.contains(closed.active) { activate(reopened[closed.active]) }
  }

  /// ⌘D: flip between the journal/notes and the web.
  @objc func toggleJournal(_ sender: Any?) {
    if mode == .web {
      setMode(lastNoteMode)
    } else if let tab = activeTab ?? tabs.last {
      activate(tab)
    } else {
      // No tabs: the start page and its omnibox.
      setMode(.web)
    }
  }

  @objc func showJournal(_ sender: Any?) {
    setMode(.journal)
    if !restoredNotesFocus { journalView.focusToday() }
  }

  @objc func showAllNotes(_ sender: Any?) {
    setMode(.notes)
    notesView.focusSearch()
  }

  @objc func newNote(_ sender: Any?) {
    let ref = NoteStore.shared.createNote(named: NoteStore.shared.uniqueUntitledName())
    openNote(ref)
    noteView.focusTitle()
  }

  @objc func deleteNote(_ sender: Any?) {
    guard case .note(let ref) = mode else { return }
    confirmDelete(ref)
  }

  /// Moves `ref` to the Trash once confirmed (its note, if open, goes back
  /// to All Notes).
  func confirmDelete(_ ref: NoteRef) { confirmDelete([ref]) }

  /// Moves `refs` to the Trash once confirmed (the note shown, if among them,
  /// goes back to All Notes, or a journal day to the journal).
  func confirmDelete(_ refs: [NoteRef]) {
    guard let window, let first = refs.first else { return }
    let alert = NSAlert()
    if refs.count == 1 {
      alert.messageText = "Move “\(first.displayTitle)” to the Trash?"
      alert.informativeText = first.kind == .note ? "Links to it from other notes will stop working."
        : "Its entry leaves the journal."
    } else {
      alert.messageText = "Move \(refs.count) notes to the Trash?"
      alert.informativeText = "Links to them from other notes will stop working."
    }
    // Destructive: drawn red.
    alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn else { return }
      self.trash(refs)
      if case .note(let shown) = self.mode, refs.contains(shown) { self.setMode(shown.kind == .note ? .notes : .journal) }
    }
  }

  /// Moves `refs` to the Trash as one undoable step: Undo puts them back,
  /// Redo trashes them again.
  private func trash(_ refs: [NoteRef]) {
    let trashed = refs.compactMap { ref in NoteStore.shared.delete(ref).map { (ref: ref, url: $0) } }
    guard !trashed.isEmpty, let undo = window?.undoManager else { return }
    undo.registerUndo(withTarget: self) { controller in
      let restored = trashed.filter { NoteStore.shared.restore($0.ref, from: $0.url) }.map(\.ref)
      undo.registerUndo(withTarget: controller) { $0.trash(restored) }
    }
    undo.setActionName(trashed.count == 1 ? "Move to Trash" : "Move \(trashed.count) Notes to Trash")
  }

  @objc func collectPage(_ sender: Any?) {
    guard mode == .web, let tab = activeTab, tab.url.hasPrefix("http") else { return }
    let capture = Capture(kind: .page, markdown: "", text: "", pageURL: tab.url, pageTitle: tab.title)
    showCapturePanel(capture, anchorInWindow: nil, from: tab)
  }

  @objc func reload(_ sender: Any?) {
    guard mode == .web, let tab = activeTab else { return }
    if tab.errorMessage != nil {
      tab.load(tab.url)
    } else {
      tab.browserView?.reload()
    }
  }

  @objc func stopLoading(_ sender: Any?) { activeTab?.browserView?.stopLoading() }
  @objc func goBack(_ sender: Any?) {
    if mode == .web { activeTab?.browserView?.goBack() } else { goBackInNotes() }
  }

  @objc func goForward(_ sender: Any?) {
    if mode == .web { activeTab?.browserView?.goForward() } else { goForwardInNotes() }
  }
  @objc func zoomInPage(_ sender: Any?) { activeTab?.browserView?.zoomIn() }
  @objc func zoomOutPage(_ sender: Any?) { activeTab?.browserView?.zoomOut() }
  @objc func actualSizePage(_ sender: Any?) { activeTab?.browserView?.resetZoom() }
  @objc func showDeveloperTools(_ sender: Any?) { activeTab?.devTools?.toggle() }

  @objc func dockDeveloperTools(_ sender: NSMenuItem) {
    guard let dock = GleaDevToolsDock(rawValue: sender.tag) else { return }
    if let devTools = activeTab?.devTools, mode == .web {
      devTools.show(dock)
    } else {
      GleaBrowserView.preferredDevToolsDock = dock
    }
  }

  @objc func findInPage(_ sender: Any?) {
    guard mode == .web else { return }
    if let bar = findBar {
      window?.makeFirstResponder(bar.field)
      return
    }
    let bar = FindBar()
    bar.onSearch = { [weak self] text, forward, next in
      if text.isEmpty {
        self?.activeTab?.browserView?.stopFinding()
      } else {
        self?.activeTab?.browserView?.findText(text, forward: forward, findNext: next)
      }
    }
    bar.onClose = { [weak self] in
      self?.closeFindBar()
      self?.activeTab?.browserView?.focusPage()
    }
    bar.translatesAutoresizingMaskIntoConstraints = false
    overlayRoot.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: overlayRoot.topAnchor, constant: Theme.topBarHeight + 10),
      bar.trailingAnchor.constraint(equalTo: overlayRoot.trailingAnchor, constant: -14),
    ])
    findBar = bar
    raiseOverlayWindow()
    overlayWindow.ignoresMouseEvents = false
    overlayWindow.makeKey()
    overlayWindow.makeFirstResponder(bar.field)
    // Drop in from just above.
    bar.animateIn(scale: 0.96, offsetY: 8, fade: 0.1, duration: 0.4, timing: Motion.easeOut)
  }

  @objc func findNextInPage(_ sender: Any?) { findBar?.next() }
  @objc func findPreviousInPage(_ sender: Any?) { findBar?.previous() }

  // Not NSWindow's selectNextTab:, which would catch the action first.
  @objc func showNextTab(_ sender: Any?) { cycleTab(by: 1) }
  @objc func showPreviousTab(_ sender: Any?) { cycleTab(by: -1) }

  private func cycleTab(by delta: Int) {
    // In the notes, the "tabs" are Journal and All Notes (a note counts as
    // being in All Notes).
    if mode != .web {
      let onJournal = mode == .journal
      if case .note = mode {
        setMode(delta > 0 ? .notes : .journal)
      } else {
        setMode(onJournal ? .notes : .journal)
      }
      return
    }
    guard !tabs.isEmpty else { return }
    let current = activeTab.flatMap { tab in tabs.firstIndex { $0 === tab } } ?? 0
    activate(tabs[(current + delta + tabs.count) % tabs.count])
  }

  @objc func selectTabByNumber(_ sender: NSMenuItem) {
    guard !tabs.isEmpty else { return }
    let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
    if tabs.indices.contains(index) { activate(tabs[index]) }
  }

  @objc func exportAllNotes(_ sender: Any?) {
    guard let window else { return }
    MarkdownEditorView.flushAll()
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Export"
    panel.message = "Choose where to export your notes and journal as Markdown files."
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        let folder = try NoteStore.shared.exportAll(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
      } catch {
        NSAlert(error: error).beginSheetModal(for: window)
      }
    }
  }

  @objc func exportCurrentNote(_ sender: Any?) {
    guard case .note(let ref) = mode else { return }
    export(ref)
  }

  /// Saves `ref` as a Markdown file where the user picks.
  func export(_ ref: NoteRef) {
    guard let window else { return }
    MarkdownEditorView.flushAll()
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (ref.kind == .journal ? ref.name : ref.name) + ".md"
    panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try NoteStore.shared.export(ref, to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } catch {
        NSAlert(error: error).beginSheetModal(for: window)
      }
    }
  }

  @objc func revealDataFolder(_ sender: Any?) {
    NSWorkspace.shared.activateFileViewerSelecting([NoteStore.shared.root])
  }

  @objc func changeDataFolder(_ sender: Any?) {
    guard let window else { return }
    MarkdownEditorView.flushAll()
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use Folder"
    panel.message = "Choose the folder where Glea keeps its Markdown notes and journal."
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let url = panel.url else { return }
      NoteStore.shared.changeRoot(to: url)
      self.journalView.reload()
      self.setMode(.journal)
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let web = mode == .web && activeTab != nil && !isShowingNewTab
    switch item.action {
    case #selector(showDeveloperTools(_:)):
      item.title = activeTab?.devTools?.isOpen == true ? "Hide Developer Tools" : "Show Developer Tools"
      return web
    case #selector(reload(_:)), #selector(stopLoading(_:)), #selector(zoomInPage(_:)), #selector(zoomOutPage(_:)),
         #selector(actualSizePage(_:)), #selector(findInPage(_:)):
      return web
    case #selector(dockDeveloperTools(_:)):
      item.state = GleaBrowserView.preferredDevToolsDock.rawValue == item.tag ? .on : .off
      return true
    case #selector(collectPage(_:)):
      return web && activeTab?.url.hasPrefix("http") == true
    case #selector(findNextInPage(_:)), #selector(findPreviousInPage(_:)):
      return web && findBar != nil
    case #selector(goBack(_:)):
      return mode == .web ? web && activeTab?.canGoBack == true : canGoBackInNotes
    case #selector(goForward(_:)):
      return mode == .web ? web && activeTab?.canGoForward == true : canGoForwardInNotes
    case #selector(reopenClosedTab(_:)):
      return !closedTabs.isEmpty
    case #selector(closeAllTabs(_:)):
      return tabs.contains { !$0.isPinned }
    case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
      return mode != .web || !tabs.isEmpty
    case #selector(selectTabByNumber(_:)):
      return !tabs.isEmpty
    case #selector(deleteNote(_:)):
      if case .note = mode { return true }
      return false
    case #selector(exportCurrentNote(_:)):
      if case .note = mode { return true }
      return false
    case #selector(toggleJournal(_:)):
      item.title = mode == .web ? "Show Journal & Notes" : "Show Web"
      return true
    default:
      return true
    }
  }
}
