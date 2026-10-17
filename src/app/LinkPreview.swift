import AppKit

/// What a page says about itself, for link previews: its title, Open Graph
/// tags and icon, read from the top of its HTML.
struct LinkMetadata {
  var url: URL
  var title: String?
  var summary: String?
  var siteName: String?
  var image: URL?
  var icon: URL?

  var host: String { url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
}

/// Fetches and remembers link metadata (until Glea quits).
@MainActor
final class LinkMetadataStore {
  static let shared = LinkMetadataStore()

  private var cache: [URL: LinkMetadata] = [:]
  private var waiting: [URL: [(LinkMetadata) -> Void]] = [:]

  /// Fetched without cookies or a disk cache: hovering a link shouldn't
  /// sign you in anywhere or leave traces.
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.httpAdditionalHeaders = [
      "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
      // Some sites only describe themselves to browsers they know.
      "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    ]
    return URLSession(configuration: configuration)
  }()

  func cached(_ url: URL) -> LinkMetadata? { cache[url] }

  /// Calls `completion` with what the page says (just its address if it
  /// can't be read).
  func metadata(for url: URL, completion: @escaping (LinkMetadata) -> Void) {
    if let known = cache[url] { return completion(known) }
    if waiting[url] != nil {
      waiting[url]?.append(completion)
      return
    }
    waiting[url] = [completion]
    session.dataTask(with: url) { data, response, _ in
      let metadata = LinkMetadata.parse(data, response: response, url: url)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.cache[url] = metadata
          let callbacks = self.waiting.removeValue(forKey: url) ?? []
          for callback in callbacks { callback(metadata) }
        }
      }
    }.resume()
  }
}

extension LinkMetadata {
  /// Reads the page's `<head>`: Open Graph and Twitter tags first, then the
  /// plain title and description.
  nonisolated static func parse(_ data: Data?, response: URLResponse?, url: URL) -> LinkMetadata {
    let base = response?.url ?? url
    var metadata = LinkMetadata(url: url)
    let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    if type.hasPrefix("image/") {
      metadata.image = base
      metadata.title = base.lastPathComponent
      return metadata
    }
    guard let data, !data.isEmpty, type.isEmpty || type.contains("html") else {
      if !base.lastPathComponent.isEmpty, base.lastPathComponent != "/" { metadata.title = base.lastPathComponent }
      return metadata
    }
    let head = data.prefix(400_000)
    var html = String(decoding: head, as: UTF8.self)
    if let end = html.range(of: "</head>", options: .caseInsensitive) { html = String(html[..<end.lowerBound]) }
    let text = html as NSString

    var meta: [String: String] = [:]
    for match in Self.metaTag.matches(in: html, range: NSRange(location: 0, length: text.length)) {
      let attributes = Self.attributes(text.substring(with: match.range))
      guard let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
            let content = attributes["content"], !content.isEmpty, meta[key] == nil else { continue }
      meta[key] = Self.decodeEntities(content)
    }
    var title: String?
    if let match = Self.titleTag.firstMatch(in: html, range: NSRange(location: 0, length: text.length)) {
      title = Self.decodeEntities(text.substring(with: match.range(at: 1)))
    }
    var icon: URL?
    for match in Self.linkTag.matches(in: html, range: NSRange(location: 0, length: text.length)) {
      let attributes = Self.attributes(text.substring(with: match.range))
      guard let rel = attributes["rel"]?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
            let href = attributes["href"], let resolved = URL(string: Self.decodeEntities(href), relativeTo: base)?.absoluteURL else { continue }
      // An Apple touch icon is larger and crisper: prefer it.
      if icon == nil || rel.contains("apple-touch-icon") { icon = resolved }
    }

    func clean(_ value: String?) -> String? {
      guard let value else { return nil }
      let collapsed = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
      return collapsed.isEmpty ? nil : collapsed
    }
    metadata.title = clean(meta["og:title"] ?? meta["twitter:title"] ?? title)
    metadata.summary = clean(meta["og:description"] ?? meta["twitter:description"] ?? meta["description"])
    metadata.siteName = clean(meta["og:site_name"] ?? meta["application-name"])
    if let image = meta["og:image:secure_url"] ?? meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"] {
      metadata.image = URL(string: image, relativeTo: base)?.absoluteURL
    }
    if metadata.image?.scheme != "https" && metadata.image?.scheme != "http" { metadata.image = nil }
    metadata.icon = icon ?? URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL
    return metadata
  }

  private nonisolated static let metaTag = try! NSRegularExpression(pattern: "<meta\\s[^>]*>", options: .caseInsensitive)
  private nonisolated static let linkTag = try! NSRegularExpression(pattern: "<link\\s[^>]*>", options: .caseInsensitive)
  private nonisolated static let titleTag = try! NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: .caseInsensitive)
  private nonisolated static let attribute = try! NSRegularExpression(
    pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")

  private nonisolated static func attributes(_ tag: String) -> [String: String] {
    let text = tag as NSString
    var result: [String: String] = [:]
    for match in attribute.matches(in: tag, range: NSRange(location: 0, length: text.length)) {
      let name = text.substring(with: match.range(at: 1)).lowercased()
      let value = (2...4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(text.substring(with:)) ?? ""
      if result[name] == nil { result[name] = value }
    }
    return result
  }

  private nonisolated static let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'",
    "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
  ]

  nonisolated static func decodeEntities(_ value: String) -> String {
    guard value.contains("&") else { return value }
    var result = ""
    var rest = Substring(value)
    while let amp = rest.firstIndex(of: "&") {
      result += rest[..<amp]
      let after = rest[rest.index(after: amp)...]
      guard let semi = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semi) <= 8 else {
        result += "&"
        rest = after
        continue
      }
      let name = String(after[..<semi])
      if let named = namedEntities[name.lowercased()] {
        result += named
      } else if name.hasPrefix("#x") || name.hasPrefix("#X"), let code = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
        result.unicodeScalars.append(scalar)
      } else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(code) {
        result.unicodeScalars.append(scalar)
      } else {
        result += "&" + name + ";"
      }
      rest = after[after.index(after: semi)...]
    }
    return result + rest
  }
}

