import AppKit
import GleaBridge

@objc(GleaAppDelegate)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: BrowserWindowController!
  private var incognitoControllers: [BrowserWindowController] = []
  /// Regular windows besides the main one (⌘N on the web).
  private var extraControllers: [BrowserWindowController] = []
  private var pendingURLs: [URL] = []

  /// The window in front: the main one, an extra or an incognito one.
  /// (Pages and overlays are child windows of theirs.)
  private var frontController: BrowserWindowController? {
    var window = NSApp.keyWindow ?? NSApp.mainWindow
    while let current = window {
      if let owner = current.windowController as? BrowserWindowController { return owner }
      window = current.parent
    }
    return controller
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = buildMenu()
    controller = BrowserWindowController()
    controller.showWindow(nil)
    // The other windows of last time, the front one last (on top).
    for saved in (Session.load()?.windows ?? []).reversed() { openExtraWindow(restoring: saved) }
    NSApp.activate(ignoringOtherApps: true)

    GleaCEF.willQuitHandler = { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        for controller in [self.controller] + self.extraControllers + self.incognitoControllers { controller?.prepareForQuit() }
      }
    }
    NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      guard let self else { return event }
      for controller in [self.controller] + self.extraControllers + self.incognitoControllers {
        controller?.modifierFlagsChanged(event.modifierFlags)
      }
      return event
    }
    // Pages are Chromium windows, which claim ⌘-shortcuts for Chrome's own
    // commands before the page (or Glea's menu) sees them: give Glea's
    // menu the first pick there.
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.contains(.command), let window = event.window,
            GleaBrowserWindow.host(of: window) != nil else { return event }
      return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? nil : event
    }
    GleaCEF.chromeWindowHandler = { [weak self] url in
      MainActor.assumeIsolated { self?.controller.chromeOpenedWindow(showing: url) }
    }
    TestHooks.install(controller: controller)
    for url in pendingURLs { controller.openTab(url.absoluteString) }
    pendingURLs = []

    // Testing hook: open a URL at launch without touching the saved session.
    if let url = ProcessInfo.processInfo.environment["GLEA_OPEN_URL"] { controller.openTab(url) }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let controller else {
      pendingURLs += urls
      return
    }
    reopenMain()
    for url in urls { controller.openTab(url.absoluteString) }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    controller?.dayMayHaveChanged()
  }

  /// ⌘W on the main window without tabs only closes it: Glea keeps running.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// The Dock icon brings the main window back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { reopenMain() }
    return true
  }

  // MARK: Menu

  private func buildMenu() -> NSMenu {
    let main = NSMenu()

    let app = submenu(main, "Glea")
    app.addItem(withTitle: "About Glea", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    let engines = NSMenu(title: "Search Engine")
    for (index, engine) in SearchEngine.allCases.enumerated() {
      let item = NSMenuItem(title: engine.name, action: #selector(setSearchEngine(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
      engines.addItem(item)
    }
    let enginesItem = NSMenuItem(title: "Search Engine", action: nil, keyEquivalent: "")
    enginesItem.submenu = engines
    app.addItem(enginesItem)
    app.addItem(withTitle: "Change Notes Folder…", action: #selector(BrowserWindowController.changeDataFolder(_:)), keyEquivalent: "")
    app.addItem(.separator())
    let services = NSMenu(title: "Services")
    NSApp.servicesMenu = services
    app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Glea", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
      .keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit Glea", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let file = submenu(main, "File")
    // Targeted at the app delegate so they work from any window or field.
    let newTabItem = file.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
    newTabItem.target = self
    let searchItem = file.addItem(withTitle: "Search…", action: #selector(openOmnibox(_:)), keyEquivalent: "k")
    searchItem.target = self
    file.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n").target = self
    item(file, "New Incognito Window", #selector(newIncognitoWindow(_:)), "n", [.command, .shift]).target = self
    file.addItem(withTitle: "Open Location…", action: #selector(BrowserWindowController.openLocation(_:)), keyEquivalent: "l")
    item(file, "New Note", #selector(BrowserWindowController.newNote(_:)), "n", [.command, .option])
    file.addItem(.separator())
    file.addItem(withTitle: "Collect Page…", action: #selector(BrowserWindowController.collectPage(_:)), keyEquivalent: "s")
    file.addItem(.separator())
    file.addItem(withTitle: "Close Tab", action: #selector(BrowserWindowController.closeCurrentTab(_:)), keyEquivalent: "w")
    item(file, "Close All Tabs", #selector(BrowserWindowController.closeAllTabs(_:)), "w", [.command, .option])
    item(file, "Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift])
    // ⌥⌘⌫, not ⌘⌫: that one deletes to the start of the line while editing.
    item(file, "Move Note to Trash", #selector(BrowserWindowController.deleteNote(_:)), "\u{8}", [.command, .option])
    file.addItem(.separator())
    file.addItem(withTitle: "Export Note as Markdown…", action: #selector(BrowserWindowController.exportCurrentNote(_:)), keyEquivalent: "")
    file.addItem(withTitle: "Export All Notes as Markdown…", action: #selector(BrowserWindowController.exportAllNotes(_:)), keyEquivalent: "")
    file.addItem(withTitle: "Show Notes Folder in Finder", action: #selector(BrowserWindowController.revealDataFolder(_:)), keyEquivalent: "")

    let edit = submenu(main, "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    item(edit, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Find in Page…", action: #selector(BrowserWindowController.findInPage(_:)), keyEquivalent: "f")
    edit.addItem(withTitle: "Find Next", action: #selector(BrowserWindowController.findNextInPage(_:)), keyEquivalent: "g")
    item(edit, "Find Previous", #selector(BrowserWindowController.findPreviousInPage(_:)), "g", [.command, .shift])

    let format = submenu(main, "Format")
    item(format, "Bold", #selector(MarkdownTextView.formatBold(_:)), "b", [.command])
    item(format, "Italic", #selector(MarkdownTextView.formatItalic(_:)), "i", [.command])
    item(format, "Strikethrough", #selector(MarkdownTextView.formatStrikethrough(_:)), "x", [.command, .shift])
    item(format, "Code", #selector(MarkdownTextView.formatCode(_:)), "e", [.command])
    item(format, "Link", #selector(MarkdownTextView.formatLink(_:)), "k", [.command, .shift])
    format.addItem(.separator())
    item(format, "Heading 1", #selector(MarkdownTextView.formatHeading1(_:)), "1", [.command, .option])
    item(format, "Heading 2", #selector(MarkdownTextView.formatHeading2(_:)), "2", [.command, .option])
    item(format, "Heading 3", #selector(MarkdownTextView.formatHeading3(_:)), "3", [.command, .option])
    item(format, "Quote", #selector(MarkdownTextView.formatQuote(_:)), ".", [.command, .shift])
    item(format, "Bulleted List", #selector(MarkdownTextView.formatBulletList(_:)), "8", [.command, .shift])
    item(format, "Task List", #selector(MarkdownTextView.formatTaskList(_:)), "9", [.command, .shift])
    format.addItem(.separator())
    item(format, "Insert Table", #selector(MarkdownTextView.formatInsertTable(_:)), "t", [.command, .option])

    let view = submenu(main, "View")
    view.addItem(withTitle: "Show Web", action: #selector(BrowserWindowController.toggleJournal(_:)), keyEquivalent: "d")
    item(view, "Journal", #selector(BrowserWindowController.showJournal(_:)), "j", [.command, .shift])
    item(view, "All Notes", #selector(BrowserWindowController.showAllNotes(_:)), "n", [.command, .option, .shift])
    view.addItem(.separator())
    view.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reload(_:)), keyEquivalent: "r")
    view.addItem(withTitle: "Stop", action: #selector(BrowserWindowController.stopLoading(_:)), keyEquivalent: ".")
    view.addItem(.separator())
    view.addItem(withTitle: "Zoom In", action: #selector(BrowserWindowController.zoomInPage(_:)), keyEquivalent: "=")
    view.addItem(withTitle: "Zoom Out", action: #selector(BrowserWindowController.zoomOutPage(_:)), keyEquivalent: "-")
    view.addItem(withTitle: "Actual Size", action: #selector(BrowserWindowController.actualSizePage(_:)), keyEquivalent: "0")
    view.addItem(.separator())
    let devTools = NSMenu(title: "Developer Tools")
    item(devTools, "Show Developer Tools", #selector(BrowserWindowController.showDeveloperTools(_:)), "i", [.command, .option])
    devTools.addItem(.separator())
    for (title, dock) in [("Dock to Right", GleaDevToolsDock.right), ("Dock to Bottom", .bottom), ("Dock to Left", .left), ("Open in Separate Window", .window)] {
      let dockItem = devTools.addItem(withTitle: title, action: #selector(BrowserWindowController.dockDeveloperTools(_:)), keyEquivalent: "")
      dockItem.tag = dock.rawValue
    }
    view.addItem(withTitle: "Developer Tools", action: nil, keyEquivalent: "").submenu = devTools
    item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

    let history = submenu(main, "History")
    history.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
    history.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")

    let window = submenu(main, "Window")
    window.addItem(withTitle: "Extensions", action: #selector(BrowserWindowController.showExtensionsPage(_:)), keyEquivalent: "")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    window.addItem(.separator())
    item(window, "Next Tab", #selector(BrowserWindowController.showNextTab(_:)), "]", [.command, .shift])
    item(window, "Previous Tab", #selector(BrowserWindowController.showPreviousTab(_:)), "[", [.command, .shift])
    item(window, "Next Tab", #selector(BrowserWindowController.showNextTab(_:)), "\t", [.control]).isAlternate = false
    // ⌥⌘→ / ⌥⌘← like Chrome and Safari: working shortcuts, not listed twice.
    for (key, action) in [(NSRightArrowFunctionKey, #selector(BrowserWindowController.showNextTab(_:))),
                          (NSLeftArrowFunctionKey, #selector(BrowserWindowController.showPreviousTab(_:)))] {
      let arrow = item(window, "", action, String(Character(UnicodeScalar(key)!)), [.command, .option])
      arrow.isHidden = true
      arrow.allowsKeyEquivalentWhenHidden = true
    }
    for n in 1...9 {
      let tabItem = NSMenuItem(title: n == 9 ? "Last Tab" : "Tab \(n)", action: #selector(BrowserWindowController.selectTabByNumber(_:)), keyEquivalent: "\(n)")
      tabItem.tag = n
      window.addItem(tabItem)
    }
    NSApp.windowsMenu = window

    let help = submenu(main, "Help")
    let tips = NSMenuItem(title: "Hold ⌥ Option on a page and click to collect content", action: nil, keyEquivalent: "")
    tips.isEnabled = false
    help.addItem(tips)
    NSApp.helpMenu = help
    return main
  }

  private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
    let menu = NSMenu(title: title)
    main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
    return menu
  }

  @discardableResult
  private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
  }

  // With every window closed, these menu commands reach the app delegate
  // instead of a window: they bring the main window back.

  /// ⌥⌘N: a new note, in the main window.
  @objc func newNote(_ sender: Any?) {
    reopenMain()
    controller?.newNote(nil)
  }

  /// ⌘N: a new window, in the mode (web or notes) of the front one. With
  /// every window closed, the main window comes back instead.
  @objc func newWindow(_ sender: Any?) {
    let anyOpen = NSApp.windows.contains { $0.windowController is BrowserWindowController && $0.isVisible }
    guard anyOpen else {
      reopenMain()
      return
    }
    openExtraWindow(restoring: nil, mode: openWindowMode(besides: nil))
  }

  /// A regular window besides the main one: empty on the web (a little down
  /// and right of the front window), or last time's (`saved`) at launch.
  private func openExtraWindow(restoring saved: Session.SavedWindow?, mode: BrowserWindowController.Mode? = nil) {
    let extra = BrowserWindowController(extra: true, restoring: saved, mode: mode)
    if saved?.frame == nil, let window = extra.window {
      if let front = frontController?.window, front.isVisible, !front.styleMask.contains(.fullScreen) {
        let frame = front.frame.offsetBy(dx: 24, dy: -24)
        window.setFrame(window.constrainFrameRect(frame, to: front.screen), display: false)
      } else {
        window.center()
      }
    }
    extra.onClose = { [weak self, weak extra] in
      self?.extraControllers.removeAll { $0 === extra }
    }
    extraControllers.append(extra)
    extra.showWindow(nil)
  }

  /// ⇧⌘T: the main window, with the tabs closed last reopened.
  @objc func reopenClosedTab(_ sender: Any?) {
    guard let controller else { return }
    reopenMain()
    controller.reopenClosedTab(nil)
  }

  /// ⌘T: bring the browser window forward, on a new tab (its start page).
  @objc func newTab(_ sender: Any?) {
    guard let controller = frontController, let window = controller.window else { return }
    controller.reopen(in: openWindowMode(besides: controller))
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    controller.openNewTab()
  }

  /// ⌘K: bring the browser window forward and open the omnibox.
  @objc func openOmnibox(_ sender: Any?) {
    guard let controller = frontController, let window = controller.window else { return }
    controller.reopen(in: openWindowMode(besides: controller))
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    controller.showOmnibox(target: .newTab)
  }

  /// The main window reopening matches the mode (web or notes) of the front
  /// window already open; with none, it opens in the notes. (Incognito
  /// windows always open on the web.)
  private func openWindowMode(besides other: BrowserWindowController?) -> BrowserWindowController.Mode? {
    NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }
      .first { $0 !== other && $0.window?.isVisible == true }?.mode
  }

  /// Brings back the main window (closed with ⌘W without tabs).
  private func reopenMain() {
    controller?.reopen(in: openWindowMode(besides: controller))
  }

  /// ⇧⌘N: a new incognito window, a little down and right of the front one.
  @objc func newIncognitoWindow(_ sender: Any?) {
    let incognito = BrowserWindowController(incognito: true)
    if let window = incognito.window {
      if let front = frontController?.window, front.isVisible, !front.styleMask.contains(.fullScreen) {
        let frame = front.frame.offsetBy(dx: 24, dy: -24)
        window.setFrame(window.constrainFrameRect(frame, to: front.screen), display: false)
      } else {
        window.center()
      }
    }
    incognito.onClose = { [weak self, weak incognito] in
      self?.incognitoControllers.removeAll { $0 === incognito }
    }
    incognitoControllers.append(incognito)
    NSApp.activate(ignoringOtherApps: true)
    incognito.showWindow(nil)
  }

  @objc private func setSearchEngine(_ sender: NSMenuItem) {
    SearchEngine.current = SearchEngine.allCases[sender.tag]
  }

  @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(setSearchEngine(_:)) {
      item.state = SearchEngine.allCases[item.tag] == SearchEngine.current ? .on : .off
    }
    return true
  }
}
