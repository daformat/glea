import AppKit

// The Obsidian flavor of Markdown that Glea reads, so notes written in either
// app work in the other: links to headings and blocks (`[[Note#Heading]]`),
// embeds (`![[image.png]]`, `![[Note]]`), YAML frontmatter (properties, with
// `aliases` and `tags`), `#tags`, `==highlights==`, `%%comments%%` and
// callouts (`> [!note] Title`).

/// What a `[[…]]` link or `![[…]]` embed points to.
struct WikiTarget: Equatable {
  /// The note or file, as written (may be a path, or end in ".md"). Empty
  /// for a link within the same note (`[[#Heading]]`).
  var name: String
  /// A heading, or a block id starting with "^".
  var anchor: String?

  /// Splits "Note#Heading" (or "Note#^block") at its first "#".
  init(_ target: String) {
    let text = target.trimmingCharacters(in: .whitespaces)
    if let hash = text.firstIndex(of: "#") {
      name = String(text[..<hash]).trimmingCharacters(in: .whitespaces)
      let rest = text[text.index(after: hash)...].trimmingCharacters(in: .whitespaces)
      anchor = rest.isEmpty ? nil : rest
    } else {
      name = text
      anchor = nil
    }
  }

  /// The note name a link resolves by: the last path component, without
  /// ".md" ("Projects/Glea.md" → "Glea").
  static func noteName(_ name: String) -> String {
    var base = name.split(separator: "/").last.map(String.init) ?? name
    if base.lowercased().hasSuffix(".md") { base.removeLast(3) }
    return base
  }

  /// The heading it points to, as written (nil for a block or no anchor).
  var heading: String? {
    guard let anchor, !anchor.hasPrefix("^") else { return nil }
    // Nested headings are written "Note#Parent#Child": the last one counts.
    return anchor.split(separator: "#").last.map { $0.trimmingCharacters(in: .whitespaces) }
  }
}

/// A note's YAML frontmatter: a block between "---" lines at its very top.
/// Only what notes use is read: `key: value`, `key: [a, b]` and lists of
/// `- item` lines.
struct Frontmatter {
  /// The block, from the opening "---" to the end of the closing line
  /// (its line break included), in UTF-16.
  let range: NSRange
  /// Lines of the block (indexes into the note's lines), fences included.
  let lineCount: Int
  let properties: [(key: String, values: [String])]

  func values(_ key: String) -> [String] {
    properties.first { $0.key.lowercased() == key }?.values ?? []
  }

  var aliases: [String] { values("aliases") + values("alias") }
  /// Without "#". A tag can't hold a space, so `tags: one two` (or
  /// `one, two`) is two tags, as Obsidian reads it.
  var tags: [String] {
    (values("tags") + values("tag"))
      .flatMap { $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }) }
      .map { $0.hasPrefix("#") ? String($0.dropFirst()) : String($0) }
      .filter { !$0.isEmpty }
  }

  static func parse(_ text: String) -> Frontmatter? {
    guard text.hasPrefix("---") else { return nil }
    let ns = text as NSString
    var lines: [(String, NSRange)] = []
    var closing: Int?
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, _, enclosing, stop in
      let line = line ?? ""
      if lines.isEmpty, line.trimmingCharacters(in: .whitespaces) != "---" {
        stop.pointee = true
        return
      }
      lines.append((line, enclosing))
      if lines.count > 1, ["---", "..."].contains(line.trimmingCharacters(in: .whitespaces)) {
        closing = lines.count - 1
        stop.pointee = true
      }
    }
    guard let closing else { return nil }
    let end = NSMaxRange(lines[closing].1)

    var properties: [(String, [String])] = []
    for (line, _) in lines[1..<closing] {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      if trimmed.hasPrefix("- "), !properties.isEmpty, line.first == " " || line.first == "\t" || line.hasPrefix("-") {
        let item = unquote(String(trimmed.dropFirst(2)))
        if !item.isEmpty { properties[properties.count - 1].1.append(item) }
        continue
      }
      guard let colon = trimmed.firstIndex(of: ":") else { continue }
      let key = unquote(String(trimmed[..<colon]))
      let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      var values: [String] = []
      if value.hasPrefix("["), value.hasSuffix("]") {
        values = value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
      } else if !value.isEmpty {
        values = [unquote(value)]
      }
      properties.append((key, values))
    }
    return Frontmatter(range: NSRange(location: 0, length: end), lineCount: closing + 1, properties: properties)
  }

  private static func unquote(_ text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespaces)
    if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
      value = String(value.dropFirst().dropLast())
    }
    return value
  }

  /// The note's text after its frontmatter.
  static func body(of text: String) -> String {
    guard let frontmatter = parse(text) else { return text }
    return (text as NSString).substring(from: frontmatter.range.length)
  }
}

