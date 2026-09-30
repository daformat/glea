import AppKit
import GleaBridge

@MainActor
protocol TabOwner: AnyObject {
  func tabDidUpdate(_ tab: Tab)
  func tab(_ tab: Tab, requestsNewTab url: String, background: Bool)
  func tab(_ tab: Tab, didReceiveMessage name: String, payload: [String: Any])
  func tab(_ tab: Tab, contextCommand: GleaContextCommand, argument: String)
  func tab(_ tab: Tab, didFailWithError error: String, url: String)
  func tab(_ tab: Tab, findResultCount count: Int, active: Int)
  func tab(_ tab: Tab, didDownload path: String)
  /// The page asks for the camera and/or microphone.
  func tab(_ tab: Tab, requestsMediaAccessFor origin: String, camera: Bool, microphone: Bool,
           completion: @escaping (Bool) -> Void)
  func tabDidClose(_ tab: Tab)
}

/// One browser tab. Its Chromium browser is created when the tab is first
/// attached to the window (restored tabs are, in the background, at launch).
@MainActor
final class Tab: NSObject, GleaBrowserViewDelegate {
  static let contentScript: String = {
    guard let url = Bundle.main.url(forResource: "content-script", withExtension: "js"),
          let script = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    return script
  }()

  weak var owner: TabOwner?
  private(set) var browserView: GleaBrowserView?
  private(set) var devTools: DevToolsController?
  private(set) var url: String
  private(set) var title: String
  private(set) var favicon: NSImage?
  private var faviconURL: String?
  private var hasRecordedVisit = false
  var errorMessage: String?
  /// Pinned tabs sit, icon-only, at the start of the tab bar; ⌘W doesn't
  /// close them and links to other sites open in new tabs.
  var isPinned = false
  var groupID: UUID?
  /// Incognito tabs' browsing session (in memory): nothing about them is
  /// written to disk, history included.
  let session: GleaBrowsingSession?
  var isIncognito: Bool { session != nil }

  init(url: String, title: String = "", session: GleaBrowsingSession? = nil) {
    self.url = url
    self.title = title
    self.session = session
    super.init()
    SoundMonitor.shared.register(self)
  }

  /// Favicon downloads for incognito tabs: no disk cache or cookies.
  private static let ephemeralSession = URLSession(configuration: .ephemeral)

  // MARK: Sound, camera and microphone

  /// The page's frames playing sound (each reports it; they're gone when
  /// their page goes).
  private var audibleFrames: Set<String> = []
  var isAudible: Bool { !audibleFrames.isEmpty }
  private(set) var isMuted = false
  private(set) var usesCamera = false
  private(set) var usesMicrophone = false

  /// For automated checks: as if the page used the camera and/or microphone.
  func debugSetMediaAccess(camera: Bool, microphone: Bool) {
    usesCamera = camera
    usesMicrophone = microphone
    owner?.tabDidUpdate(self)
  }

  func setMuted(_ muted: Bool) {
    guard muted != isMuted else { return }
    isMuted = muted
    browserView?.audioMuted = muted
    updateKeepsRunning()
    owner?.tabDidUpdate(self)
    SoundMonitor.shared.sourceDidChange()
  }

  /// A page playing sound keeps running out of sight (its sound may be
  /// driven by animation frames and timers, which Chromium stops there).
  private func updateKeepsRunning() {
    browserView?.keepsRunningWhenHidden = isAudible && !isMuted
  }

  var isLoading: Bool { browserView?.isLoading ?? false }
  var progress: Double { browserView?.loadProgress ?? 0 }
  var canGoBack: Bool { browserView?.canGoBack ?? false }
  var canGoForward: Bool { browserView?.canGoForward ?? false }

  var displayTitle: String {
    if !title.isEmpty { return title }
    if let host = URL(string: url)?.host { return host.replacingOccurrences(of: "www.", with: "") }
    return url.isEmpty ? "New Tab" : url
  }

  var host: String {
    URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
  }

  @discardableResult
  func ensureBrowserView() -> GleaBrowserView {
    if let browserView { return browserView }
    let view = GleaBrowserView(url: url, contentScript: Tab.contentScript)
    // A Chrome-style browser where the window allows it (extensions work).
    view.prefersChromeStyle = true
    view.session = session
    view.audioMuted = isMuted
    view.keepsRunningWhenHidden = isAudible && !isMuted
    view.delegate = self
    browserView = view
    let devTools = DevToolsController(page: view)
    devTools.onOpenURL = { [weak self] url in
      guard let self else { return }
      self.owner?.tab(self, requestsNewTab: url, background: false)
    }
    devTools.pageTitle = { [weak self] in self?.displayTitle ?? "" }
    self.devTools = devTools
    return view
  }

  func load(_ url: String) {
    self.url = url
    errorMessage = nil
    if let browserView { browserView.loadURL(url) } else { ensureBrowserView() }
    owner?.tabDidUpdate(self)
  }

  func close() {
    // Closed, it plays nothing.
    if isAudible {
      audibleFrames = []
      SoundMonitor.shared.sourceDidChange()
    }
    devTools?.close()
    if let browserView {
      browserView.close()
    } else {
      owner?.tabDidClose(self)
    }
  }

  // MARK: GleaBrowserViewDelegate

  func browserViewDidChangeState(_ view: GleaBrowserView) {
    if !view.url.isEmpty { url = view.url }
    if !view.title.isEmpty, view.title != url {
      title = view.title
      if !isIncognito { HistoryStore.shared.updateTitle(url: url, title: title) }
    }
    owner?.tabDidUpdate(self)
  }

