import AppKit
import AVKit
import PDFKit
import UniformTypeIdentifiers
import GleaBridge

// Media blocks in notes: images, videos and embeds (YouTube, Spotify, X…),
// shown inline and collapsible, after hello-mat.com's media component.
//
// A line holding only an image (`![alt](src)`), a video file, or a link from
// a supported service becomes a block. Collapsed, it's one line: an icon (the
// picture itself, or the site's icon) and the title. Expanded, it shows the
// media. Embeds load in a Chromium view and have a loading state (a small box
// with the service's icon beating); local images and videos appear at once.

// MARK: - Providers

struct EmbedProvider {
  enum Sizing {
    /// Video-like: full width, height from the aspect ratio.
    case aspect(CGFloat)
    /// Fixed height (players, cards).
    case fixed(CGFloat)
    /// The page reports its height (tweets, posts).
    case dynamic
  }

  let name: String
  let symbol: String
  let pattern: NSRegularExpression
  let sizing: Sizing
  var maxWidth: CGFloat? = nil
  /// oEmbed endpoint for a URL (title, and html when there's no player URL).
  var oembed: ((String) -> String)? = nil
  /// A player URL built from the regex groups, used instead of oEmbed html.
  var player: ((String, [String]) -> String)? = nil

  private static func re(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
  }

  private static func q(_ url: String) -> String {
    url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
  }

  static let all: [EmbedProvider] = [
    EmbedProvider(
      name: "YouTube", symbol: "play.rectangle.fill",
      pattern: re("^https?://(?:www\\.|m\\.)?(?:youtube\\.com/(?:watch\\?(?:.*&)?v=|shorts/|embed/|live/)|youtu\\.be/)([\\w-]{11})"),
      sizing: .aspect(16 / 9),
      oembed: { "https://www.youtube.com/oembed?format=json&url=\(q($0))" },
      player: { _, g in "https://www.youtube-nocookie.com/embed/\(g[1])?rel=0&modestbranding=1" }),
    EmbedProvider(
      name: "Vimeo", symbol: "play.rectangle.fill",
      pattern: re("^https?://(?:www\\.|player\\.)?vimeo\\.com/(?:video/)?(\\d+)"),
      sizing: .aspect(16 / 9),
      oembed: { "https://vimeo.com/api/oembed.json?url=\(q($0))" },
      player: { _, g in "https://player.vimeo.com/video/\(g[1])?dnt=1" }),
    EmbedProvider(
      name: "Loom", symbol: "video.fill",
      pattern: re("^https?://(?:www\\.)?loom\\.com/(?:share|embed)/(\\w+)"),
      sizing: .aspect(16 / 9),
      oembed: { "https://www.loom.com/v1/oembed?url=\(q($0))" },
      player: { _, g in "https://www.loom.com/embed/\(g[1])" }),
    EmbedProvider(
      name: "TED", symbol: "person.wave.2.fill",
      pattern: re("^https?://(?:www\\.)?ted\\.com/talks/([\\w-]+)"),
      sizing: .aspect(16 / 9),
      oembed: { "https://www.ted.com/services/v1/oembed.json?url=\(q($0))" },
      player: { _, g in "https://embed.ted.com/talks/\(g[1])" }),
    EmbedProvider(
      name: "Spotify", symbol: "music.note",
      pattern: re("^https?://open\\.spotify\\.com/(?:intl-\\w+/)?(track|album|playlist|artist|show|episode)/(\\w+)"),
      sizing: .fixed(352),
      oembed: { "https://open.spotify.com/oembed?url=\(q($0))" },
      player: { _, g in "https://open.spotify.com/embed/\(g[1])/\(g[2])" }),
    EmbedProvider(
      name: "SoundCloud", symbol: "waveform",
      pattern: re("^https?://(?:www\\.|m\\.)?soundcloud\\.com/[\\w-]+/[\\w-]+"),
      sizing: .fixed(166),
      oembed: { "https://soundcloud.com/oembed?format=json&maxheight=166&url=\(q($0))" }),
    EmbedProvider(
      name: "Apple Music", symbol: "music.note",
      pattern: re("^https?://music\\.apple\\.com/(.+)"),
      sizing: .fixed(450),
      player: { url, g in
        "https://embed.music.apple.com/\(g[1])"
      }),
    EmbedProvider(
      name: "X", symbol: "bubble.left.fill",
      pattern: re("^https?://(?:www\\.|mobile\\.)?(?:twitter|x)\\.com/\\w+/status(?:es)?/\\d+"),
      sizing: .dynamic, maxWidth: 550,
      oembed: { "https://publish.x.com/oembed?dnt=true&url=\(q($0))" }),
    EmbedProvider(
      name: "Bluesky", symbol: "bubble.left.fill",
      pattern: re("^https?://bsky\\.app/profile/[^/]+/post/\\w+"),
      sizing: .dynamic, maxWidth: 600,
      oembed: { "https://embed.bsky.app/oembed?url=\(q($0))" }),
    EmbedProvider(
      name: "Reddit", symbol: "bubble.left.and.bubble.right.fill",
      pattern: re("^https?://(?:www\\.|old\\.)?reddit\\.com/r/\\w+/comments/\\w+"),
      sizing: .dynamic, maxWidth: 640,
      oembed: { "https://www.reddit.com/oembed?url=\(q($0))" }),
    EmbedProvider(
      name: "Instagram", symbol: "camera.fill",
      pattern: re("^https?://(?:www\\.)?instagram\\.com/(p|reel|tv)/([\\w-]+)"),
      sizing: .fixed(620), maxWidth: 480,
      player: { _, g in "https://www.instagram.com/\(g[1])/\(g[2])/embed/captioned/" }),
    EmbedProvider(
      name: "TikTok", symbol: "music.note.tv",
      pattern: re("^https?://(?:www\\.)?tiktok\\.com/@[\\w.-]+/video/(\\d+)"),
      sizing: .fixed(740), maxWidth: 340,
      oembed: { "https://www.tiktok.com/oembed?url=\(q($0))" },
      player: { _, g in "https://www.tiktok.com/embed/v2/\(g[1])" }),
    EmbedProvider(
      name: "Figma", symbol: "square.on.circle",
      pattern: re("^https?://(?:www\\.)?figma\\.com/(?:file|design|proto|board)/[\\w-]+"),
      sizing: .aspect(16 / 10),
      player: { url, _ in "https://www.figma.com/embed?embed_host=glea&url=\(q(url))" }),
    EmbedProvider(
      name: "CodePen", symbol: "chevron.left.forwardslash.chevron.right",
      pattern: re("^https?://codepen\\.io/([\\w-]+)/(?:pen|full)/(\\w+)"),
      sizing: .fixed(400),
      oembed: { "https://codepen.io/api/oembed?format=json&url=\(q($0))" },
      player: { _, g in "https://codepen.io/\(g[1])/embed/\(g[2])?default-tab=result" }),
    EmbedProvider(
      name: "GitHub Gist", symbol: "chevron.left.forwardslash.chevron.right",
      pattern: re("^https?://gist\\.github\\.com/([\\w-]+)/(\\w+)"),
      sizing: .dynamic,
      player: nil),
    EmbedProvider(
      name: "Flickr", symbol: "photo",
      pattern: re("^https?://(?:www\\.)?(?:flickr\\.com/photos|flic\\.kr/p)/\\S+"),
      sizing: .aspect(3 / 2),
      oembed: { "https://www.flickr.com/services/oembed?format=json&url=\(q($0))" }),
    EmbedProvider(
      name: "Giphy", symbol: "photo",
      pattern: re("^https?://(?:www\\.)?giphy\\.com/(?:gifs|embed)/(?:[\\w-]*-)?(\\w+)"),
      sizing: .aspect(4 / 3)),
  ]

  static func match(_ url: String) -> (EmbedProvider, [String])? {
    let range = NSRange(url.startIndex..., in: url)
    for provider in all {
      guard let m = provider.pattern.firstMatch(in: url, range: range) else { continue }
      let groups = (0..<m.numberOfRanges).map { i -> String in
        guard let r = Range(m.range(at: i), in: url) else { return "" }
        return String(url[r])
      }
      return (provider, groups)
    }
    return nil
  }
}

// MARK: - Descriptors (what a line shows)

final class MediaDescriptor: NSObject {
  enum Kind {
    case image(URL)
    case video(URL)
    case embed(URL, EmbedProvider, [String])
    /// A PDF (`![[paper.pdf]]`, `![](paper.pdf)` or a link on its own
    /// line), in a PDFKit view.
    case document(URL)
    /// Another note, or a section of it, shown in place (`![[Note#Heading]]`).
    case note(WikiTarget)
  }

  let key: String
  let kind: Kind
  let title: String?
  let indent: CGFloat
  /// The width it's asked to show at (`![[image.png|300]]`).
  let preferredWidth: CGFloat?

  init(key: String, kind: Kind, title: String?, indent: CGFloat, preferredWidth: CGFloat? = nil) {
    self.key = key
    self.kind = kind
    self.title = title
    self.indent = indent
    self.preferredWidth = preferredWidth
  }

  var isLocal: Bool {
    switch kind {
    case .image(let url), .video(let url), .document(let url): return url.isFileURL
    case .embed: return false
    case .note: return true
    }
  }

  var sourceURL: URL {
    switch kind {
    case .image(let url), .video(let url), .embed(let url, _, _), .document(let url): return url
    case .note(let target):
      let written = target.name + (target.anchor.map { "#" + $0 } ?? "")
      return URL(string: "glea-note:" + (written.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? written))
        ?? URL(string: "glea-note:")!
    }
  }

  static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

