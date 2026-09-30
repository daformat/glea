import AppKit

enum AppPaths {
  static let support: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var dir = base.appendingPathComponent("Glea", isDirectory: true)
    if let override = ProcessInfo.processInfo.environment["GLEA_SUPPORT_DIR"] {
      dir = URL(fileURLWithPath: override, isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()
}

enum SearchEngine: String, CaseIterable {
  case google, duckDuckGo, kagi, bing

  var name: String {
    switch self {
    case .google: return "Google"
    case .duckDuckGo: return "DuckDuckGo"
    case .kagi: return "Kagi"
    case .bing: return "Bing"
    }
  }

  static var current: SearchEngine {
    get { SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "searchEngine") }
  }

  func searchURL(_ query: String) -> String {
    let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
    switch self {
    case .google: return "https://www.google.com/search?q=\(q)"
    case .duckDuckGo: return "https://duckduckgo.com/?q=\(q)"
    case .kagi: return "https://kagi.com/search?q=\(q)"
    case .bing: return "https://www.bing.com/search?q=\(q)"
    }
  }

  /// Fetches query suggestions (Google's endpoint works for every engine).
  static func suggestions(for query: String, completion: @escaping ([String]) -> Void) {
    guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)") else {
      completion([])
      return
    }
    URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 2)) { data, _, _ in
      var result: [String] = []
      if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count > 1,
         let list = json[1] as? [String] {
        result = list
      }
      DispatchQueue.main.async { completion(result) }
    }.resume()
  }
}

/// Visited pages, used by the omnibox. Stored as JSON in Application Support.
@MainActor
final class HistoryStore {
  static let shared = HistoryStore()

  struct Entry: Codable {
    var url: String
    var title: String
    var visits: Int
    var lastVisit: Date
  }

  private var entries: [String: Entry] = [:]
  private let file = AppPaths.support.appendingPathComponent("history.json")
  private var saveScheduled = false

  private init() {
    if let data = try? Data(contentsOf: file),
       let list = try? JSONDecoder().decode([Entry].self, from: data) {
      for entry in list { entries[entry.url] = entry }
    }
  }

  func recordVisit(url: String, title: String) {
    guard url.hasPrefix("http") else { return }
    var entry = entries[url] ?? Entry(url: url, title: title, visits: 0, lastVisit: Date())
    entry.visits += 1
    entry.lastVisit = Date()
    if !title.isEmpty { entry.title = title }
    entries[url] = entry
    scheduleSave()
  }

  func updateTitle(url: String, title: String) {
    guard !title.isEmpty, var entry = entries[url], entry.title != title else { return }
    entry.title = title
    entries[url] = entry
    scheduleSave()
  }

  private func score(_ e: Entry) -> Double {
    let days = max(0, -e.lastVisit.timeIntervalSinceNow / 86_400)
    return Double(e.visits) * (1 / (1 + days / 7))
  }

  func search(_ query: String, limit: Int = 5) -> [Entry] {
    let terms = query.lowercased().split(separator: " ").map(String.init)
    guard !terms.isEmpty else { return [] }
    return entries.values.filter { e in
      let haystack = (e.title + " " + e.url).lowercased()
      return terms.allSatisfy { haystack.contains($0) }
    }.sorted { score($0) > score($1) }.prefix(limit).map { $0 }
  }

