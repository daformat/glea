import AppKit
import GleaBridge
import Network

/// DevTools for one tab: docked right, left or below the page, or in their
/// own window.
///
/// Chromium's own DevTools can't be embedded in a view with this CEF version
/// (they must be a Chrome-style browser, and embedded browsers are Alloy
/// style). So these are the bundled DevTools frontend running in a regular
/// browser view, connected to the page through a local WebSocket that relays
/// Chrome DevTools Protocol messages via CEF. The socket listens on
/// 127.0.0.1 only, accepts a single connection from the DevTools origin, and
/// stops listening once connected.
///
/// Docking works like in Chrome: the frontend runs with `can_dock=true`, so
/// its ⋮ menu has the "Dock side" buttons; a small script reports changes.
@MainActor
final class DevToolsController: NSObject, GleaBrowserViewDelegate, NSWindowDelegate {
  private weak var page: GleaBrowserView?
  private var frontend: GleaBrowserView?
  private var relay: DevToolsRelay?
  private var window: NSWindow?
  private var dock: GleaDevToolsDock = .right
  private var pendingInspect: NSPoint?
  var onOpenURL: ((String) -> Void)?
  var pageTitle: () -> String = { "" }

  init(page: GleaBrowserView) {
    self.page = page
  }

  var isOpen: Bool { frontend != nil }

  func toggle() {
    if isOpen { close() } else { show(GleaBrowserView.preferredDevToolsDock) }
  }

  func show(_ newDock: GleaDevToolsDock, inspecting point: NSPoint? = nil) {
    guard let page else { return }
    GleaBrowserView.preferredDevToolsDock = newDock
    if let point { pendingInspect = point }
    if frontend != nil {
      if newDock == dock {
        window?.makeKeyAndOrderFront(nil)
        flushPendingInspect(after: 0)
        return
      }
      // The frontend is tied to where it was created: reopen it at the new place.
      teardown()
    }
    dock = newDock
    let relay = DevToolsRelay(page: page)
    self.relay = relay
    relay.onReady = { [weak self] address in self?.attachFrontend(address) }
    relay.onClose = { [weak self] in self?.close() }
    relay.onConnected = { [weak self] in self?.flushPendingInspect(after: 0.6) }
    relay.start()
  }

  func close() {
    teardown()
    page?.closeDetachedDevTools()
  }

  private func attachFrontend(_ address: String) {
    guard let page, relay != nil else { return }
    let side: String
    switch dock {
    case .bottom: side = "bottom"
    case .left: side = "left"
    case .window: side = "undocked"
    default: side = "right"
    }
    let url = "devtools://devtools/bundled/devtools_app.html?ws=\(address)&can_dock=true&panel=elements"
    let view = GleaBrowserView(url: url, contentScript: DevToolsController.dockWatcher(initialSide: side))
    view.delegate = self
    frontend = view
    if dock == .window {
      openWindow(with: view)
    } else {
      page.dockedDevToolsView = view
    }
  }

  private func openWindow(with view: GleaBrowserView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Developer Tools – \(pageTitle())"
    window.delegate = self
    view.frame = window.contentView?.bounds ?? .zero
    view.autoresizingMask = [.width, .height]
    window.contentView?.addSubview(view)
    if !window.setFrameUsingName("GleaDevToolsWindow") { window.center() }
    window.setFrameAutosaveName("GleaDevToolsWindow")
    window.makeKeyAndOrderFront(nil)
    self.window = window
  }

  private func teardown() {
    relay?.stop()
    relay = nil
    guard let view = frontend else { return }
    frontend = nil
    if let window {
      self.window = nil
      window.delegate = nil
      // The browser view closes with it.
      view.close()
      window.orderOut(nil)
    } else {
      page?.dockedDevToolsView = nil
      view.close()
    }
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
    close()
  }

  // MARK: Inspect element

  private func flushPendingInspect(after delay: TimeInterval) {
    guard let point = pendingInspect, let relay, relay.isConnected else { return }
    pendingInspect = nil
    // Give the frontend a moment to enable its domains.
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { relay.inspect(point) }
  }

  // MARK: Frontend browser delegate