  /// The file types AVFoundation plays (audio and video).
  private static let playableTypes: Set<String> = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))

  /// A file (by its extension) that can be played: shown as a player.
  static func isPlayable(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if videoExtensions.contains(ext) { return true }
    guard !ext.isEmpty, !imageExtensions.contains(ext), let type = UTType(filenameExtension: ext) else { return false }
    return playableTypes.contains(type.identifier)
  }

  /// Sound only: a compact player.
  static func isAudio(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .audio) ?? false
  }

  var isAudio: Bool {
    if case .video(let url) = kind { return Self.isAudio(url) }
    return false
  }
  /// PDFs, shown in a PDFKit view.
  static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

  static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "avif", "svg"]

  private static let imageLine = try! NSRegularExpression(pattern: "^!\\[([^\\]\\n]*)\\]\\(([^)\\s]+)(?:\\s+\"([^\"]*)\")?\\)$")
  private static let videoLinkLine = try! NSRegularExpression(pattern: "^\\[([^\\]\\n]*)\\]\\((https?://[^)\\s]+)\\)$")
  private static let urlLine = try! NSRegularExpression(pattern: "^https?://\\S+$")
  /// `![[file or note]]`, with what follows "|": a size or a caption.
  private static let wikiEmbedLine = try! NSRegularExpression(pattern: "^!\\[\\[([^\\]\\n|]+)(?:\\|([^\\]\\n]*))?\\]\\]$")

  /// The media a line's content stands for, if it is a media line.
  @MainActor
  static func parse(_ content: String, baseDirectory: URL, indent: CGFloat, occurrence: Int) -> MediaDescriptor? {
    let text = content.trimmingCharacters(in: .whitespaces)
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    if let m = wikiEmbedLine.firstMatch(in: text, range: full) {
      return wikiEmbed(ns.substring(with: m.range(at: 1)),
                       option: m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil,
                       indent: indent, occurrence: occurrence)
    }
    func resolve(_ source: String) -> URL? {
      if source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("file://") { return URL(string: source) }
      let path = source.removingPercentEncoding ?? source
      return baseDirectory.appendingPathComponent(path).standardizedFileURL
    }
    if let m = imageLine.firstMatch(in: text, range: full) {
      let source = ns.substring(with: m.range(at: 2))
      guard let url = resolve(source) else { return nil }
      // (`![alt|300](…)` sets its width, like Obsidian.)
      let (alt, width) = splitWidth(ns.substring(with: m.range(at: 1)))
      let title = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : (alt.isEmpty ? nil : alt)
      let key = "\(source)#\(occurrence)"
      if isPlayable(url) {
        return MediaDescriptor(key: key, kind: .video(url), title: title == "Video" ? nil : title, indent: indent, preferredWidth: width)
      }
      if isPDF(url) { return MediaDescriptor(key: key, kind: .document(url), title: title, indent: indent, preferredWidth: width) }
      // An embed link written as an image.
      if let (provider, groups) = EmbedProvider.match(source) {
        return MediaDescriptor(key: key, kind: .embed(url, provider, groups), title: title, indent: indent)
      }
      return MediaDescriptor(key: key, kind: .image(url), title: title, indent: indent, preferredWidth: width)
    }
    // A line that is only a link to a video file (older captures) plays too.
    if let m = videoLinkLine.firstMatch(in: text, range: full) {
      let source = ns.substring(with: m.range(at: 2))
      if let url = URL(string: source), isPlayable(url) {
        let alt = ns.substring(with: m.range(at: 1))
        return MediaDescriptor(key: "\(source)#\(occurrence)", kind: .video(url), title: alt.isEmpty || alt == "Video" ? nil : alt, indent: indent)
      }
    }
    if urlLine.firstMatch(in: text, range: full) != nil, let url = URL(string: text) {
      let key = "\(text)#\(occurrence)"
      if let (provider, groups) = EmbedProvider.match(text) {
        return MediaDescriptor(key: key, kind: .embed(url, provider, groups), title: nil, indent: indent)
      }
      let ext = url.pathExtension.lowercased()
      if isPlayable(url) { return MediaDescriptor(key: key, kind: .video(url), title: nil, indent: indent) }
      if imageExtensions.contains(ext) { return MediaDescriptor(key: key, kind: .image(url), title: nil, indent: indent) }
      if isPDF(url) { return MediaDescriptor(key: key, kind: .document(url), title: nil, indent: indent) }
    }
    return nil
  }

  /// "alt|300" (or "alt|300x200"): the alt text, and the width.
  private static func splitWidth(_ alt: String) -> (String, CGFloat?) {
    guard let bar = alt.range(of: "\\|\\d+(x\\d+)?$", options: .regularExpression) else { return (alt, nil) }
    let number = alt[alt.index(after: bar.lowerBound)...].split(separator: "x")[0]
    return (String(alt[..<bar.lowerBound]), Double(number).map { CGFloat($0) })
  }

  private static let sizedWikiLine = try! NSRegularExpression(pattern: "^!\\[\\[([^\\]\\n|]+)(?:\\|(\\d+(?:x\\d+)?)?)?\\]\\]$")
  private static let sizedImageLine = try! NSRegularExpression(pattern: "^!\\[([^\\]\\n]*)\\]\\((.+)\\)$")

  /// The media line `content` showing its media `width` points wide (nil:
  /// as wide as it goes), in the notation that holds a size: `![[file|300]]`
  /// stays a wiki embed, and the rest becomes `![alt|300](source)`. Nil if
  /// it can't hold one (a wiki embed with a caption).
  static func line(_ content: String, sizedTo width: Int?) -> String? {
    let leading = String(content.prefix { $0 == " " || $0 == "\t" })
    let text = content.trimmingCharacters(in: .whitespaces)
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    let size = width.map { "|\($0)" } ?? ""
    if text.hasPrefix("![[") {
      guard let m = sizedWikiLine.firstMatch(in: text, range: full) else { return nil }
      return leading + "![[\(ns.substring(with: m.range(at: 1)))\(size)]]"
    }
    if let m = sizedImageLine.firstMatch(in: text, range: full) {
      let alt = splitWidth(ns.substring(with: m.range(at: 1))).0
      return leading + "![\(alt)\(size)](\(ns.substring(with: m.range(at: 2))))"
    }
    // A link on its own line (or one written as a link to a video).
    if let m = videoLinkLine.firstMatch(in: text, range: full) {
      return leading + "![\(splitWidth(ns.substring(with: m.range(at: 1))).0)\(size)](\(ns.substring(with: m.range(at: 2))))"
    }
    if urlLine.firstMatch(in: text, range: full) != nil { return leading + "![\(size)](\(text))" }
    return nil
  }

  /// `![[target|option]]`: a file from the notes folder (an image, a video
  /// or sound, a PDF), or a note. The option is a width ("300", "300x200")
  /// or, for a file, a caption.
  @MainActor
  private static func wikiEmbed(_ written: String, option: String?, indent: CGFloat, occurrence: Int) -> MediaDescriptor? {
    let target = WikiTarget(written)
    // Without its size or caption: resizing keeps the block (it takes the
    // new description, see MediaBlockView.adopt).
    let key = "![[\(written)]]#\(occurrence)"
    let ext = (target.name as NSString).pathExtension.lowercased()
    guard !ext.isEmpty, ext != "md" else {
      guard !target.name.isEmpty || target.anchor != nil else { return nil }
      return MediaDescriptor(key: key, kind: .note(target), title: nil, indent: indent)
    }
    let option = option?.trimmingCharacters(in: .whitespaces)
    let width = option.flatMap { $0.range(of: "^\\d+(x\\d+)?$", options: .regularExpression) != nil
      ? Double($0.split(separator: "x")[0]).map { CGFloat($0) } : nil }
    let caption = width == nil && option?.isEmpty == false ? option : nil
    // Not in the folder: an image still shows where it would be, missing.
    let url = NoteStore.shared.attachment(named: target.name)
      ?? NoteStore.shared.assetsDirectory.appendingPathComponent(target.name)
    if isPlayable(url) {
      return MediaDescriptor(key: key, kind: .video(url), title: caption, indent: indent, preferredWidth: width)
    }
    if isPDF(url) {
      return MediaDescriptor(key: key, kind: .document(url), title: caption, indent: indent, preferredWidth: width)
    }
    guard imageExtensions.contains(ext) else { return nil }
    return MediaDescriptor(key: key, kind: .image(url), title: caption, indent: indent, preferredWidth: width)
  }
}

// MARK: - Embed resolution

struct EmbedResolution {
  enum Target {
    case page(URL)
    case html(String)
    case image(URL)
  }

  var target: Target
  var title: String?
  var sizing: EmbedProvider.Sizing
}

@MainActor
enum EmbedService {
  private static var cache: [String: EmbedResolution] = [:]

  static func resolve(_ url: URL, provider: EmbedProvider, groups: [String], dark: Bool,
                      completion: @escaping (EmbedResolution?) -> Void) {
    let source = url.absoluteString
    let cacheKey = source + (dark ? "#dark" : "")
    if let cached = cache[cacheKey] {
      completion(cached)
      return
    }
    func finish(_ resolution: EmbedResolution?) {
      if let resolution { cache[cacheKey] = resolution }
      completion(resolution)
    }

    // Giphy: the animated GIF itself.
    if provider.name == "Giphy", groups.count > 1 {
      finish(EmbedResolution(target: .image(URL(string: "https://media.giphy.com/media/\(groups[1])/giphy.gif")!),
                             title: nil, sizing: provider.sizing))
      return
    }
    // Gists: their script renders the code.
    if provider.name == "GitHub Gist", groups.count > 2 {
      finish(EmbedResolution(target: .html("<script src=\"https://gist.github.com/\(groups[1])/\(groups[2]).js\"></script>"),
                             title: nil, sizing: .dynamic))
      return
    }

    guard let endpoint = provider.oembed?(source).appending(dark && provider.name == "X" ? "&theme=dark" : ""),
          let oembedURL = URL(string: endpoint) else {
      if let player = provider.player?(source, groups), let page = URL(string: player) {
        finish(EmbedResolution(target: .page(page), title: nil,
                               sizing: playerSizing(provider, source) ?? provider.sizing))
      } else {
        finish(nil)
      }
      return
    }
    URLSession.shared.dataTask(with: URLRequest(url: oembedURL, timeoutInterval: 12)) { data, _, _ in
      let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
      DispatchQueue.main.async {
        let title = json["title"] as? String
        // A player URL is more reliable than oEmbed html when there is one.
        if let player = provider.player?(source, groups), let page = URL(string: player) {
          finish(EmbedResolution(target: .page(page), title: title,
                                 sizing: playerSizing(provider, source) ?? sizing(provider, json)))
          return
        }
        if (json["type"] as? String) == "photo", let photo = (json["url"] as? String).flatMap(URL.init(string:)) {
          finish(EmbedResolution(target: .image(photo), title: title, sizing: sizing(provider, json)))
          return
        }
        guard let html = json["html"] as? String else {
          finish(nil)
          return
        }
        if let src = singleIframeSource(html), let page = URL(string: src) {
          finish(EmbedResolution(target: .page(page), title: title, sizing: sizing(provider, json)))
        } else {
          finish(EmbedResolution(target: .html(html), title: title, sizing: .dynamic))
        }
      }
    }.resume()
  }

  private static func number(_ value: Any?) -> CGFloat? {
    if let n = value as? NSNumber { return CGFloat(truncating: n) }
    if let s = value as? String, let d = Double(s) { return CGFloat(d) }
    return nil
  }

  /// Players whose height depends on what they show.
  private static func playerSizing(_ provider: EmbedProvider, _ source: String) -> EmbedProvider.Sizing? {
    // Apple Music: a song's player is compact, an album's or playlist's lists tracks.
    if provider.name == "Apple Music", source.contains("?i=") || source.contains("&i=") || source.contains("/song/") {
      return .fixed(175)
    }
    return nil
  }