  /// Inline completion for the omnibox (Beam, browsers): the visited address
  /// that best continues `typed`, ignoring the scheme and "www.". While the
  /// text is still a domain it completes the domain; after a "/", the path.
  /// Returns the text to append, the URL to open and its page's title.
  func completion(for typed: String) -> (suffix: String, url: String, title: String)? {
    // What's typed may start with a scheme or "www." too.
    var prefix = typed.lowercased()
    for start in ["https://", "http://"] where prefix.hasPrefix(start) { prefix.removeFirst(start.count) }
    if prefix.hasPrefix("www.") { prefix.removeFirst(4) }
    guard !prefix.isEmpty, !prefix.contains(" ") else { return nil }
    let completesPath = prefix.contains("/")
    var best: (text: String, url: String, score: Double)?
    var hostScores: [String: (score: Double, url: String, urlScore: Double)] = [:]
    for entry in entries.values {
      let bare = HistoryStore.bareAddress(entry.url)
      guard bare.lowercased().hasPrefix(prefix) else { continue }
      let s = score(entry)
      if completesPath {
        if best == nil || s > best!.score { best = (bare, entry.url, s) }
      } else {
        let host = String(bare.prefix { $0 != "/" })
        guard host.lowercased().hasPrefix(prefix) else { continue }
        var h = hostScores[host] ?? (0, entry.url, -1)
        h.score += s
        // The host's own page when visited, else its most visited page's scheme.
        let isRoot = bare == host || bare == host + "/"
        if isRoot && h.urlScore < .greatestFiniteMagnitude {
          h.url = entry.url
          h.urlScore = .greatestFiniteMagnitude
        } else if s > h.urlScore {
          h.url = (URL(string: entry.url)?.scheme ?? "https") + "://" + host
          h.urlScore = s
        }
        hostScores[host] = h
      }
    }
    if !completesPath, let (host, h) = hostScores.max(by: { $0.value.score < $1.value.score }) {
      best = (host, h.url, h.score)
    }
    guard let best, best.text.count > prefix.count else { return nil }
    // The title of that very page (a domain's own page only if visited).
    return (String(best.text.dropFirst(prefix.count)), best.url, entries[best.url]?.title ?? "")
  }

  /// "https://www.example.com/a" -> "example.com/a" (no trailing "/").
  static func bareAddress(_ url: String) -> String {
    var s = url
    for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
    if s.hasPrefix("www.") { s.removeFirst(4) }
    if s.hasSuffix("/") { s.removeLast() }
    return s
  }

  func recent(limit: Int) -> [Entry] {
    entries.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit).map { $0 }
  }

  private func scheduleSave() {
    guard !saveScheduled else { return }
    saveScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.save() }
  }

  func save() {
    saveScheduled = false
    // Keep the most useful 5000 entries.
    let list = entries.values.sorted { score($0) > score($1) }.prefix(5000)
    if let data = try? JSONEncoder().encode(Array(list)) { try? data.write(to: file, options: .atomic) }
  }
}

/// Open tabs, restored at launch.
struct Session: Codable {
  struct SavedTab: Codable {
    var url: String
    var title: String
    var pinned: Bool?
    var group: UUID?
  }

  struct SavedGroup: Codable {
    var id: UUID
    var title: String
    var color: Int
    var collapsed: Bool
  }

  /// A window besides the main one (⌘N on the web), restored at launch.
  struct SavedWindow: Codable {
    var tabs: [SavedTab]
    var activeIndex: Int?
    var groups: [SavedGroup]?
    /// Its frame on screen (NSStringFromRect).
    var frame: String?
  }

  // The main window's (as before other windows were saved).
  var tabs: [SavedTab]
  var activeIndex: Int?
  var groups: [SavedGroup]?
  /// The other windows, front to back.
  var windows: [SavedWindow]?

  private static let file = AppPaths.support.appendingPathComponent("session.json")

  static func load() -> Session? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(Session.self, from: data)
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) { try? data.write(to: Session.file, options: .atomic) }
  }
}

/// Small in-memory cache of favicons and note images.
@MainActor
final class ImageCache {
  static let shared = ImageCache()
  static let didLoad = Notification.Name("GleaImageDidLoad")

  private var images: [URL: NSImage] = [:]
  private var loading: Set<URL> = []
  private var failed: Set<URL> = []

  /// Returns the image if cached; otherwise starts loading it and posts
  /// `ImageCache.didLoad` when it arrives.
  func image(for url: URL) -> NSImage? {
    if let image = images[url] { return image }
    guard !loading.contains(url), !failed.contains(url) else { return nil }
    if url.isFileURL {
      if let image = NSImage(contentsOf: url) {
        images[url] = image
        return image
      }
      failed.insert(url)
      return nil
    }
    loading.insert(url)
    URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 20)) { data, _, _ in
      DispatchQueue.main.async {
        self.loading.remove(url)
        if let data, let image = NSImage(data: data), image.size.width > 0 {
          self.images[url] = image
          NotificationCenter.default.post(name: ImageCache.didLoad, object: url)
        } else {
          self.failed.insert(url)
        }
      }
    }.resume()
    return nil
  }
}
