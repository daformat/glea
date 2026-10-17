// The settings window, from Subtitles (app/macos/Settings.swift there): a
// header of panes drawn by hand (symbol over label, grey until selected), and
// under it the selected pane's sections, each a title, a line on what it does
// and its controls. Every control applies as it changes and is saved as it
// goes: there's no OK button. What can also be changed from a menu (vertical
// tabs, the search engine) is read again when the window comes back to the
// front.

import AppKit

/// Glea's own settings. Test copies keep theirs apart, not to change the
/// real app's.
@MainActor
enum AppDefaults {
  static let store = ProcessInfo.processInfo.environment["GLEA_TEST_HOOKS"] == "1"
    ? UserDefaults(suiteName: "app.glea.test-copy") ?? .standard : .standard
}

/// How web links in the notes (and the journal) behave here: previewed in a
/// peek when clicked, and in a card while the pointer rests on them. Both on
/// unless turned off.
@MainActor
enum NoteLinks {
  static var peek: Bool {
    get { AppDefaults.store.object(forKey: "notesLinkPeek") as? Bool ?? true }
    set { AppDefaults.store.set(newValue, forKey: "notesLinkPeek") }
  }

  static var previews: Bool {
    get { AppDefaults.store.object(forKey: "notesLinkPreviews") as? Bool ?? true }
    set { AppDefaults.store.set(newValue, forKey: "notesLinkPreviews") }
  }
}

/// Where links clicked in the notes (and the journal) open: in a tab here, or
/// in another browser. Glea opens web links itself, so it can be the system's
/// default browser: the browser is picked among the others.
@MainActor
enum LinkOpening {
  struct Browser {
    let id: String
    let name: String
    let url: URL
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
  }

  /// Open links in another browser rather than in a tab here.
  static var opensElsewhere: Bool {
    get { AppDefaults.store.bool(forKey: "linksInOtherBrowser") }
    set { AppDefaults.store.set(newValue, forKey: "linksInOtherBrowser") }
  }

  /// The browser chosen, by bundle identifier (nil: the system's default).
  static var browserID: String? {
    get { AppDefaults.store.string(forKey: "linksBrowser") }
    set { AppDefaults.store.set(newValue, forKey: "linksBrowser") }
  }

  /// The installed browsers other than Glea: the system's default first,
  /// then by name.
  static func browsers() -> [Browser] {
    guard let probe = URL(string: "https://glea.app") else { return [] }
    let own = Bundle.main.bundleIdentifier
    let fallback = NSWorkspace.shared.urlForApplication(toOpen: probe)
    var seen = Set<String>()
    let all = NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url -> Browser? in
      guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
      let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
      return Browser(id: id, name: name, url: url)
    }
    let defaultID = fallback.flatMap { Bundle(url: $0)?.bundleIdentifier }
    return all.sorted { a, b in
      if (a.id == defaultID) != (b.id == defaultID) { return a.id == defaultID }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
  }

  /// The browser links go to: the one chosen if it's still installed, else
  /// the first of `browsers()`.
  static func browser() -> Browser? {
    let all = browsers()
    return all.first { $0.id == browserID } ?? all.first
  }

  /// Opens `url` in the other browser when that's the setting; false to open
  /// it here. `background`: it opens behind (⌘-click).
  static func openElsewhere(_ url: URL, background: Bool) -> Bool {
    guard opensElsewhere, let browser = browser() else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = !background
    NSWorkspace.shared.open([url], withApplicationAt: browser.url, configuration: configuration)
    return true
  }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
  static let shared = SettingsWindow()

  private static let width: CGFloat = 430
  private static let inset: CGFloat = 22
  /// The width everything inside a pane is laid out against.
  private static var contentWidth: CGFloat { width - inset * 2 }

  /// The panes, in header order.
  private static let panes: [(label: String, symbol: String)] = [
    ("Browser", "globe"),
    ("Notes", "doc.text"),
  ]

