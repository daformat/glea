import AppKit

/// A note or journal day. Each one is a Markdown file:
/// `<root>/notes/<name>.md` (or `<root>/notes/<group>/<name>.md`, see
/// `NoteStore.groups`) or `<root>/journal/<yyyy-MM-dd>.md`.
struct NoteRef: Hashable {
  enum Kind: String {
    case note = "notes"
    case journal
  }

  let kind: Kind
  let name: String

  var id: String { "\(kind.rawValue)/\(name)" }

  static func journal(_ date: Date) -> NoteRef {
    NoteRef(kind: .journal, name: NoteStore.dayFormatter.string(from: date))
  }

  var date: Date? { kind == .journal ? NoteStore.dayFormatter.date(from: name) : nil }

  var displayTitle: String {
    guard let date else { return name }
    return NoteStore.longDateFormatter.string(from: date)
  }
}

extension Notification.Name {
  /// userInfo["ids"] holds the Set<String> of changed note ids (empty when
  /// only the groups changed).
  static let notesDidChange = Notification.Name("GleaNotesDidChange")
}

/// Content collected from a web page with point-and-shoot or the context menu.
struct Capture {
  enum Kind: String {
    case element, selection, image, page
  }

  var kind: Kind
  var markdown: String
  var text: String
  var pageURL: String
  var pageTitle: String
  /// PNG of an area capture, written to assets/ only when collected.
  var imageData: Data? = nil
}

@MainActor
final class NoteStore {
  static let shared = NoteStore()