  func browserView(_ view: GleaBrowserView, didReceiveMessage name: String, payload json: String) {
    guard view === frontend else { return }
    switch name {
    case "devtoolsBounds":
      // The area DevTools reserve for the page, in CSS pixels of the frontend.
      guard dock != .window,
            let rect = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Double] else { return }
      page?.inspectedPageBounds = NSRect(x: rect["x"] ?? 0, y: rect["y"] ?? 0,
                                         width: rect["width"] ?? 0, height: rect["height"] ?? 0)
    case "devtoolsClose":
      DispatchQueue.main.async { [weak self] in self?.close() }
    case "devtoolsDock":
      let newDock: GleaDevToolsDock
      switch json {
      case "bottom": newDock = .bottom
      case "left": newDock = .left
      case "undocked": newDock = .window
      default: newDock = .right
      }
      guard newDock != dock else { return }
      if dock != .window && newDock != .window {
        // Docked → docked: the frontend re-lays itself out and reports new
        // page bounds; nothing to rebuild.
        dock = newDock
        GleaBrowserView.preferredDevToolsDock = newDock
        return
      }
      // Moving between the window and the page needs a new frontend.
      DispatchQueue.main.async { [weak self] in self?.show(newDock) }
    default:
      break
    }
  }

  func browserView(_ view: GleaBrowserView, requestsNewTabWithURL url: String, background: Bool) {
    onOpenURL?(url)
  }

  func browserViewDidChangeState(_ view: GleaBrowserView) {
    if view === frontend, let window { window.title = "Developer Tools – \(pageTitle())" }
  }

  /// Runs in the frontend before its scripts:
  /// - seeds its dock setting so it opens laid out for the current side;
  /// - reports clicks on the ⋮ menu's "Dock side" buttons;
  /// - hooks the embedder calls this app has to answer: where the page goes
  ///   (`setInspectedPageBounds`) and the ✕ button (`closeWindow`).
  private static func dockWatcher(initialSide: String) -> String {
    """
    (() => {
      const post = (name, value) => { try { __gleaNative.post(name, String(value)); } catch (e) {} };
      try { localStorage.setItem('currentDockState', JSON.stringify('\(initialSide)')); } catch (e) {}

      document.addEventListener('click', (event) => {
        for (const node of event.composedPath()) {
          const label = (node.getAttribute && (node.getAttribute('aria-label') || node.getAttribute('title'))) || '';
          if (/undock/i.test(label)) { post('devtoolsDock', 'undocked'); return; }
          const match = label.match(/dock to (bottom|right|left)/i);
          if (match) { post('devtoolsDock', match[1].toLowerCase()); return; }
        }
      }, true);

      const SIDE = JSON.stringify('\(initialSide)');
      // Hook the embedder API as soon as the frontend installs it, before it
      // reads its preferences.
      const hook = (host) => {
        if (!host || host.__gleaHooked) return;
        const wrap = (name, before) => {
          const original = typeof host[name] === 'function' ? host[name].bind(host) : null;
          host[name] = (...args) => { before(...args); return original ? original(...args) : undefined; };
        };
        wrap('setInspectedPageBounds', (bounds) => post('devtoolsBounds', JSON.stringify(bounds)));
        wrap('closeWindow', () => post('devtoolsClose', ''));
        // Where the app actually put the frontend wins over its saved dock side.
        const getPreferences = typeof host.getPreferences === 'function' ? host.getPreferences.bind(host) : null;
        if (getPreferences) {
          host.getPreferences = (callback) => getPreferences((prefs) => {
            callback(Object.assign({}, prefs, { currentDockState: SIDE }));
          });
        }
        const getPreference = typeof host.getPreference === 'function' ? host.getPreference.bind(host) : null;
        if (getPreference) {
          host.getPreference = (name, callback) => name === 'currentDockState'
            ? callback(SIDE) : getPreference(name, callback);
        }
        host.__gleaHooked = true;
      };
      let current = globalThis.InspectorFrontendHost;
      if (current) {
        hook(current);
      } else {
        Object.defineProperty(globalThis, 'InspectorFrontendHost', {
          configurable: true,
          enumerable: true,
          get: () => current,
          set: (value) => { current = value; hook(value); },
        });
      }
    })();
    """
  }
}

/// A one-shot WebSocket server bridging the DevTools frontend to a page.
@MainActor
private final class DevToolsRelay {
  /// Frontend message ids are shifted into their own range so they never
  /// collide with the app's own protocol calls (e.g. screenshots).
  private static let idOffset = 1_000_000_000
  private static let inspectId = 999_000_001

  var onReady: ((String) -> Void)?
  var onConnected: (() -> Void)?
  var onClose: (() -> Void)?
  private(set) var isConnected = false

  private weak var page: GleaBrowserView?
  private var listener: NWListener?
  private var connection: NWConnection?
  private var forwarder: DevToolsMessageForwarder?
  private var pendingInspectPoint: NSPoint?

  init(page: GleaBrowserView) {
    self.page = page
  }