enum ObsidianSyntax {
  /// `#tag`, as Obsidian reads it: letters, digits, "_", "-" and "/" for
  /// nesting, not only digits ("#1" isn't a tag), not inside a word or URL.
  static let tag = try! NSRegularExpression(
    pattern: "(?<![\\p{L}\\p{N}_&#/\\]\\)])#([\\p{L}\\p{N}_/-]*[\\p{L}_/-][\\p{L}\\p{N}_/-]*)")

  /// Tags written in `text` (without "#"), outside code blocks, inline code
  /// and links, plus those of its frontmatter. Lowercased unless `keepingCase`.
  static func tags(in text: String, keepingCase: Bool = false) -> Set<String> {
    func cased(_ tag: String) -> String { keepingCase ? tag : tag.lowercased() }
    var tags = Set((Frontmatter.parse(text)?.tags ?? []).map(cased))
    guard text.contains("#") else { return tags }
    let ns = text as NSString
    let skipped = noTags.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    for m in tag.matches(in: text, range: NSRange(location: 0, length: ns.length))
      where !skipped.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
      tags.insert(cased(ns.substring(with: m.range(at: 1))))
    }
    return tags
  }

  /// Where a "#" doesn't start a tag: code, links and URLs.
  private static let noTags = try! NSRegularExpression(pattern: [
    "(?ms)^[ \\t]*```.*?(^[ \\t]*```|\\z)",
    "`[^`\\n]+`",
    "\\[\\[[^\\]\\n]*\\]\\]",
    "\\]\\([^)\\n]*\\)",
    "\\b[a-z][a-z0-9+.-]*://\\S+",
  ].joined(separator: "|"), options: [.caseInsensitive])

  /// Callout types, by their aliases, and their colors (as in Obsidian).
  static func calloutColor(_ type: String) -> NSColor {
    switch type.lowercased() {
    case "abstract", "summary", "tldr", "info", "todo": return .systemTeal
    case "tip", "hint", "important": return .systemCyan
    case "success", "check", "done": return .systemGreen
    case "question", "help", "faq", "warning", "caution", "attention": return .systemOrange
    case "failure", "fail", "missing", "danger", "error", "bug": return .systemRed
    case "example": return .systemPurple
    case "quote", "cite": return .systemGray
    default: return .systemBlue  // note
    }
  }

  /// `> [!type]` (optionally "+" or "-", foldable in Obsidian) at the start
  /// of a quote's first line, and its title.
  static let callout = try! NSRegularExpression(pattern: "^\\[!([\\w-]+)\\][+-]?[ \\t]*")
}

// MARK: - Store

extension NoteRef {
  /// From its `id` ("notes/Name", "journal/2026-01-31").
  init?(id: String) {
    let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, let kind = Kind(rawValue: parts[0]) else { return nil }
    self.init(kind: kind, name: parts[1])
  }
}

extension NoteStore {
  /// Every tag the notes use (as first written), with how many notes have it.
  func tagCounts() -> [(tag: String, count: Int)] {
    var counts: [String: (tag: String, count: Int)] = [:]
    for ref in notes + journalDays {
      for tag in ObsidianSyntax.tags(in: content(of: ref), keepingCase: true) {
        counts[tag.lowercased(), default: (tag, 0)].count += 1
      }
    }
    return Array(counts.values)
  }

  /// A file the vault holds that `![[name]]` (or `![[folder/name]]`) points
  /// to: looked for where it's written (from the notes folder, then the
  /// root), then by its name anywhere in the folder, like Obsidian.
  func attachment(named name: String) -> URL? {
    let path = name.removingPercentEncoding ?? name
    for base in [assetsDirectory, notesDirectory, root] {
      let url = base.appendingPathComponent(path).standardizedFileURL
      if url.path.hasPrefix(root.standardizedFileURL.path), FileManager.default.fileExists(atPath: url.path) { return url }
    }
    let file = (path as NSString).lastPathComponent.lowercased()
    return attachmentIndex()[file]
  }
}

// MARK: - Embedded notes

/// A note, or one of its sections, shown inside another (`![[Note]]`,
/// `![[Note#Heading]]`, `![[Note#^block]]`), rendered like the note itself
/// (tables, math, media, embeds) but read-only, and following edits to it.
/// Its name above it opens it.
final class NoteEmbedView: FlippedView {
  let target: WikiTarget
  /// The note holding the embed, for `![[#Heading]]`.
  let host: NoteRef?
  /// The notes it's shown in, outermost first.
  let chain: [String]
  var onOpenLink: ((URL) -> Void)? {
    didSet { editor?.onOpenLink = onOpenLink }
  }
  /// Its height may have changed (the note was edited, media loaded).
  var onContentChange: (() -> Void)?