  private static func sizing(_ provider: EmbedProvider, _ json: [String: Any]) -> EmbedProvider.Sizing {
    switch provider.sizing {
    case .aspect:
      if let w = number(json["width"]), let h = number(json["height"]), w > 0, h > 0 { return .aspect(w / h) }
      return provider.sizing
    default:
      return provider.sizing
    }
  }

  private static func singleIframeSource(_ html: String) -> String? {
    let lower = html.lowercased()
    guard lower.components(separatedBy: "<iframe").count == 2, !lower.contains("<script") else { return nil }
    let pattern = try! NSRegularExpression(pattern: "src=\"([^\"]+)\"")
    let range = NSRange(html.startIndex..., in: html)
    guard let m = pattern.firstMatch(in: html, range: range), let r = Range(m.range(at: 1), in: html) else { return nil }
    var src = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
    if src.hasPrefix("//") { src = "https:" + src }
    return src
  }

  /// Where generated pages are served (answered locally, see
  /// GleaBrowserView.servedHTML): embeds refuse to be framed by data: URLs.
  static let hostURL = "https://embed.glea.app/embed"

  /// A page hosting script-based embeds (tweets, posts, gists).
  static func hostPage(_ html: String, dark: Bool) -> String {
    let page = """
      <!doctype html><html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="\(dark ? "dark" : "light")">
      <style>
        html, body { margin: 0; padding: 0; background: \(dark ? "#1c1c1f" : "#fff"); overflow: hidden; }
        body { font: 14px -apple-system, sans-serif; }
        body > * { margin: 0 auto !important; }
        .twitter-tweet, .bluesky-embed, .reddit-embed-bq { margin: 0 auto !important; }
        /* Tweets are rounded cards on an opaque white iframe backdrop, which
           shows in their corners: clip the iframe to the card. */
        .twitter-tweet iframe { border-radius: 12px; }
      </style></head><body>\(html)</body></html>
      """
    return page
  }

  /// Reports the page height to the app (for dynamic embeds), and when the
  /// embed is rendered: its script has replaced the fallback blockquote with
  /// an iframe and sized it.
  static let sizeReporter = """
    (() => {
      let last = 0, ready = false;
      const isReady = () =>
        !document.querySelector('blockquote.twitter-tweet, blockquote.bluesky-embed, blockquote.reddit-embed-bq') &&
        // Visible iframes (not helpers) sized by the embed's script: a new
        // iframe first has the default height (150px), before the embed
        // reports its own.
        [...document.querySelectorAll('iframe')].filter(f => f.offsetWidth > 0)
          .every(f => f.offsetHeight > 20 && (f.style.height || f.hasAttribute('height')));
      const report = () => {
        const b = document.body;
        if (!b) return;
        // Embeds scroll themselves while the view is still small; the view
        // grows to fit, so always show the top.
        if (scrollY || scrollX) scrollTo(0, 0);
        const h = Math.ceil(Math.max(b.scrollHeight, b.getBoundingClientRect().height));
        if (h && Math.abs(h - last) > 1) { last = h; try { __gleaNative.post('embedSize', JSON.stringify({ height: h })); } catch (e) {} }
        if (!ready && isReady()) { ready = true; try { __gleaNative.post('embedReady', '{}'); } catch (e) {} }
      };
      const start = () => {
        new ResizeObserver(report).observe(document.body);
        new MutationObserver(report).observe(document.body, { childList: true, subtree: true, attributes: true });
        report();
      };
      if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);
      addEventListener('load', report);
      let n = 0;
      const t = setInterval(() => { report(); if (++n > 40) clearInterval(t); }, 250);
    })();
    """
}

// MARK: - Collapsed state

/// Remembers which blocks are collapsed, per note (outside the Markdown).
@MainActor
enum MediaState {
  private static let file = AppPaths.support.appendingPathComponent("media-state.json")
  private static var collapsed: Set<String> = {
    guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(list)
  }()

  static func isCollapsed(note: String, key: String) -> Bool { collapsed.contains(note + "|" + key) }

  static func set(_ value: Bool, note: String, key: String) {
    if value { collapsed.insert(note + "|" + key) } else { collapsed.remove(note + "|" + key) }
    if let data = try? JSONEncoder().encode(Array(collapsed)) { try? data.write(to: file, options: .atomic) }
  }
}

// MARK: - Easing

/// cubic-bezier(x1, y1, x2, y2), evaluated like CSS.
struct CubicBezier {
  let x1, y1, x2, y2: Double

  func callAsFunction(_ t: Double) -> Double {
    guard t > 0 else { return 0 }
    guard t < 1 else { return 1 }
    func sample(_ a1: Double, _ a2: Double, _ s: Double) -> Double {
      let inv = 1 - s
      return 3 * inv * inv * s * a1 + 3 * inv * s * s * a2 + s * s * s
    }
    // Solve x(s) = t by bisection, then return y(s).
    var lo = 0.0, hi = 1.0, s = t
    for _ in 0..<24 {
      let x = sample(x1, x2, s)
      if abs(x - t) < 0.0005 { break }
      if x < t { lo = s } else { hi = s }
      s = (lo + hi) / 2
    }
    return sample(y1, y2, s)
  }

  /// hello-mat's --custom-ease.
  static let media = CubicBezier(x1: 0.42, y1: 0, x2: 0.25, y2: 1)
  /// The cubic ease-out sections fold with.
  static let fold = CubicBezier(x1: 0.33, y1: 1, x2: 0.68, y2: 1)

  var timingFunction: CAMediaTimingFunction {
    CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
  }
}

// MARK: - Loading order

/// Media blocks load what's on screen first. Blocks on or near the visible
/// part of their page start right away; the others wait their turn, a few at
/// a time, nearest first (and move up as the page scrolls).
@MainActor
final class MediaLoadQueue {
  static let shared = MediaLoadQueue()

  private let waiting = NSHashTable<MediaBlockView>.weakObjects()
  /// Loads under way, by when they started (a load that never reports back
  /// gives its turn up after a while).
  private var active: [ObjectIdentifier: CFTimeInterval] = [:]
  private var scheduled = false
  private static let offscreenAtOnce = 2
  private static let patience: CFTimeInterval = 6

  func request(_ block: MediaBlockView) {
    waiting.add(block)
    schedule()
  }

  func finished(_ block: MediaBlockView) {
    waiting.remove(block)
    if active.removeValue(forKey: ObjectIdentifier(block)) != nil { schedule() }
  }

  /// Looks again soon (the page scrolled, a load finished).
  func schedule() {
    guard !scheduled, waiting.count > 0 else { return }
    scheduled = true
    // (After this turn: new blocks get their place in the page first.)
    DispatchQueue.main.async { [self] in
      scheduled = false
      pump()
    }
  }

  private func pump() {
    let now = CACurrentMediaTime()
    active = active.filter { now - $0.value < Self.patience }
    let candidates = waiting.allObjects
      .map { ($0, $0.distanceFromView) }
      .sorted { $0.1 < $1.1 }
    for (block, distance) in candidates {
      guard block.window != nil else {
        waiting.remove(block)
        continue
      }
      if distance > 0 && active.count >= Self.offscreenAtOnce { break }
      waiting.remove(block)
      active[ObjectIdentifier(block)] = now
      block.startQueuedLoad()
    }
    // Turns given up after a while free their place.
    if waiting.count > 0, !active.isEmpty {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.schedule() }
    }
  }
}

// MARK: - Block view

/// One media block. Its height drives the space reserved in the text.
final class MediaBlockView: NSView, GleaBrowserViewDelegate {
  static let rowHeight: CGFloat = 26
  /// Room right of the text column for the expand/collapse toggle.
  static let gutterWidth: CGFloat = 110
  private static let loadingSize = NSSize(width: 224, height: 56)

  private(set) var descriptor: MediaDescriptor
  let noteID: String
  /// The notes it's in, outermost first (see MarkdownEditorView.embedChain).
  let embedChain: [String]
  /// The reserved height changed: animating from the old one (given), or
  /// at once.
  var onHeightChange: ((_ animatedFrom: CGFloat?) -> Void)?
  var onOpenURL: ((URL) -> Void)?
  /// Dragged to a new width (nil: as wide as it goes), to write in its line.
  var onResize: ((Int?) -> Void)?
  /// Whether its line can hold a width (see `MediaDescriptor.line(_:sizedTo:)`).
  var canResize = false { didSet { updateHandle(animated: false) } }

  /// The height the text reserves for this block (animated).
  private(set) var blockHeight: CGFloat = rowHeight

  private var collapsed: Bool
  private var loaded = false
  private var naturalSize: NSSize?
  private var dynamicHeight: CGFloat?
  private var resolution: EmbedResolution?
  /// The appearance a themed embed page (tweets, posts) was loaded in.
  private var contentDark: Bool?
  /// The embed reloading in a new appearance, behind the current one until
  /// it's ready (so the block keeps its size), with its reported height.
  private var pending: GleaBrowserView?
  private var pendingHeight: CGFloat?
  private var pendingReady = false
  private var pendingSwap: DispatchWorkItem?
  private var titleText: String?

  private let row = NSView()
  private let rowIcon = NSImageView()
  private let rowTitle = NSTextField.label("", size: 14, color: Theme.secondaryText)
  /// Flipped: content is pinned top-left, so it's revealed (and hidden)
  /// from that corner as the block expands and collapses.
  private let wrapper = FlippedView()
  private let placeholder = PassthroughImageView()
  private var content: NSView?
  private let toggle = MediaToggleButton()
  /// Right of the media, halfway down: drags its width (images, videos, PDFs).
  private let handle = MediaResizeHandle()
  /// Its handle is being dragged: the text below follows at once.
  var isResizing: Bool { handle.isDragging }
  /// The width while dragging, and until its line says the same.
  private var draggedWidth: CGFloat?
  private var dragStartWidth: CGFloat = 0
  /// Over the media while its line is in the note's selection.
  private let selectionTint = PassthroughView()
  private var tracking: NSTrackingArea?

  private var wrapperFrame = NSRect.zero
  private var sizeObservation: NSKeyValueObservation?
  // Sound: the embed's frames playing it, or the video file playing.
  private var audibleFrames: Set<String> = []
  private var playerPlaying = false
  private var soundMuted = false
  private var playbackObservation: NSKeyValueObservation?
  private var statusObservation: NSKeyValueObservation?
  /// The running animation follows the content resizing itself (a post's
  /// "Read more"): the media keeps its size and the wrapper reveals or hides
  /// its bottom, instead of scaling it like expanding and collapsing do.
  private var resizesWithContent = false
  private var rowGeneration = 0

  var availableWidth: CGFloat = 600 {
    didSet { if abs(availableWidth - oldValue) > 0.5 { relayout(animated: false) } }
  }