  private var window: NSWindow?
  private var body: NSView?
  private var bodyHeight: NSLayoutConstraint?
  private var stacks: [NSStackView] = []
  private var buttons: [PaneButton] = []
  private var selected = 0

  /// Held: a switch's target is weak.
  private var verticalTabsRow: ToggleRow?
  private var linksRow: ToggleRow?
  private var peekRow: ToggleRow?
  private var previewsRow: ToggleRow?
  private let enginePopup = NSPopUpButton()
  private let browserPopup = NSPopUpButton()
  /// The browsers listed in `browserPopup`, in its order.
  private var browsers: [LinkOpening.Browser] = []
  private var tabLayoutObserver: NSObjectProtocol?

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }
    let window = build()
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(nil)
  }

  /// For automated checks: the window, on pane `index`.
  func showForTesting(pane index: Int) {
    show()
    show(pane: index)
  }

  /// Torn down rather than hidden: the next open reads the settings as they
  /// stand.
  func windowWillClose(_ notification: Notification) {
    window = nil
    body = nil
    bodyHeight = nil
    stacks = []
    buttons = []
    verticalTabsRow = nil
    linksRow = nil
    peekRow = nil
    previewsRow = nil
    browsers = []
    if let tabLayoutObserver { NotificationCenter.default.removeObserver(tabLayoutObserver) }
    tabLayoutObserver = nil
  }

  /// The menus can change some of these while the window is open, and a
  /// browser may have been installed or removed meanwhile.
  func windowDidBecomeKey(_ notification: Notification) {
    verticalTabsRow?.isOn = TabLayout.isVertical
    enginePopup.selectItem(at: SearchEngine.allCases.firstIndex(of: SearchEngine.current) ?? 0)
    reloadBrowsers()
  }

  // MARK: Building

  private func build() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
    window.title = "Settings"
    // One color from the traffic lights to the bottom edge.
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.delegate = self
    self.window = window
    tabLayoutObserver = NotificationCenter.default.addObserver(forName: TabLayout.didChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.verticalTabsRow?.isOn = TabLayout.isVertical }
    }

    stacks = [buildBrowserStack(), buildNotesStack()]
    buttons = Self.panes.enumerated().map { index, pane in
      PaneButton(label: pane.label, symbol: pane.symbol) { [weak self] in self?.show(pane: index) }
    }
    let header = NSStackView(views: buttons)
    header.orientation = .horizontal
    header.spacing = 2
    // Centered under the title, on the window's own background.
    let headerBar = NSView()
    headerBar.addSubview(header)
    header.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      header.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
      header.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 6),
      header.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -10),
    ])
    let divider = NSBox()
    divider.boxType = .separator

    // The selected pane goes in here, so the header and its rule stay put.
    let body = NSView()
    body.translatesAutoresizingMaskIntoConstraints = false
    let height = body.heightAnchor.constraint(equalToConstant: 0)
    bodyHeight = height
    height.isActive = true
    self.body = body

    let root = NSStackView(views: [headerBar, divider, body])
    root.orientation = .vertical
    root.spacing = 0
    root.alignment = .centerX
    NSLayoutConstraint.activate([
      headerBar.widthAnchor.constraint(equalTo: root.widthAnchor),
      divider.widthAnchor.constraint(equalTo: root.widthAnchor),
      body.widthAnchor.constraint(equalToConstant: Self.width),
    ])
    window.contentView = root
    show(pane: selected)
    return window
  }

  /// Swaps in one pane and fits the window to it, keeping its top edge.
  private func show(pane index: Int) {
    guard stacks.indices.contains(index), let window, let body, let bodyHeight else { return }
    selected = index
    for (i, button) in buttons.enumerated() { button.isSelected = i == index }
    body.subviews.forEach { $0.removeFromSuperview() }
    let stack = stacks[index]
    body.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: body.topAnchor),
      stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
    ])
    bodyHeight.constant = stack.fittingSize.height
    let content = NSRect(x: 0, y: 0, width: Self.width, height: window.contentView?.fittingSize.height ?? 0)
    var frame = window.frameRect(forContentRect: content)
    frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
    window.setFrame(frame, display: true, animate: window.isVisible && frame != window.frame)
  }

  /// An empty pane, and the `section` that fills it: a title (with a switch
  /// beside it, maybe), what it does, then its controls.
  private static func makeStack() -> (NSStackView, (String, String, NSView?) -> Void) {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
    stack.translatesAutoresizingMaskIntoConstraints = false
    func section(_ title: String, _ detail: String, _ content: NSView?) {
      if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
      stack.addArrangedSubview(header(title))
      stack.addArrangedSubview(caption(detail))
      if let content { stack.addArrangedSubview(content) }
    }
    return (stack, section)
  }

  private func buildBrowserStack() -> NSStackView {
    let (stack, section) = Self.makeStack()

    let vertical = ToggleRow("Vertical tabs", detail: "A sidebar down the window's left while you browse.",
                             value: TabLayout.isVertical, width: Self.contentWidth) { TabLayout.isVertical = $0 }
    verticalTabsRow = vertical
    section("Tabs", "Where your tabs go: along the top bar, or down a sidebar with the page beside it. The notes keep the top bar.",
            vertical.view)

    enginePopup.removeAllItems()
    enginePopup.addItems(withTitles: SearchEngine.allCases.map(\.name))
    enginePopup.selectItem(at: SearchEngine.allCases.firstIndex(of: SearchEngine.current) ?? 0)
    enginePopup.target = self
    enginePopup.action = #selector(chooseEngine)
    section("Search", "What the address field searches when you type something that isn't an address.",
            Self.labeled("Search engine", enginePopup))
    return stack
  }

  private func buildNotesStack() -> NSStackView {
    let (stack, section) = Self.makeStack()

    let peek = ToggleRow("Preview links in a peek",
                         detail: "A click opens the page over your notes, without a tab. ⌘‑click still opens a tab.",
                         value: NoteLinks.peek, width: Self.contentWidth) { NoteLinks.peek = $0 }
    peek.control.isEnabled = !LinkOpening.opensElsewhere
    peekRow = peek
    let previews = ToggleRow("Show link previews",
                             detail: "Resting the pointer on a link shows its page's picture, title and description.",
                             value: NoteLinks.previews, width: Self.contentWidth) { on in
      NoteLinks.previews = on
      if !on { LinkPreviewController.shared.hide() }
    }
    previewsRow = previews
    let webLinks = NSStackView(views: [peek.view, previews.view])
    webLinks.orientation = .vertical
    webLinks.alignment = .leading
    webLinks.spacing = 10
    section("Web links", "What clicking or pointing at a web link in your notes and journal does.", webLinks)

    let links = ToggleRow("Open links in another browser",
                          detail: "Links you click in your notes and journal open there, not in a tab here.",
                          value: LinkOpening.opensElsewhere, width: Self.contentWidth) { [weak self] on in
      LinkOpening.opensElsewhere = on
      self?.browserPopup.isEnabled = on && self?.browsers.isEmpty == false
      // Opened elsewhere, a link can't be peeked at here.
      self?.peekRow?.control.isEnabled = !on
    }
    linksRow = links
    browserPopup.target = self
    browserPopup.action = #selector(chooseBrowser)
    reloadBrowsers()
    let content = NSStackView(views: [links.view, Self.labeled("Browser", browserPopup)])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 10
    section("Another browser", "Your notes' links can open in the browser you use otherwise, rather than here.", content)
    return stack
  }

  /// Lists the installed browsers, the chosen one selected.
  private func reloadBrowsers() {
    browsers = LinkOpening.browsers()
    browserPopup.removeAllItems()
    for (index, browser) in browsers.enumerated() {
      browserPopup.addItem(withTitle: index == 0 ? "\(browser.name) (Default)" : browser.name)
      let icon = browser.icon
      icon.size = NSSize(width: 16, height: 16)
      browserPopup.lastItem?.image = icon
    }
    if browsers.isEmpty { browserPopup.addItem(withTitle: "No other browser") }
    let chosen = LinkOpening.browser()
    browserPopup.selectItem(at: browsers.firstIndex { $0.id == chosen?.id } ?? 0)
    browserPopup.isEnabled = LinkOpening.opensElsewhere && !browsers.isEmpty
  }

  @objc private func chooseEngine(_ sender: NSPopUpButton) {
    SearchEngine.current = SearchEngine.allCases[max(0, sender.indexOfSelectedItem)]
  }

  @objc private func chooseBrowser(_ sender: NSPopUpButton) {
    guard browsers.indices.contains(sender.indexOfSelectedItem) else { return }
    LinkOpening.browserID = browsers[sender.indexOfSelectedItem].id
  }

  // MARK: Rows

  /// A control after its label, across the pane.
  private static func labeled(_ title: String, _ control: NSView) -> NSView {
    let label = NSTextField(labelWithString: title)
    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let row = NSStackView(views: [label, spacer, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    return row
  }

  private static func header(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    return label
  }

  private static func caption(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    // Pinned to the pane's width: a leading-aligned stack would let it run
    // through the trailing inset.
    label.preferredMaxLayoutWidth = contentWidth
    label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    return label
  }

  /// A title, a line under it, and a switch at the pane's right edge.
  private final class ToggleRow: NSObject {
    let view: NSStackView
    let control = NSSwitch()
    private let apply: (Bool) -> Void

    init(_ title: String, detail: String, value: Bool, width: CGFloat, apply: @escaping (Bool) -> Void) {
      self.apply = apply
      let label = NSTextField(labelWithString: title)
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let sub = NSTextField(wrappingLabelWithString: detail)
      sub.preferredMaxLayoutWidth = width - 60
      sub.font = .systemFont(ofSize: 11)
      sub.textColor = .secondaryLabelColor
      let text = NSStackView(views: [label, sub])
      text.orientation = .vertical
      text.alignment = .leading
      text.spacing = 1
      // Takes the slack: the switch sits at the margin.
      let spacer = NSView()
      spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
      view = NSStackView(views: [text, spacer, control])
      view.orientation = .horizontal
      view.alignment = .centerY
      view.spacing = 8
      view.widthAnchor.constraint(equalToConstant: width).isActive = true
      super.init()
      control.state = value ? .on : .off
      control.target = self
      control.action = #selector(changed)
    }

    @objc private func changed(_ sender: NSSwitch) { apply(sender.state == .on) }

    var isOn: Bool {
      get { control.state == .on }
      set { control.state = newValue ? .on : .off }
    }
  }

  /// One pane in the header: symbol over label, grey until selected, then
  /// full contrast on a wash.
  private final class PaneButton: NSView {
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let onClick: () -> Void

    var isSelected = false {
      didSet {
        guard isSelected != oldValue else { return }
        restyle()
        needsDisplay = true
      }
    }

    init(label: String, symbol: String, onClick: @escaping () -> Void) {
      self.onClick = onClick
      super.init(frame: .zero)
      icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
        .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
      icon.imageScaling = .scaleNone
      caption.stringValue = label
      caption.font = .systemFont(ofSize: 11)
      caption.alignment = .center
      let stack = NSStackView(views: [icon, caption])
      stack.orientation = .vertical
      stack.spacing = 3
      stack.translatesAutoresizingMaskIntoConstraints = false
      addSubview(stack)
      NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
        stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
      ])
      restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
      let tint: NSColor = isSelected ? .labelColor : .secondaryLabelColor
      icon.contentTintColor = tint
      caption.textColor = tint
    }

    override func draw(_ dirtyRect: NSRect) {
      guard isSelected else { return }
      NSColor.quaternaryLabelColor.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick() }
  }
}