  private let header = LinkLabel("", size: 12, weight: .medium, color: Theme.tertiaryText)
  /// Along its left edge, like a quote's.
  private let bar = NSView()
  private static let indent: CGFloat = 16
  private let message = NSTextField(wrappingLabelWithString: "")
  private var editor: MarkdownEditorView?
  private var shownRef: NoteRef?
  private static let headerHeight: CGFloat = 22
  private static let inset = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

  init(target: WikiTarget, host: NoteRef?, chain: [String]) {
    self.target = target
    self.host = host
    self.chain = chain
    super.init(frame: .zero)
    header.translatesAutoresizingMaskIntoConstraints = true
    bar.wantsLayer = true
    bar.layer?.cornerRadius = 1.5
    addSubview(bar)
    header.onClick = { [weak self] in self?.open() }
    addSubview(header)
    message.isSelectable = false
    message.font = .systemFont(ofSize: Theme.bodySize)
    message.textColor = Theme.tertiaryText
    addSubview(message)
    build()
    NotificationCenter.default.addObserver(self, selector: #selector(notesChanged(_:)), name: .notesDidChange, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The note it shows (nil when there's none by that name yet).
  private var ref: NoteRef? {
    target.name.isEmpty ? host : NoteStore.shared.resolve(linkName: target.name)
  }

  @objc private func notesChanged(_ notification: Notification) {
    // A note it didn't find may have been created or renamed; the one it
    // shows updates itself.
    if ref != shownRef || (ref != nil && editor == nil) {
      build()
      onContentChange?()
    } else if let ref, editor != nil, (notification.userInfo?["ids"] as? Set<String>)?.contains(ref.id) == true {
      updateMessage()
    }
  }

  private func build() {
    editor?.removeFromSuperview()
    editor = nil
    shownRef = ref
    let name = target.name.isEmpty ? (host?.displayTitle ?? "") : WikiTarget.noteName(target.name)
    let anchor = target.anchor.map { $0.hasPrefix("^") ? String($0.dropFirst()) : $0 }
    header.stringValue = (anchor.map { name.isEmpty ? $0 : "\(name) › \($0)" } ?? name) + "  ↗"
    guard let ref else {
      message.stringValue = "“\(name)” doesn't exist yet"
      message.isHidden = false
      needsLayout = true
      return
    }
    // A note in itself (or in a note it's shown in) would never end.
    let shownIn = chain + [host?.id].compactMap { $0 }
    let ownSection = ref == host && target.anchor != nil
    guard chain.count < 4, ownSection || !shownIn.contains(ref.id) else {
      message.stringValue = "\(ref.displayTitle) is already shown here"
      message.isHidden = false
      needsLayout = true
      return
    }
    let editor = MarkdownEditorView(ref: ref, embedded: target, embedChain: chain + [host?.id].compactMap { $0 })
    editor.onOpenLink = onOpenLink
    editor.onHeightChange = { [weak self] in self?.onContentChange?() }
    addSubview(editor)
    self.editor = editor
    updateMessage()
    needsLayout = true
  }

  /// Says why nothing shows, when the section is missing or empty.
  private func updateMessage() {
    guard let ref, let editor else { return }
    let empty = editor.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    message.isHidden = !empty
    editor.isHidden = empty
    if empty {
      message.stringValue = target.heading.map { "No heading “\($0)” in \(ref.displayTitle)" }
        ?? (target.anchor.map { "No block “\($0)” in \(ref.displayTitle)" } ?? "\(ref.displayTitle) is empty")
    }
  }

  private func open() {
    let written = target.name + (target.anchor.map { "#" + $0 } ?? "")
    let name = target.name.isEmpty ? (host?.name ?? "") + written : written
    if let url = URL(string: "glea-note:" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)) {
      onOpenLink?(url)
    }
  }

  /// The lines it shows: the whole note (without its frontmatter), the
  /// section under a heading (the heading included), or a block's line (its
  /// "^id" removed). Blank lines at either end go.
  static func section(of target: WikiTarget, in content: String) -> [String] {
    var lines = Frontmatter.body(of: content).components(separatedBy: "\n")
    if let heading = target.heading {
      let headings = markdownHeadings(in: lines.joined(separator: "\n"))
      var offsets: [Int] = []
      var offset = 0
      for line in lines {
        offsets.append(offset)
        offset += (line as NSString).length + 1
      }
      guard let start = headings.firstIndex(where: { $0.title.caseInsensitiveCompare(heading) == .orderedSame }),
            let first = offsets.firstIndex(of: headings[start].offset) else { return [] }
      let level = headings[start].level
      let next = headings[(start + 1)...].first { $0.level <= level }
      let last = next.flatMap { offsets.firstIndex(of: $0.offset) } ?? lines.count
      lines = Array(lines[first..<last])
    } else if let anchor = target.anchor, anchor.hasPrefix("^") {
      guard let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix(" " + anchor) }) else { return [] }
      lines = [line.trimmingCharacters(in: .whitespaces).dropLast(anchor.count).trimmingCharacters(in: .whitespaces)]
    }
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
    if lines.count > 80 { lines = Array(lines.prefix(80)) + ["…"] }
    return lines
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    let inset = NoteEmbedView.inset
    var body: CGFloat
    let width = width - NoteEmbedView.indent
    if let editor, !editor.isHidden {
      if abs(editor.frame.width - width) > 0.5 {
        editor.frame.size.width = width
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
      }
      body = editor.intrinsicContentSize.height
    } else {
      body = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 20
    }
    return ceil(NoteEmbedView.headerHeight + body + inset.top + inset.bottom)
  }

  override func layout() {
    super.layout()
    let inset = NoteEmbedView.inset
    header.sizeToFit()
    let indent = NoteEmbedView.indent
    header.frame.origin = NSPoint(x: indent, y: inset.top)
    let top = inset.top + NoteEmbedView.headerHeight
    let rest = NSRect(x: indent, y: top, width: max(0, bounds.width - indent), height: max(0, bounds.height - top - inset.bottom))
    message.frame = rest
    if let editor {
      editor.frame = NSRect(x: indent, y: top, width: rest.width, height: editor.intrinsicContentSize.height)
    }
    bar.layer?.backgroundColor = resolvedCGColor(Theme.accent.withAlphaComponent(0.45))
    bar.frame = NSRect(x: 2, y: inset.top + 2, width: 3, height: max(0, bounds.height - inset.top - inset.bottom - 4))
  }
}