/// A web link's preview card, shown while the pointer rests on the link:
/// the page's image, site, title and description.
final class LinkPreviewCard: NSView {
  static let width: CGFloat = 320
  /// The image area follows the image's proportions within these heights,
  /// cropped beyond them (very wide banners, very tall posters).
  private static let minImageHeight: CGFloat = 120
  private static let maxImageHeight: CGFloat = 360
  /// Smaller images (logos, icons) show at their own size on a backdrop,
  /// not blown up to the card's width.
  private static let smallImageWidth: CGFloat = 220
  private static let padding: CGFloat = 12

  private let shadowHost = NSView()
  private let card = FlippedView()
  private let imageView = AspectFillImageView()
  private let imageBackdrop = NSView()
  private let icon = NSImageView()
  private let siteLabel = NSTextField.label("", size: 11.5, color: Theme.secondaryText)
  private let titleLabel = NSTextField(wrappingLabelWithString: "")
  private let summaryLabel = NSTextField(wrappingLabelWithString: "")
  private(set) var metadata: LinkMetadata
  private var image: NSImage?

  init(metadata: LinkMetadata) {
    self.metadata = metadata
    super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 60))
    wantsLayer = true
    shadowHost.wantsLayer = true
    shadowHost.shadow = NSShadow()
    shadowHost.layer?.shadowColor = NSColor.black.cgColor
    shadowHost.layer?.shadowOpacity = 0.2
    shadowHost.layer?.shadowRadius = 16
    shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -5)
    shadowHost.frame = bounds
    shadowHost.autoresizingMask = [.width, .height]
    addSubview(shadowHost)
    card.wantsLayer = true
    card.layer?.cornerRadius = 12
    card.layer?.cornerCurve = .continuous
    card.layer?.masksToBounds = true
    card.layer?.borderWidth = 1
    card.frame = shadowHost.bounds
    card.autoresizingMask = [.width, .height]
    shadowHost.addSubview(card)

    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 3
    icon.layer?.masksToBounds = true
    siteLabel.lineBreakMode = .byTruncatingTail
    titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
    titleLabel.textColor = Theme.text
    titleLabel.maximumNumberOfLines = 2
    titleLabel.lineBreakMode = .byWordWrapping
    titleLabel.cell?.truncatesLastVisibleLine = true
    summaryLabel.font = .systemFont(ofSize: 12)
    summaryLabel.textColor = Theme.secondaryText
    summaryLabel.maximumNumberOfLines = 3
    summaryLabel.lineBreakMode = .byWordWrapping
    summaryLabel.cell?.truncatesLastVisibleLine = true
    imageBackdrop.wantsLayer = true
    imageBackdrop.addSubview(imageView)
    for view in [imageBackdrop, icon, siteLabel, titleLabel, summaryLabel] { card.addSubview(view) }
    updateColors()
    NotificationCenter.default.addObserver(self, selector: #selector(imageLoaded), name: ImageCache.didLoad, object: nil)
    apply(metadata)
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    card.layer?.backgroundColor = resolvedCGColor(Theme.background)
    card.layer?.borderColor = resolvedCGColor(Theme.separator)
    imageBackdrop.layer?.backgroundColor = resolvedCGColor(Theme.codeBackground)
  }

  /// Shows what's known about the page (first just its address, then what
  /// it says about itself).
  func apply(_ metadata: LinkMetadata) {
    self.metadata = metadata
    siteLabel.stringValue = metadata.siteName.map { $0.caseInsensitiveCompare(metadata.host) == .orderedSame ? $0 : "\($0) · \(metadata.host)" } ?? metadata.host
    let path = metadata.url.path == "/" ? "" : metadata.url.path
    titleLabel.stringValue = metadata.title ?? (metadata.host + path)
    summaryLabel.stringValue = metadata.summary ?? ""
    let placeholder = Theme.symbol("globe", size: 11)
    icon.image = metadata.icon.flatMap { ImageCache.shared.image(for: $0) } ?? placeholder
    icon.contentTintColor = icon.image === placeholder ? Theme.secondaryText : nil
    image = metadata.image.flatMap { ImageCache.shared.image(for: $0) }
    imageView.image = image
    layoutContent()
  }

  /// The image's size in pixels (an NSImage's size depends on its DPI).
  private static func pixelSize(of image: NSImage) -> NSSize {
    let pixels = image.representations.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
      .filter { $0.width > 0 && $0.height > 0 }
      .max { $0.width < $1.width }
    return pixels ?? image.size
  }

  @objc private func imageLoaded(_ note: Notification) {
    guard let url = note.object as? URL, url == metadata.image || url == metadata.icon else { return }
    let before = image == nil
    apply(metadata)
    if before, image != nil { imageBackdrop.animateIn(scale: 1, fade: 0.16, duration: 0.16) }
  }

  /// The height the card needs, for its content at its width.
  private(set) var contentHeight: CGFloat = 60

  private func layoutContent() {
    let width = Self.width
    let inner = width - 2 * Self.padding
    var y: CGFloat = 0
    if let image, image.size.width > 0, image.size.height > 0 {
      let size = Self.pixelSize(of: image)
      let height: CGFloat
      if size.width < Self.smallImageWidth {
        // At its own size (halved on Retina screens, at most the card's
        // width and the area's height), centered.
        let scale = window?.backingScaleFactor ?? 2
        var shown = NSSize(width: size.width / scale, height: size.height / scale)
        let fit = min(1, (width - 32) / shown.width, (Self.maxImageHeight * 0.6 - 32) / shown.height)
        shown = NSSize(width: max(1, shown.width * fit), height: max(1, shown.height * fit))
        height = min(max(shown.height + 32, 96), Self.maxImageHeight * 0.6)
        imageView.frame = NSRect(x: ((width - shown.width) / 2).rounded(), y: ((height - shown.height) / 2).rounded(),
                                 width: shown.width, height: shown.height)
      } else {
        // As tall as its proportions ask, within limits (cropped beyond).
        height = min(Self.maxImageHeight, max(Self.minImageHeight, (width * size.height / size.width).rounded()))
        imageView.frame = NSRect(x: 0, y: 0, width: width, height: height)
      }
      imageBackdrop.frame = NSRect(x: 0, y: 0, width: width, height: height)
      imageBackdrop.isHidden = false
      y = height
    } else {
      imageBackdrop.isHidden = true
    }
    y += Self.padding
    icon.frame = NSRect(x: Self.padding, y: y + 1, width: 14, height: 14)
    siteLabel.frame = NSRect(x: Self.padding + 20, y: y, width: inner - 20, height: 16)
    y += 16 + 5
    titleLabel.preferredMaxLayoutWidth = inner
    let titleHeight = ceil(titleLabel.sizeThatFits(NSSize(width: inner, height: 100)).height)
    titleLabel.frame = NSRect(x: Self.padding, y: y, width: inner, height: titleHeight)
    y += titleHeight
    if summaryLabel.stringValue.isEmpty {
      summaryLabel.isHidden = true
    } else {
      summaryLabel.isHidden = false
      summaryLabel.preferredMaxLayoutWidth = inner
      let height = ceil(summaryLabel.sizeThatFits(NSSize(width: inner, height: 100)).height)
      y += 4
      summaryLabel.frame = NSRect(x: Self.padding, y: y, width: inner, height: height)
      y += height
    }
    contentHeight = y + Self.padding
    onHeightChange?(contentHeight)
  }

  var onHeightChange: ((CGFloat) -> Void)?

  func animateAppear() { shadowHost.animateIn(scale: 0.97, offsetY: 0, fade: 0.12, duration: 0.18) }

  func animateDisappear(completion: @escaping () -> Void) {
    shadowHost.animateOut(scale: 0.98, fade: 0.1, duration: 0.12, completion: completion)
  }
}