  nonisolated static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  nonisolated static let longDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .full
    return f
  }()

  private struct Entry {
    var content: String
    var modified: Date
    /// The group (folder in notes/) it's in, "" for none.
    var folder = ""
  }

  private(set) var root: URL
  private var entries: [NoteRef: Entry] = [:]
  /// The folders in notes/ that are groups (see `isGroupFolder`).
  private var groupFolders: Set<String> = []
  /// The group each note moved to the Trash was in, to put it back there.
  private var trashedFolders: [NoteRef: String] = [:]
  /// Notes by their frontmatter aliases (lowercased), built when needed.
  private var aliasIndex: [String: NoteRef]?
  /// Files other than notes, by their lowercased name (see `attachment`).
  private var attachments: [String: URL]?
  private var eventStream: FSEventStreamRef?

  var notesDirectory: URL { root.appendingPathComponent("notes", isDirectory: true) }
  var journalDirectory: URL { root.appendingPathComponent("journal", isDirectory: true) }
  var assetsDirectory: URL { root.appendingPathComponent("assets", isDirectory: true) }

  private init() {
    root = NoteStore.configuredRoot()
    load()
  }

  static func configuredRoot() -> URL {
    if let env = ProcessInfo.processInfo.environment["GLEA_DATA_DIR"] {
      return URL(fileURLWithPath: env, isDirectory: true)
    }
    if let saved = UserDefaults.standard.string(forKey: "dataDirectory") {
      return URL(fileURLWithPath: saved, isDirectory: true)
    }
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documents.appendingPathComponent("Glea", isDirectory: true)
  }

  func changeRoot(to url: URL) {
    UserDefaults.standard.set(url.path, forKey: "dataDirectory")
    root = url
    load()
    postChange(Set(entries.keys.map(\.id)))
  }

  // MARK: Loading

  private func load() {
    stopWatching()
    entries = [:]
    groupFolders = []
    aliasIndex = nil
    attachments = nil
    let fm = FileManager.default
    for dir in [notesDirectory, journalDirectory, assetsDirectory] {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    for kind in [NoteRef.Kind.note, .journal] {
      let dir = directory(for: kind)
      let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for file in files where file.pathExtension.lowercased() == "md" {
        let ref = NoteRef(kind: kind, name: file.deletingPathExtension().lastPathComponent)
        if kind == .journal && ref.date == nil { continue }
        if let entry = readEntry(at: file) { entries[ref] = entry }
      }
    }
    // Groups: one level of folders in notes/. (A name already taken, at the
    // top or in another group, keeps its first note.)
    let folders = (try? fm.contentsOfDirectory(at: notesDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for folder in folders where isGroupFolder(folder) {
      let name = folder.lastPathComponent
      groupFolders.insert(name)
      let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for file in files where file.pathExtension.lowercased() == "md" {
        let ref = NoteRef(kind: .note, name: file.deletingPathExtension().lastPathComponent)
        if entries[ref] == nil, var entry = readEntry(at: file) {
          entry.folder = name
          entries[ref] = entry
        }
      }
    }
    startWatching()
  }

  /// A folder in notes/ is a group when it holds notes, or nothing (a folder
  /// of images or other files isn't one).
  private func isGroupFolder(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard !name.hasPrefix("."), (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
    return files.isEmpty || files.contains { ($0 as NSString).pathExtension.lowercased() == "md" }
  }

  private func readEntry(at url: URL) -> Entry? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
    return Entry(content: String(decoding: data, as: UTF8.self), modified: modified)
  }

  private func directory(for kind: NoteRef.Kind) -> URL {
    kind == .note ? notesDirectory : journalDirectory
  }

  private func groupDirectory(_ folder: String) -> URL {
    folder.isEmpty ? notesDirectory : notesDirectory.appendingPathComponent(folder, isDirectory: true)
  }

  func fileURL(for ref: NoteRef) -> URL {
    fileURL(for: ref, folder: entries[ref]?.folder ?? "")
  }

  private func fileURL(for ref: NoteRef, folder: String) -> URL {
    let dir = ref.kind == .note ? groupDirectory(folder) : journalDirectory
    return dir.appendingPathComponent(ref.name).appendingPathExtension("md")
  }

  // MARK: Queries

  func exists(_ ref: NoteRef) -> Bool { entries[ref] != nil }

  func content(of ref: NoteRef) -> String { entries[ref]?.content ?? "" }

  func modified(_ ref: NoteRef) -> Date? { entries[ref]?.modified }

  /// Notes (not journal days), most recently edited first.
  var notes: [NoteRef] {
    entries.filter { $0.key.kind == .note }
      .sorted { $0.value.modified > $1.value.modified }
      .map(\.key)
  }

  /// Journal days with content, newest first.
  var journalDays: [NoteRef] {
    entries.keys.filter { $0.kind == .journal }.sorted { $0.name > $1.name }
  }

  var noteNames: [String] { notes.map(\.name) }

  var today: NoteRef { .journal(Date()) }

  /// Finds the note a `[[name]]` link points to (case-insensitive): by its
  /// name (a path or ".md" is fine, as Obsidian writes them), or one of the
  /// `aliases` in its frontmatter.
  func resolve(linkName: String) -> NoteRef? {
    let written = linkName.trimmingCharacters(in: .whitespaces)
    if let ref = note(named: written) { return ref }
    let name = WikiTarget.noteName(written)
    if let date = NoteStore.dayFormatter.date(from: name) { return .journal(date) }
    if name != written, let ref = note(named: name) { return ref }
    return aliases()[name.lowercased()]
  }

  /// The note with exactly this name (case-insensitive), or the journal day.
  private func note(named name: String) -> NoteRef? {
    let wanted = name.lowercased()
    if let date = NoteStore.dayFormatter.date(from: wanted) { return .journal(date) }
    return entries.keys.first { $0.kind == .note && $0.name.lowercased() == wanted }
  }

  private func aliases() -> [String: NoteRef] {
    if let aliasIndex { return aliasIndex }
    var index: [String: NoteRef] = [:]
    for (ref, entry) in entries where ref.kind == .note && entry.content.hasPrefix("---") {
      for alias in Frontmatter.parse(entry.content)?.aliases ?? [] { index[alias.lowercased()] = index[alias.lowercased()] ?? ref }
    }
    aliasIndex = index
    return index
  }

  /// The aliases `ref`'s frontmatter gives it.
  func aliases(of ref: NoteRef) -> [String] {
    let content = content(of: ref)
    return content.hasPrefix("---") ? Frontmatter.parse(content)?.aliases ?? [] : []
  }

  /// Files in the notes folder that aren't notes, by lowercased name.
  func attachmentIndex() -> [String: URL] {
    if let attachments { return attachments }
    var index: [String: URL] = [:]
    let skipped: Set<String> = [".obsidian", ".git", ".trash", "node_modules"]
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) {
      for case let url as URL in files {
        if skipped.contains(url.lastPathComponent) {
          files.skipDescendants()
          continue
        }
        let name = url.lastPathComponent.lowercased()
        guard url.pathExtension.lowercased() != "md", !name.hasPrefix("."), index[name] == nil,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
        index[name] = url
      }
    }
    attachments = index
    return index
  }

  /// Markdown reduced to readable text, for snippets and excerpts.
  nonisolated static func plainText(_ markdown: String) -> String {
    var text = Frontmatter.body(of: markdown)
    let replacements: [(String, String)] = [
      ("%%.*?%%", ""),
      ("(?m)\\s\\^[\\w-]+$", ""),
      ("(?m)^(\\s*>\\s?)+\\[![\\w-]+\\][+-]?[ \\t]*", ""),
      ("==(?=\\S)(.+?)(?<=\\S)==", "$1"),
      ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
      ("!?\\[\\[[^\\]|]*\\|([^\\]]+)\\]\\]", "$1"),
      ("!?\\[\\[([^\\]#|]+)(#[^\\]|]*)?\\]\\]", "$1"),
      ("!?\\[\\[#\\^?([^\\]|]*)\\]\\]", "$1"),
      ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
      ("(?m)^\\s*(#{1,6}|>|[-*+]( \\[[ xX]\\])?|\\d+[.)])\\s+", ""),
      ("(\\*\\*|__|~~|`)", ""),
      ("(?<![\\w*])[*_](?=\\S)|(?<=\\S)[*_](?![\\w*])", ""),
    ]
    for (pattern, template) in replacements {
      text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return text
  }

  func excerpt(of ref: NoteRef, length: Int = 140) -> String {
    let body = NoteStore.plainText(content(of: ref))
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return String(body.prefix(length))
  }

  struct SearchResult {
    let ref: NoteRef
    let snippet: String
    let score: Int
  }

  func search(_ query: String, limit: Int = 8) -> [SearchResult] {
    let terms = query.lowercased().split(separator: " ").map(String.init)
    guard !terms.isEmpty else { return [] }
    var results: [SearchResult] = []
    for (ref, entry) in entries {
      let title = ref.displayTitle.lowercased()
      let body = entry.content.lowercased()
      var score = 0
      var matchedAll = true
      var tags: Set<String>?
      for term in terms {
        // "#tag" finds the notes tagged with it (or a tag nested in it).
        if term.count > 1, term.hasPrefix("#") {
          if tags == nil { tags = ObsidianSyntax.tags(in: entry.content) }
          let tag = String(term.dropFirst())
          if tags!.contains(where: { $0 == tag || $0.hasPrefix(tag + "/") }) {
            score += 10
            continue
          }
          matchedAll = false
          break
        }
        if title.hasPrefix(term) { score += 30 } else if title.contains(term) { score += 20 } else if body.contains(term) {
          score += 5
        } else {
          matchedAll = false
          break
        }
      }
      guard matchedAll else { continue }
      if ref.kind == .note { score += 2 }
      results.append(SearchResult(ref: ref, snippet: snippet(in: NoteStore.plainText(entry.content), around: terms[0]), score: score))
    }
    return Array(results.sorted {
      $0.score != $1.score ? $0.score > $1.score : (entries[$0.ref]?.modified ?? .distantPast) > (entries[$1.ref]?.modified ?? .distantPast)
    }.prefix(limit))
  }

  private func snippet(in content: String, around term: String) -> String {
    guard let range = content.range(of: term, options: .caseInsensitive) else {
      return String(content.prefix(100)).replacingOccurrences(of: "\n", with: " ")
    }
    let start = content.index(range.lowerBound, offsetBy: -40, limitedBy: content.startIndex) ?? content.startIndex
    let end = content.index(range.upperBound, offsetBy: 60, limitedBy: content.endIndex) ?? content.endIndex
    let text = content[start..<end].replacingOccurrences(of: "\n", with: " ")
    return (start > content.startIndex ? "…" : "") + text + (end < content.endIndex ? "…" : "")
  }

  /// Notes that link to `ref` with `[[name]]` (or `[[name#heading]]`, or
  /// one of its aliases), with the lines containing the link.
  func backlinks(to ref: NoteRef) -> [(ref: NoteRef, lines: [String])] {
    let needles = ([ref.name] + aliases(of: ref)).map { "[[\($0.lowercased())" }
    var result: [(NoteRef, [String])] = []
    for (other, entry) in entries where other != ref {
      let content = entry.content.lowercased()
      guard needles.contains(where: content.contains) else { continue }
      let lines = entry.content.split(separator: "\n").filter { line in
        let lower = line.lowercased()
        return needles.contains { lower.contains($0 + "]]") || lower.contains($0 + "|") || lower.contains($0 + "#") }
      }.map { $0.trimmingCharacters(in: .whitespaces) }
      if !lines.isEmpty { result.append((other, lines)) }
    }
    return result.sorted { ($0.0.kind == .journal ? $0.0.name : "~" + $0.0.name) > ($1.0.kind == .journal ? $1.0.name : "~" + $1.0.name) }
  }

  /// A place where a note's name appears as plain text, not as a link.
  struct Mention {
    /// The name as written, in the source's content (UTF-16).
    let range: NSRange
    /// The line it's on, and where the name is in that line.
    let line: String
    let rangeInLine: NSRange
  }

  /// Text that never becomes a link: code, links, images and URLs.
  nonisolated(unsafe) private static let unlinkableText = try! NSRegularExpression(pattern: [
    "(?ms)^[ \\t]*```.*?(^[ \\t]*```|\\z)",
    "`[^`\\n]+`",
    "\\[\\[[^\\]\\n]*\\]\\]",
    "!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)",
    "<[a-z][a-z0-9+.-]*:[^>\\s]*>",
    "\\b[a-z][a-z0-9+.-]*://\\S+",
  ].joined(separator: "|"), options: [.caseInsensitive])

  /// Notes and days that mention `ref`'s name without linking to it (Beam's
  /// unlinked references): whole words, case-insensitive, outside code and
  /// links. Only notes are looked for; day names aren't written as text.
  func unlinkedReferences(to ref: NoteRef) -> [(ref: NoteRef, mentions: [Mention])] {
    let name = ref.name
    guard ref.kind == .note, name.count >= 2 else { return [] }
    var result: [(NoteRef, [Mention])] = []
    for (other, entry) in entries where other != ref {
      let mentions = NoteStore.mentions(of: name, in: entry.content)
      if !mentions.isEmpty { result.append((other, mentions)) }
    }
    return result.sorted { ($0.0.kind == .journal ? $0.0.name : "~" + $0.0.name) > ($1.0.kind == .journal ? $1.0.name : "~" + $1.0.name) }
  }

  nonisolated static func mentions(of name: String, in content: String) -> [Mention] {
    guard content.range(of: name, options: .caseInsensitive) != nil else { return [] }
    let text = content as NSString
    var excluded = unlinkableText.matches(in: content, range: NSRange(location: 0, length: text.length)).map(\.range)
    if let frontmatter = Frontmatter.parse(content) { excluded.append(frontmatter.range) }
    let wordEdges = (first: name.unicodeScalars.first.map(isWordCharacter) ?? false,
                     last: name.unicodeScalars.last.map(isWordCharacter) ?? false)
    var mentions: [Mention] = []
    var searchStart = 0
    while searchStart < text.length {
      let found = text.range(of: name, options: .caseInsensitive, range: NSRange(location: searchStart, length: text.length - searchStart))
      guard found.location != NSNotFound else { break }
      searchStart = found.upperBound
      // Whole words only: "Go" isn't mentioned in "Google".
      if wordEdges.first, found.location > 0, isWordCharacter(at: found.location - 1, in: text) { continue }
      if wordEdges.last, found.upperBound < text.length, isWordCharacter(at: found.upperBound, in: text) { continue }
      if excluded.contains(where: { NSIntersectionRange($0, found).length > 0 }) { continue }
      let lineRange = text.lineRange(for: found)
      var line = text.substring(with: lineRange)
      while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
      mentions.append(Mention(range: found, line: line,
                              rangeInLine: NSRange(location: found.location - lineRange.location, length: found.length)))
    }
    return mentions
  }

  private nonisolated static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
  }

  private nonisolated static func isWordCharacter(at index: Int, in text: NSString) -> Bool {
    let range = text.rangeOfComposedCharacterSequence(at: index)
    return text.substring(with: range).unicodeScalars.first.map(isWordCharacter) ?? false
  }

  /// Turns mentions of `target` in `source` into `[[links]]`, keeping the
  /// text as written (links resolve case-insensitively). Mentions that no
  /// longer match the content (it changed since) are left alone.
  func link(_ mentions: [Mention], in source: NoteRef, to target: NoteRef) {
    let current = content(of: source)
    let stillMentioned = Set(NoteStore.mentions(of: target.name, in: current).map(\.range))
    let text = NSMutableString(string: current)
    for mention in mentions.sorted(by: { $0.range.location > $1.range.location }) where stillMentioned.contains(mention.range) {
      let written = text.substring(with: mention.range)
      text.replaceCharacters(in: mention.range, with: "[[\(written)]]")
    }
    save(source, content: text as String)
  }

  // MARK: Mutations

  func save(_ ref: NoteRef, content: String) {
    if let existing = entries[ref], existing.content == content { return }
    // Don't litter the journal folder with empty days.
    if ref.kind == .journal && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entries[ref] == nil {
      return
    }
    let url = fileURL(for: ref)
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try content.write(to: url, atomically: true, encoding: .utf8)
      entries[ref] = Entry(content: content, modified: Date(), folder: entries[ref]?.folder ?? "")
      if ref.kind == .note { aliasIndex = nil }
      postChange([ref.id])
    } catch {
      NSLog("Glea: failed to save \(url.path): \(error)")
    }
  }

  static func sanitize(_ name: String) -> String {
    var cleaned = name.replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    return String(cleaned.prefix(200))
  }

  /// Creates an empty note, or returns the existing one with the same name.
  @discardableResult
  /// A note (not a journal day) with this name exists, as `createNote`
  /// would name it (case-insensitive).
  func hasNote(named title: String) -> Bool {
    let name = NoteStore.sanitize(title).lowercased()
    return !name.isEmpty && entries.keys.contains { $0.kind == .note && $0.name.lowercased() == name }
  }

  func createNote(named title: String) -> NoteRef {
    let name = NoteStore.sanitize(title).isEmpty ? "Untitled" : NoteStore.sanitize(title)
    if let existing = note(named: name) { return existing }
    let ref = NoteRef(kind: .note, name: name)
    let url = fileURL(for: ref)
    try? "".write(to: url, atomically: true, encoding: .utf8)
    entries[ref] = Entry(content: "", modified: Date())
    postChange([ref.id])
    return ref
  }

  func uniqueUntitledName() -> String {
    var name = "Untitled"
    var i = 2
    while note(named: name) != nil {
      name = "Untitled \(i)"
      i += 1
    }
    return name
  }

  enum RenameError: Error {
    case invalidName, alreadyExists
  }

  /// Renames a note and rewrites every `[[old name]]` link to it.
  func rename(_ ref: NoteRef, to newTitle: String) -> Result<NoteRef, RenameError> {
    let name = NoteStore.sanitize(newTitle)
    guard ref.kind == .note, !name.isEmpty else { return .failure(.invalidName) }
    if name == ref.name { return .success(ref) }
    if let existing = note(named: name), existing != ref { return .failure(.alreadyExists) }

    let newRef = NoteRef(kind: .note, name: name)
    do {
      let source = fileURL(for: ref)
      let dest = fileURL(for: newRef, folder: entries[ref]?.folder ?? "")
      if source.path.lowercased() == dest.path.lowercased() {
        // Case-only rename on a case-insensitive volume needs a hop.
        let temp = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try FileManager.default.moveItem(at: source, to: temp)
        try FileManager.default.moveItem(at: temp, to: dest)
      } else {
        try FileManager.default.moveItem(at: source, to: dest)
      }
    } catch {
      NSLog("Glea: rename failed: \(error)")
      return .failure(.invalidName)
    }
    entries[newRef] = entries.removeValue(forKey: ref)
    aliasIndex = nil

    // Links to a heading or block in it too ("[[Old#Heading]]").
    let pattern = "\\[\\[" + NSRegularExpression.escapedPattern(for: ref.name) + "(\\||\\]\\]|#)"
    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
      let template = "[[" + NSRegularExpression.escapedTemplate(for: name) + "$1"
      for (other, entry) in entries {
        let range = NSRange(entry.content.startIndex..., in: entry.content)
        guard regex.firstMatch(in: entry.content, range: range) != nil else { continue }
        save(other, content: regex.stringByReplacingMatches(in: entry.content, range: range, withTemplate: template))
      }
    }
    ActivityLog.shared.renamed(ref, to: newRef)
    postChange([ref.id, newRef.id])
    return .success(newRef)
  }

  /// Moves the note's file to the Trash.
  /// A note created and never written in: still "Untitled" (or "Untitled
  /// 2"...), with no text.
  func isUntouched(_ ref: NoteRef) -> Bool {
    ref.kind == .note && ref.name.range(of: "^Untitled( \\d+)?$", options: .regularExpression) != nil
      && content(of: ref).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Removes an untouched note's (empty) file, not to the Trash.
  func discard(_ ref: NoteRef) {
    try? FileManager.default.removeItem(at: fileURL(for: ref))
    entries[ref] = nil
    postChange([ref.id])
  }

  /// Moves the note to the Trash. Returns where it went there (to put it
  /// back with `restore`).
  @discardableResult
  func delete(_ ref: NoteRef) -> URL? {
    let url = fileURL(for: ref)
    var trashed: NSURL?
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
    }
    trashedFolders[ref] = entries[ref]?.folder
    entries[ref] = nil
    aliasIndex = nil
    postChange([ref.id])
    return trashed as URL?
  }

  /// Puts a note moved to the Trash back. False if it's no longer there, or
  /// another note has its name now.
  @discardableResult
  func restore(_ ref: NoteRef, from trashed: URL) -> Bool {
    // Back in its group, if it's still there.
    let folder = trashedFolders.removeValue(forKey: ref).flatMap { groupFolders.contains($0) ? $0 : nil } ?? ""
    let url = fileURL(for: ref, folder: folder)
    guard !FileManager.default.fileExists(atPath: url.path),
          (try? FileManager.default.moveItem(at: trashed, to: url)) != nil else { return false }
    if var entry = readEntry(at: url) {
      entry.folder = folder
      entries[ref] = entry
    }
    postChange([ref.id])
    return true
  }

  // MARK: Groups

  /// The groups notes can be in: the folders in notes/, by name.
  var groups: [String] {
    groupFolders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// The group `ref` is in, nil for none.
  func group(of ref: NoteRef) -> String? {
    guard let folder = entries[ref]?.folder, !folder.isEmpty else { return nil }
    return folder
  }

  /// A name for a new group: `base`, or `base 2`...
  func uniqueGroupName(_ base: String = "New Group") -> String {
    var name = base
    var i = 2
    while hasGroup(named: name) {
      name = "\(base) \(i)"
      i += 1
    }
    return name
  }

  func hasGroup(named name: String) -> Bool {
    groupFolders.contains { $0.lowercased() == name.lowercased() }
  }

  /// Makes an empty group. Nil if the name isn't usable or is taken.
  @discardableResult
  func createGroup(named title: String) -> String? {
    let name = NoteStore.sanitize(title)
    guard !name.isEmpty, !hasGroup(named: name),
          (try? FileManager.default.createDirectory(at: groupDirectory(name), withIntermediateDirectories: true)) != nil else { return nil }
    groupFolders.insert(name)
    postChange([])
    return name
  }

  /// Moves `refs` into `group` (nil: out of their groups). Links to images
  /// and files relative to a note are rewritten to still point there.
  func move(_ refs: [NoteRef], toGroup group: String?) {
    let folder = group ?? ""
    guard folder.isEmpty || groupFolders.contains(folder) else { return }
    var moved = Set<String>()
    for ref in refs where ref.kind == .note {
      guard var entry = entries[ref], entry.folder != folder else { continue }
      let source = fileURL(for: ref)
      let dest = fileURL(for: ref, folder: folder)
      guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
      let content = NoteStore.rebasingLinks(in: entry.content, from: source.deletingLastPathComponent(),
                                            to: dest.deletingLastPathComponent())
      do {
        try FileManager.default.moveItem(at: source, to: dest)
        if content != entry.content { try content.write(to: dest, atomically: true, encoding: .utf8) }
      } catch {
        NSLog("Glea: moving \(ref.name) failed: \(error)")
        continue
      }
      // (Moving doesn't count as editing: it keeps its place in the list.)
      if content != entry.content {
        try? FileManager.default.setAttributes([.modificationDate: entry.modified], ofItemAtPath: dest.path)
      }
      entry.folder = folder
      entry.content = content
      entries[ref] = entry
      moved.insert(ref.id)
    }
    if !moved.isEmpty { postChange(moved) }
  }

  /// Renames a group (its folder). Nil if the name isn't usable or is taken.
  func renameGroup(_ group: String, to title: String) -> String? {
    let name = NoteStore.sanitize(title)
    guard groupFolders.contains(group), !name.isEmpty else { return nil }
    if name == group { return group }
    guard !groupFolders.contains(where: { $0 != group && $0.lowercased() == name.lowercased() }) else { return nil }
    do {
      let source = groupDirectory(group)
      if group.lowercased() == name.lowercased() {
        // Case-only rename on a case-insensitive volume needs a hop.
        let temp = notesDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: source, to: temp)
        try FileManager.default.moveItem(at: temp, to: groupDirectory(name))
      } else {
        try FileManager.default.moveItem(at: source, to: groupDirectory(name))
      }
    } catch {
      NSLog("Glea: renaming group \(group) failed: \(error)")
      return nil
    }
    groupFolders.remove(group)
    groupFolders.insert(name)
    var ids = Set<String>()
    for (ref, entry) in entries where entry.folder == group {
      entries[ref]?.folder = name
      ids.insert(ref.id)
    }
    postChange(ids)
    return name
  }

  /// Removes a group: its notes go back to the top level, and its folder
  /// (with anything else left in it) to the Trash.
  func deleteGroup(_ group: String) {
    guard groupFolders.contains(group) else { return }
    let refs = entries.filter { $0.value.folder == group }.map(\.key)
    move(refs, toGroup: nil)
    let dir = groupDirectory(group)
    let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }
    if left.isEmpty { try? FileManager.default.removeItem(at: dir) } else { try? FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
    groupFolders.remove(group)
    // Notes that couldn't move out (a name taken at the top) went with it.
    for ref in refs where entries[ref]?.folder == group { entries[ref] = nil }
    postChange(Set(refs.map(\.id)))
  }

  /// Markdown links (`](path)`, `src="path"`) relative to `old` that point to
  /// a file, made relative to `new`.
  nonisolated static func rebasingLinks(in content: String, from old: URL, to new: URL) -> String {
    guard old.standardizedFileURL != new.standardizedFileURL,
          let link = try? NSRegularExpression(pattern: #"(?:\]\(|src=")([^)"\s]+)"#) else { return content }
    let ns = content as NSString
    var result = content
    var done = Set<String>()
    for match in link.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
      let source = ns.substring(with: match.range(at: 1))
      guard !done.contains(source), !source.contains("://"), !source.hasPrefix("#"), !source.hasPrefix("/"),
            !source.hasPrefix("mailto:") else { continue }
      done.insert(source)
      let path = source.removingPercentEncoding ?? source
      let target = old.appendingPathComponent(path).standardizedFileURL
      guard FileManager.default.fileExists(atPath: target.path) else { continue }
      var rebased = relativePath(to: target, from: new.standardizedFileURL)
      if source != path { rebased = rebased.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rebased }
      result = result.replacingOccurrences(of: "](\(source)", with: "](\(rebased)")
        .replacingOccurrences(of: "src=\"\(source)", with: "src=\"\(rebased)")
    }
    return result
  }

  private nonisolated static func relativePath(to target: URL, from directory: URL) -> String {
    let to = target.pathComponents, from = directory.pathComponents
    var common = 0
    while common < min(to.count, from.count), to[common] == from[common] { common += 1 }
    return (Array(repeating: "..", count: from.count - common) + to[common...]).joined(separator: "/")
  }

  func append(_ markdown: String, to ref: NoteRef) {
    var content = content(of: ref)
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    content = trimmed.isEmpty ? markdown + "\n" : content.replacingOccurrences(
      of: "\\s+$", with: "", options: .regularExpression) + "\n\n" + markdown + "\n"
    save(ref, content: content)
  }

  // MARK: Captures

  /// Appends a capture to `ref`, first downloading its images into `assets/`
  /// so notes keep working offline and when exported.
  func collect(_ capture: Capture, into ref: NoteRef, completion: @escaping () -> Void) {
    var capture = capture
    if let data = capture.imageData {
      let name = UUID().uuidString.prefix(12).lowercased() + ".png"
      if (try? data.write(to: assetsDirectory.appendingPathComponent(name))) != nil {
        let alt = capture.pageTitle.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        capture.markdown = "![\(alt)](../assets/\(name))"
      }
    }
    let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\((https?://[^)\\s]+)\\)")
    let markdown = capture.markdown
    let matches = imageRegex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
    let remoteURLs = Set(matches.compactMap { Range($0.range(at: 2), in: markdown).map { String(markdown[$0]) } })

    let group = DispatchGroup()
    var localPaths: [String: String] = [:]
    for remote in remoteURLs {
      guard let url = URL(string: remote) else { continue }
      group.enter()
      downloadAsset(url) { local in
        if let local { localPaths[remote] = local }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      var body = markdown
      for (remote, local) in localPaths {
        body = body.replacingOccurrences(of: "](\(remote))", with: "](\(local))")
      }
      // (Links made from notes/: from a group's folder, they go up one more.)
      let entry = NoteStore.rebasingLinks(in: NoteStore.format(capture, body: body), from: self.notesDirectory,
                                          to: self.fileURL(for: ref).deletingLastPathComponent())
      self.append(entry, to: ref)
      ActivityLog.shared.collected(into: ref)
      completion()
    }
  }

  private func downloadAsset(_ url: URL, completion: @escaping (String?) -> Void) {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    let assets = assetsDirectory
    URLSession.shared.dataTask(with: request) { data, response, _ in
      var result: String?
      if let data, !data.isEmpty, data.count < 25_000_000,
         let mime = (response as? HTTPURLResponse)?.mimeType, mime.hasPrefix("image/") {
        let ext: String
        switch mime {
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/svg+xml": ext = "svg"
        case "image/avif": ext = "avif"
        default: ext = "jpg"
        }
        let name = UUID().uuidString.prefix(12).lowercased() + "." + ext
        let dest = assets.appendingPathComponent(name)
        if (try? data.write(to: dest)) != nil { result = "../assets/" + name }
      }
      DispatchQueue.main.async { completion(result) }
    }.resume()
  }

  /// Stores an image in assets/ and returns its path relative to notes/
  /// (see `rebasingLinks` for a note in a group).
  func saveImageAsset(data: Data, fileExtension: String) -> String? {
    let ext = fileExtension.isEmpty ? "png" : fileExtension.lowercased()
    let name = UUID().uuidString.prefix(12).lowercased() + "." + ext
    try? FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
    guard (try? data.write(to: assetsDirectory.appendingPathComponent(name))) != nil else { return nil }
    attachments = nil
    return "../assets/" + name
  }

  static func format(_ capture: Capture, body: String) -> String {
    let title = (capture.pageTitle.isEmpty ? capture.pageURL : capture.pageTitle)
      .replacingOccurrences(of: "[", with: "(")
      .replacingOccurrences(of: "]", with: ")")
    let url = capture.pageURL
      .replacingOccurrences(of: " ", with: "%20")
      .replacingOccurrences(of: "(", with: "%28")
      .replacingOccurrences(of: ")", with: "%29")
    let source = "[\(title)](\(url))"
    if capture.kind == .page { return "- \(source)" }

    // A lone image or video, or a post or video the notes embed (its bare
    // address), stands as a media block, credited below.
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.contains("\n"), (trimmed.hasPrefix("![") && trimmed.hasSuffix(")")) || EmbedProvider.match(trimmed) != nil {
      return "\(trimmed)\n— \(source)"
    }
    let quoted = trimmed
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.isEmpty ? ">" : "> \($0)" }
      .joined(separator: "\n")
    return "\(quoted)\n>\n> — \(source)"
  }

  // MARK: Export

  /// Writes one note to `file`. Its local images and videos are copied into
  /// a "<name> assets" folder beside it, and the links point there.
  func export(_ ref: NoteRef, to file: URL) throws {
    var content = content(of: ref)
    let base = fileURL(for: ref).deletingLastPathComponent()
    let assetsName = file.deletingPathExtension().lastPathComponent + " assets"
    let assetsFolder = file.deletingLastPathComponent().appendingPathComponent(assetsName, isDirectory: true)
    let link = try NSRegularExpression(pattern: "\\]\\(([^)\\s]+)")
    let ns = content as NSString
    var copied: [String: String] = [:]
    for match in link.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
      let source = ns.substring(with: match.range(at: 1))
      guard copied[source] == nil, !source.contains("://"), !source.hasPrefix("#"), !source.hasPrefix("mailto:") else { continue }
      let original = base.appendingPathComponent(source.removingPercentEncoding ?? source).standardizedFileURL
      guard original.pathExtension.lowercased() != "md", FileManager.default.fileExists(atPath: original.path) else { continue }
      try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
      let destination = assetsFolder.appendingPathComponent(original.lastPathComponent)
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.copyItem(at: original, to: destination)
      let encoded = assetsName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetsName
      copied[source] = encoded + "/" + original.lastPathComponent
    }
    for (source, exported) in copied {
      content = content.replacingOccurrences(of: "](\(source)", with: "](\(exported)")
    }
    try content.write(to: file, atomically: true, encoding: .utf8)
  }

  /// Copies notes, journal and assets into a new folder inside `destination`.
  func exportAll(to destination: URL) throws -> URL {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH.mm"
    let folder = destination.appendingPathComponent("Glea Export \(stamp.string(from: Date()))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for dir in [notesDirectory, journalDirectory, assetsDirectory] {
      try FileManager.default.copyItem(at: dir, to: folder.appendingPathComponent(dir.lastPathComponent))
    }
    return folder
  }

  // MARK: File watching

  private func postChange(_ ids: Set<String>) {
    NotificationCenter.default.post(name: .notesDidChange, object: self, userInfo: ["ids": ids])
  }

  /// Picks up edits made by other apps (editors, sync tools).
  private func startWatching() {
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let store = Unmanaged<NoteStore>.fromOpaque(info).takeUnretainedValue()
      let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
      let changed = Array(array.prefix(count))
      MainActor.assumeIsolated { store.filesChanged(changed) }
    }
    let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
    guard let stream = FSEventStreamCreate(
      nil, callback, &context, [root.path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    FSEventStreamStart(stream)
    eventStream = stream
  }

  private func stopWatching() {
    guard let stream = eventStream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    eventStream = nil
  }

  private func filesChanged(_ paths: [String]) {
    var changed = Set<String>()
    var groupsChanged = false
    if paths.contains(where: { !$0.hasSuffix(".md") }) { attachments = nil }
    let notesPath = notesDirectory.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    // Folders made or removed in notes/ (by Finder, Obsidian, sync...).
    for path in paths where !path.hasSuffix(".md") {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard url.deletingLastPathComponent().path == notesPath else { continue }
      let name = url.lastPathComponent
      let isGroup = isGroupFolder(url)
      guard isGroup != groupFolders.contains(name) else { continue }
      groupsChanged = true
      if isGroup {
        groupFolders.insert(name)
      } else {
        groupFolders.remove(name)
      }
      // A folder renamed or moved reports only itself: its notes come or go
      // with it.
      for (ref, entry) in entries where entry.folder == name && !FileManager.default.fileExists(atPath: fileURL(for: ref).path) {
        entries[ref] = nil
        changed.insert(ref.id)
      }
      guard isGroup else { continue }
      let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for file in files where file.pathExtension.lowercased() == "md" {
        let ref = NoteRef(kind: .note, name: file.deletingPathExtension().lastPathComponent)
        guard entries[ref] == nil, var entry = readEntry(at: file) else { continue }
        entry.folder = name
        entries[ref] = entry
        changed.insert(ref.id)
      }
    }
    for path in paths where path.hasSuffix(".md") {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let parent = url.deletingLastPathComponent()
      // notes/<name>.md, notes/<group>/<name>.md or journal/<day>.md.
      let kind: NoteRef.Kind
      var folder = ""
      if parent.path == notesPath {
        kind = .note
      } else if parent.deletingLastPathComponent().path == notesPath {
        kind = .note
        folder = parent.lastPathComponent
      } else if parent.deletingLastPathComponent().path == rootPath, let journal = NoteRef.Kind(rawValue: parent.lastPathComponent),
                journal == .journal {
        kind = .journal
      } else {
        continue
      }
      let ref = NoteRef(kind: kind, name: url.deletingPathExtension().lastPathComponent)
      if kind == .journal && ref.date == nil { continue }
      if FileManager.default.fileExists(atPath: path) {
        if !folder.isEmpty, !groupFolders.contains(folder) {
          groupFolders.insert(folder)
          groupsChanged = true
        }
        // (Another note with its name, elsewhere: the one already there stays.)
        if let existing = entries[ref], existing.folder != folder,
           FileManager.default.fileExists(atPath: fileURL(for: ref).path) { continue }
        guard var entry = readEntry(at: url), entry.content != entries[ref]?.content || folder != entries[ref]?.folder else { continue }
        entry.folder = folder
        entries[ref] = entry
      } else {
        // (Gone from where it was, not from where it moved.)
        guard let existing = entries[ref], existing.folder == folder else { continue }
        entries[ref] = nil
      }
      if kind == .note { aliasIndex = nil }
      changed.insert(ref.id)
    }
    if !changed.isEmpty || groupsChanged { postChange(changed) }
  }
}