  init(descriptor: MediaDescriptor, noteID: String, embedChain: [String] = []) {
    self.descriptor = descriptor
    self.noteID = noteID
    self.embedChain = embedChain
    collapsed = MediaState.isCollapsed(note: noteID, key: descriptor.key)
    titleText = descriptor.title
    super.init(frame: .zero)
    SoundMonitor.shared.register(self)
    wantsLayer = true
    // A collapsing block's media shrinks past its new, smaller frame.
    if #available(macOS 14, *) { clipsToBounds = false }
    layer?.masksToBounds = false

    rowIcon.imageScaling = .scaleProportionallyUpOrDown
    rowIcon.wantsLayer = true
    rowIcon.layer?.cornerRadius = 3
    rowIcon.layer?.masksToBounds = true
    let iconButton = ClickableView { [weak self] in self?.setCollapsed(!(self?.collapsed ?? true)) }
    iconButton.addSubview(rowIcon)
    row.addSubview(iconButton)
    rowTitle.translatesAutoresizingMaskIntoConstraints = true
    let titleButton = ClickableView { [weak self] in
      guard let self else { return }
      self.onOpenURL?(self.descriptor.sourceURL)
    }
    titleButton.addSubview(rowTitle)
    row.addSubview(titleButton)
    addSubview(row)

    wrapper.wantsLayer = true
    wrapper.layer?.cornerRadius = 6
    wrapper.layer?.cornerCurve = .continuous
    wrapper.layer?.masksToBounds = true
    placeholder.imageScaling = .scaleProportionallyUpOrDown
    placeholder.contentTintColor = Theme.tertiaryText
    placeholder.wantsLayer = true
    wrapper.addSubview(placeholder)
    addSubview(wrapper)

    selectionTint.wantsLayer = true
    selectionTint.layer?.cornerRadius = 6
    selectionTint.layer?.cornerCurve = .continuous
    selectionTint.alphaValue = 0
    addSubview(selectionTint)

    toggle.onClick = { [weak self] in self?.setCollapsed(!(self?.collapsed ?? true)) }
    toggle.collapsed = collapsed
    toggle.alphaValue = 0
    addSubview(toggle)

    handle.onDragBegan = { [weak self] in
      guard let self else { return }
      self.dragStartWidth = self.wrapperFrame.width
    }
    handle.onDrag = { [weak self] dx in
      guard let self else { return }
      self.draggedWidth = min(max(MediaBlockView.minimumWidth, self.dragStartWidth + dx), self.maximumWidth)
      // Follows the pointer at once, like the text below it.
      self.relayout(animated: false)
    }
    handle.onDragEnded = { [weak self] in
      guard let self, let width = self.draggedWidth else { return }
      let rounded = Int(width.rounded())
      self.onResize?(CGFloat(rounded) >= self.maximumWidth - 0.5 ? nil : rounded)
      self.updateHandle(animated: true)
    }
    addSubview(handle)

    configureIcon()
    updateTitle()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private var resizeObserver: NSObjectProtocol?
  private var scrollObserver: NSObjectProtocol?
  private var activeObservers: [NSObjectProtocol] = []

  /// For automated checks: the toggle shown, its label animating in or out
  /// (logging what's on screen every 50ms).
  func debugToggleLabel(_ shows: Bool) {
    toggle.alphaValue = 1
    // (No relayout after: the page's own width would decide again.)
    toggle.setShowsLabel(shows, animated: true)
    for step in 0..<10 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.05) { [weak self] in
        guard let self else { return }
        NSLog("Glea label t=%.2f %@ toggleWidth=%.0f", Double(step) * 0.05, self.toggle.debugLabelState, self.toggle.frame.width)
      }
    }
  }

  private var focusObservation: NSKeyValueObservation?

  /// Its line is in the note's selection: it shows selected, tinted like
  /// selected text.
  /// (`emphasized`: the note has the focus, so the selection is colored, not gray.)
  func setSelected(_ selected: Bool, emphasized: Bool) {
    let color = emphasized ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
    selectionTint.layer?.backgroundColor = resolvedCGColor(color.withAlphaComponent(0.5))
    guard selected != isSelected else { return }
    isSelected = selected
    needsLayout = true
    // At once, like the text's selection as it's dragged.
    Motion.withoutAnimation { selectionTint.alphaValue = selected ? 1 : 0 }
  }

  private var isSelected = false

  /// Whether `view` is in an embed that wasn't just clicked.
  static func takesFocusUnasked(_ view: NSView) -> Bool {
    var block: MediaBlockView?
    var current: NSView? = view.superview
    while let next = current, block == nil {
      block = next as? MediaBlockView
      current = next.superview
    }
    guard let block, view.isDescendant(of: block.wrapper) else { return false }
    return !block.wasJustClicked
  }

  private var wasJustClicked: Bool {
    guard let event = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
          event.window === window else { return false }
    return bounds.contains(convert(event.locationInWindow, from: nil))
  }

  /// An embedded page can take the keyboard focus on its own as it loads
  /// (autofocus, scripts): the focus goes back where it was (typing in the
  /// note, ⌘A) unless the embed was clicked.
  private func guardFocus() {
    focusObservation = window?.observe(\.firstResponder, options: [.old, .new]) { [weak self] window, change in
      MainActor.assumeIsolated {
        guard let self, let taken = change.newValue as? NSView, taken.isDescendant(of: self.wrapper), !self.wasJustClicked else { return }
        let previous = change.oldValue ?? nil
        DispatchQueue.main.async {
          guard window.firstResponder === taken else { return }
          if let previous, (previous as? NSView)?.window === window || previous === window {
            window.makeFirstResponder(previous)
          } else {
            window.makeFirstResponder(nil)
          }
        }
      }
    }
  }

  /// Whether the window is looking for a scroll event's view.
  static var hitTestingScroll: Bool { NSApp.currentEvent?.type == .scrollWheel || debugScrollHitTest }
  /// For automated checks: hit tests as if for a scroll.
  static var debugScrollHitTest = false

  /// A PDF scrolls its pages once clicked, until a click anywhere else;
  /// before that, and always with the pointer outside it, the wheel
  /// scrolls the note.
  private var scrollsItself = false
  private var clickMonitor: Any?

  private func watchClicks() {
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    guard window != nil, case .document = descriptor.kind else { return }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.scrollsItself = event.window === self.window && self.loaded && !self.collapsed
          && self.wrapperFrame.contains(self.convert(event.locationInWindow, from: nil))
      }
      return event
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guardFocus()
    watchClicks()
    // The toggle's label fits or not as the window resizes.
    if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    resizeObserver = window.map {
      NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: $0, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.needsLayout = true }
      }
    }
    // The pointer isn't tracked while Glea is in the background: no hover
    // then, and on coming back, wherever the pointer now is.
    for observer in activeObservers { NotificationCenter.default.removeObserver(observer) }
    activeObservers = []
    if window != nil {
      activeObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.hovering = false }
      })
      activeObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncHoverWithPointer() }
      })
    }
    // Scrolled out from under the pointer, its toggle goes (and comes back).
    if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    scrollObserver = nil
    if window != nil, let clip = enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.syncHoverWithPointer()
          MediaLoadQueue.shared.schedule()
        }
      }
    }
    if window != nil {
      // Collapsed too: the row shows the real title, and the media is ready
      // when expanded.
      if content == nil { loadContent() }
      relayout(animated: false)
    } else {
      unloadContent()
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    wrapper.layer?.backgroundColor = resolvedCGColor(Theme.codeBackground)
    // Themed embeds reload in the new appearance (once the app has it).
    DispatchQueue.main.async { [weak self] in self?.reloadForAppearance() }
  }

  /// Loads a themed embed again in the current appearance. The current one
  /// stays until the new one is ready, so the block doesn't resize.
  private func reloadForAppearance() {
    let dark = isDark
    guard let contentDark, contentDark != dark, let current = content as? GleaBrowserView,
          case .embed(let url, let provider, let groups) = descriptor.kind else { return }
    guard loaded else {
      unloadContent()
      loadContent()
      return
    }
    self.contentDark = dark
    EmbedService.resolve(url, provider: provider, groups: groups, dark: dark) { [weak self] resolution in
      guard let self, self.content === current, self.contentDark == dark,
            case .html(let html)? = resolution?.target else { return }
      self.discardPending()
      let view = GleaBrowserView(url: EmbedService.hostURL, contentScript: EmbedService.sizeReporter)
      view.audioMuted = self.soundMuted
      view.servedHTML = EmbedService.hostPage(html, dark: dark)
      view.delegate = self
      view.referrerOverride = "https://glea.app/"
      view.pageBackgroundColor = self.pageBackground
      view.wantsLayer = true
      view.alphaValue = 0
      view.frame = NSRect(origin: .zero, size: self.targetMediaSize())
      self.wrapper.addSubview(view, positioned: .below, relativeTo: current)
      self.pending = view
      // Whatever happens, don't keep the old theme forever.
      self.schedulePendingSwap(after: 6)
    }
  }

  /// Swaps in the reloaded embed once it's rendered: right away when it's as
  /// tall as the one it replaces (the same post in another theme), otherwise
  /// once its height settles.
  private func schedulePendingSwapIfReady() {
    guard pendingReady, let pendingHeight else { return }
    if let dynamicHeight, abs(pendingHeight - dynamicHeight) <= 2 {
      schedulePendingSwap(after: 0.15)
    } else {
      schedulePendingSwap(after: 0.8)
    }
  }

  private func schedulePendingSwap(after delay: TimeInterval) {
    pendingSwap?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.swapPending() }
    pendingSwap = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func swapPending() {
    guard let pending else { return }
    pendingSwap?.cancel()
    pendingSwap = nil
    if let old = content as? GleaBrowserView { old.close() }
    content?.removeFromSuperview()
    content = pending
    self.pending = nil
    if let pendingHeight { dynamicHeight = pendingHeight }
    pendingHeight = nil
    pendingReady = false
    pending.alphaValue = 1
    relayout(animated: true, followingContent: true)
  }

  private func discardPending() {
    pendingSwap?.cancel()
    pendingSwap = nil
    pending?.close()
    pending?.removeFromSuperview()
    pending = nil
    pendingHeight = nil
    pendingReady = false
  }

  // MARK: Title and icon

  private var displayTitle: String {
    if let titleText, !titleText.isEmpty { return titleText }
    switch descriptor.kind {
    case .embed(let url, let provider, _):
      if resolution == nil && !loaded { return "Loading \(provider.name)…" }
      // No title from the service (e.g. Instagram): name the service.
      let kind = url.path.contains("/reel/") ? "reel" : url.path.contains("/status") || url.path.contains("/post/") ? "post" : ""
      return kind.isEmpty ? provider.name : "\(provider.name) \(kind)"
    case .image(let url), .video(let url), .document(let url):
      if !url.isFileURL && !loaded { return "Loading \(url.host ?? "media")…" }
      return url.lastPathComponent
    case .note(let target):
      let name = target.name.isEmpty ? "" : WikiTarget.noteName(target.name)
      guard let anchor = target.heading ?? target.anchor else { return name }
      return name.isEmpty ? anchor : "\(name) › \(anchor)"
    }
  }

  private func updateTitle() {
    let title = NSMutableAttributedString(string: displayTitle, attributes: [
      .font: Theme.bodyFont, .foregroundColor: Theme.text,
      .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Theme.tertiaryText,
    ])
    title.append(NSAttributedString(string: " ↗", attributes: [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.tertiaryText, .baselineOffset: 3,
    ]))
    rowTitle.attributedStringValue = title
    needsLayout = true
  }

  private func configureIcon() {
    switch descriptor.kind {
    case .image(let url):
      if url.isFileURL, let image = NSImage(contentsOf: url) {
        rowIcon.image = image
        placeholder.image = image
      } else {
        rowIcon.image = Theme.symbol("photo", size: 12)
      }
      placeholder.image = Theme.symbol("photo", size: 22, weight: .regular)
    case .video:
      let symbol = descriptor.isAudio ? "waveform" : "film"
      rowIcon.image = Theme.symbol(symbol, size: 12)
      rowIcon.contentTintColor = Theme.secondaryText
      placeholder.image = Theme.symbol(symbol, size: 22, weight: .regular)
    case .document, .note:
      let symbol = { if case .document = descriptor.kind { return "doc.richtext" } else { return "doc.text" } }()
      rowIcon.image = Theme.symbol(symbol, size: 12)
      rowIcon.contentTintColor = Theme.secondaryText
      placeholder.image = Theme.symbol(symbol, size: 22, weight: .regular)
    case .embed(let url, let provider, _):
      rowIcon.image = Theme.symbol(provider.symbol, size: 12)
      rowIcon.contentTintColor = Theme.secondaryText
      placeholder.image = Theme.symbol(provider.symbol, size: 24, weight: .regular)
      // The site's own icon, when it has one.
      if let host = url.host, let favicon = URL(string: "https://\(host)/favicon.ico") {
        URLSession.shared.dataTask(with: favicon) { [weak self] data, _, _ in
          guard let data, let image = NSImage(data: data), image.size.width > 0 else { return }
          DispatchQueue.main.async {
            self?.rowIcon.image = image
            self?.rowIcon.contentTintColor = nil
          }
        }.resume()
      }
    }
  }

  // MARK: Loading content

  /// From the app: a block may not know its own appearance yet when it loads.
  private var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

  /// Loads now when it's at hand (a local or cached image), otherwise when
  /// its turn comes (see MediaLoadQueue), showing that it's loading.
  private func loadContent() {
    switch descriptor.kind {
    case .image(let url) where url.isFileURL || ImageCache.shared.image(for: url) != nil:
      performLoad()
    case .video(let url) where url.isFileURL:
      performLoad()
    case .note:
      performLoad()
    default:
      if !waitingToLoad { startLoading() }
      waitingToLoad = true
      MediaLoadQueue.shared.request(self)
    }
  }

  private var waitingToLoad = false

  func startQueuedLoad() {
    guard waitingToLoad, content == nil, window != nil else { return }
    waitingToLoad = false
    performLoad()
  }

  /// How far it is from the visible part of its page: 0 on screen or close
  /// to it.
  var distanceFromView: CGFloat {
    guard !isHiddenOrHasHiddenAncestor, frame.minX > -50_000 else { return .greatestFiniteMagnitude }
    guard let clip = enclosingScrollView?.contentView else { return 0 }
    let visible = clip.convert(clip.bounds, to: nil).insetBy(dx: 0, dy: -clip.bounds.height / 2)
    let rect = convert(bounds, to: nil)
    if rect.maxY >= visible.minY && rect.minY <= visible.maxY { return 0 }
    return rect.minY > visible.maxY ? rect.minY - visible.maxY : visible.minY - rect.maxY
  }

  private func performLoad() {
    switch descriptor.kind {
    case .image(let url):
      if url.isFileURL {
        if let image = NSImage(contentsOf: url) { showImage(image, immediately: true) }
      } else if let cached = ImageCache.shared.image(for: url) {
        showImage(cached, immediately: true)
      } else {
        startLoading()
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
          let image = data.flatMap { NSImage(data: $0) }
          DispatchQueue.main.async { if let image { self?.showImage(image, immediately: false) } }
        }.resume()
      }
    case .video(let url):
      let player = AVPlayer(url: url)
      player.isMuted = soundMuted
      playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
        let playing = player.timeControlStatus == .playing && player.volume > 0
        DispatchQueue.main.async {
          guard let self, playing != self.playerPlaying else { return }
          self.playerPlaying = playing
          SoundMonitor.shared.sourceDidChange()
        }
      }
      let view: NSView
      if descriptor.isAudio {
        // Sound only: the app's own compact player (see-through: no
        // loading icon behind it).
        view = AudioPlayerView(player: player)
        if url.isFileURL { placeholder.isHidden = true }
      } else {
        let video = AVPlayerView()
        video.player = player
        video.controlsStyle = .floating
        video.videoGravity = .resizeAspect
        view = video
      }
      install(view)
      // 16:9 until the player knows the real size. A local file has no
      // loading state; a remote one pulses like other media until it's ready.
      naturalSize = NSSize(width: 16, height: 9)
      if url.isFileURL {
        loaded = true
        relayout(animated: false)
      } else {
        view.alphaValue = 0
        startLoading()
      }
      sizeObservation = player.currentItem?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
        let size = item.presentationSize
        guard size.width > 0 else { return }
        DispatchQueue.main.async {
          guard let self else { return }
          self.naturalSize = size
          if self.loaded { self.relayout(animated: true) } else { self.finishLoading(immediately: false) }
        }
      }
      let audio = descriptor.isAudio
      statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
        // Sound has no picture size to wait for: ready is loaded.
        if audio, item.status == .readyToPlay {
          DispatchQueue.main.async {
            guard let self, !self.loaded else { return }
            self.finishLoading(immediately: false)
          }
          return
        }
        guard item.status == .failed else { return }
        DispatchQueue.main.async {
          self?.placeholder.layer?.removeAnimation(forKey: "pulse")
          self?.placeholder.image = Theme.symbol("exclamationmark.triangle", size: 22, weight: .regular)
          if let self { MediaLoadQueue.shared.finished(self) }
        }
      }
    case .document(let url):
      if url.isFileURL {
        if let document = PDFDocument(url: url) { showPDF(document, immediately: true) } else { showFailure() }
      } else {
        startLoading()
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
          DispatchQueue.main.async {
            if let document = data.flatMap(PDFDocument.init(data:)) { self?.showPDF(document, immediately: false) } else { self?.showFailure() }
          }
        }.resume()
      }
    case .note(let target):
      let view = NoteEmbedView(target: target, host: NoteRef(id: noteID), chain: embedChain)
      view.onOpenLink = { [weak self] url in self?.onOpenURL?(url) }
      view.onContentChange = { [weak self] in
        guard let self, self.loaded else { return }
        self.relayout(animated: true, followingContent: true)
      }
      install(view)
      finishLoading(immediately: true)
    case .embed(let url, let provider, let groups):
      startLoading()
      EmbedService.resolve(url, provider: provider, groups: groups, dark: isDark) { [weak self] resolution in
        guard let self else { return }
        guard let resolution else {
          self.placeholder.image = Theme.symbol("exclamationmark.triangle", size: 22, weight: .regular)
          MediaLoadQueue.shared.finished(self)
          return
        }
        self.resolution = resolution
        if let title = resolution.title, self.titleText == nil { self.titleText = title }
        self.updateTitle()
        guard self.window != nil else { return }
        switch resolution.target {
        case .image(let image):
          URLSession.shared.dataTask(with: image) { [weak self] data, _, _ in
            let picture = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { if let picture { self?.showImage(picture, immediately: false) } }
          }.resume()
        case .page(let page):
          self.showBrowser(page.absoluteString, script: nil)
        case .html(let html):
          self.contentDark = self.isDark
          self.showBrowser(EmbedService.hostURL, served: EmbedService.hostPage(html, dark: self.isDark),
                           script: EmbedService.sizeReporter)
        }
      }
    }
  }

  /// The player of a video or sound file.
  private var contentPlayer: AVPlayer? {
    (content as? AVPlayerView)?.player ?? (content as? AudioPlayerView)?.player
  }

  private func install(_ view: NSView) {
    content?.removeFromSuperview()
    content = view
    view.wantsLayer = true
    wrapper.addSubview(view, positioned: .below, relativeTo: nil)
  }

  private func showImage(_ image: NSImage, immediately: Bool) {
    let view = NSImageView(image: image)
    view.imageScaling = .scaleProportionallyUpOrDown
    view.animates = true
    install(view)
    naturalSize = image.size
    if descriptor.isLocal { rowIcon.image = image }
    finishLoading(immediately: immediately)
  }

  private func showPDF(_ document: PDFDocument, immediately: Bool) {
    let view = PDFEmbedView(document: document)
    view.onPassScroll = { [weak self] event in self?.enclosingScrollView?.scrollWheel(with: event) }
    view.frame = NSRect(origin: .zero, size: targetMediaSize())
    install(view)
    finishLoading(immediately: immediately)
  }

  private func showFailure() {
    placeholder.layer?.removeAnimation(forKey: "pulse")
    placeholder.image = Theme.symbol("exclamationmark.triangle", size: 22, weight: .regular)
    MediaLoadQueue.shared.finished(self)
  }

  private func showBrowser(_ url: String, served html: String? = nil, script: String?) {
    let view = GleaBrowserView(url: url, contentScript: script)
    view.audioMuted = soundMuted
    view.servedHTML = html
    view.delegate = self
    view.referrerOverride = "https://glea.app/"
    view.pageBackgroundColor = pageBackground
    view.alphaValue = 0
    view.frame = NSRect(origin: .zero, size: targetMediaSize())
    install(view)
  }

  private var pageBackground: NSColor {
    isDark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : .white
  }

  private func unloadContent() {
    waitingToLoad = false
    MediaLoadQueue.shared.finished(self)
    discardPending()
    playbackObservation = nil
    if isPlayingSound {
      audibleFrames = []
      playerPlaying = false
      SoundMonitor.shared.sourceDidChange()
    }
    if let browser = content as? GleaBrowserView { browser.close() }
    contentPlayer?.pause()
    content?.removeFromSuperview()
    content = nil
    loaded = false
  }

  private func startLoading() {
    // Already showing it (it waited its turn to load): it carries on.
    if !loaded, placeholder.layer?.animation(forKey: "pulse") != nil { return }
    loaded = false
    placeholder.isHidden = false
    placeholder.alphaValue = 0.6
    updateTitle()
    relayout(animated: !collapsed)
    // After layout: the pulse scales around the icon's center (its layer is
    // anchored at a corner).
    let pulse = CAKeyframeAnimation(keyPath: "transform")
    pulse.values = [1, 1.12, 1, 1.1, 1].map { NSValue(caTransform3D: placeholder.centeredScale($0)) }
    pulse.keyTimes = [0, 0.19, 0.375, 0.56, 1]
    pulse.duration = 1.6
    pulse.repeatCount = .infinity
    placeholder.layer?.add(pulse, forKey: "pulse")
  }

  private func finishLoading(immediately: Bool) {
    MediaLoadQueue.shared.finished(self)
    placeholder.layer?.removeAnimation(forKey: "pulse")
    loaded = true
    updateHandle(animated: false)
    placeholder.alphaValue = 0
    placeholder.isHidden = true
    updateTitle()
    relayout(animated: !immediately)
    guard let content else { return }
    if immediately {
      content.alphaValue = 1
    } else {
      content.alphaValue = 1
      content.fadeIn(0.3)
    }
  }

  // MARK: Browser delegate

  /// Script embeds (tweets, posts) show once rendered, not on page load:
  /// before that they're plain text.
  private var waitsForRender: Bool {
    if case .html? = resolution?.target { return true }
    return false
  }

  func browserViewDidChangeState(_ view: GleaBrowserView) {
    guard view === content, !loaded, !view.isLoading, view.url != "about:blank" else { return }
    // A script embed that never renders (offline, blocked) shows anyway.
    DispatchQueue.main.asyncAfter(deadline: .now() + (waitsForRender ? 8 : 0.25)) { [weak self] in
      guard let self, view === self.content, !self.loaded else { return }
      self.finishLoading(immediately: false)
    }
  }

  func browserView(_ view: GleaBrowserView, didReceiveMessage name: String, payload json: String) {
    if name == "audible" {
      guard view === content,
            let payload = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
            let frame = payload["frame"] as? String else { return }
      let was = isPlayingSound
      if payload["audible"] as? Bool == true { audibleFrames.insert(frame) } else { audibleFrames.remove(frame) }
      if isPlayingSound != was { SoundMonitor.shared.sourceDidChange() }
      return
    }
    if name == "embedReady" {
      if view === pending {
        pendingReady = true
        schedulePendingSwapIfReady()
      } else if view === content, !loaded {
        // Let the rendered embed paint before it fades in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
          guard let self, view === self.content, !self.loaded else { return }
          self.finishLoading(immediately: false)
        }
      }
      return
    }
    guard name == "embedSize",
          let size = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Double],
          let height = size["height"], height > 20 else { return }
    if view === pending {
      // Ready once it's as tall as the one it replaces (the same post in
      // another theme), or once its height settles.
      pendingHeight = CGFloat(height)
      schedulePendingSwapIfReady()
      return
    }
    guard view === content else { return }
    dynamicHeight = CGFloat(height)
    if loaded { relayout(animated: true, followingContent: true) }
  }

  func browserView(_ view: GleaBrowserView, requestsNewTabWithURL url: String, background: Bool) {
    if let url = URL(string: url) { onOpenURL?(url) }
  }

  // MARK: Collapse

  func setCollapsed(_ value: Bool) {
    guard value != collapsed else { return }
    collapsed = value
    MediaState.set(value, note: noteID, key: descriptor.key)
    toggle.collapsed = value
    updateHandle(animated: true)
    if value {
      // Collapsing only hides the media: embeds stay loaded (and keep
      // playing), like the demo.
      content?.fadeOut(0.2)
    } else if content == nil {
      loadContent()
    } else {
      content?.fadeIn(0.25)
    }
    relayout(animated: true)
  }

  // MARK: Layout

  /// Its line was rewritten: a new size or caption shows in place.
  func adopt(_ newDescriptor: MediaDescriptor) {
    let resized = newDescriptor.preferredWidth != descriptor.preferredWidth
    descriptor = newDescriptor
    if titleText != newDescriptor.title {
      titleText = newDescriptor.title
      updateTitle()
    }
    // Written after a drag: it's already that size.
    if let dragged = draggedWidth, !handle.isDragging {
      draggedWidth = nil
      if abs(dragged - (newDescriptor.preferredWidth.map { min($0, maximumWidth) } ?? maximumWidth)) > 0.5 { relayout(animated: true) }
    } else if resized {
      relayout(animated: true)
    }
  }

  static let minimumWidth: CGFloat = 48

  /// As wide as it can show: the column, or for an image or a video its own
  /// size (and no taller than the limit).
  private var maximumWidth: CGFloat {
    max(MediaBlockView.minimumWidth, mediaSize(maxWidth: availableWidth).width)
  }

  /// Images, videos and PDFs, once shown and open.
  private var resizable: Bool {
    guard canResize, loaded, !collapsed else { return false }
    switch descriptor.kind {
    case .image, .document: return true
    case .video: return !descriptor.isAudio
    case .embed, .note: return false
    }
  }

  private func updateHandle(animated: Bool) {
    let shown = resizable && (hovering || handle.isDragging)
    handle.isHidden = !resizable
    handle.setShown(shown, animated: animated)
  }

  private func targetMediaSize() -> NSSize {
    mediaSize(maxWidth: min(availableWidth, draggedWidth ?? descriptor.preferredWidth ?? availableWidth))
  }

  private func mediaSize(maxWidth: CGFloat) -> NSSize {
    switch descriptor.kind {
    case .document:
      return NSSize(width: maxWidth, height: round(min(760, maxWidth * 1.3)))
    case .note:
      return NSSize(width: maxWidth, height: (content as? NoteEmbedView)?.height(forWidth: maxWidth) ?? 44)
    case .video where descriptor.isAudio:
      // A player bar.
      return NSSize(width: min(maxWidth, 480), height: 54)
    case .image, .video:
      guard let natural = naturalSize, natural.width > 0, natural.height > 0 else { return NSSize(width: maxWidth, height: maxWidth * 9 / 16) }
      var size = natural
      if size.width > maxWidth { size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width) }
      if size.height > 520 { size = NSSize(width: size.width * 520 / size.height, height: 520) }
      return NSSize(width: round(size.width), height: round(size.height))
    case .embed(_, let provider, _):
      if case .image = resolution?.target, let natural = naturalSize, natural.width > 0 {
        let width = min(maxWidth, natural.width)
        return NSSize(width: width, height: round(natural.height * width / natural.width))
      }
      let width = min(maxWidth, provider.maxWidth ?? maxWidth)
      switch resolution?.sizing ?? provider.sizing {
      case .aspect(let ratio): return NSSize(width: width, height: round(width / ratio))
      case .fixed(let height): return NSSize(width: width, height: height)
      case .dynamic: return NSSize(width: width, height: dynamicHeight ?? 220)
      }
    }
  }

  private func targetState() -> (NSRect, CGFloat) {
    if collapsed {
      let size = loaded ? targetMediaSize() : MediaBlockView.loadingSize
      // Shrinks to nothing at the top-left, under the collapsed row.
      return (NSRect(x: 0, y: 0, width: size.width * 0.4, height: 0), MediaBlockView.rowHeight)
    }
    let size = loaded ? targetMediaSize() : MediaBlockView.loadingSize
    return (NSRect(origin: .zero, size: size), size.height)
  }

  func relayout(animated: Bool, followingContent: Bool = false) {
    resizesWithContent = followingContent
    let (rect, height) = targetState()
    apply(rect, height: height, animated: animated && window != nil && !Motion.reduceMotion)
  }

  /// How long a block takes to resize. The render server runs it, so it
  /// stays smooth however busy the page is. (A variable so automated checks
  /// can slow it down.)
  static var resizeDuration: CFTimeInterval = 0.3

  private func apply(_ rect: NSRect, height: CGFloat, animated: Bool) {
    let animatable: [(CALayer?, String)] = [
      (wrapper.layer, "position"), (wrapper.layer, "bounds"), (wrapper.layer, "opacity"), (content?.layer, "transform"),
      (row.layer, "opacity"), (placeholder.layer, "position"), (placeholder.layer, "bounds"),
    ]
    // A resize under way turns from where things are on screen.
    let from = animatable.map { layer, key in (layer?.presentation() ?? layer)?.value(forKeyPath: key) }

    Motion.withoutAnimation {
      wrapperFrame = rect
      wrapper.frame = rect
      if !collapsed { selectionTint.frame = rect }
      wrapper.layer?.backgroundColor = resolvedCGColor(loaded ? .clear : Theme.codeBackground)
      // The media is always laid out at its final size, so embedded pages
      // never see a resize (their responsive layout stays put). Expanding and
      // collapsing scale it from the top-left corner instead; the wrapper
      // clips.
      if let content {
        let size = targetMediaSize()
        if content.frame.size != size { content.frame = NSRect(origin: .zero, size: size) }
        let scale = loaded && !resizesWithContent
          ? max(0.001, min(1, min(rect.width / max(size.width, 1), rect.height / max(size.height, 1)))) : 1
        content.layer?.transform = scale >= 0.999 ? CATransform3DIdentity : content.topLeftScale(scale)
      }
      let iconSize: CGFloat = 26
      placeholder.frame = NSRect(x: (rect.width - iconSize) / 2, y: (rect.height - iconSize) / 2, width: iconSize, height: iconSize)
      wrapper.alphaValue = collapsed ? min(1, rect.height / 40) : 1
      // No taller than the media (its round ends included); still easy to grab.
      handle.barLength = max(0, min(MediaResizeHandle.height, rect.height - 4))
      let handleHeight = max(24, handle.barLength)
      handle.frame = NSRect(x: rect.maxX + 5 - MediaResizeHandle.width / 2, y: rect.midY - handleHeight / 2,
                            width: MediaResizeHandle.width, height: handleHeight)
      // The collapsed row shows as the media leaves.
      row.alphaValue = collapsed ? 1 : 0
    }
    // Hidden once faded out (and not shown again since).
    rowGeneration += 1
    if row.alphaValue > 0 {
      row.isHidden = false
    } else if !animated {
      row.isHidden = true
    } else {
      let generation = rowGeneration
      DispatchQueue.main.asyncAfter(deadline: .now() + MediaBlockView.resizeDuration) { [weak self] in
        guard let self, self.rowGeneration == generation else { return }
        self.row.isHidden = true
      }
    }
    if animated {
      for ((layer, key), value) in zip(animatable, from) {
        guard let layer, var value else { continue }
        // The media scales with the wrapper from where it is, like expanding
        // (it was at full size while loading, behind the placeholder).
        if let content, layer === content.layer, loaded, !resizesWithContent,
           let bounds = (from[1] as? NSValue)?.rectValue {
          let size = content.frame.size
          let scale = max(0.001, min(1, min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))))
          value = NSValue(caTransform3D: scale >= 0.999 ? CATransform3DIdentity : content.topLeftScale(scale))
        }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = value
        animation.toValue = layer.value(forKeyPath: key)
        animation.duration = MediaBlockView.resizeDuration
        animation.timingFunction = CubicBezier.media.timingFunction
        // The row fades in late and out early, as the media leaves and comes.
        if layer === row.layer {
          animation.timingFunction = collapsed ? CAMediaTimingFunction(controlPoints: 0.7, 0, 0.84, 0) : CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        }
        layer.add(animation, forKey: "glea.block.\(key)")
      }
    }

    let old = blockHeight
    blockHeight = height
    needsLayout = true
    if abs(height - old) > 0.25 { onHeightChange?(animated ? old : nil) }
  }

  override func layout() {
    super.layout()
    let rowY = (MediaBlockView.rowHeight - 18) / 2
    rowIcon.superview?.frame = NSRect(x: 0, y: rowY, width: 18, height: 18)
    rowIcon.frame = NSRect(x: 0, y: 0, width: 18, height: 18)
    let titleWidth = min(bounds.width - 30, ceil(rowTitle.intrinsicContentSize.width) + 2)
    rowTitle.superview?.frame = NSRect(x: 26, y: (MediaBlockView.rowHeight - 18) / 2, width: titleWidth, height: 18)
    rowTitle.frame = NSRect(x: 0, y: 0, width: titleWidth, height: 18)
    row.frame = NSRect(x: 0, y: 0, width: bounds.width, height: MediaBlockView.rowHeight)
    selectionTint.frame = collapsed
      ? NSRect(x: -3, y: 0, width: min(bounds.width, rowTitle.frame.maxX + 32), height: MediaBlockView.rowHeight)
      : wrapperFrame

    // In the gutter, right of the text column, level with the first line;
    // just its icon when the window is too narrow for its label.
    let toggleX = availableWidth + 14
    if let window {
      let fits = convert(NSPoint(x: toggleX + toggle.labelledWidth, y: 0), to: nil).x <= window.contentLayoutRect.maxX - 8
      toggle.setShowsLabel(fits, animated: window.isVisible) { [weak self] in self?.needsLayout = true }
    }
    let toggleSize = toggle.fittingSize
    toggle.frame = NSRect(x: toggleX, y: (MediaBlockView.rowHeight - toggleSize.height) / 2 - 1,
                          width: toggleSize.width, height: toggleSize.height)
  }

  // MARK: Hover (toggle visibility)

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    // Its own bounds (the visible rect would cover the whole page: views
    // don't clip to their bounds). A new area starts where the hover is: if
    // it thinks the pointer is outside while it's inside, leaving never
    // sends an exit and the toggle stays.
    var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp]
    if hovering { options.insert(.assumeInside) }
    let area = NSTrackingArea(rect: bounds, options: options, owner: self)
    addTrackingArea(area)
    tracking = area
  }

  // Moved or resized (embeds loading, the page reflowing) under a still
  // pointer: no enter or exit events, so check where it is.
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateTrackingAreas()
    scheduleHoverSync()
  }

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    scheduleHoverSync()
  }

  private var hoverSyncPending = false

  /// Once per run loop turn, after the moves and resizes of a layout pass.
  private func scheduleHoverSync() {
    guard !hoverSyncPending, window != nil else { return }
    hoverSyncPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.hoverSyncPending = false
      self.syncHoverWithPointer()
    }
  }

  private var hovering = false {
    didSet {
      guard hovering != oldValue else { return }
      let shown: CGFloat = hovering ? 1 : 0
      Motion.animate(0.2, timing: Motion.easeInOut) { toggle.animator().alphaValue = shown }
      updateHandle(animated: true)
      // The tracking area follows (see updateTrackingAreas).
      updateTrackingAreas()
    }
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  /// The page scrolled under a still pointer (no enter or exit events):
  /// match the hover to where the pointer is now.
  private func syncHoverWithPointer() {
    guard let window, !isHiddenOrHasHiddenAncestor else {
      hovering = false
      return
    }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    // (The visible rect isn't clipped to the bounds: views don't clip.)
    hovering = bounds.intersection(visibleRect).contains(point)
  }

  /// The note scrolls when the wheel is over an embed (embeds are sized to
  /// their content, so they have nothing to scroll themselves; a PDF does,
  /// once clicked: see `scrollsItself`).
  override func scrollWheel(with event: NSEvent) {
    enclosingScrollView?.scrollWheel(with: event)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if MediaBlockView.hitTestingScroll {
      guard bounds.contains(local) else { return nil }
      if scrollsItself, !collapsed, wrapperFrame.contains(local) { return super.hitTest(point) ?? self }
      return self
    }
    // Only the visible parts take clicks; the rest belongs to the text.
    if !handle.isHidden, handle.frame.contains(local) { return handle }
    if toggle.alphaValue > 0.1, toggle.frame.contains(local) { return toggle.hitTest(convert(local, to: toggle.superview)) ?? toggle }
    if collapsed { return NSRect(x: 0, y: 0, width: 26 + rowTitle.frame.width, height: MediaBlockView.rowHeight).contains(local) ? super.hitTest(point) : nil }
    return wrapperFrame.contains(local) ? super.hitTest(point) : nil
  }
}