  /// Pages often list a 16px icon before bigger ones, and the tab draws
  /// icons at 16pt (32px on Retina): fetch the candidates and keep the
  /// smallest one that's at least 32px, else the biggest.
  func browserView(_ view: GleaBrowserView, didChangeFaviconURLs faviconURLs: [String]) {
    let key = faviconURLs.joined(separator: " ")
    guard key != faviconURL else { return }
    faviconURL = key
    let urls = faviconURLs.prefix(6).compactMap(URL.init(string:))
    let downloads = isIncognito ? Tab.ephemeralSession : URLSession.shared
    Task { [weak self] in
      var images: [NSImage] = []
      await withTaskGroup(of: NSImage?.self) { group in
        for url in urls {
          group.addTask {
            guard let (data, _) = try? await downloads.data(from: url) else { return nil }
            return NSImage(data: data)
          }
        }
        for await image in group { if let image { images.append(image) } }
      }
      func pixels(_ image: NSImage) -> Int { image.representations.map(\.pixelsWide).max() ?? 0 }
      let best = images.filter { pixels($0) >= 32 }.min { pixels($0) < pixels($1) } ?? images.max { pixels($0) < pixels($1) }
      guard let self, let best, self.faviconURL == key else { return }
      self.favicon = best
      self.owner?.tabDidUpdate(self)
    }
  }

  func browserView(_ view: GleaBrowserView, didCommitNavigationToURL url: String) {
    if URL(string: url)?.host != URL(string: self.url)?.host {
      favicon = nil
      faviconURL = nil
    }
    let isNewPage = url.components(separatedBy: "#")[0] != self.url.components(separatedBy: "#")[0]
    self.url = url
    errorMessage = nil
    if (isNewPage || !hasRecordedVisit) && !isIncognito { HistoryStore.shared.recordVisit(url: url, title: view.title) }
    hasRecordedVisit = true
    owner?.tabDidUpdate(self)
  }

  func browserView(_ view: GleaBrowserView, didFailLoadWithError error: String, url: String) {
    errorMessage = error
    owner?.tab(self, didFailWithError: error, url: url)
  }

  /// A pinned tab stays on its site: clicking a link to another one opens a
  /// new tab instead.
  func browserView(_ view: GleaBrowserView, shouldNavigateToURL target: String, userGesture: Bool) -> Bool {
    guard isPinned, userGesture, let from = URL(string: url)?.host, let to = URL(string: target)?.host,
          target.hasPrefix("http") else { return true }
    func site(_ host: String) -> String { host.split(separator: ".").suffix(2).joined(separator: ".") }
    if site(from) == site(to) { return true }
    owner?.tab(self, requestsNewTab: target, background: false)
    return false
  }

  func browserView(_ view: GleaBrowserView, requestsNewTabWithURL url: String, background: Bool) {
    owner?.tab(self, requestsNewTab: url, background: background)
  }

  func browserView(_ view: GleaBrowserView, didReceiveMessage name: String, payload json: String) {
    let payload = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    if name == "audible" {
      guard let frame = payload["frame"] as? String else { return }
      let wasAudible = isAudible
      if payload["audible"] as? Bool == true { audibleFrames.insert(frame) } else { audibleFrames.remove(frame) }
      if isAudible != wasAudible {
        updateKeepsRunning()
        owner?.tabDidUpdate(self)
        SoundMonitor.shared.sourceDidChange()
      }
      return
    }
    owner?.tab(self, didReceiveMessage: name, payload: payload)
  }

  func browserView(_ view: GleaBrowserView, didChangeMediaAccessCamera camera: Bool, microphone: Bool) {
    guard camera != usesCamera || microphone != usesMicrophone else { return }
    usesCamera = camera
    usesMicrophone = microphone
    owner?.tabDidUpdate(self)
  }

  func browserView(_ view: GleaBrowserView, contextCommand command: GleaContextCommand, argument: String) {
    owner?.tab(self, contextCommand: command, argument: argument)
  }

  func browserView(_ view: GleaBrowserView, findResultCount count: Int, activeMatch active: Int) {
    owner?.tab(self, findResultCount: count, active: active)
  }

  func browserView(_ view: GleaBrowserView, didFinishDownloadAtPath path: String) {
    owner?.tab(self, didDownload: path)
  }

  func browserView(_ view: GleaBrowserView, requestsMediaAccessForOrigin origin: String, camera: Bool, microphone: Bool,
                   completion: @escaping (Bool) -> Void) {
    guard let owner else { return completion(false) }
    owner.tab(self, requestsMediaAccessFor: origin, camera: camera, microphone: microphone, completion: completion)
  }

  func browserViewDidChangeDevTools(_ view: GleaBrowserView) {
    owner?.tabDidUpdate(self)
  }

  func browserView(_ view: GleaBrowserView, didReceiveDevToolsMessage json: String) {
    view.delegateForwarder?.handler(json)
  }

  func browserView(_ view: GleaBrowserView, requestsDevToolsDock dock: GleaDevToolsDock) {
    devTools?.show(dock)
  }

  func browserViewRequestsDevToolsClose(_ view: GleaBrowserView) {
    devTools?.close()
  }

  func browserView(_ view: GleaBrowserView, requestsInspectElementAt point: NSPoint) {
    devTools?.show(GleaBrowserView.preferredDevToolsDock, inspecting: point)
  }

  func browserViewDidClose(_ view: GleaBrowserView) {
    owner?.tabDidClose(self)
  }
}

extension Tab: SoundSource {
  var isPlayingSound: Bool { isAudible }
  var isSoundMuted: Bool { isMuted }
  func setSoundMuted(_ muted: Bool) { setMuted(muted) }
}