/// An image that fills its frame, cropped rather than stretched (an
/// NSImageView only scales to fit or stretches). A tall image keeps its
/// top part (faces and titles are rarely at the bottom); a wide one, its
/// middle.
final class AspectFillImageView: NSView {
  var image: NSImage? {
    didSet {
      layer?.contents = image
      updateCrop()
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.contentsGravity = .resize
    layer?.masksToBounds = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateCrop()
  }

  /// The part of the image shown, in unit coordinates (y up from its bottom).
  private func updateCrop() {
    guard let image, image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else {
      layer?.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
      return
    }
    let imageAspect = image.size.width / image.size.height
    let viewAspect = bounds.width / bounds.height
    if imageAspect < viewAspect {
      let height = imageAspect / viewAspect
      // A little below the very top: room above a head.
      let fromTop = (1 - height) * 0.15
      layer?.contentsRect = CGRect(x: 0, y: 1 - height - fromTop, width: 1, height: height)
    } else {
      let width = viewAspect / imageAspect
      layer?.contentsRect = CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    layer?.contentsScale = window?.backingScaleFactor ?? 2
  }
}

/// Shows a link's preview card once the pointer has rested on it. Note
/// editors say which web link is under the pointer (or none) as it moves,
/// the page scrolls or the text changes under it.
@MainActor
final class LinkPreviewController {
  static let shared = LinkPreviewController()
  static let testing = ProcessInfo.processInfo.environment["GLEA_TEST_HOOKS"] == "1"

  /// How long the pointer rests on a link before its preview shows; once
  /// one has shown, moving to the next link is quicker (like tooltips).
  private static let delay: TimeInterval = 0.55
  private static let warmDelay: TimeInterval = 0.12

  private var card: LinkPreviewCard?
  private weak var owner: AnyObject?
  private var url: URL?
  /// The link's text in window coordinates.
  private var anchor: NSRect = .zero
  private weak var host: NSView?
  private var pending: DispatchWorkItem?
  private var timeout: DispatchWorkItem?
  /// The pointer has rested long enough; the card shows once the page's
  /// details and pictures are in (or after `maxWait`, with what's there).
  private var delayPassed = false
  private var waitedEnough = false
  private static let maxWait: TimeInterval = 3
  private var lastShown: Date = .distantPast
  /// Below the link, or above it (no room below): which edge stays put as
  /// the card grows.
  private var below = true

  private init() {
    NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { LinkPreviewController.shared.hide() }
    }
    NotificationCenter.default.addObserver(forName: ImageCache.didSettle, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { LinkPreviewController.shared.showIfReady() }
    }
  }

  /// `owner` (an editor) has `url` under the pointer, its text at `rect`
  /// (window coordinates), or no link (nil): only its own preview goes then.
  func hover(_ url: URL?, rect: NSRect, in view: NSView, owner: AnyObject) {
    guard let url, NoteLinks.previews else {
      if owner === self.owner { hide() }
      return
    }
    if url == self.url, owner === self.owner {
      // The same link, moved (the page scrolled under a still pointer).
      if rect != anchor {
        anchor = rect
        if let card { place(card, height: card.frame.height, animated: false) }
      }
      return
    }
    let warm = card != nil || Date().timeIntervalSince(lastShown) < 0.6
    hide()
    self.owner = owner
    self.url = url
    anchor = rect
    host = view.window?.appRootView
    // Fetched while the pointer rests, pictures included, so the card
    // shows complete.
    LinkMetadataStore.shared.metadata(for: url) { [weak self] metadata in
      guard let self, self.url == url else { return }
      for picture in [metadata.image, metadata.icon].compactMap({ $0 }) { _ = ImageCache.shared.image(for: picture) }
      if let card = self.card { card.apply(metadata) } else { self.showIfReady() }
    }
    let work = DispatchWorkItem { [weak self] in
      self?.pending = nil
      self?.delayPassed = true
      self?.showIfReady()
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? Self.warmDelay : Self.delay), execute: work)
    let giveUp = DispatchWorkItem { [weak self] in
      self?.timeout = nil
      self?.waitedEnough = true
      self?.showIfReady()
    }
    timeout = giveUp
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxWait, execute: giveUp)
  }

  /// Shows the card once the pointer has rested and everything it shows
  /// has loaded (or failed to).
  private func showIfReady() {
    guard let url, card == nil, delayPassed else { return }
    if !waitedEnough {
      guard let metadata = LinkMetadataStore.shared.cached(url) else { return }
      let pictures = [metadata.image, metadata.icon].compactMap { $0 }
      guard pictures.allSatisfy(ImageCache.shared.isSettled) else { return }
    }
    show(url)
  }

  func hide() {
    pending?.cancel()
    pending = nil
    timeout?.cancel()
    timeout = nil
    delayPassed = false
    waitedEnough = false
    url = nil
    owner = nil
    guard let card else { return }
    self.card = nil
    lastShown = Date()
    card.onHeightChange = nil
    card.animateDisappear { card.removeFromSuperview() }
  }

  private func show(_ url: URL) {
    timeout?.cancel()
    timeout = nil
    guard self.url == url, let host, NSApp.isActive || Self.testing, NSEvent.pressedMouseButtons == 0 else { return }
    let card = LinkPreviewCard(metadata: LinkMetadataStore.shared.cached(url) ?? LinkMetadata(url: url))
    self.card = card
    let room = anchor.minY - 8
    below = room >= min(card.contentHeight + 150, 260) || anchor.minY > host.bounds.height / 2
    place(card, height: card.contentHeight, animated: false)
    host.addSubview(card)
    card.onHeightChange = { [weak self, weak card] height in
      guard let self, let card, card === self.card else { return }
      self.place(card, height: height, animated: true)
    }
    card.animateAppear()
    lastShown = Date()
  }

  /// Under the link's text (or over it), its left edge at the link's,
  /// inside the window. The root view isn't flipped: y goes up.
  private func place(_ card: LinkPreviewCard, height: CGFloat, animated: Bool) {
    guard let host else { return }
    let rect = host.convert(anchor, from: nil)
    let width = LinkPreviewCard.width
    let x = min(max(8, rect.minX), host.bounds.width - width - 8)
    var y = below ? rect.minY - 6 - height : rect.maxY + 6
    y = min(max(8, y), host.bounds.height - height - 8)
    let frame = NSRect(x: x, y: y, width: width, height: height)
    if animated, !card.frame.isEmpty, !Motion.reduceMotion {
      Motion.animate(0.18, timing: Motion.easeOut) { card.animator().frame = frame }
    } else {
      card.frame = frame
    }
  }
}
