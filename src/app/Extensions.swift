import AppKit
import GleaBridge

/// An installed, enabled Chrome extension, read from the Chromium profile.
struct InstalledExtension {
  let id: String
  let name: String
  let icon: NSImage?
  /// Its toolbar popup, relative to the extension root (action.default_popup).
  let popup: String?
  let optionsPage: String?

  var popupURL: String? { popup.map { "chrome-extension://\(id)/\($0)" } }
  var optionsURL: String { optionsPage.map { "chrome-extension://\(id)/\($0)" } ?? "chrome://extensions/?id=\(id)" }
}

enum ExtensionStore {
  /// Extensions the user installed (Web Store or unpacked), enabled ones only.
  static func installed() -> [InstalledExtension] {
    let profile = URL(fileURLWithPath: GleaCEF.profilePath)
    var settings: [String: [String: Any]] = [:]
    // Chromium keeps them in "Secure Preferences" (and older builds in "Preferences").
    for file in ["Preferences", "Secure Preferences"] {
      guard let data = try? Data(contentsOf: profile.appendingPathComponent(file)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = (json["extensions"] as? [String: Any])?["settings"] as? [String: [String: Any]] else { continue }
      settings.merge(entries) { _, new in new }
    }
    var result: [InstalledExtension] = []
    for (id, entry) in settings {
      // Locations: 1 Web Store, 4 unpacked; 5 and 10 are Chromium's own components.
      guard let location = entry["location"] as? Int, [1, 2, 3, 4, 6, 8, 9].contains(location) else { continue }
      if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { continue }
      if let reasons = entry["disable_reasons"] as? Int, reasons != 0 { continue }
      if let state = entry["state"] as? Int, state == 0 { continue }
      guard let rawPath = entry["path"] as? String else { continue }
      let root = rawPath.hasPrefix("/") ? URL(fileURLWithPath: rawPath)
        : profile.appendingPathComponent("Extensions").appendingPathComponent(rawPath)
      guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      let action = (manifest["action"] ?? manifest["browser_action"] ?? manifest["page_action"]) as? [String: Any]
      let name = localized(manifest["name"] as? String ?? id, root: root, manifest: manifest)
      let options = (manifest["options_ui"] as? [String: Any])?["page"] as? String ?? manifest["options_page"] as? String
      result.append(InstalledExtension(id: id, name: name, icon: icon(manifest: manifest, action: action, root: root),
                                       popup: action?["default_popup"] as? String, optionsPage: options))
    }
    return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Resolves "__MSG_name__" from the extension's default locale.
  private static func localized(_ value: String, root: URL, manifest: [String: Any]) -> String {
    guard value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
    let key = String(value.dropFirst(6).dropLast(2))
    let locales = [Locale.current.identifier.replacingOccurrences(of: "-", with: "_"),
                   Locale.current.language.languageCode?.identifier ?? "en",
                   manifest["default_locale"] as? String ?? "en"]
    for locale in locales {
      let file = root.appendingPathComponent("_locales/\(locale)/messages.json")
      guard let data = try? Data(contentsOf: file),
            let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      let entry = messages.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value as? [String: Any]
      if let message = entry?["message"] as? String { return message }
    }
    return value
  }

  /// The icon closest to 32px: the toolbar icon if there is one.
  private static func icon(manifest: [String: Any], action: [String: Any]?, root: URL) -> NSImage? {
    var candidates: [String: String] = [:]
    if let icons = manifest["icons"] as? [String: String] { candidates.merge(icons) { a, _ in a } }
    if let icons = action?["default_icon"] as? [String: String] { candidates.merge(icons) { _, b in b } }
    if let single = action?["default_icon"] as? String { candidates["32"] = single }
    let best = candidates.min { abs((Int($0.key) ?? 0) - 32) < abs((Int($1.key) ?? 0) - 32) }
    guard let path = best?.value else { return nil }
    return NSImage(contentsOf: root.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path))
  }
}

/// Extensions pinned to the top bar, in pin order (saved beside the session).
enum ExtensionPins {
  private static let file = AppPaths.support.appendingPathComponent("pinned-extensions.json")

  static var ids: [String] {
    get {
      guard let data = try? Data(contentsOf: file) else { return [] }
      return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: file, options: .atomic) }
    }
  }

  static func isPinned(_ id: String) -> Bool { ids.contains(id) }

  static func toggle(_ id: String) {
    var list = ids
    if let index = list.firstIndex(of: id) { list.remove(at: index) } else { list.append(id) }
    ids = list
  }

  /// The pinned extensions still installed, in pin order.
  static func pinned(in installed: [InstalledExtension]) -> [InstalledExtension] {
    ids.compactMap { id in installed.first { $0.id == id } }
  }
}