/// A media block's resize handle (as in Beam): a short rounded bar right of
/// the media, shown while the block is hovered, thicker and darker while the
/// pointer is on it. Dragging it sideways changes the media's width.
final class MediaResizeHandle: NSView {
  static let width: CGFloat = 12
  static let height: CGFloat = 44

  var onDragBegan: (() -> Void)?
  /// How far the pointer moved sideways since the press.
  var onDrag: ((CGFloat) -> Void)?
  var onDragEnded: (() -> Void)?
  private(set) var isDragging = false

  /// How long the bar is drawn, centered in the handle.
  var barLength: CGFloat = height { didSet { if barLength != oldValue { needsLayout = true } } }
  private let bar = CAShapeLayer()
  private var pointerOn = false { didSet { updateBar() } }
  private var pressX: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    bar.lineCap = .round
    bar.fillColor = nil
    bar.opacity = 0
    layer?.addSublayer(bar)
    HoverView.track(self) { [weak self] on in
      guard let self else { return }
      self.pointerOn = on
      self.updateCursor()
    }
    updateBar()
  }

  /// Cursor rects only follow the pointer moving: scrolled away from under a
  /// still pointer (or onto it), the cursor would keep its old shape.
  private func updateCursor() {
    guard !isDragging, let window else { return }
    if pointerOn { return NSCursor.resizeLeftRight.set() }
    let hit = window.contentView?.hitTest(window.mouseLocationOutsideOfEventStream)
    (hit is NSTextView ? NSCursor.iBeam : NSCursor.arrow).set()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let path = CGMutablePath()
    let length = min(barLength, bounds.height)
    path.move(to: CGPoint(x: bounds.midX, y: (bounds.height - length) / 2))
    path.addLine(to: CGPoint(x: bounds.midX, y: (bounds.height + length) / 2))
    Motion.withoutAnimation {
      bar.frame = bounds
      bar.path = path
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    Motion.withoutAnimation { updateBar() }
  }

  /// Fades in or out (the layer's own short fade).
  func setShown(_ shown: Bool, animated: Bool) {
    let opacity: Float = shown ? 1 : 0
    guard bar.opacity != opacity else { return }
    if animated { bar.opacity = opacity } else { Motion.withoutAnimation { bar.opacity = opacity } }
  }

  /// Thicker and darker while the pointer is on it or it's dragged; the
  /// change eases (the layer's implicit animation).
  private func updateBar() {
    let active = pointerOn || isDragging
    bar.lineWidth = active ? 4 : 2
    bar.strokeColor = resolvedCGColor(active ? Theme.resizeHandleHover : Theme.resizeHandle)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func mouseDown(with event: NSEvent) {
    pressX = event.locationInWindow.x
    isDragging = true
    updateBar()
    onDragBegan?()
  }

  override func mouseDragged(with event: NSEvent) {
    NSCursor.resizeLeftRight.set()
    onDrag?(event.locationInWindow.x - pressX)
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    isDragging = false
    updateBar()
    onDragEnded?()
  }
}

/// A PDF's pages, scrolling in place once its block is clicked (see
/// `MediaBlockView.scrollsItself`). A scroll that starts at the top or the
/// bottom and pushes past it goes to the note instead; one that reaches an
/// end mid-way stops there.
final class PDFEmbedView: NSView {
  /// Hands a scroll to the note.
  var onPassScroll: ((NSEvent) -> Void)?
  private let pdfView = PDFView()
  /// Where the current gesture's events go, once its direction is known.
  private var passesGesture: Bool?

  init(document: PDFDocument) {
    super.init(frame: .zero)
    pdfView.document = document
    pdfView.displayMode = .singlePageContinuous
    pdfView.displaysPageBreaks = true
    pdfView.autoresizingMask = [.width, .height]
    addSubview(pdfView)
    updateBackground()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    pdfView.frame = bounds
    if bounds.size != fittedSize { fitPage() }
  }

  private var fittedSize = NSSize.zero

  /// A whole page in view: as wide as fits, unless that's too tall.
  private func fitPage() {
    guard let page = pdfView.document?.page(at: 0), bounds.width > 0, bounds.height > 0 else { return }
    fittedSize = bounds.size
    var size = page.bounds(for: pdfView.displayBox).size
    if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
    let margins = pdfView.pageBreakMargins
    let width = bounds.width - margins.left - margins.right
    let height = bounds.height - margins.top - margins.bottom
    guard size.width > 0, size.height > 0, width > 0, height > 0 else { return }
    pdfView.scaleFactor = min(width / size.width, height / size.height)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackground()
  }

  private func updateBackground() {
    pdfView.backgroundColor = Theme.codeBackground
  }

  private var pagesScrollView: NSScrollView? {
    func find(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      for sub in view.subviews { if let found = find(sub) { return found } }
      return nil
    }
    return find(pdfView)
  }

  /// Scroll events stop here, to be sent on to the pages or the note.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit != nil && MediaBlockView.hitTestingScroll ? self : hit
  }

  override func scrollWheel(with event: NSEvent) {
    guard let scroll = pagesScrollView else { return onPassScroll?(event) ?? () }
    // Its ends bounce no further: what's past them is the note's.
    scroll.verticalScrollElasticity = .none
    let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
    // A wheel's clicks are each their own gesture.
    if !gesture || event.phase.contains(.began) || event.phase.contains(.mayBegin) { passesGesture = nil }
    if passesGesture == nil, event.scrollingDeltaY != 0 {
      let (top, bottom) = ends(of: scroll)
      // (A positive delta moves toward the top.)
      passesGesture = event.scrollingDeltaY > 0 ? top : bottom
    }
    if passesGesture == true { onPassScroll?(event) } else { scroll.scrollWheel(with: event) }
  }

  /// For automated checks: the pages' visible rect and ends.
  var debugScrollState: String {
    guard let scroll = pagesScrollView else { return "no scroll view" }
    let (top, bottom) = ends(of: scroll)
    return "\(NSStringFromRect(scroll.documentVisibleRect)) top=\(top) bottom=\(bottom)"
  }

  /// Whether its pages are scrolled all the way to the top, to the bottom.
  private func ends(of scroll: NSScrollView) -> (Bool, Bool) {
    guard let document = scroll.documentView else { return (true, true) }
    let visible = scroll.documentVisibleRect
    let full = document.bounds
    let atMin = visible.minY <= full.minY + 0.5
    let atMax = visible.maxY >= full.maxY - 0.5
    return document.isFlipped ? (atMin, atMax) : (atMax, atMin)
  }
}