  func start() {
    let ws = NWProtocolWebSocket.Options()
    ws.autoReplyPing = true
    ws.maximumMessageSize = 256 * 1024 * 1024
    // Only the DevTools frontend may connect.
    ws.setClientRequestHandler(DispatchQueue.main) { _, headers in
      let origin = headers.first { $0.name.lowercased() == "origin" }?.value
      return NWProtocolWebSocket.Response(status: origin == "devtools://devtools" ? .accept : .reject,
                                          subprotocol: nil, additionalHeaders: nil)
    }
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    parameters.acceptLocalOnly = true
    guard let listener = try? NWListener(using: parameters) else {
      onClose?()
      return
    }
    self.listener = listener
    listener.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        guard let self, case .ready = state, let port = listener.port else { return }
        self.onReady?("127.0.0.1:\(port.rawValue)/page")
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      MainActor.assumeIsolated { self?.accept(connection) }
    }
    listener.start(queue: .main)
  }

  private func accept(_ newConnection: NWConnection) {
    guard connection == nil else {
      newConnection.cancel()
      return
    }
    connection = newConnection
    // One frontend per relay: stop listening.
    listener?.cancel()
    listener = nil
    newConnection.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        switch state {
        case .ready:
          self?.isConnected = true
          self?.onConnected?()
        case .failed, .cancelled:
          if self?.connection != nil { self?.onClose?() }
        default:
          break
        }
      }
    }
    newConnection.start(queue: .main)
    receive()

    let forwarder = DevToolsMessageForwarder { [weak self] json in self?.fromPage(json) }
    self.forwarder = forwarder
    page?.delegateForwarder = forwarder
    page?.forwardsDevToolsMessages = true
  }

  func stop() {
    listener?.cancel()
    listener = nil
    let current = connection
    connection = nil
    current?.cancel()
    page?.forwardsDevToolsMessages = false
    page?.delegateForwarder = nil
    isConnected = false
  }

  private func receive() {
    connection?.receiveMessage { [weak self] data, context, _, error in
      MainActor.assumeIsolated {
        guard let self else { return }
        if let data, !data.isEmpty, let json = String(data: data, encoding: .utf8) { self.fromFrontend(json) }
        if error == nil && self.connection != nil { self.receive() }
      }
    }
  }

  private func send(_ text: String) {
    guard let connection else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
    connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
  }

  // MARK: Relaying

  private func fromFrontend(_ json: String) {
    guard var message = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
          let id = message["id"] as? Int else { return }
    message["id"] = id + Self.idOffset
    guard let data = try? JSONSerialization.data(withJSONObject: message),
          let shifted = String(data: data, encoding: .utf8) else { return }
    page?.sendDevToolsMessage(shifted)
  }

  private func fromPage(_ json: String) {
    // Events (no id) go straight through; results only if they're the frontend's.
    guard json.contains("\"id\":"),
          var message = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
          let id = message["id"] as? Int else {
      send(json)
      return
    }
    if id == Self.inspectId {
      revealInspectedNode(message)
      return
    }
    guard id >= Self.idOffset else { return }
    message["id"] = id - Self.idOffset
    if let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) {
      send(text)
    }
  }

  /// Asks the page for the node at `point`, then tells the frontend to
  /// reveal it, as if the element picker had selected it.
  func inspect(_ point: NSPoint) {
    let request: [String: Any] = [
      "id": Self.inspectId,
      "method": "DOM.getNodeForLocation",
      "params": ["x": Int(point.x), "y": Int(point.y), "includeUserAgentShadowDOM": false],
    ]
    if let data = try? JSONSerialization.data(withJSONObject: request), let text = String(data: data, encoding: .utf8) {
      page?.sendDevToolsMessage(text)
    }
  }

  private func revealInspectedNode(_ response: [String: Any]) {
    guard let result = response["result"] as? [String: Any], let node = result["backendNodeId"] as? Int else { return }
    let event: [String: Any] = ["method": "Overlay.inspectNodeRequested", "params": ["backendNodeId": node]]
    if let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) {
      send(text)
    }
  }
}

/// Receives the page's protocol messages. The page view has a single
/// delegate (its Tab), so the Tab hands these on.
@MainActor
final class DevToolsMessageForwarder {
  let handler: (String) -> Void
  init(handler: @escaping (String) -> Void) { self.handler = handler }
}

private var forwarderKey: UInt8 = 0

extension GleaBrowserView {
  /// Where `browserView(_:didReceiveDevToolsMessage:)` should be forwarded.
  var delegateForwarder: DevToolsMessageForwarder? {
    get { objc_getAssociatedObject(self, &forwarderKey) as? DevToolsMessageForwarder }
    set { objc_setAssociatedObject(self, &forwarderKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }
}