/// The puzzle-piece dropdown: installed extensions, then "Manage Extensions".
final class ExtensionsMenu: OverlayView {
  var onChoose: ((PickerItem) -> Void)?
  /// The pin toggle of an extension's row.
  var onTogglePin: ((String) -> Void)?

  private let list = PickerList(rowHeight: 32)
  private let anchor: NSRect

  /// `anchor` is the puzzle button's rect in this view's (flipped) coordinates.
  init(extensions: [InstalledExtension], anchor: NSRect) {
    self.anchor = anchor
    super.init(frame: .zero)
    var items = extensions.map { ext in
      PickerItem(icon: "puzzlepiece.extension", title: ext.name, subtitle: "", action: .open(url: ext.id), image: ext.icon,
                 pinned: ExtensionPins.isPinned(ext.id))
    }
    if extensions.isEmpty {
      items.append(PickerItem(icon: "puzzlepiece.extension", title: "No extensions yet", subtitle: "",
                              action: .open(url: "https://chromewebstore.google.com/")))
    }
    items.append(PickerItem(icon: "gearshape", title: "Manage Extensions…", subtitle: "", action: .open(url: "chrome://extensions")))
    list.items = items
    list.select(0)
    list.onChoose = { [weak self] item in self?.onChoose?(item) }
    list.onTogglePin = { [weak self] index in
      guard let self, case .open(let id) = self.list.items[index].action else { return }
      self.onTogglePin?(id)
      self.list.items[index].pinned = ExtensionPins.isPinned(id)
    }
    list.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(list)
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
      list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
      list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
      list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }

  override func layout() {
    super.layout()
    let size = NSSize(width: 260, height: CGFloat(min(list.items.count, 10)) * list.rowHeight + 12)
    let x = min(max(12, anchor.maxX - size.width), bounds.width - size.width - 12)
    cardFrame = NSRect(origin: NSPoint(x: x, y: anchor.maxY + 6), size: size)
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 125: list.moveSelection(by: 1)       // down
    case 126: list.moveSelection(by: -1)      // up
    case 36, 76: if let item = list.selectedItem { onChoose?(item) }  // return
    case 53: onDismiss?()                     // escape
    default: super.keyDown(with: event)
    }
  }
}

/// An extension's toolbar popup: a card under the puzzle button holding the
/// popup page (a Chrome-style browser, so extension APIs work), sized to its
/// content like Chrome's. Clicking outside closes it.
final class ExtensionPopup: OverlayView, GleaBrowserViewDelegate {
  var onOpenTab: ((String, Bool) -> Void)?

  private let page: GleaBrowserView
  private let anchor: NSRect
  private var contentSize = NSSize(width: 200, height: 60)
  /// Shown once the page has loaded and its size is known (Chrome sizes
  /// popups to their content), so it opens at its size.
  private var revealed = false
  private var revealWork: DispatchWorkItem?
  private var sizeKnown = false
  /// Only for pages that never report a size.
  private static let maxWait: TimeInterval = 1

  private static let minimumSize = NSSize(width: 200, height: 60)
  private static let maximumSize = NSSize(width: 800, height: 600)

  // The popup is its own Chromium window (one Chrome-style browser per
  // window), so for Chrome its "current window" is the popup's, not the
  // page's. The page's window is the last focused one (the popup opens without
  // taking focus), so point "current window" queries at that. Then report the
  // page's natural size: Chrome sizes popups to their content.
  private static let popupScript = """
  (() => {
    // Extension APIs appear after this script first runs: try now, after
    // this task, and when the document turns interactive (before deferred
    // and module scripts run).
    let done = false;
    const patch = () => {
      const api = typeof chrome === 'object' && chrome;
      if (done || !api || !api.tabs || !api.tabs.query) return;
      done = true;
      const query = api.tabs.query.bind(api.tabs);
      const retarget = (info) => {
        if (!info || !info.currentWindow) return info;
        const copy = Object.assign({}, info, { lastFocusedWindow: true });
        delete copy.currentWindow;
        return copy;
      };
      try {
        Object.defineProperty(api.tabs, 'query', { configurable: true, writable: true,
          value: (info, callback) => callback ? query(retarget(info), callback) : query(retarget(info)) });
        if (api.windows && api.windows.getLastFocused) {
          Object.defineProperty(api.windows, 'getCurrent', { configurable: true, writable: true,
            value: api.windows.getLastFocused.bind(api.windows) });
        }
      } catch (e) {}
    };
    patch();
    queueMicrotask(patch);
    setTimeout(patch, 0);
    document.addEventListener('readystatechange', patch);
  })();
  """

