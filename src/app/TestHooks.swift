import AppKit
import GleaBridge

/// Development-only remote control, enabled with GLEA_TEST_HOOKS=1. Lets
/// scripts drive the UI (switch modes, type in the omnibox, run page script)
/// through distributed notifications named "app.glea.test" (or
/// GLEA_TEST_CHANNEL).
@MainActor
enum TestHooks {
  private static func allSubviews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allSubviews)
  }

  static func install(controller: BrowserWindowController) {
    guard ProcessInfo.processInfo.environment["GLEA_TEST_HOOKS"] == "1" else { return }
    // Make this copy unmistakable on screen (unless GLEA_HIDE_TEST_BADGE=1,
    // for screenshots of a demo profile).
    if ProcessInfo.processInfo.environment["GLEA_HIDE_TEST_BADGE"] != "1", let root = controller.window?.appRootView {
      let badge = NSTextField.label("TEST COPY – automated checks", size: 11, weight: .bold, color: .white)
      badge.wantsLayer = true
      badge.layer?.backgroundColor = NSColor.systemRed.cgColor
      badge.layer?.cornerRadius = 4
      badge.alignment = .center
      root.addSubview(badge)
      NSLayoutConstraint.activate([
        badge.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        badge.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        badge.widthAnchor.constraint(equalToConstant: 220),
      ])
      controller.window?.title = "Glea (test copy)"
    }
    DistributedNotificationCenter.default().addObserver(
      // GLEA_TEST_CHANNEL separates copies running side by side.
      forName: Notification.Name(ProcessInfo.processInfo.environment["GLEA_TEST_CHANNEL"] ?? "app.glea.test"), object: nil, queue: .main
    ) { note in
      guard let command = note.object as? String else { return }
      MainActor.assumeIsolated { run(command, controller: controller) }
    }
  }

  private static func run(_ command: String, controller: BrowserWindowController) {
    let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
    let argument = parts.count > 1 ? parts[1] : ""
    switch parts[0] {
    case "journal": controller.setMode(.journal)
    case "notes": controller.setMode(.notes)
    case "all-notes":
      NSApp.activate(ignoringOtherApps: true)
      controller.window?.makeKeyAndOrderFront(nil)
      controller.showAllNotes(nil)
    case "web": controller.toggleJournal(nil)
    case "note":
      if let ref = NoteStore.shared.resolve(linkName: argument) { controller.openNote(ref) }
    case "newnote": controller.newNote(nil)
    case "incognito": NSApp.sendAction(#selector(AppDelegate.newIncognitoWindow(_:)), to: nil, from: nil)
    case "key-window-type":
      // Types into the key window's (or an incognito window's) focused field, "\r" chooses.
      let target = NSApp.keyWindow ?? NSApp.windows.last { ($0.windowController as? BrowserWindowController)?.isIncognito == true && $0.isVisible }
        ?? controller.window
      // (A transition's overlay can hold key: the window's own field then.)
      guard let editor = (target?.firstResponder as? NSTextView) ?? (controller.window?.firstResponder as? NSTextView) else { NSLog("Glea test: no field in \(String(describing: target?.title)) parent=\(String(describing: target?.parent?.title)): \(String(describing: target?.firstResponder)) main=\(String(describing: NSApp.mainWindow?.title)) active=\(NSApp.isActive)"); break }
      if argument == "\r" { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) } else { editor.insertText(argument, replacementRange: editor.selectedRange()) }
    case "cmd-w":
      // cmd-w:main|incognito: ⌘W in that window.
      let target = argument == "incognito"
        ? NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.last { $0.isIncognito }
        : controller
      target?.closeCurrentTab(nil)
    case "close-all": controller.closeAllTabs(nil)
    case "action":
      // action:<selector>: a menu command, sent where the menu would send it.
      NSApp.sendAction(Selector(argument), to: nil, from: nil)
    case "reopen": NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
    case "menu-key":
      // menu-key:<key>: the ⌘<key> menu item, sent as the menu sends it.
      func find(_ menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
          if item.keyEquivalent == argument, item.keyEquivalentModifierMask == [.command] { return item }
          if let found = find(item.submenu) { return found }
        }
        return nil
      }
      if let item = find(NSApp.mainMenu), let action = item.action {
        NSLog("Glea test menu: %@", item.title)
        NSApp.sendAction(action, to: item.target, from: item)
      }
    case "main-close": controller.window?.performClose(nil)
    case "extra-close":
      // Closes the front extra window (⌘N on the web), like its close button.
      NSApp.orderedWindows.first { ($0.windowController as? BrowserWindowController)?.isExtra == true }?.performClose(nil)
    case "incognito-close-window":
      NSApp.windows.last { ($0.windowController as? BrowserWindowController)?.isIncognito == true }?.performClose(nil)
    case "incognito-toggle":
      NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.last { $0.isIncognito }?.toggleJournal(nil)
    case "incognito-js", "incognito-close-tab":
      let incognito = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.last { $0.isIncognito }
      if parts[0] == "incognito-js" {
        incognito?.activeTab?.browserView?.executeJavaScript(argument)
      } else if let tab = incognito?.activeTab {
        incognito?.closeTab(tab)
      }
    case "windows":
      for window in NSApp.windows where window.windowController is BrowserWindowController {
        let owner = window.windowController as! BrowserWindowController
        NSLog("Glea test window: \(window.title) incognito=\(owner.isIncognito) tabs=\(owner.tabs.count) \(owner.tabs.map { URL(string: $0.url)?.host ?? "" }) active=\(owner.activeTab.map { URL(string: $0.url)?.host ?? "" } ?? "-") mode=\(owner.mode) visible=\(window.isVisible) key=\(window.isKeyWindow) field=\(window.firstResponder is NSTextView)")
      }
    case "update-ready": Updater.shared.simulateReady(argument.isEmpty ? nil : argument)
    case "update-check-background": Updater.shared.checkInBackground()
    case "update-install": Updater.shared.installAndRelaunch()
    case "open": controller.openTab(argument)
    case "omnibox":
      controller.showOmnibox(target: .newTab)
      if let field = controller.window?.firstResponder as? NSTextView {
        field.insertText(argument, replacementRange: field.selectedRange())
      }
    case "key":
      // Sends a key command to the first responder, e.g. key:moveDown:
      (NSApp.keyWindow ?? controller.window)?.firstResponder?.doCommand(by: Selector(argument))
    case "js": controller.activeTab?.browserView?.executeJavaScript(argument)
    case "option": controller.modifierFlagsChanged(argument == "down" ? .option : [])
    case "collect": controller.collectPage(nil)
    case "find": controller.findInPage(nil)
    case "hover-tab":
      // hover-tab:<index> (or -1 to stop): the tab as if the pointer were over it.
      if let i = Int(argument) {
        for j in controller.tabs.indices { controller.topBar.simulateHover(tabAt: j, j == i) }
      }
    case "focus-today": controller.showJournal(nil)
    case "type":
      (controller.window?.firstResponder as? NSTextView)?.insertText(argument, replacementRange: NSRange(location: NSNotFound, length: 0))
    case "move":
      // move:<n>:<line> moves the nth block of the visible note before a line.
      let editor = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MarkdownEditorView }.first { !$0.isHiddenOrHasHiddenAncestor }
      let numbers = argument.split(separator: ":").compactMap { Int($0) }
      if let editor, numbers.count >= 2 {
        editor.debugMoveBlock(numbers[0], before: numbers[1])
      }
    case "drag-begin", "drag-move", "drag-end", "lift-duration":
      // drag-begin:<n>, drag-move:<dy>, drag-end: drags the nth block of the visible note.
      let editor = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MarkdownEditorView }.first { !$0.isHiddenOrHasHiddenAncestor }
      switch parts[0] {
      case "drag-begin": if let n = Int(argument) { editor?.debugBeginDrag(n) }
      case "drag-move": if let dy = Double(argument) { editor?.debugMoveDrag(by: dy) }
      case "lift-duration": if let seconds = Double(argument) { BlockDragDebug.liftDuration = seconds }
      default: editor?.debugEndDrag()
      }
    case "undo", "redo":
      // Like ⌘Z / ⇧⌘Z, with the window's undo manager.
      // Through the responder chain, like the menu (a table cell's editor
      // routes it to its note).
      if NSApp.sendAction(Selector(parts[0] + ":"), to: nil, from: nil) == false {
        let undo = controller.window?.firstResponder?.undoManager ?? controller.window?.undoManager
        if parts[0] == "undo" { undo?.undo() } else { undo?.redo() }
      }
    case "focus-note":
      // Puts the cursor at the start of the visible note.
      let editor = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MarkdownEditorView }.first { !$0.isHiddenOrHasHiddenAncestor }
      editor?.focus(atEnd: false)
    case "fold-duration":
      if let seconds = Double(argument) { Motion.foldDuration = seconds }
    case "table-hover":
      // table-hover:<n>: the pointer over the visible note's nth table (-1: away).
      let editor = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MarkdownEditorView }.first { !$0.isHiddenOrHasHiddenAncestor }
      if let n = Int(argument) { editor?.debugHoverTable(n) } else { editor?.debugClickTableToggle() }
    case "table-add":
      // table-add:row|column: the "+" on the edge of the table the cursor is
      // in; table-add:log logs where those buttons are.
      let editor = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MarkdownEditorView }.first { !$0.isHiddenOrHasHiddenAncestor }
      if argument == "log" { NSLog("Glea test table-add: %@", editor?.debugTableAddButtons ?? "no editor") } else { editor?.debugAddToTable(column: argument == "column") }
    case "media-duration":
      if let seconds = Double(argument) { MediaBlockView.resizeDuration = seconds }
    case "fold":
      // fold:<n> collapses or expands the nth heading's section in the visible note.
      let editor = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MarkdownEditorView }.first { !$0.isHiddenOrHasHiddenAncestor }
      if let editor, let n = Int(argument) {
        let sections = MarkdownStyler.headingSections(in: editor.content as NSString)
        if sections.indices.contains(n) { editor.toggleFold(sections[n].key) }
      }
    case "tab-media":
      // tab-media:<camera 0/1>,<microphone 0/1> for the active tab; tab-mute toggles its sound.
      let flags = argument.split(separator: ",").map { $0 == "1" }
      if flags.count == 2 { controller.activeTab?.debugSetMediaAccess(camera: flags[0], microphone: flags[1]) }
    case "tab-menu":
      // tab-menu:<title> runs that item of the active tab's right-click menu.
      if let tab = controller.activeTab,
         let item = controller.tabMenu(for: tab).items.first(where: { $0.title == argument }), let action = item.action {
        NSApp.sendAction(action, to: item.target, from: item)
      }
    case "media-collapse":
      // media-collapse:<n>,<0|1>: collapses or expands the nth media block shown.
      let v = argument.split(separator: ",").compactMap { Int($0) }
      let blocks = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MediaBlockView }
        .filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.minX > -50_000 }
        .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
      if v.count == 2, blocks.indices.contains(v[0]) { blocks[v[0]].setCollapsed(v[1] == 1) }
    case "media-label":
      // media-label:<0/1>: the first media block's toggle, its label shrinking out or growing in.
      let blocks = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MediaBlockView }
      blocks.first?.debugToggleLabel(argument == "1")
    case "tab-mute":
      if let tab = controller.activeTab { tab.setMuted(!tab.isMuted) }
    case "sheet-button":
      // sheet-button:<title> presses that button of the window's sheet (an alert).
      if let sheet = controller.window?.attachedSheet?.contentView,
         let button = allSubviews(sheet).compactMap({ $0 as? NSButton }).first(where: { $0.title == argument }) {
        button.performClick(nil)
      }
    case "check-note":
      // check-note:<row> checks or unchecks a note in All Notes.
      let list = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? NotesListView }.first
      if let row = Int(argument) { list?.debugToggleCheck(row) }
    case "lift-note", "drag-note-to", "end-note-drag":
      // lift-note:<row>, drag-note-to:<y in the list>, end-note-drag:drop (or
      // cancel) drag a note in All Notes.
      let list = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? NotesListView }.first
      switch parts[0] {
      case "lift-note": if let row = Int(argument) { list?.debugLift(row) }
      case "drag-note-to": if let y = Double(argument) { list?.debugDragTo(y) }
      default: list?.debugEndDrag(drop: argument == "drop")
      }
    case "drop-note", "toggle-group", "delete-group", "rename-group", "notes-toc", "scroll-notes":
      // drop-note:<name>|<row>|on (or above) drops a note in All Notes as if
      // dragged there; toggle-group:<name> ("" for ungrouped) and
      // delete-group:<name>.
      let list = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? NotesListView }.first
      if parts[0] == "toggle-group" { list?.debugToggleGroup(argument) }
      if parts[0] == "delete-group" { list?.debugDeleteGroup(argument) }
      if parts[0] == "scroll-notes", let y = Double(argument) { list?.debugScroll(to: y) }
      if parts[0] == "notes-toc", let index = Int(argument) { list?.debugSelectTocEntry(index) }
      if parts[0] == "rename-group", case let names = argument.split(separator: "|").map(String.init), names.count == 2 {
        list?.debugRenameGroup(names[0], to: names[1])
      }
      let fields = argument.split(separator: "|").map(String.init)
      if parts[0] == "drop-note", fields.count == 3, let row = Int(fields[1]) { list?.debugDrop(fields[0], row: row, on: fields[2] == "on") }
    case "toc-hover", "toc-click":
      let page = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? ColumnPageView }.first { !$0.isHiddenOrHasHiddenAncestor }
      let index = Int(argument)
      if parts[0] == "toc-hover" { page?.toc.debugHover(index) } else if let index { page?.toc.onSelect?(index) }
    case "devtools":
      let docks: [String: GleaDevToolsDock] = ["right": .right, "bottom": .bottom, "left": .left, "window": .window]
      if let dock = docks[argument] {
        controller.activeTab?.devTools?.show(dock)
      } else if argument.hasPrefix("inspect") {
        controller.activeTab?.devTools?.show(.right, inspecting: NSPoint(x: 80, y: 80))
      } else {
        controller.activeTab?.devTools?.close()
      }
    case "devtools-js":
      // Runs script in the docked DevTools frontend (for tests).
      let frontends = NSApp.windows.compactMap(\.contentView).flatMap(allSubviews).compactMap { $0 as? GleaBrowserView }
        .filter { $0.url.hasPrefix("devtools://") }
      frontends.first?.executeJavaScript(argument)
    case "select":
      // select:<location>,<length> in the focused editor, or a search string.
      guard let text = controller.window?.firstResponder as? NSTextView else { break }
      let numbers = argument.split(separator: ",").compactMap { Int($0) }
      if numbers.count == 2 {
        text.setSelectedRange(NSRange(location: numbers[0], length: numbers[1]))
      } else {
        let found = (text.string as NSString).range(of: argument)
        if found.location != NSNotFound { text.setSelectedRange(found) }
      }
    case "caret":
      // caret:<text> puts the cursor right after the first occurrence.
      guard let text = controller.window?.firstResponder as? NSTextView else { break }
      let found = (text.string as NSString).range(of: argument)
      if found.location != NSNotFound { text.setSelectedRange(NSRange(location: NSMaxRange(found), length: 0)) }
    case "focus-editor":
      let editors = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MarkdownEditorView }
        .filter { !$0.isHiddenOrHasHiddenAncestor }
      if let editor = editors.first { controller.window?.makeFirstResponder(editor.textView) }
    case "drop-file":
      // Simulates dropping a file on the editor, via a private pasteboard.
      guard let text = controller.window?.firstResponder as? MarkdownTextView else { break }
      let board = NSPasteboard(name: NSPasteboard.Name("glea.test.\(UUID().uuidString)"))
      board.clearContents()
      board.writeObjects([URL(fileURLWithPath: argument) as NSURL])
      if let images = text.imageMarkdown(from: board) { text.insertImages(images, at: text.selectedRange().location) }
      board.releaseGlobally()
    case "paste-image-data":
      // Simulates pasting image data (e.g. a screenshot), via a private pasteboard.
      guard let text = controller.window?.firstResponder as? MarkdownTextView,
            let data = try? Data(contentsOf: URL(fileURLWithPath: argument)) else { break }
      let board = NSPasteboard(name: NSPasteboard.Name("glea.test.\(UUID().uuidString)"))
      board.clearContents()
      board.setData(data, forType: .png)
      if let images = text.imageMarkdown(from: board, preferText: true) { text.insertImages(images, at: text.selectedRange().location) }
      board.releaseGlobally()
    case "keydown":
      // keydown:<keyCode>[,<characters>] sent through NSWindow like a real key
      // (to the overlay window while an overlay is up).
      let overlayWindow = NSApp.windows.first { w in w.contentView?.subviews.contains { $0 is OverlayView } == true }
      guard let window = overlayWindow ?? controller.window else { break }
      // (keydown:<keyCode>,<characters>,<cmd|opt|shift|ctrl joined by +> for modifiers.)
      let parts = argument.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
      let code = UInt16(parts[0]) ?? 0
      let chars = parts.count > 1 ? parts[1].replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\r", with: "\r") : ""
      var flags: NSEvent.ModifierFlags = []
      for name in (parts.count > 2 ? parts[2] : "").split(separator: "+") {
        flags.insert(["cmd": .command, "opt": .option, "shift": .shift, "ctrl": .control][String(name)] ?? [])
      }
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
          window.sendEvent(event)
        }
      }
    case "click-cell":
      // click-cell:<row>,<column>,<fraction> clicks inside a rendered table
      // cell of the focused editor (row 0 = header, fraction across the cell).
      guard let text = controller.window?.firstResponder as? MarkdownTextView, let window = controller.window,
            let lm = text.layoutManager, let storage = text.textStorage else { break }
      let n = argument.split(separator: ",").compactMap { Double($0) }
      var rows: [(NSRange, MarkdownTableRow)] = []
      storage.enumerateAttribute(.gleaTableRow, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        if let info = value as? MarkdownTableRow { rows.append((range, info)) }
      }
      guard n.count == 3, Int(n[0]) < rows.count else { break }
      let (range, info) = rows[Int(n[0])]
      let column = Int(n[1])
      let lineRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
      let scroll = (lm as? MarkdownLayoutManager)?.scrollX(of: info) ?? 0
      let x = info.columnX[column] + (info.columnX[column + 1] - info.columnX[column]) * n[2] + text.textContainerOrigin.x - scroll
      let point = text.convert(NSPoint(x: x, y: lineRect.midY + text.textContainerOrigin.y), to: nil)
      func mouse(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      }
      // The text view tracks the mouse until it sees the button come up, so
      // queue the mouse-up before delivering the mouse-down.
      if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
      if let down = mouse(.leftMouseDown) { window.sendEvent(down) }
    case "drag-file":
      // Runs AppKit's full drop sequence on the editor with a Finder-like
      // file pasteboard, and logs what each step answered.
      // drag-file:<path>[|<y in the text view>]
      guard let text = controller.window?.firstResponder as? MarkdownTextView else { break }
      let fields = argument.split(separator: "|").map(String.init)
      let board = NSPasteboard(name: NSPasteboard.Name("glea.test.\(UUID().uuidString)"))
      board.clearContents()
      board.writeObjects([URL(fileURLWithPath: fields[0]) as NSURL])
      let y = fields.count > 1 ? Double(fields[1]) ?? 20 : 20
      let info = FakeDragInfo(pasteboard: board, location: text.convert(NSPoint(x: 40, y: y), to: nil), window: controller.window)
      let entered = text.draggingEntered(info)
      let updated = text.draggingUpdated(info)
      let prepared = text.prepareForDragOperation(info)
      let performed = prepared && text.performDragOperation(info)
      if performed { text.concludeDragOperation(info) }
      NSLog("Glea drag: entered=%lu updated=%lu prepared=%d performed=%d types=%@", entered.rawValue, updated.rawValue, prepared, performed,
            String(describing: text.registeredDraggedTypes.map(\.rawValue)))
      board.releaseGlobally()
    case "line-heights":
      // Logs the laid-out height of every line of the focused editor.
      guard let text = controller.window?.firstResponder as? NSTextView, let lm = text.layoutManager else { break }
      let ns = text.string as NSString
      var out: [String] = []
      ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
        let glyph = lm.glyphIndexForCharacter(at: min(enclosing.location, max(0, ns.length - 1)))
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let label = ns.substring(with: line).prefix(18)
        out.append(String(format: "%5.1f | %@", used.height, String(label).isEmpty ? "(empty)" : String(label)))
      }
      NSLog("Glea line heights:\n%@", out.joined(separator: "\n"))
    case "extensions-menu":
      // Opens the puzzle menu as if its button (near the top-right) was clicked.
      let width = controller.window?.frame.width ?? 1200
      controller.topBarShowExtensions(from: NSRect(x: width - 112, y: 12, width: 28, height: 28))
    case "hittest":
      // hittest:x,y (window points from the top left): which view gets a click there.
      let xy = argument.split(separator: ",").compactMap { Double($0) }
      if xy.count == 2, let window = controller.window, let frameView = window.contentView?.superview {
        // As AppKit dispatches a click: from the window's frame view, in window coordinates.
        let hit = frameView.hitTest(NSPoint(x: xy[0], y: window.frame.height - xy[1]))
        if let root = window.appRootView, let content = window.contentView {
          let p = content.convert(NSPoint(x: xy[0], y: window.frame.height - xy[1]), from: nil)
          NSLog("Glea hittest root frame %@ in %@ (flipped %d); root.hitTest -> %@; content subviews %@",
                NSStringFromRect(root.frame), String(describing: type(of: content)), content.isFlipped,
                root.hitTest(p).map { String(describing: type(of: $0)) } ?? "nil",
                content.subviews.map { String(describing: type(of: $0)) }.joined(separator: ","))
        }
        NSLog("Glea hittest %@ -> %@", argument, hit.map { String(describing: type(of: $0)) } ?? "nil")
      }
    case "window-frame":
      // window-frame:<x>,<y>,<width>,<height>: from the main screen's top left.
      let v = argument.split(separator: ",").compactMap { Double($0) }
      if v.count == 4, let window = controller.window, let screen = window.screen ?? NSScreen.main {
        window.setFrame(NSRect(x: v[0], y: screen.frame.maxY - v[1] - v[3], width: v[2], height: v[3]), display: true)
      }
    case "window-size":
      // window-size:<width>,<height>
      let size = argument.split(separator: ",").compactMap { Double($0) }
      if size.count == 2, let window = controller.window {
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
      }
    case "export-note":
      // export-note:<note name>|<file path>
      let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
      if parts.count == 2, let ref = NoteStore.shared.resolve(linkName: parts[0]) {
        do { try NoteStore.shared.export(ref, to: URL(fileURLWithPath: parts[1])) } catch { NSLog("Glea export failed: %@", "\(error)") }
      }
    case "log-scroll":
      // Logs the visible page's scroll position.
      let pages = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? ColumnPageView }
        .filter { !$0.isHiddenOrHasHiddenAncestor }
      if let page = pages.first { NSLog("Glea scroll y=%.1f %@", page.scrollView.contentView.bounds.minY, argument) }
    case "scroll-page":
      let pages = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? ColumnPageView }
        .filter { !$0.isHiddenOrHasHiddenAncestor }
      if let page = pages.first, let y = Double(argument) {
        let maxY = max(0, (page.scrollView.documentView?.frame.height ?? 0) - page.scrollView.contentView.bounds.height)
        page.scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
        page.scrollView.reflectScrolledClipView(page.scrollView.contentView)
        NSLog("Glea scrolled %@ to %.0f (max %.0f)", String(describing: type(of: page)), page.scrollView.contentView.bounds.minY, maxY)
      }
    case "caret-walk":
      // caret-walk:<n>: ↓ n times in the focused editor (like a held key), logging
      // the page's scroll offset after each (the caret's line in the window too).
      let steps = Int(argument) ?? 20
      let pages = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? ColumnPageView }
        .filter { !$0.isHiddenOrHasHiddenAncestor }
      let editor = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MarkdownEditorView }.first { !$0.isHiddenOrHasHiddenAncestor }
      guard let page = pages.first, let editor else { break }
      let textView = editor.textView
      controller.window?.makeFirstResponder(textView)
      textView.setSelectedRange(NSRange(location: 0, length: 0))
      page.scrollView.contentView.scroll(to: .zero)
      page.scrollView.reflectScrolledClipView(page.scrollView.contentView)
      var values: [String] = []
      func step(_ i: Int) {
        guard i < steps else {
          NSLog("Glea caret-walk: %@", values.joined(separator: " "))
          return
        }
        textView.moveDown(nil)
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let inWindow = controller.window.map { $0.convertFromScreen(caret).minY } ?? 0
        values.append(String(format: "%.0f/%.0f", page.scrollView.contentView.bounds.minY, inWindow))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { step(i + 1) }
      }
      step(0)
    case "media-frames":
      let blocks = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MediaBlockView }
      for block in blocks {
        let inner = allSubviews(block).filter { $0 is GleaBrowserView || $0 is NSImageView }.map { "\(type(of: $0)) \(NSStringFromRect($0.frame))" }
        NSLog("Glea media %@ frame=%@ height=%.0f %@", block.descriptor.key, NSStringFromRect(block.frame), block.blockHeight, inner.joined(separator: ", "))
      }
    case "embed-js":
      // embed-js:<index>|<script> runs script in a media embed; the script
      // sets document.title to its result, logged with embed-title.
      let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
      let blocks = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MediaBlockView }
        .filter { !$0.isHiddenOrHasHiddenAncestor }.sorted { $0.frame.minY < $1.frame.minY }
      guard parts.count == 2, let index = Int(parts[0]), index < blocks.count else { break }
      let browsers = allSubviews(blocks[index]).compactMap { $0 as? GleaBrowserView }
      browsers.first?.executeJavaScript(parts[1])
    case "embed-title":
      let blocks = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews).compactMap { $0 as? MediaBlockView }
        .filter { !$0.isHiddenOrHasHiddenAncestor }.sorted { $0.frame.minY < $1.frame.minY }
      for (i, block) in blocks.enumerated() {
        for browser in allSubviews(block).compactMap({ $0 as? GleaBrowserView }) {
          NSLog("Glea embed %d: url=%@ title=%@", i, browser.url, browser.title)
        }
      }
    case "pdf-scroll":
      // pdf-scroll:<delta>,<phase>: a trackpad scroll over the first PDF (+
      // goes down the page), then logs the PDF's and the note's positions.
      let parts = argument.split(separator: ",").map(String.init)
      guard parts.count == 2, let delta = Int32(parts[0]), let window = controller.window,
            let pdf = allSubviews(window.contentView!).first(where: { $0 is PDFEmbedView }) as? PDFEmbedView,
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0)
      else { break }
      let point = window.convertPoint(toScreen: pdf.convert(NSPoint(x: pdf.bounds.midX, y: pdf.bounds.midY), to: nil))
      event.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(-delta))
      event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(-delta))
      let phases: [String: (scroll: Int64, momentum: Int64)] = [
        "began": (1, 0), "changed": (2, 0), "ended": (4, 0), "momentum": (0, 2), "momentum-ended": (0, 3), "wheel": (0, 0),
      ]
      guard let phase = phases[parts[1]] else { break }
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.scroll)
      event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase.momentum)
      // Routed as the window would (posted events don't reach a window
      // that isn't in front).
      if let ns = NSEvent(cgEvent: event), let content = window.contentView {
        MediaBlockView.debugScrollHitTest = true
        let target = content.hitTest(window.convertPoint(fromScreen: point))
        MediaBlockView.debugScrollHitTest = false
        target?.scrollWheel(with: ns)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        let page = allSubviews(window.contentView!).compactMap { $0 as? ColumnPageView }.first { !$0.isHiddenOrHasHiddenAncestor }
        NSLog("Glea pdf-scroll %@ pdf=%@ note=%.0f", argument, pdf.debugScrollState, page?.scrollView.contentView.bounds.minY ?? -1)
      }
    case "trackpad-scroll":
      // trackpad-scroll:<delta>,<began|changed|ended|momentum|momentum-ended>
      // scrolls the tab bar like a trackpad gesture (pixels, + goes right).
      let parts = argument.split(separator: ",").map(String.init)
      // (Global event coordinates go down from the top of the main screen.)
      guard parts.count == 2, let delta = Int32(parts[0]), let window = controller.window,
            let screen = NSScreen.screens.first,
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -delta, wheel3: 0)
      else { break }
      let bar = controller.topBar
      let point = window.convertPoint(toScreen: bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil))
      event.location = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(-delta))
      event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(-delta))
      let phases: [String: (scroll: Int64, momentum: Int64)] = [
        "began": (1, 0), "changed": (2, 0), "ended": (4, 0), "momentum": (0, 2), "momentum-ended": (0, 3),
      ]
      guard let phase = phases[parts[1]] else { break }
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.scroll)
      event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase.momentum)
      if let ns = NSEvent(cgEvent: event) { window.sendEvent(ns) }
    case "media-resize":
      // media-resize:<dx>[,<n>]: drags the nth (first) media resize handle
      // sideways, then logs the note's media lines and the blocks' frames.
      let values = argument.split(separator: ",").compactMap { Double($0) }
      let handles = controller.window.map { allSubviews($0.contentView!).compactMap { $0 as? MediaResizeHandle }.filter { !$0.isHidden } } ?? []
      let index = values.count > 1 ? Int(values[1]) : 0
      guard let window = controller.window, let dx = values.first, index < handles.count else {
        NSLog("Glea media-resize: no handle"); break
      }
      let handle = handles[index]
      let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
      func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + x, y: start.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
      }
      handle.mouseDown(with: mouse(.leftMouseDown, 0))
      // The gap from the block to the next one, after each step (in the
      // same turn: what a frame would show).
      let blocks = allSubviews(window.contentView!).compactMap { $0 as? MediaBlockView }.sorted { $0.frame.minY < $1.frame.minY }
      let block = blocks.first { allSubviews($0).contains(handle) }
      let next = block.flatMap { b in blocks.first { $0.frame.minY > b.frame.minY } }
      var gaps: [String] = []
      for step in 1...10 {
        handle.mouseDragged(with: mouse(.leftMouseDragged, CGFloat(dx) * CGFloat(step) / 10))
        if let block, let next { gaps.append(String(format: "%.0f", next.frame.minY - (block.frame.minY + block.blockHeight))) }
      }
      NSLog("Glea media-resize gaps: %@", gaps.joined(separator: " "))
      handle.mouseUp(with: mouse(.leftMouseUp, CGFloat(dx)))
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let editor = allSubviews(window.contentView!).compactMap { $0 as? MarkdownEditorView }.first { !$0.isHiddenOrHasHiddenAncestor }
        let lines = (editor?.textView.string ?? "").split(separator: "\n").filter { $0.contains("![") }
        let blocks = allSubviews(window.contentView!).compactMap { $0 as? MediaBlockView }
          .map { "\($0.descriptor.key) w=\($0.descriptor.preferredWidth.map { "\($0)" } ?? "-") h=\($0.blockHeight)" }
        NSLog("Glea media-resize %@: lines=%@ blocks=%@", argument, lines.joined(separator: " | "), blocks.joined(separator: " | "))
      }
    case "pdf-click":
      // pdf-click / pdf-click:outside: clicks the first PDF's middle, or the
      // note just above it, through the app (its event monitors see it).
      guard let window = controller.window,
            let pdf = allSubviews(window.contentView!).first(where: { $0 is PDFEmbedView }) else { break }
      let inWindow = pdf.convert(NSPoint(x: pdf.bounds.midX, y: argument == "outside" ? pdf.bounds.maxY + 40 : pdf.bounds.midY), to: nil)
      // (Flipped views: maxY is the bottom; "above" is the other way then.)
      let point = argument == "outside" && pdf.isFlipped ? pdf.convert(NSPoint(x: pdf.bounds.midX, y: -40), to: nil) : inWindow
      func mouse(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      }
      if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
      if let down = mouse(.leftMouseDown) { NSApp.sendEvent(down) }
    case "click":
      // click:<x>,<y> clicks at a point of the window (points, from the top left).
      let parts = argument.split(separator: ",").compactMap { Double($0) }
      guard parts.count == 2, let window = controller.window, let content = window.contentView else { break }
      let point = NSPoint(x: parts[0], y: content.bounds.height - parts[1])
      func mouse(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      }
      // The up is queued first: views that track the mouse (buttons) wait
      // for it in the event queue while handling the down.
      if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
      if let down = mouse(.leftMouseDown) { window.sendEvent(down) }
    case "drag-select":
      // drag-select:<x1>,<y1>,<x2>,<y2>: press, drag and release in the window
      // (points, from the top left), through the event queue.
      let v = argument.split(separator: ",").compactMap { Double($0) }
      guard v.count == 4, let window = controller.window, let content = window.contentView else { break }
      func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: content.bounds.height - y), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      }
      for step in 1...6 {
        let t = Double(step) / 6
        if let drag = event(.leftMouseDragged, v[0] + (v[2] - v[0]) * t, v[1] + (v[3] - v[1]) * t) { NSApp.postEvent(drag, atStart: false) }
      }
      if let up = event(.leftMouseUp, v[2], v[3]) { NSApp.postEvent(up, atStart: false) }
      if let down = event(.leftMouseDown, v[0], v[1]) { window.sendEvent(down) }
    case "real-click":
      // real-click:<x>,<y>: a click through the event queue, dispatched like
      // a real one (the window's hit testing, the table's checks).
      let parts = argument.split(separator: ",").compactMap { Double($0) }
      guard parts.count == 2, let window = controller.window, let content = window.contentView else { break }
      let point = NSPoint(x: parts[0], y: content.bounds.height - parts[1])
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          NSApp.postEvent(event, atStart: false)
        }
      }
    case "appearance":
      // appearance:light|dark|system switches this copy only.
      NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : argument == "light" ? NSAppearance(named: .aqua) : nil
    case "editor-text":
      if let text = controller.window?.firstResponder as? NSTextView {
        NSLog("Glea editor text: %@", String(reflecting: text.string.suffix(160)))
        NSLog("Glea editor selection: %@", NSStringFromRange(text.selectedRange()))
      } else {
        NSLog("Glea editor text: first responder is %@", String(describing: controller.window?.firstResponder))
      }
    case "page-key":
      // page-key:<keyCode>,<cmdopt|cmd|none>: a key press in the active page's window.
      let parts = argument.split(separator: ",").map(String.init)
      guard let window = controller.activeTab?.browserView?.chromeWindow, let code = UInt16(parts.first ?? "") else { break }
      var flags: NSEvent.ModifierFlags = []
      if parts.count > 1, parts[1].contains("cmd") { flags.insert(.command) }
      if parts.count > 1, parts[1].contains("opt") { flags.insert(.option) }
      let chars = code == 123 ? String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)) : code == 124 ? String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)) : ""
      // Through the event queue, like a real key (local monitors see it).
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
          NSApp.postEvent(event, atStart: false)
        }
      }
    case "page-layer":
      if let window = controller.activeTab?.browserView?.chromeWindow, let content = window.contentView {
        let layer = content.layer
        NSLog("Glea page layer flipped=%d radius=%.1f corners=%lu masks=%d styleMask=%lu frameView=%@ frameLayerRadius=%.1f",
              content.isFlipped, layer?.cornerRadius ?? -1, layer?.maskedCorners.rawValue ?? 0, layer?.masksToBounds ?? false,
              window.styleMask.rawValue, String(describing: type(of: content.superview!)), content.superview?.layer?.cornerRadius ?? -1)
      }
    case "hover-row":
      // hover-row:<n>,<0|1>: the nth hover-tracked row (top to bottom) as if
      // the pointer came over it or left.
      let parts = argument.split(separator: ",").compactMap { Int($0) }
      guard parts.count == 2, let root = controller.window?.contentView else { break }
      let rows = allSubviews(root).compactMap { $0 as? HoverView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
      if parts[0] < rows.count { rows[parts[0]].debugSetHovering(parts[1] == 1) }
    case "quiet-buttons":
      // Logs each quiet button (Link, Link All): its title, shown or not.
      guard let root = controller.window?.contentView else { break }
      let buttons = allSubviews(root).compactMap { $0 as? QuietButton }
        .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
      NSLog("Glea quiet buttons: %@", buttons.map { "\($0.accessibilityLabel() ?? "?") alpha=\(String(format: "%.2f", $0.alphaValue)) hidden=\($0.isHidden)" }.joined(separator: " | "))
    case "quit": NSApp.terminate(nil)
    case "press-option":
      // A ⌥ key press (flags changed), through the event queue.
      if let window = controller.window,
         let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: argument == "up" ? [] : [.option],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58) {
        NSApp.postEvent(event, atStart: false)
      }
    case "pin":
      if let i = Int(argument), controller.tabs.indices.contains(i) { controller.setPinned(controller.tabs[i], !controller.tabs[i].isPinned) }
    case "group":
      // group:<tabIndex>[,<name>]: a new group with that tab.
      let parts = argument.split(separator: ",", maxSplits: 1).map(String.init)
      if let i = Int(parts[0]), controller.tabs.indices.contains(i) {
        let group = controller.createGroup(with: controller.tabs[i])
        if parts.count > 1 { group.title = parts[1]; controller.refreshTopBarForTests() }
      }
    case "addto":
      // addto:<tabIndex>,<groupIndex>
      let xy = argument.split(separator: ",").compactMap { Int($0) }
      if xy.count == 2, controller.tabs.indices.contains(xy[0]), controller.groups.indices.contains(xy[1]) {
        controller.move(controller.tabs[xy[0]], to: controller.groups[xy[1]])
      }
    case "collapse":
      if let i = Int(argument), controller.groups.indices.contains(i) { controller.toggleCollapsed(controller.groups[i]) }
    case "slow-animations":
      // slow-animations:<speed>: the top bar's animations run at that speed.
      controller.topBar.layer?.speed = Float(argument) ?? 1
    case "toggle-extension-pin":
      // The first installed extension's pin, as its menu row toggles it.
      if let ext = ExtensionStore.installed().first {
        ExtensionPins.toggle(ext.id)
        controller.updatePinnedExtensions()
      }
    case "open-extension":
      // open-extension: the first installed extension's popup, from the puzzle button.
      if let ext = ExtensionStore.installed().first {
        let width = controller.window?.frame.width ?? 1200
        controller.topBarOpenExtension(ext.id, from: NSRect(x: width - 112, y: 12, width: 28, height: 28))
      }
    case "dismiss-overlay":
      controller.dismissOverlayForTesting()
    case "overlay-type":
      // overlay-type:<text> (or "BACKSPACE"): typed into the omnibox; then its field is logged.
      controller.typeInOverlayForTesting(argument == "BACKSPACE" ? "\u{8}" : argument)
      NSLog("Glea overlay field: %@", controller.overlayFieldTextForTesting())
    case "flags":
      // flags:command|option|none: a modifier key change, through the event queue.
      let flags: [String: NSEvent.ModifierFlags] = ["command": .command, "option": .option]
      if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags[argument] ?? [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55) {
        NSApp.postEvent(event, atStart: false)
      }
    case "overlay-return":
      // overlay-return[:option|command|shift-command]: Return in the omnibox.
      let modifiers: [String: NSEvent.ModifierFlags] = ["option": .option, "command": .command, "shift-command": [.shift, .command]]
      controller.pressReturnInOverlayForTesting(modifiers[argument] ?? [])
    case "window-active":
      // window-active:0|1: the top bar as if the window were focused or not.
      controller.topBar.setWindowActiveForTesting(argument != "0")
    case "activate-tab":
      // activate-tab:<index>: shows that tab.
      if let i = Int(argument), controller.tabs.indices.contains(i) { controller.activate(controller.tabs[i]) }
    case "tabs-state":
      for (i, tab) in controller.tabs.enumerated() {
        let g = controller.groups.firstIndex { $0.id == tab.groupID }.map(String.init) ?? "-"
        NSLog("Glea tab %d %@ pinned=%d group=%@ active=%d", i, tab.displayTitle, tab.isPinned, g, tab === controller.activeTab)
      }
    case "drag":
      // drag:x1,x2 (points in the window, at the tab bar's middle): a mouse drag.
      let xs = argument.split(separator: ",").compactMap { Double($0) }
      let flags: NSEvent.ModifierFlags = argument.hasSuffix(",opt") ? [.option] : []
      guard xs.count >= 2, let window = controller.window else { break }
      let y = window.frame.height - Theme.topBarHeight / 2
      var events: [NSEvent] = []
      func mouse(_ type: NSEvent.EventType, _ x: Double) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      }
      if let e = mouse(.leftMouseDown, xs[0]) { events.append(e) }
      for step in 1...12 {
        if let e = mouse(.leftMouseDragged, xs[0] + (xs[1] - xs[0]) * Double(step) / 12) { events.append(e) }
      }
      if let e = mouse(.leftMouseUp, xs[1]) { events.append(e) }
      // (Holds before the release so a screenshot can catch the drag.)
      for (i, e) in events.enumerated() {
        let delay = Double(i) * 0.03 + (e.type == .leftMouseUp ? 1.2 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSApp.postEvent(e, atStart: false) }
      }
    case "traffic-lights":
      if let window = controller.window {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
          if let button = window.standardWindowButton(type) {
            let r = button.convert(button.bounds, to: nil)
            NSLog("Glea traffic light %d at x=%.1f y-from-top=%.1f size=%@ in %@ frame=%@ hidden=%d", type.rawValue, r.minX, window.frame.height - r.maxY,
                  NSStringFromSize(r.size), NSStringFromClass(button.superview!.classForCoder), NSStringFromRect(button.frame), button.isHiddenOrHasHiddenAncestor)
          }
        }
      }
    case "cdp":
      // cdp:<json>: a DevTools protocol message to the active page.
      controller.activeTab?.browserView?.sendDevToolsMessage(argument)
    case "click-front":
      // click-front:x,y (points from the top-left of the smallest visible window: a dialog).
      let xy = argument.split(separator: ",").compactMap { Double($0) }
      let front = NSApp.windows.filter { $0.isVisible && $0.frame.width > 100 && !($0.contentView?.subviews.isEmpty ?? true) }
        .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
      if let window = front, xy.count == 2 {
        let point = NSPoint(x: xy[0], y: window.frame.height - xy[1])
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            NSApp.postEvent(event, atStart: false)
          }
        }
      }
    case "key-front":
      // key-front:<keyCode>,<chars>: a key to the frontmost visible app window (dialogs).
      let parts = argument.split(separator: ",", maxSplits: 1).map(String.init)
      // The smallest visible window: a dialog in front of the page.
      let front = NSApp.windows.filter { $0.isVisible && $0.frame.width > 100 && !($0.contentView?.subviews.isEmpty ?? true) }
        .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
      if let window = front, let code = UInt16(parts[0]) {
        NSLog("Glea key-front to %@ %@", String(describing: type(of: window)), NSStringFromRect(window.frame))
        let chars = parts.count > 1 ? parts[1] : ""
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: chars,
                                          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
            NSApp.postEvent(event, atStart: false)
          }
        }
      }
    case "page-red":
      if let window = controller.activeTab?.browserView?.chromeWindow {
        window.backgroundColor = .systemRed
        window.isOpaque = true
        window.contentView?.superview?.layer?.backgroundColor = NSColor.systemRed.cgColor
      }
    case "corner-methods":
      if let window = controller.activeTab?.browserView?.chromeWindow {
        var cls: AnyClass? = object_getClass(window)
        while let c = cls, c != NSObject.self {
          var count: UInt32 = 0
          if let methods = class_copyMethodList(c, &count) {
            let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(methods[$0])) }.filter { $0.lowercased().contains("corner") }
            if !names.isEmpty { NSLog("Glea corner methods %@: %@", NSStringFromClass(c), names.joined(separator: ", ")) }
            free(methods)
          }
          cls = class_getSuperclass(c)
        }
      }
    case "page-windows":
      for tab in controller.tabs {
        let w = tab.browserView?.chromeWindow
        NSLog("Glea page window %@: #%ld %@ visible=%d parent=%ld", tab.url, w?.windowNumber ?? -1,
              w.map { NSStringFromRect($0.frame) } ?? "-", w?.isVisible ?? false, w?.parent?.windowNumber ?? -1)
      }
      for w in NSApp.windows {
        NSLog("Glea app window #%ld %@ %@ visible=%d parent=%ld", w.windowNumber, String(describing: type(of: w)),
              NSStringFromRect(w.frame), w.isVisible, w.parent?.windowNumber ?? -1)
      }
    case "tab-frames":
      let views = [controller.window?.contentView].compactMap { $0 }.flatMap(allSubviews)
      for view in views where String(describing: type(of: view)).contains("Tab") || String(describing: type(of: view)).contains("Separator") {
        let shown = view.layer?.presentation()?.position.x ?? -1
        NSLog("Glea tabs: %@ %@ hidden=%d alpha=%.2f opacity=%.2f shownX=%.1f", String(describing: type(of: view)), NSStringFromRect(view.convert(view.bounds, to: nil)), view.isHidden, view.alphaValue, view.layer?.opacity ?? -1, shown)
      }
    case "debug":
      if let window = controller.window, let content = window.contentView {
        NSLog("Glea debug: frame=\(NSStringFromRect(window.frame)) fitting=\(NSStringFromSize(content.fittingSize))")
        if let b = window.standardWindowButton(.closeButton) {
          var v: NSView? = b
          while let view = v { NSLog("Glea debug: \(type(of: view)) \(NSStringFromRect(view.frame))"); v = view.superview }
        }
      }
    default: NSLog("Glea test hook: unknown command \(command)")
    }
  }
}


/// Minimal NSDraggingInfo for simulating drops in tests.
@MainActor
final class FakeDragInfo: NSObject, @preconcurrency NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  let draggingLocation: NSPoint
  let draggingDestinationWindow: NSWindow?
  init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow?) {
    draggingPasteboard = pasteboard
    draggingLocation = location
    draggingDestinationWindow = window
  }
  var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination: Bool = false
  var numberOfValidItemsForDrop: Int = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                              searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                              using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
  func resetSpringLoading() {}
}