/// Centered on a label's lowercase letters rather than on its line box,
/// whose middle sits higher: `shift` moves it down by the difference.
private final class LowercaseCenteredImageView: NSImageView {
  var shift: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: -shift, left: 0, bottom: shift, right: 0) }
}

/// "↘↖ collapse" / "↖↘ expand", shown on hover. Also a table's
/// "markdown" / "table" (other `looks`).
final class MediaToggleButton: NSView {
  struct Look {
    let symbol: String
    let label: String
    let tooltip: String
  }

  var onClick: (() -> Void)?
  var collapsed = false { didSet { update() } }
  /// Centers the icon on the label's capitals instead of its lowercase
  /// letters (labels with tall letters, like "markdown" and "table").
  var centersIconOnCapitals = false { didSet { updateIconShift() } }

  private func updateIconShift() {
    guard let font = label.font else { return }
    let middle = centersIconOnCapitals ? font.capHeight / 2 : font.xHeight / 2
    icon.shift = (font.ascender + font.descender) / 2 - middle
  }

  /// What it shows when `collapsed`, and when not.
  var looks = (collapsed: Look(symbol: "arrow.up.left.and.arrow.down.right", label: "expand", tooltip: "Expand"),
               expanded: Look(symbol: "arrow.down.right.and.arrow.up.left", label: "collapse", tooltip: "Collapse")) {
    didSet { update() }
  }
  private let icon = LowercaseCenteredImageView()
  private let label = NSTextField.label("collapse", size: 12, weight: .regular, color: Theme.tertiaryText)