  private static let sizeReporter = """
  (() => {
    const report = () => {
      const d = document.documentElement, b = document.body;
      if (!b) return;
      __gleaNative.post('size', JSON.stringify({ w: Math.max(d.scrollWidth, b.scrollWidth), h: Math.max(d.scrollHeight, b.scrollHeight) }));
    };
    addEventListener('load', () => {
      report();
      const observer = new ResizeObserver(report);
      observer.observe(document.documentElement);
      if (document.body) observer.observe(document.body);
    });
  })();
  """

  /// `anchor` is the puzzle button's rect in this view's (flipped) coordinates.
  init(url: String, anchor: NSRect) {
    self.anchor = anchor
    page = GleaBrowserView(url: url, contentScript: Self.popupScript + Self.sizeReporter)
    super.init(frame: .zero)
    page.delegate = self
    page.prefersChromeStyle = true
    page.chromeCornerRadius = 12
    page.pageBackgroundColor = Theme.background
    // Chrome's own popup sizing: the page's preferred size, not its
    // scrollWidth (which counts overflowing content, e.g. LastPass's tabs).
    page.enableAutoResize(withMinSize: Self.minimumSize, maxSize: Self.maximumSize)
    page.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(page)
    page.pinEdges(to: card)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let size = NSSize(width: min(max(contentSize.width, Self.minimumSize.width), Self.maximumSize.width),
                      height: min(max(contentSize.height, Self.minimumSize.height), Self.maximumSize.height))
    let x = min(max(12, anchor.maxX - size.width), bounds.width - size.width - 12)
    cardFrame = NSRect(origin: NSPoint(x: x, y: anchor.maxY + 6), size: size)
    // The page's window can appear after animateAppear(): keep it invisible.
    if !revealed { page.chromeWindow?.alphaValue = 0 }
  }

  override func removeFromSuperview() {
    revealWork?.cancel()
    page.close()
    super.removeFromSuperview()
  }

  // The page is its own window over the card: it can fade with the card,
  // not scale with it.
  override var appearScale: CGFloat { 1 }
  override var dismissScale: CGFloat { 1 }

  /// Waits (invisible, still rendering) for the page's final size first.
  override func animateAppear() {
    hideCardUntilAppear()
    page.chromeWindow?.alphaValue = 0
    scheduleReveal(after: Self.maxWait)
  }

  private func scheduleReveal(after delay: TimeInterval) {
    revealWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.reveal() }
    revealWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func reveal() {
    guard !revealed, !isDismissing else { return }
    revealed = true
    layoutSubtreeIfNeeded()
    showCard()
    super.animateAppear()
    fadePage(to: 1, duration: 0.08)
  }

  override func animateDismiss() {
    revealWork?.cancel()
    fadePage(to: 0, duration: 0.1)
    super.animateDismiss()
  }

  private func fadePage(to alpha: CGFloat, duration: TimeInterval) {
    guard let window = page.chromeWindow else { return }
    Motion.animate(duration, timing: Motion.easeOut) { window.animator().alphaValue = alpha }
  }

  func focus() { page.focusPage() }

  // MARK: GleaBrowserViewDelegate

  func browserView(_ view: GleaBrowserView, didAutoResizeTo size: NSSize) {
    usesAutoResize = true
    setContentSize(size)
  }

  private var usesAutoResize = false

  private func setContentSize(_ size: NSSize) {
    contentSize = size
    sizeKnown = true
    needsLayout = true
    revealIfReady()
  }

  func browserViewDidChangeState(_ view: GleaBrowserView) { revealIfReady() }

  /// While loading, the reported size is the blank page's.
  private func revealIfReady() {
    if !revealed, sizeKnown, !page.isLoading { reveal() }
  }

  func browserView(_ view: GleaBrowserView, didReceiveMessage name: String, payload json: String) {
    // The script's measure is only a fallback for when auto-resize is silent.
    guard name == "size", !usesAutoResize, let data = json.data(using: .utf8),
          let size = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
          let w = size["w"], let h = size["h"] else { return }
    setContentSize(NSSize(width: w, height: h))
  }

  func browserView(_ view: GleaBrowserView, requestsNewTabWithURL url: String, background: Bool) {
    onOpenTab?(url, background)
  }
}