// MARK: - Formatting

extension MarkdownTextView {
  /// Text whose syntax styling would break, wholly or in part.
  private static let unstylable: [(regex: NSRegularExpression, whole: Bool)] = [
    // Embeds, link targets and media lines: not even whole.
    (try! NSRegularExpression(pattern: "!\\[\\[[^\\]\\n]*\\]\\]"), false),
    (try! NSRegularExpression(pattern: "\\]\\([^)\\n]*\\)"), false),
    // Links, code, URLs, tags and block ids: whole is fine (**[[Note]]**).
    (try! NSRegularExpression(pattern: "\\[\\[[^\\]\\n]*\\]\\]"), true),
    (try! NSRegularExpression(pattern: "`[^`\\n]+`"), true),
    (try! NSRegularExpression(pattern: "\\b[a-z][a-z0-9+.-]*://\\S+", options: .caseInsensitive), true),
    (ObsidianSyntax.tag, true),
    (try! NSRegularExpression(pattern: "\\s\\^[\\w-]+$", options: .anchorsMatchLines), true),
  ]

  /// Whether the formatting bar offers styling `range`: not in a formula,
  /// code, an embed, a link's address, the frontmatter or a media line, nor
  /// in part of a link, URL or tag.
  func allowsFormatting(_ range: NSRange) -> Bool {
    if isInMath(range) { return false }
    let s = string as NSString
    if let frontmatter = Frontmatter.parse(string), range.location < NSMaxRange(frontmatter.range) { return false }
    // Fenced code: inside a block, or across a fence.
    let fences = MarkdownStyler.fenceLineStarts(in: s)
    if fences.filter({ $0 <= range.location }).count % 2 == 1 { return false }
    if fences.contains(where: { $0 > range.location && $0 < NSMaxRange(range) }) { return false }
    let lines = s.lineRange(for: range)
    var media = false
    s.enumerateSubstrings(in: lines, options: .byLines) { line, _, _, stop in
      if let line, MarkdownStyler.mediaSourceHint(line) != nil {
        media = true
        stop.pointee = true
      }
    }
    if media { return false }
    for (regex, whole) in MarkdownTextView.unstylable {
      for m in regex.matches(in: string, range: lines) where NSIntersectionRange(m.range, range).length > 0 {
        let covers = range.location <= m.range.location && NSMaxRange(range) >= NSMaxRange(m.range)
        if !whole || !covers { return false }
      }
    }
    return true
  }
}

extension MarkdownStyler {
  /// Where the lines opening or closing fenced code ("```", "~~~") start.
  static func fenceLineStarts(in text: NSString) -> [Int] {
    var starts: [Int] = []
    text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, _ in
      let trimmed = line?.trimmingCharacters(in: .whitespaces) ?? ""
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { starts.append(range.location) }
    }
    return starts
  }
}