  private var hovering = false { didSet { update() } }
  private var tracking: NSTrackingArea?
  /// Off where the window is too narrow for it: just the icon (its label
  /// becomes a tooltip).
  private(set) var showsLabel = true

  /// Its width with the longer label ("collapse"): every toggle decides by
  /// it, so they all show or hide their label at once.
  var labelledWidth: CGFloat {
    let longer = looks.collapsed.label.count > looks.expanded.label.count ? looks.collapsed.label : looks.expanded.label
    let text = (longer as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12)]).width + 4
    return 2 + (icon.image?.size.width ?? 12) + 6 + ceil(text) + 4
  }

  /// Grows the label in from the icon (a short spring, a small bounce) as it
  /// fades in, or shrinks it back as it fades out.
  func setShowsLabel(_ shows: Bool, animated: Bool, completion: (() -> Void)? = nil) {
    guard shows != showsLabel else { return }
    showsLabel = shows
    update()
    guard animated, !Motion.reduceMotion, let layer = label.layer else {
      labelGeneration += 1
      label.layer?.removeAllAnimations()
      label.isHidden = !shows
      completion?()
      return
    }
    // Around its left edge, next to the icon.
    let mid = label.bounds.midY
    func scale(_ s: CGFloat) -> CATransform3D {
      CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(0, mid, 0), s, s, 1), 0, -mid, 0)
    }
    // Back from hidden: from small and clear (its layer was reset).
    let fromHidden = shows && label.isHidden
    if shows { label.isHidden = false }
    let current = fromHidden ? nil : layer.presentation()
    let grow = Motion.spring("transform", stiffness: 520, damping: 20)
    grow.fromValue = current?.transform ?? scale(shows ? 0.6 : 1)
    grow.toValue = shows ? CATransform3DIdentity : scale(0.6)
    // As long as the shrink (a quick fade would hide it before it shows).
    let fade = Motion.basic("opacity", duration: shows ? 0.16 : 0.22, timing: shows ? Motion.easeOut : Motion.easeInOut)
    fade.fromValue = current?.opacity ?? (shows ? 0 : 1)
    fade.toValue = shows ? 1 : 0
    for animation in [grow, fade] as [CAAnimation] {
      animation.fillMode = .forwards
      animation.isRemovedOnCompletion = shows
    }
    layer.add(grow, forKey: "glea.label.transform")
    layer.add(fade, forKey: "glea.label.opacity")
    // Done once the spring settles (a transaction's completion, begun during
    // layout, can come at once).
    labelGeneration += 1
    let generation = labelGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + grow.duration) { [weak self] in
      guard let self, generation == self.labelGeneration else { return }
      if !shows {
        self.label.isHidden = true
        self.label.layer?.removeAllAnimations()
      }
      completion?()
    }
  }

  private var labelGeneration = 0

  var debugLabelState: String {
    let shown = label.layer?.presentation()
    return String(format: "hidden=%d opacity=%.2f scale=%.2f", label.isHidden, shown?.opacity ?? -1, shown?.transform.m11 ?? -1)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // Its own layer from the start: made on the way out, it would have
    // nothing drawn in it yet (the label would vanish, not shrink).
    label.wantsLayer = true
    let stack = NSStackView(views: [icon, label])
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 3, left: 2, bottom: 3, right: 4)
    updateIconShift()
    addSubview(stack)
    stack.pinEdges(to: self)
    update()
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

  /// The page scrolled under a still pointer (no enter or exit events).
  private var scrollWatch: NSObjectProtocol?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scrollWatch = watchScrolling(replacing: scrollWatch) { [weak self] in
      guard let self else { return }
      guard let window = self.window, !self.isHiddenOrHasHiddenAncestor else { return self.hovering = false }
      self.hovering = self.bounds.intersection(self.visibleRect).contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  private func update() {
    let look = collapsed ? looks.collapsed : looks.expanded
    icon.image = Theme.symbol(look.symbol, size: 10, weight: .semibold)
    label.stringValue = look.label
    toolTip = showsLabel ? nil : look.tooltip
    let color = hovering ? Theme.text : Theme.tertiaryText
    label.textColor = color
    icon.contentTintColor = color
  }

  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private extension NSView {
  func fadeIn(_ duration: TimeInterval) {
    alphaValue = 0
    Motion.animate(duration, timing: Motion.easeOut) { animator().alphaValue = 1 }
  }

  func fadeOut(_ duration: TimeInterval) {
    Motion.animate(duration, timing: Motion.easeInOut) { animator().alphaValue = 0 }
  }
}

/// An image view that never takes clicks (the loading icon sits over the
/// embed; the player's own button is right under it).
private final class PassthroughImageView: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A plain view that runs an action when clicked.
private final class ClickableView: NSView {
  let action: () -> Void
  init(action: @escaping () -> Void) {
    self.action = action
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

extension MediaBlockView: SoundSource {
  var isPlayingSound: Bool { !audibleFrames.isEmpty || playerPlaying }
  var isSoundMuted: Bool { soundMuted }

  func setSoundMuted(_ muted: Bool) {
    soundMuted = muted
    (content as? GleaBrowserView)?.audioMuted = muted
    contentPlayer?.isMuted = muted
    SoundMonitor.shared.sourceDidChange()
  }
}

/// A sound file's player: play / pause, the time, a scrubber and the
/// duration, on a pill like the search field's.
final class AudioPlayerView: NSView {
  let player: AVPlayer
  private lazy var playButton = IconButton(symbol: "play.fill", size: 12, tooltip: "Play", target: self, action: #selector(togglePlay))
  private let elapsed = NSTextField.label("0:00", size: 11.5, color: Theme.secondaryText)
  private let remaining = NSTextField.label("0:00", size: 11.5, color: Theme.secondaryText)
  private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
  private var timeObserver: Any?
  private var statusObservation: NSKeyValueObservation?
  private var loadedDuration: Double = 0
  private var endObserver: NSObjectProtocol?
  private var scrubbing = false

  init(player: AVPlayer) {
    self.player = player
    super.init(frame: .zero)
    wantsLayer = true
    for label in [elapsed, remaining] {
      label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    }
    scrubber.controlSize = .small
    scrubber.target = self
    scrubber.action = #selector(scrub)
    scrubber.isContinuous = true
    for view in [playButton, elapsed, scrubber, remaining] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      elapsed.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 6),
      elapsed.centerYAnchor.constraint(equalTo: centerYAnchor),
      scrubber.leadingAnchor.constraint(equalTo: elapsed.trailingAnchor, constant: 10),
      scrubber.centerYAnchor.constraint(equalTo: centerYAnchor),
      remaining.leadingAnchor.constraint(equalTo: scrubber.trailingAnchor, constant: 10),
      remaining.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      remaining.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.update() }
    }
    statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.update() }
    }
    // The length, read from the file.
    if let asset = player.currentItem?.asset {
      Task { @MainActor [weak self] in
        guard let length = try? await asset.load(.duration), length.seconds.isFinite else { return }
        self?.loadedDuration = length.seconds
        self?.update()
      }
    }
    // Played to the end: back to the start, ready to play again.
    endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem,
                                                         queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.player.seek(to: .zero)
        self?.update()
      }
    }
    update()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
  }

  private var duration: Double {
    let seconds = player.currentItem?.duration.seconds ?? 0
    return seconds.isFinite && seconds > 0 ? seconds : loadedDuration
  }

  private func update() {
    let playing = player.timeControlStatus != .paused
    playButton.setSymbol(playing ? "pause.fill" : "play.fill", size: 12, animated: false)
    playButton.toolTip = playing ? "Pause" : "Play"
    let now = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
    elapsed.stringValue = Self.format(now)
    // The length rounded up (a 0.9s clip lasts 0:01).
    remaining.stringValue = Self.format(duration.rounded(.up))
    if !scrubbing { scrubber.doubleValue = duration > 0 ? now / duration : 0 }
  }

  private static func format(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
      : String(format: "%d:%02d", total / 60, total % 60)
  }

  @objc private func togglePlay() {
    if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    update()
  }

  @objc private func scrub() {
    guard duration > 0 else { return }
    let ended = NSApp.currentEvent?.type == .leftMouseUp
    scrubbing = !ended
    player.seek(to: CMTime(seconds: scrubber.doubleValue * duration, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
    elapsed.stringValue = Self.format(scrubber.doubleValue * duration)
  }

  // The arrow over the player (not the text's I-beam), like other embeds.
  private var cursorArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorArea { removeTrackingArea(cursorArea) }
    let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area)
    cursorArea = area
  }

  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.backgroundColor = resolvedCGColor(Theme.searchFill)
    layer?.borderColor = resolvedCGColor(Theme.searchStroke)
  }
}
