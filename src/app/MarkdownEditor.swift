import AppKit

// A Markdown editor whose document is always plain Markdown text.
//
// Styling is applied as attributes on top of the text: syntax characters are
// shown (faded) on the paragraph being edited and hidden everywhere else,
// which gives a clean, rendered look without converting the document. Images,
// bullets, checkboxes, quote bars and code backgrounds are drawn by the layout
// manager.

extension NSAttributedString.Key {
  static let gleaQuote = NSAttributedString.Key("gleaQuote")
  static let gleaCode = NSAttributedString.Key("gleaCode")
  static let gleaRule = NSAttributedString.Key("gleaRule")
  static let gleaBullet = NSAttributedString.Key("gleaBullet")
  /// NSNumber(bool): whether the task is done. Set on the "[ ]" characters.
  static let gleaTask = NSAttributedString.Key("gleaTask")
  /// Whether the checkbox should be drawn (the "[ ]" text is hidden).
  static let gleaTaskDrawn = NSAttributedString.Key("gleaTaskDrawn")
  static let gleaImage = NSAttributedString.Key("gleaImage")
  /// MediaDescriptor: set on a line shown as a media block.
  static let gleaMedia = NSAttributedString.Key("gleaMedia")
  /// Set when a media line's source is being edited: the block goes below.
  static let gleaMediaBelow = NSAttributedString.Key("gleaMediaBelow")
  /// MarkdownTableRow: set on each rendered table row.
  static let gleaTableRow = NSAttributedString.Key("gleaTableRow")
  /// A row of a table too wide for one line per row: its text shrinks to
  /// nothing and the layout manager draws its cells, wrapped.
  static let gleaTableWrapped = NSAttributedString.Key("gleaTableWrapped")
  /// A link inside a wrapped table cell (drawn by the layout manager).
  static let gleaCellLink = NSAttributedString.Key("gleaCellLink")
  /// Set on the content of a collapsed section: it takes no space.
  static let gleaFolded = NSAttributedString.Key("gleaFolded")
  /// The line break after a collapsed section's content. It still breaks the
  /// line, but must not add a blank line of its own.
  static let gleaFoldEnd = NSAttributedString.Key("gleaFoldEnd")
  /// NSNumber(CGFloat): how far the line's section indents it. Set on every
  /// styled line, so what is drawn at its left edge moves with it.
  static let gleaSectionIndent = NSAttributedString.Key("gleaSectionIndent")
}

/// A block that can be dragged to another place: a line, with what belongs
/// to it (a heading's section, a list item's nested lines, a code block's
/// lines, a quote's or table's rows).
struct MarkdownBlock {
  /// Indexes of its lines.
  let lines: Range<Int>
}

/// A heading and the section it starts: every line up to the next heading of
/// the same or a higher level.
struct HeadingSection {
  /// Identifies the heading across restyles: its line and occurrence.
  let key: String
  let heading: NSRange
  /// The section's lines, except the last line break, which stays so the
  /// next line starts on its own. Empty when there is nothing to collapse.
  let body: NSRange
}

/// Geometry of a rendered table row, used to draw its grid.
final class MarkdownTableRow: NSObject {
  let columnX: [CGFloat]
  let isHeader: Bool
  let isFirst: Bool
  let isLast: Bool
  /// In a wrapped table, the cells' styled text, drawn inside their column
  /// (inset by `padding`), since the row's own text shrinks to nothing.
  var cells: [NSAttributedString]?
  var padding = NSSize(width: 12, height: 7)

  init(columnX: [CGFloat], isHeader: Bool, isFirst: Bool, isLast: Bool) {
    self.columnX = columnX
    self.isHeader = isHeader
    self.isFirst = isFirst
    self.isLast = isLast
  }

  /// Where cell `column`'s text goes, given the row's rect.
  func cellRect(_ column: Int, in row: NSRect) -> NSRect {
    NSRect(x: row.minX + columnX[column] - columnX[0] + padding.width, y: row.minY + padding.height,
           width: columnX[column + 1] - columnX[column] - padding.width * 2, height: row.height - padding.height * 2)
  }

  /// The link at `point` (relative to the cell's text rect) in a wrapped cell.
  func link(inCell column: Int, at point: NSPoint, width: CGFloat) -> Any? {
    guard let cells, cells.indices.contains(column) else { return nil }
    let storage = NSTextStorage(attributedString: cells[column])
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)
    guard layout.usedRect(for: container).contains(point) else { return nil }
    var fraction: CGFloat = 0
    let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
    let index = layout.characterIndexForGlyph(at: glyph)
    guard index < storage.length else { return nil }
    return storage.attribute(.gleaCellLink, at: index, effectiveRange: nil)
  }
}

final class MarkdownImage: NSObject {
  let image: NSImage
  let size: NSSize
  let indent: CGFloat

  init(image: NSImage, size: NSSize, indent: CGFloat) {
    self.image = image
    self.size = size
    self.indent = indent
  }
}

// MARK: - Styling

@MainActor
struct MarkdownStyler {
  /// Directory used to resolve relative image paths (the note's folder).
  let baseDirectory: URL
  /// Width available for text, used to size images.
  let width: CGFloat
  /// The selection when the editor has focus. Markdown syntax is shown only
  /// for the construct the cursor is in; everything else renders as you type.
  let selection: NSRange?
  /// Current height of a media block, by key (nil until its view exists).
  var mediaHeight: (String) -> CGFloat? = { _ in nil }
  /// Keys of the collapsed sections.
  var folded: Set<String> = []
  /// The table the cursor is in shows as Markdown (the table / Markdown
  /// toggle), not as a table.
  var tableAsMarkdown = false
  /// The wrapped table cell being edited (by its row's location and its
  /// column): measured with its raw text, which its editor shows.
  var editingCell: (row: Int, column: Int)?

  private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
  }

  private static let fence = regex("^\\s*(```|~~~)")
  private static let rule = regex("^\\s*([-*_])(\\s*\\1){2,}\\s*$")
  private static let heading = regex("^(#{1,6})\\s+")
  private static let quote = regex("^(\\s*>\\s?)+")
  private static let list = regex("^(\\s*)([-*+]|\\d+[.)])\\s+(\\[[ xX]\\]\\s+)?")
  private static let inlineCode = regex("`[^`\\n]+`")
  private static let image = regex("!\\[([^\\]\\n]*)\\]\\(([^)\\s]+)(?:\\s+\"[^\"]*\")?\\)")
  private static let link = regex("(?<!!)\\[([^\\]\\n]+)\\]\\(([^)\\s]+)(?:\\s+\"[^\"]*\")?\\)")
  private static let wikiLink = regex("\\[\\[([^\\]\\n|]+)(?:\\|([^\\]\\n]+))?\\]\\]")
  private static let bareURL = regex("\\bhttps?://[^\\s<>()\\[\\]]*[^\\s<>()\\[\\].,;:!?'\"]")
  private static let bold = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
  private static let italic = regex("(?<![*\\w])\\*(?=\\S)([^*\\n]+?)(?<=\\S)\\*(?![*\\w])|(?<![_\\w])_(?=\\S)([^_\\n]+?)(?<=\\S)_(?![_\\w])")
  private static let strike = regex("~~(?=\\S)(.+?)(?<=\\S)~~")
  private static let tableSeparator = regex("^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$")

  nonisolated static let lineSpacing: CGFloat = 3
  nonisolated static let paragraphSpacing: CGFloat = 6
  /// How far each level of heading nesting indents its section.
  nonisolated static let sectionIndent: CGFloat = 20

  static var baseAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    paragraph.paragraphSpacing = paragraphSpacing
    return [.font: Theme.bodyFont, .foregroundColor: Theme.text, .paragraphStyle: paragraph]
  }

  private let faded: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.tertiaryText]
  private let hidden: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear,
  ]

  /// Hides Markdown syntax without shrinking it: the characters turn clear
  /// and their advance is cancelled by kerning. The line keeps its height
  /// (an otherwise empty "> " or "## " line still takes its space) and the
  /// cursor keeps its size next to hidden characters.
  private func hide(_ storage: NSTextStorage, _ range: NSRange) {
    guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
    for i in range.location..<NSMaxRange(range) {
      let char = NSRange(location: i, length: 1)
      var attributes = storage.attributes(at: i, effectiveRange: nil)
      attributes[.kern] = nil
      let width = NSAttributedString(string: (storage.string as NSString).substring(with: char), attributes: attributes).size().width
      storage.addAttribute(.kern, value: -width, range: char)
    }
  }

  /// Whether the syntax of a construct spanning `range` should show: the
  /// cursor is strictly inside it, or the selection overlaps it. A cursor
  /// right after a construct leaves it converted.
  private func reveals(_ range: NSRange) -> Bool {
    guard let selection else { return false }
    if selection.length > 0 { return NSIntersectionRange(selection, range).length > 0 }
    return selection.location > range.location && selection.location < NSMaxRange(range)
  }

  /// Same for a block marker ("# ", "> ", "- "): shown only when the cursor
  /// sits on the marker itself (e.g. at the start of the line).
  private func revealsMarker(_ range: NSRange) -> Bool {
    guard let selection else { return false }
    if selection.length > 0 { return NSIntersectionRange(selection, range).length > 0 }
    return selection.location >= range.location && selection.location < NSMaxRange(range)
  }

  /// Styles the whole text, or only the lines intersecting `limit` (the
  /// rest keeps its attributes; used when just the cursor moved).
  func apply(to storage: NSTextStorage, limit: NSRange? = nil) {
    let string = storage.string as NSString
    let full = NSRange(location: 0, length: string.length)

    var lines: [(line: NSRange, enclosing: NSRange)] = []
    string.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, lineRange, enclosing, _ in
      lines.append((lineRange, enclosing))
    }

    let fenceLines = lines.map {
      MarkdownStyler.fence.firstMatch(in: string as String, range: $0.line) != nil
    }
    let codeBlocks = fencedBlocks(lines: lines, string: string, fenceLines: fenceLines)
    let depths = MarkdownStyler.sectionDepths(lines: lines, string: string, fenceLines: fenceLines)
    let foldRanges = MarkdownStyler.headingSections(lines: lines, string: string, fenceLines: fenceLines)
      .filter { folded.contains($0.key) && $0.body.length > 0 }.map(\.body)
    func foldRange(of line: NSRange) -> NSRange? {
      foldRanges.first { NSIntersectionRange($0, line).length > 0 || (line.length == 0 && line.location > $0.location && line.location < NSMaxRange($0)) }
    }

    // Grow the limit to whole tables, whose layout depends on every row,
    // and whole code blocks, whose colors can span lines.
    var target = limit.map { string.paragraphRange(for: $0) } ?? full
    if limit != nil {
      var blockRanges = tableBlocks(lines: lines, string: string).map {
        NSRange(location: lines[$0.lowerBound].enclosing.location,
                length: NSMaxRange(lines[$0.upperBound - 1].enclosing) - lines[$0.lowerBound].enclosing.location)
      }
      blockRanges += codeBlocks.map(\.block)
      for blockRange in blockRanges {
        if NSIntersectionRange(blockRange, target).length > 0 || NSLocationInRange(target.location, blockRange) {
          target = NSUnionRange(target, blockRange)
        }
      }
    }
    func inTarget(_ r: NSRange) -> Bool {
      NSIntersectionRange(r, target).length > 0 || (r.length == 0 && NSLocationInRange(r.location, target))
        || (r.location == target.location)
    }

    storage.beginEditing()
    storage.setAttributes(MarkdownStyler.baseAttributes, range: target)

    let tables = tableBlocks(lines: lines, string: string)
    var tableAt: [Int: Range<Int>] = [:]
    for block in tables { tableAt[block.lowerBound] = block }

    var inFence = false
    var index = 0
    var mediaCounts: [String: Int] = [:]
    while index < lines.count {
      let (lineRange, enclosing) = lines[index]
      let line = string.substring(with: lineRange)
      let isFence = fenceLines[index]
      // Media lines are keyed by source and occurrence, counted over the
      // whole text so keys stay stable when only part of it is restyled.
      var mediaOccurrence = 0
      if !inFence && !isFence, let source = MarkdownStyler.mediaSourceHint(line) {
        mediaOccurrence = mediaCounts[source, default: 0]
        mediaCounts[source] = mediaOccurrence + 1
      }

      // Collapsed lines aren't styled, only hidden. Their media blocks are
      // still marked so the views exist (and embeds load) while hidden.
      if let fold = foldRange(of: enclosing) {
        if inTarget(enclosing) {
          storage.addAttribute(.gleaFolded, value: true, range: NSIntersectionRange(fold, enclosing))
          if !inFence && !isFence, MarkdownStyler.mediaSourceHint(line) != nil {
            let quote = MarkdownStyler.quote.firstMatch(in: line, range: NSRange(location: 0, length: lineRange.length))
            let content = (line as NSString).substring(from: quote?.range.length ?? 0)
            if let media = MediaDescriptor.parse(content, baseDirectory: baseDirectory, indent: 0, occurrence: mediaOccurrence) {
              storage.addAttribute(.gleaMedia, value: media, range: lineRange)
            }
          }
        }
        if isFence { inFence.toggle() }
        index += 1
        continue
      }
      if !inFence, let block = tableAt[index] {
        let blockLines = Array(lines[block])
        if blockLines.contains(where: { inTarget($0.enclosing) }) {
          styleTable(storage, string: string, lines: blockLines, indent: CGFloat(depths[index]) * MarkdownStyler.sectionIndent)
        }
        index = block.upperBound
        continue
      }
      if inTarget(enclosing) {
        styleLine(storage, line: line, lineRange: lineRange, enclosing: enclosing, inFence: inFence, isFence: isFence,
                  sectionIndent: CGFloat(depths[index]) * MarkdownStyler.sectionIndent, mediaOccurrence: mediaOccurrence)
      }
      if isFence { inFence.toggle() }
      index += 1
    }
    for fold in foldRanges where NSMaxRange(fold) < string.length && NSLocationInRange(NSMaxRange(fold), target) {
      storage.addAttribute(.gleaFoldEnd, value: true, range: NSRange(location: NSMaxRange(fold), length: 1))
    }
    for block in codeBlocks where NSIntersectionRange(block.content, target).length > 0 {
      SyntaxHighlighter.highlight(storage, range: block.content, language: block.language)
    }
    storage.endEditing()
  }

  /// Fenced code blocks: the whole block (fences included), its content and
  /// the language named after the opening fence. An unclosed block runs to
  /// the end of the text.
  private func fencedBlocks(lines: [(line: NSRange, enclosing: NSRange)], string: NSString,
                          fenceLines: [Bool]) -> [(block: NSRange, content: NSRange, language: String)] {
    var blocks: [(block: NSRange, content: NSRange, language: String)] = []
    var open: (index: Int, language: String)?
    func add(from start: Int, language: String, contentEnd: Int, blockEnd: Int) {
      let contentStart = NSMaxRange(lines[start].enclosing)
      blocks.append((NSRange(location: lines[start].enclosing.location, length: blockEnd - lines[start].enclosing.location),
                     NSRange(location: contentStart, length: max(0, contentEnd - contentStart)), language))
    }
    for (index, isFence) in fenceLines.enumerated() where isFence {
      if let start = open {
        add(from: start.index, language: start.language, contentEnd: lines[index].enclosing.location,
            blockEnd: NSMaxRange(lines[index].enclosing))
        open = nil
      } else {
        let info = string.substring(with: lines[index].line).trimmingCharacters(in: .whitespaces)
          .drop { $0 == "`" || $0 == "~" }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? ""
        open = (index, language)
      }
    }
    if let start = open {
      add(from: start.index, language: start.language, contentEnd: string.length, blockEnd: string.length)
    }
    return blocks
  }

  static func headingSections(in string: NSString) -> [HeadingSection] {
    var lines: [(line: NSRange, enclosing: NSRange)] = []
    string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, lineRange, enclosing, _ in
      lines.append((lineRange, enclosing))
    }
    let fenceLines = lines.map { fence.firstMatch(in: string as String, range: $0.line) != nil }
    return headingSections(lines: lines, string: string, fenceLines: fenceLines)
  }

  private static func headingSections(lines: [(line: NSRange, enclosing: NSRange)], string: NSString,
                                      fenceLines: [Bool]) -> [HeadingSection] {
    var headings: [(index: Int, level: Int, key: String)] = []
    var occurrences: [String: Int] = [:]
    var inFence = false
    for (index, line) in lines.enumerated() {
      if fenceLines[index] {
        inFence.toggle()
        continue
      }
      guard !inFence, let m = heading.firstMatch(in: string as String, range: line.line) else { continue }
      let text = string.substring(with: line.line)
      let occurrence = occurrences[text, default: 0]
      occurrences[text] = occurrence + 1
      headings.append((index, m.range(at: 1).length, "\(text)#\(occurrence)"))
    }
    return headings.enumerated().map { i, heading in
      let end = headings[(i + 1)...].first { $0.level <= heading.level }?.index ?? lines.count
      var body = NSRange(location: NSMaxRange(lines[heading.index].enclosing), length: 0)
      if end > heading.index + 1 {
        body.length = NSMaxRange(lines[end - 1].line) - body.location
      }
      return HeadingSection(key: heading.key, heading: lines[heading.index].line, body: body)
    }
  }

  /// How deep each line sits in the heading outline: a heading at the depth
  /// of the sections around it, any other line at its heading's depth.
  private static func sectionDepths(lines: [(line: NSRange, enclosing: NSRange)], string: NSString,
                                    fenceLines: [Bool]) -> [Int] {
    var open: [Int] = []
    var inFence = false
    return lines.enumerated().map { index, line in
      let contentDepth = max(0, open.count - 1)
      if fenceLines[index] {
        inFence.toggle()
        return contentDepth
      }
      guard !inFence, let m = heading.firstMatch(in: string as String, range: line.line) else { return contentDepth }
      let level = m.range(at: 1).length
      while let last = open.last, last >= level { open.removeLast() }
      defer { open.append(level) }
      return open.count
    }
  }

  static func isHeading(_ line: String) -> Bool {
    heading.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
  }

  /// The draggable blocks of a text, nested ones included, in order.
  static func blocks(in string: String) -> [MarkdownBlock] {
    let lines = string.components(separatedBy: "\n")
    func blank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
    func indent(_ i: Int) -> Int { lines[i].prefix { $0 == " " || $0 == "\t" }.count }
    func matches(_ regex: NSRegularExpression, _ i: Int) -> NSTextCheckingResult? {
      regex.firstMatch(in: lines[i], range: NSRange(location: 0, length: (lines[i] as NSString).length))
    }
    func isQuote(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") }
    /// A capture's source ("— [page](url)"), under the extract it credits.
    func isCredit(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("— ") }
    func isTable(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") }
    let isFence = lines.indices.map { matches(fence, $0) != nil }
    var inFence = Array(repeating: false, count: lines.count)
    var open = false
    for i in lines.indices {
      if isFence[i] { open.toggle() } else { inFence[i] = open }
    }
    func headingLevel(_ i: Int) -> Int? {
      guard !inFence[i], !isFence[i], let m = matches(heading, i) else { return nil }
      return m.range(at: 1).length
    }

    var blocks: [MarkdownBlock] = []
    var i = 0
    var fenceOpen = false
    while i < lines.count {
      defer { i += 1 }
      if isFence[i] {
        defer { fenceOpen.toggle() }
        guard !fenceOpen else { continue }
        let close = (i + 1..<lines.count).first { isFence[$0] }.map { $0 + 1 } ?? lines.count
        blocks.append(MarkdownBlock(lines: i..<close))
        continue
      }
      if inFence[i] || blank(i) { continue }
      // A source line goes with what it credits (the line above).
      if isCredit(i), i > 0, !blank(i - 1), headingLevel(i - 1) == nil { continue }
      var end = i + 1
      if let level = headingLevel(i) {
        end = (i + 1..<lines.count).first { headingLevel($0).map { $0 <= level } ?? false } ?? lines.count
      } else if matches(list, i) != nil {
        while end < lines.count, !blank(end), indent(end) > indent(i) { end += 1 }
      } else if isQuote(i) {
        if i > 0 && isQuote(i - 1) { continue }
        while end < lines.count, isQuote(end) { end += 1 }
      } else if isTable(i) {
        if i > 0 && isTable(i - 1) { continue }
        while end < lines.count, isTable(end) { end += 1 }
      }
      // An extract (a media line, a quote…) takes its source line along.
      if headingLevel(i) == nil, end < lines.count, !inFence[end], isCredit(end) { end += 1 }
      while end > i + 1, blank(end - 1) { end -= 1 }
      blocks.append(MarkdownBlock(lines: i..<end))
    }
    return blocks
  }

  /// The text with `block` moved before line `target` (any line outside
  /// it, or the line count for the end), and the line it starts on there.
  /// Nil when that leaves it where it is. Its lines move as they are, except
  /// that quotes and tables that would touch another of their kind (and so
  /// merge with it) get a blank line between.
  static func moving(_ block: MarkdownBlock, before target: Int, in string: String) -> (text: String, line: Int)? {
    let a = block.lines.lowerBound, b = block.lines.upperBound
    guard target < a || target > b else { return nil }
    var lines = string.components(separatedBy: "\n")
    /// Lines that merge with the same kind right next to them.
    func kind(_ i: Int) -> Character? {
      guard lines.indices.contains(i), let first = lines[i].trimmingCharacters(in: .whitespaces).first,
            first == ">" || first == "|" else { return nil }
      return first
    }
    let moved = Array(lines[a..<b])
    lines.removeSubrange(a..<b)
    var at = target > a ? target - (b - a) : target
    // Its old neighbors would now touch.
    if at != a, let above = kind(a - 1), above == kind(a) {
      lines.insert("", at: a)
      if at > a { at += 1 }
    }
    lines.insert(contentsOf: moved, at: min(at, lines.count))
    at = min(at, lines.count - moved.count)
    // Its new neighbors: below first, so `at` stays its first line.
    let end = at + moved.count
    if let last = kind(end - 1), last == kind(end) { lines.insert("", at: end) }
    if let first = kind(at), first == kind(at - 1) {
      lines.insert("", at: at)
      at += 1
    }
    return (lines.joined(separator: "\n"), at)
  }

  /// Cheap pre-check: the source of a would-be media line.
  static func mediaSourceHint(_ line: String) -> String? {
    var text = line.trimmingCharacters(in: .whitespaces)
    while text.hasPrefix(">") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
    if text.hasPrefix("!["), text.hasSuffix(")"), let open = text.range(of: "](") {
      return String(text[open.upperBound...].dropLast()).components(separatedBy: " ").first
    }
    if text.hasPrefix("http"), !text.contains(" ") { return text }
    return nil
  }

  private func styleLine(_ storage: NSTextStorage, line: String, lineRange: NSRange, enclosing: NSRange,
                         inFence: Bool, isFence: Bool, sectionIndent: CGFloat, mediaOccurrence: Int = 0) {
    let local = NSRange(location: 0, length: (line as NSString).length)
    func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + lineRange.location, length: r.length) }
    storage.addAttribute(.gleaSectionIndent, value: sectionIndent, range: enclosing)

    var indent = sectionIndent
    var spacingBefore: CGFloat = 0
    var spacingAfter = MarkdownStyler.paragraphSpacing
    var minLineHeight: CGFloat = 0

    func finishParagraph() {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = MarkdownStyler.lineSpacing
      paragraph.headIndent = indent
      paragraph.firstLineHeadIndent = indent
      paragraph.paragraphSpacing = spacingAfter
      paragraph.paragraphSpacingBefore = spacingBefore
      paragraph.minimumLineHeight = minLineHeight
      storage.addAttribute(.paragraphStyle, value: paragraph, range: enclosing)
    }

    // Fenced code blocks.
    if isFence {
      storage.addAttributes([.font: Theme.monoFont, .foregroundColor: Theme.tertiaryText, .gleaCode: true], range: enclosing)
      spacingAfter = 0
      indent += 12
      finishParagraph()
      return
    }
    if inFence {
      storage.addAttributes([.font: Theme.monoFont, .gleaCode: true], range: enclosing)
      spacingAfter = 0
      indent += 12
      finishParagraph()
      return
    }

    // Horizontal rule: shown as a line unless the cursor is on it.
    if MarkdownStyler.rule.firstMatch(in: line, range: local) != nil {
      if revealsMarker(NSRange(location: lineRange.location, length: lineRange.length + 1)) {
        storage.addAttributes(faded, range: lineRange)
      } else {
        storage.addAttributes(hidden, range: lineRange)
        storage.addAttribute(.gleaRule, value: true, range: lineRange)
      }
      minLineHeight = 24
      finishParagraph()
      return
    }

    var contentStart = 0

    // Headings.
    if let m = MarkdownStyler.heading.firstMatch(in: line, range: local) {
      let level = m.range(at: 1).length
      let sizes: [CGFloat] = [28, 22, 18, 16, 15, 15]
      storage.addAttribute(.font, value: NSFont.systemFont(ofSize: sizes[level - 1], weight: .semibold), range: lineRange)
      if revealsMarker(abs(m.range)) { storage.addAttributes(faded, range: abs(m.range)) } else { hide(storage, abs(m.range)) }
      spacingBefore = level <= 2 ? 14 : 8
      spacingAfter = 4
      contentStart = m.range.length
    }

    // Block quotes.
    if let m = MarkdownStyler.quote.firstMatch(in: line, range: local) {
      if revealsMarker(abs(m.range)) { storage.addAttributes(faded, range: abs(m.range)) } else { hide(storage, abs(m.range)) }
      storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: abs(NSRange(location: m.range.length, length: local.length - m.range.length)))
      storage.addAttribute(.gleaQuote, value: true, range: enclosing)
      indent += 16
      spacingAfter = 2
      contentStart = m.range.length
    }

    // Media blocks: the line is hidden (unless being edited) and the block
    // view is laid out in the space reserved below it.
    let content = (line as NSString).substring(from: contentStart)
    if let media = MediaDescriptor.parse(content, baseDirectory: baseDirectory, indent: indent, occurrence: mediaOccurrence) {
      let body = abs(NSRange(location: contentStart, length: local.length - contentStart))
      let blockHeight = mediaHeight(media.key) ?? MediaBlockView.rowHeight
      spacingBefore = 4
      if revealsMarker(NSRange(location: lineRange.location, length: lineRange.length + 1)) {
        // Editing the source: the Markdown shows, the block goes below it.
        storage.addAttributes(faded, range: body)
        storage.addAttribute(.gleaMediaBelow, value: true, range: lineRange)
        spacingAfter = blockHeight + 14
      } else {
        // The line keeps its real height; the block sits on it (the collapsed
        // row is the line) and pushes what follows by the rest of its height.
        hide(storage, lineRange)
        minLineHeight = MediaBlockView.rowHeight
        spacingAfter = max(0, blockHeight - MediaBlockView.rowHeight) + 10
      }
      if lineRange.length > 0 { storage.addAttribute(.gleaMedia, value: media, range: lineRange) }
      finishParagraph()
      return
    }

    // Lists and tasks.
    if let m = MarkdownStyler.list.firstMatch(in: line, range: NSRange(location: contentStart, length: local.length - contentStart)) {
      let marker = m.range(at: 2)
      let markerText = (line as NSString).substring(with: marker)
      let isBullet = ["-", "*", "+"].contains(markerText)
      let markerArea = abs(NSRange(location: marker.location, length: m.range(at: 3).location != NSNotFound
                                     ? m.range(at: 3).upperBound - marker.location : m.range.upperBound - marker.location))
      let showSyntax = revealsMarker(markerArea)
      if isBullet && !showSyntax {
        storage.addAttributes([.foregroundColor: NSColor.clear, .gleaBullet: true], range: abs(marker))
      } else {
        storage.addAttribute(.foregroundColor, value: Theme.tertiaryText, range: abs(marker))
      }
      if m.range(at: 3).location != NSNotFound {
        let box = NSRange(location: m.range(at: 3).location, length: 3)
        let done = (line as NSString).substring(with: box).lowercased() == "[x]"
        storage.addAttribute(.gleaTask, value: NSNumber(value: done), range: abs(box))
        if showSyntax {
          storage.addAttribute(.foregroundColor, value: Theme.tertiaryText, range: abs(box))
        } else {
          storage.addAttributes([.foregroundColor: NSColor.clear, .gleaTaskDrawn: true], range: abs(box))
        }
        if done {
          let rest = NSRange(location: m.range.upperBound, length: local.length - m.range.upperBound)
          storage.addAttributes([.foregroundColor: Theme.tertiaryText, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: abs(rest))
        }
      }
      let prefix = (line as NSString).substring(to: m.range.upperBound)
      let quoteWidth = indent
      indent = quoteWidth + (prefix.dropFirst(contentStart) as Substring).description.size(withAttributes: [.font: Theme.bodyFont]).width
      // The first line starts at the marker; wrapped lines align with the text.
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = MarkdownStyler.lineSpacing
      paragraph.firstLineHeadIndent = quoteWidth
      paragraph.headIndent = indent
      paragraph.paragraphSpacing = 3
      storage.addAttribute(.paragraphStyle, value: paragraph, range: enclosing)
      styleInline(storage, line: line, lineRange: lineRange, imageIndent: indent)
      return
    }

    let imageHeight = styleInline(storage, line: line, lineRange: lineRange, imageIndent: indent)
    if imageHeight > 0 { spacingAfter += imageHeight + 12 }
    finishParagraph()
  }

  // MARK: Tables

  /// Runs of lines forming GFM tables: a header row, a separator row
  /// (`| --- | :-: |`) and any number of body rows, all starting with "|".
  private func tableBlocks(lines: [(line: NSRange, enclosing: NSRange)], string: NSString) -> [Range<Int>] {
    var blocks: [Range<Int>] = []
    var inFence = false
    var i = 0
    func text(_ i: Int) -> String { string.substring(with: lines[i].line) }
    func isRow(_ i: Int) -> Bool { text(i).trimmingCharacters(in: .whitespaces).hasPrefix("|") }
    while i < lines.count {
      let t = text(i)
      if MarkdownStyler.fence.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil {
        inFence.toggle()
        i += 1
        continue
      }
      if !inFence, i + 1 < lines.count, isRow(i), isRow(i + 1),
         MarkdownStyler.tableSeparator.firstMatch(in: text(i + 1), range: NSRange(location: 0, length: (text(i + 1) as NSString).length)) != nil {
        var end = i + 2
        while end < lines.count && isRow(end) { end += 1 }
        blocks.append(i..<end)
        i = end
        continue
      }
      i += 1
    }
    return blocks
  }

  /// Cells of a table row: the trimmed content range of each, in the line.
  static func tableCells(in line: NSString) -> [NSRange] {
    var pipes: [Int] = []
    var i = 0
    var inCode = false
    while i < line.length {
      let c = line.character(at: i)
      if c == 0x5C { i += 2; continue }  // backslash escape
      if c == 0x60 { inCode.toggle() }
      if c == 0x7C && !inCode { pipes.append(i) }
      i += 1
    }
    guard pipes.count >= 2 else { return [] }
    var cells: [NSRange] = []
    for (a, b) in zip(pipes, pipes.dropFirst()) {
      var start = a + 1
      var end = b
      while start < end, line.character(at: start) == 0x20 { start += 1 }
      while end > start, line.character(at: end - 1) == 0x20 { end -= 1 }
      if start == end {
        // Empty cell: its insertion point is just after the first padding
        // space ("| ▮ |"), where typed text belongs.
        start = min(a + 2, b)
        end = start
      }
      cells.append(NSRange(location: start, length: end - start))
    }
    return cells
  }

  private func styleTable(_ storage: NSTextStorage, string: NSString, lines: [(line: NSRange, enclosing: NSRange)],
                          indent: CGFloat) {
    // Switched to Markdown while the cursor is in it.
    let editing = selection.map { sel in
      lines.contains { NSLocationInRange(sel.location, $0.enclosing) || NSIntersectionRange(sel, $0.enclosing).length > 0 }
    } ?? false
    if editing && tableAsMarkdown {
      for entry in lines { storage.addAttributes([.font: Theme.monoFont, .foregroundColor: Theme.secondaryText], range: entry.line) }
      return
    }
    let pad: CGFloat = 12
    let separatorLine = string.substring(with: lines[1].line) as NSString
    let alignments: [NSTextAlignment] = MarkdownStyler.tableCells(in: separatorLine).map { r in
      let spec = separatorLine.substring(with: r)
      if spec.hasPrefix(":") && spec.hasSuffix(":") { return .center }
      if spec.hasSuffix(":") { return .right }
      return .left
    }
    let columnCount = max(alignments.count, 1)

    // Style cell contents first (inline markup), then measure them.
    var rows: [(index: Int, cells: [NSRange])] = []
    for (i, entry) in lines.enumerated() where i != 1 {
      let line = string.substring(with: entry.line)
      styleInline(storage, line: line, lineRange: entry.line, imageIndent: 0)
      if i == 0 { storage.addAttribute(.font, value: NSFont.systemFont(ofSize: Theme.bodySize, weight: .semibold), range: entry.line) }
      let cells = MarkdownStyler.tableCells(in: line as NSString).map {
        NSRange(location: $0.location + entry.line.location, length: $0.length)
      }
      rows.append((i, cells))
    }
    var widths = [CGFloat](repeating: 40, count: columnCount)
    for row in rows {
      for (c, cell) in row.cells.prefix(columnCount).enumerated() {
        widths[c] = max(widths[c], ceil(storage.attributedSubstring(from: cell).size().width) + pad * 2)
      }
    }
    // Too wide for one line per row: cells wrap in narrower columns (and
    // are edited one at a time, over the cell). With too little room even
    // for that, it stays Markdown.
    let total = widths.reduce(0, +)
    let available = width - indent
    guard total <= available else {
      if available < CGFloat(columnCount) * 56 {
        for entry in lines { storage.addAttributes([.font: Theme.monoFont, .foregroundColor: Theme.secondaryText], range: entry.line) }
      } else {
        styleWrappedTable(storage, lines: lines, rows: rows, natural: widths, available: available,
                          alignments: alignments, indent: indent, pad: pad)
      }
      return
    }
    var columnX: [CGFloat] = [indent]
    for w in widths { columnX.append(columnX.last! + w) }

    // The separator row collapses to nothing.
    storage.addAttributes(hidden, range: lines[1].line)
    let collapsed = NSMutableParagraphStyle()
    collapsed.minimumLineHeight = 0.01
    collapsed.maximumLineHeight = 0.01
    storage.addAttribute(.paragraphStyle, value: collapsed, range: lines[1].enclosing)

    let rowStyle = NSMutableParagraphStyle()
    rowStyle.lineSpacing = 0
    rowStyle.paragraphSpacingBefore = 7
    rowStyle.paragraphSpacing = 7
    rowStyle.firstLineHeadIndent = indent
    rowStyle.headIndent = indent
    for (n, row) in rows.enumerated() {
      let entry = lines[row.index]
      storage.addAttribute(.paragraphStyle, value: rowStyle, range: entry.enclosing)
      storage.addAttribute(.gleaSectionIndent, value: indent, range: entry.enclosing)
      let info = MarkdownTableRow(columnX: columnX, isHeader: row.index == 0,
                                  isFirst: n == 0, isLast: n == rows.count - 1)
      storage.addAttribute(.gleaTableRow, value: info, range: entry.line)

      // Hide the pipes and padding, and use kerning so each cell's text
      // starts at its column (after its alignment offset).
      // Pipes and padding are drawn clear rather than shrunk, so the cursor
      // keeps its full height inside (empty) cells.
      var previousEnd = entry.line.location
      var x = indent
      for (c, cell) in row.cells.prefix(columnCount).enumerated() {
        let gap = NSRange(location: previousEnd, length: cell.location - previousEnd)
        if gap.length > 0 { storage.addAttribute(.foregroundColor, value: NSColor.clear, range: gap) }
        let gapWidth = gap.length > 0 ? storage.attributedSubstring(from: gap).size().width : 0
        let content = storage.attributedSubstring(from: cell).size().width
        let free = widths[c] - pad * 2 - content
        let offset: CGFloat
        switch alignments.indices.contains(c) ? alignments[c] : .left {
        case .right: offset = free
        case .center: offset = free / 2
        default: offset = 0
        }
        let start = columnX[c] + pad + offset
        if gap.length > 0 {
          let lastChar = NSRange(location: NSMaxRange(gap) - 1, length: 1)
          let lastWidth = storage.attributedSubstring(from: lastChar).size().width
          // The last separator character is followed by the cell: kern it so
          // the cell starts at its column (the gap's own width included).
          storage.addAttribute(.kern, value: start - x - (gapWidth - lastWidth) - lastWidth, range: lastChar)
        }
        x = start + content
        previousEnd = NSMaxRange(cell)
      }
      let tail = NSRange(location: previousEnd, length: NSMaxRange(entry.line) - previousEnd)
      if tail.length > 0 { storage.addAttributes(hidden, range: tail) }
    }
  }

  /// A table too wide for one line per row, drawn with its cells wrapping:
  /// each row's text takes no room and its line is as tall as its tallest
  /// cell, which the layout manager draws in its column.
  private func styleWrappedTable(_ storage: NSTextStorage, lines: [(line: NSRange, enclosing: NSRange)],
                                 rows: [(index: Int, cells: [NSRange])], natural: [CGFloat], available: CGFloat,
                                 alignments: [NSTextAlignment], indent: CGFloat, pad: CGFloat) {
    // No column narrower than its longest word (words don't break).
    var longestWord = [CGFloat](repeating: 0, count: natural.count)
    for row in rows {
      for (c, cell) in row.cells.prefix(natural.count).enumerated() {
        let text = storage.attributedSubstring(from: cell)
        (text.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { _, word, _, _ in
          longestWord[c] = max(longestWord[c], ceil(text.attributedSubstring(from: word).size().width) + pad * 2 + 2)
        }
      }
    }
    let minimums = longestWord.map { min(max($0, 56), available / 2) }
    let widths = MarkdownStyler.fitColumns(natural, into: available, minimums: minimums)
    var columnX: [CGFloat] = [indent]
    for w in widths { columnX.append(columnX.last! + w) }
    let vertical: CGFloat = 7
    let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: Theme.bodyFont))

    // The separator row collapses to nothing.
    storage.addAttributes(hidden, range: lines[1].line)
    let collapsed = NSMutableParagraphStyle()
    collapsed.minimumLineHeight = 0.01
    collapsed.maximumLineHeight = 0.01
    storage.addAttribute(.paragraphStyle, value: collapsed, range: lines[1].enclosing)

    for (n, row) in rows.enumerated() {
      let entry = lines[row.index]
      var heights: [CGFloat] = []
      var texts: [NSAttributedString] = []
      for c in 0..<widths.count {
        let text = c < row.cells.count ? MarkdownStyler.cellText(storage.attributedSubstring(from: row.cells[c]),
                                                               alignment: alignments.indices.contains(c) ? alignments[c] : .left)
          : NSAttributedString()
        texts.append(text)
        // The cell being edited is as tall as its raw text, in its editor.
        let measured = editingCell.map { $0.row == entry.line.location && $0.column == c } == true && c < row.cells.count
          ? MarkdownStyler.cellEditingText((storage.string as NSString).substring(with: row.cells[c]), header: row.index == 0)
          : text
        let size = measured.boundingRect(with: NSSize(width: widths[c] - pad * 2, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        heights.append(ceil(size.height))
      }
      let height = max(heights.max() ?? 0, lineHeight) + vertical * 2
      let style = NSMutableParagraphStyle()
      style.minimumLineHeight = height
      style.maximumLineHeight = height
      style.firstLineHeadIndent = indent
      style.headIndent = indent
      storage.addAttribute(.paragraphStyle, value: style, range: entry.enclosing)
      storage.addAttribute(.gleaSectionIndent, value: indent, range: entry.enclosing)
      // The row's own text shrinks to nothing (it stays on its line, which
      // keeps the row's height; null glyphs would lose their line).
      storage.addAttributes([.gleaTableWrapped: true, .foregroundColor: NSColor.clear,
                             .font: NSFont.systemFont(ofSize: 0.01)], range: entry.line)
      storage.removeAttribute(.kern, range: entry.line)
      storage.removeAttribute(.link, range: entry.line)
      let info = MarkdownTableRow(columnX: columnX, isHeader: row.index == 0, isFirst: n == 0, isLast: n == rows.count - 1)
      info.cells = texts
      info.padding = NSSize(width: pad, height: vertical)
      storage.addAttribute(.gleaTableRow, value: info, range: entry.line)
    }
  }

  /// Column widths that fit `available`: columns narrower than an even
  /// share keep their width, the others share what's left in proportion,
  /// none below its minimum (its longest word).
  static func fitColumns(_ natural: [CGFloat], into available: CGFloat, minimums: [CGFloat]) -> [CGFloat] {
    var widths = natural
    var open = Array(natural.indices)
    var remaining = available
    while !open.isEmpty {
      let share = remaining / CGFloat(open.count)
      let narrow = open.filter { natural[$0] <= share }
      if narrow.isEmpty {
        // In proportion, but a column below its minimum takes its minimum
        // and the rest share again without it.
        let sum = open.reduce(0) { $0 + natural[$1] }
        let squeezed = open.filter { remaining * natural[$0] / sum < minimums[$0] }
        if squeezed.isEmpty || squeezed.count == open.count {
          for i in open { widths[i] = max(minimums[i], floor(remaining * natural[i] / sum)) }
          break
        }
        for i in squeezed {
          widths[i] = minimums[i]
          remaining -= minimums[i]
        }
        open.removeAll { squeezed.contains($0) }
        continue
      }
      for i in narrow { remaining -= natural[i] }
      open.removeAll { narrow.contains($0) }
    }
    return widths
  }

  /// A wrapped cell's raw Markdown as its editor shows it.
  static func cellEditingText(_ raw: String, header: Bool) -> NSAttributedString {
    NSAttributedString(string: raw.isEmpty ? " " : raw, attributes: cellEditingAttributes(header: header))
  }

  static func cellEditingAttributes(header: Bool) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 2
    return [.font: header ? NSFont.systemFont(ofSize: Theme.bodySize, weight: .semibold) : Theme.bodyFont,
            .foregroundColor: Theme.text, .paragraphStyle: paragraph]
  }

  /// A cell's styled text for drawing: its own paragraph (alignment, word
  /// wrapping), links drawn in the accent color and kept for clicks.
  static func cellText(_ styled: NSAttributedString, alignment: NSTextAlignment) -> NSAttributedString {
    let text = NSMutableAttributedString(attributedString: styled)
    let full = NSRange(location: 0, length: text.length)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 2
    text.addAttribute(.paragraphStyle, value: paragraph, range: full)
    text.enumerateAttribute(.link, in: full) { value, range, _ in
      guard let value else { return }
      text.removeAttribute(.link, range: range)
      text.addAttributes([.gleaCellLink: value, .foregroundColor: Theme.accent], range: range)
    }
    for key in [NSAttributedString.Key.gleaTableRow, .gleaTableWrapped, .gleaSectionIndent] { text.removeAttribute(key, range: full) }
    return text
  }

  /// Styles links, emphasis, code and images inside one line. Returns the
  /// height of an image displayed below the line (0 if none).
  @discardableResult
  private func styleInline(_ storage: NSTextStorage, line: String, lineRange: NSRange, imageIndent: CGFloat) -> CGFloat {
    let ns = line as NSString
    let local = NSRange(location: 0, length: ns.length)
    var taken: [NSRange] = []
    func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
    func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + lineRange.location, length: r.length) }
    // Syntax of a construct: shown while the cursor is inside it.
    var construct = NSRange()
    func syntax(_ r: NSRange) {
      if reveals(abs(construct)) { storage.addAttributes(faded, range: abs(r)) } else { hide(storage, abs(r)) }
    }

    for m in MarkdownStyler.inlineCode.matches(in: line, range: local) {
      construct = m.range
      storage.addAttributes([.font: Theme.monoFont, .backgroundColor: Theme.codeBackground], range: abs(m.range))
      syntax(NSRange(location: m.range.location, length: 1))
      syntax(NSRange(location: m.range.upperBound - 1, length: 1))
      taken.append(m.range)
    }

    var imageHeight: CGFloat = 0
    for m in MarkdownStyler.image.matches(in: line, range: local) where free(m.range) {
      taken.append(m.range)
      let source = ns.substring(with: m.range(at: 2))
      guard imageHeight == 0, let url = resolveImageURL(source), let image = ImageCache.shared.image(for: url) else {
        storage.addAttributes(faded, range: abs(m.range))
        continue
      }
      let maxWidth = max(80, width - imageIndent)
      var size = image.size
      if size.width > maxWidth { size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width) }
      if size.height > 420 { size = NSSize(width: size.width * 420 / size.height, height: 420) }
      storage.addAttribute(.gleaImage, value: MarkdownImage(image: image, size: size, indent: imageIndent), range: abs(m.range))
      storage.addAttributes(reveals(abs(m.range)) ? faded : hidden, range: abs(m.range))
      imageHeight = size.height
    }

    for m in MarkdownStyler.wikiLink.matches(in: line, range: local) where free(m.range) {
      construct = m.range
      taken.append(m.range)
      let name = ns.substring(with: m.range(at: 1))
      let hasAlias = m.range(at: 2).location != NSNotFound
      let visible = hasAlias ? m.range(at: 2) : m.range(at: 1)
      if let url = MarkdownStyler.linkValue("glea-note:" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)) {
        storage.addAttribute(.link, value: url, range: abs(visible))
      }
      storage.addAttribute(.font, value: NSFont.systemFont(ofSize: Theme.bodySize, weight: .medium), range: abs(visible))
      syntax(NSRange(location: m.range.location, length: visible.location - m.range.location))
      syntax(NSRange(location: visible.upperBound, length: m.range.upperBound - visible.upperBound))
    }

    for m in MarkdownStyler.link.matches(in: line, range: local) where free(m.range) {
      construct = m.range
      taken.append(m.range)
      let text = m.range(at: 1)
      if let url = MarkdownStyler.linkValue(ns.substring(with: m.range(at: 2))) {
        storage.addAttribute(.link, value: url, range: abs(text))
      }
      syntax(NSRange(location: m.range.location, length: 1))
      syntax(NSRange(location: text.upperBound, length: m.range.upperBound - text.upperBound))
    }

    for m in MarkdownStyler.bareURL.matches(in: line, range: local) where free(m.range) {
      taken.append(m.range)
      if let url = MarkdownStyler.linkValue(ns.substring(with: m.range)) {
        storage.addAttribute(.link, value: url, range: abs(m.range))
      }
    }

    // Emphasis may wrap links and code (**[[Note]]**), as long as they sit
    // wholly inside it, clear of its markers.
    func wraps(_ outer: NSRange, inner: NSRange) -> Bool {
      taken.allSatisfy { NSIntersectionRange($0, outer).length == 0 || NSIntersectionRange($0, inner) == $0 }
    }
    for m in MarkdownStyler.bold.matches(in: line, range: local) where wraps(m.range, inner: m.range(at: 2)) {
      construct = m.range
      addTrait(.boldFontMask, to: storage, range: abs(m.range(at: 2)))
      let markerLength = m.range(at: 1).length
      syntax(NSRange(location: m.range.location, length: markerLength))
      syntax(NSRange(location: m.range.upperBound - markerLength, length: markerLength))
    }
    for m in MarkdownStyler.italic.matches(in: line, range: local)
      where wraps(m.range, inner: NSRange(location: m.range.location + 1, length: m.range.length - 2)) {
      construct = m.range
      addTrait(.italicFontMask, to: storage, range: abs(NSRange(location: m.range.location + 1, length: m.range.length - 2)))
      syntax(NSRange(location: m.range.location, length: 1))
      syntax(NSRange(location: m.range.upperBound - 1, length: 1))
    }
    for m in MarkdownStyler.strike.matches(in: line, range: local) where wraps(m.range, inner: m.range(at: 1)) {
      construct = m.range
      storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: abs(m.range(at: 1)))
      syntax(NSRange(location: m.range.location, length: 2))
      syntax(NSRange(location: m.range.upperBound - 2, length: 2))
    }
    return imageHeight
  }

  private func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, range: NSRange) {
    storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
      guard let font = value as? NSFont, font.pointSize > 1 else { return }
      storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
    }
  }

  private func resolveImageURL(_ source: String) -> URL? {
    if source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("file://") {
      return URL(string: source)
    }
    let path = source.removingPercentEncoding ?? source
    return baseDirectory.appendingPathComponent(path).standardizedFileURL
  }
}

// MARK: - Layout manager

final class MarkdownLayoutManager: NSLayoutManager {
  /// The wrapped table cell being edited (its editor shows it instead), by
  /// its row's location and its column.
  var hiddenCell: (row: Int, column: Int)?

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let storage = textStorage, let container = textContainers.first else { return }
    let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    let full = NSRange(location: 0, length: storage.length)

    func sectionIndent(at index: Int) -> CGFloat {
      guard index < storage.length else { return 0 }
      return (storage.attribute(.gleaSectionIndent, at: index, effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    func lineRects(_ range: NSRange) -> NSRect {
      var union = NSRect.null
      enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
        union = union.union(rect)
      }
      return union.offsetBy(dx: origin.x, dy: origin.y)
    }

    // Code block backgrounds and quote bars span whole runs of lines.
    for key in [NSAttributedString.Key.gleaCode, .gleaQuote] {
      var location = chars.location
      while location < NSMaxRange(chars) {
        var run = NSRange()
        let value = storage.attribute(key, at: location, longestEffectiveRange: &run, in: full)
        if value != nil {
          var rect = lineRects(run)
          if !rect.isNull {
            let indent = sectionIndent(at: run.location)
            if key == .gleaCode {
              rect.origin.x = origin.x + indent
              rect.size.width = container.size.width - indent
              Theme.codeBackground.setFill()
              NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -2), xRadius: 6, yRadius: 6).fill()
            } else {
              Theme.tertiaryText.withAlphaComponent(0.35).setFill()
              // Down to the last line's descender, not its fragment: the
              // note's last line gets no paragraph spacing, which would make
              // its bar shorter.
              var lastLine = NSRange()
              let lastGlyph = glyphRange(forCharacterRange: run, actualCharacterRange: nil).upperBound - 1
              let lastRect = lineFragmentRect(forGlyphAt: max(0, lastGlyph), effectiveRange: &lastLine)
              let baseline = origin.y + lastRect.minY + self.location(forGlyphAt: lastLine.location).y
              let bottom = baseline - Theme.bodyFont.descender
              let bar = NSRect(x: origin.x + indent + 2, y: rect.minY + 2, width: 3, height: bottom - rect.minY - 2)
              NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
          }
        }
        location = NSMaxRange(run)
      }
    }

    storage.enumerateAttribute(.gleaRule, in: chars) { value, range, _ in
      guard value != nil else { return }
      let rect = lineRects(range)
      let indent = sectionIndent(at: range.location)
      Theme.separator.setFill()
      NSRect(x: origin.x + indent, y: rect.midY - 0.5, width: container.size.width - indent, height: 1).fill()
    }

    storage.enumerateAttribute(.gleaBullet, in: chars) { value, range, _ in
      guard value != nil else { return }
      let glyph = glyphIndexForCharacter(at: range.location)
      let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let x = origin.x + location(forGlyphAt: glyph).x + line.minX
      let baseline = origin.y + line.minY + location(forGlyphAt: glyph).y
      let dot = NSRect(x: x + 1.5, y: baseline - Theme.bodyFont.xHeight / 2 - 2.5, width: 5, height: 5)
      Theme.secondaryText.setFill()
      NSBezierPath(ovalIn: dot).fill()
    }

    storage.enumerateAttribute(.gleaTaskDrawn, in: chars) { value, range, _ in
      guard value != nil else { return }
      let done = (storage.attribute(.gleaTask, at: range.location, effectiveRange: nil) as? NSNumber)?.boolValue ?? false
      let glyph = glyphIndexForCharacter(at: range.location)
      let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let x = origin.x + line.minX + location(forGlyphAt: glyph).x
      let baseline = origin.y + line.minY + location(forGlyphAt: glyph).y
      let box = NSRect(x: x + 1, y: baseline - Theme.bodyFont.capHeight / 2 - 7, width: 14, height: 14)
      let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
      if done {
        Theme.accent.setFill()
        path.fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
        check.line(to: NSPoint(x: box.minX + 6, y: box.maxY - 3.5))
        check.line(to: NSPoint(x: box.maxX - 3, y: box.minY + 3.5))
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.white.setStroke()
        check.stroke()
      } else {
        Theme.tertiaryText.setStroke()
        path.lineWidth = 1.3
        path.stroke()
      }
    }

    // Tables: a rounded outline, a tinted header, and cell dividers.
    storage.enumerateAttribute(.gleaTableRow, in: chars) { value, range, _ in
      guard let row = value as? MarkdownTableRow, let left = row.columnX.first, let right = row.columnX.last else { return }
      let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var rect = NSRect.null
      enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in rect = rect.union(lineRect) }
      guard !rect.isNull else { return }
      rect = NSRect(x: origin.x + left, y: origin.y + rect.minY, width: right - left, height: rect.height)
      let cells = rect
      // The outline's stroke is centered on its path: inset the table's outer
      // edges by half of it, or the text view clips that half (the left and
      // right borders, flush with the column, looked cropped).
      rect = rect.insetBy(dx: 0.5, dy: 0)
      if row.isFirst { rect.origin.y += 0.5; rect.size.height -= 0.5 }
      if row.isLast { rect.size.height -= 0.5 }
      let radius: CGFloat = 6
      NSGraphicsContext.saveGraphicsState()
      // Clip rows to the table's rounded outline.
      let outline = NSBezierPath()
      let tl = row.isFirst ? radius : 0
      let bl = row.isLast ? radius : 0
      outline.move(to: NSPoint(x: rect.minX, y: rect.minY + tl))
      if tl > 0 { outline.appendArc(withCenter: NSPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: 180, endAngle: 270) }
      outline.line(to: NSPoint(x: rect.maxX - tl, y: rect.minY))
      if tl > 0 { outline.appendArc(withCenter: NSPoint(x: rect.maxX - tl, y: rect.minY + tl), radius: tl, startAngle: 270, endAngle: 360) }
      outline.line(to: NSPoint(x: rect.maxX, y: rect.maxY - bl))
      if bl > 0 { outline.appendArc(withCenter: NSPoint(x: rect.maxX - bl, y: rect.maxY - bl), radius: bl, startAngle: 0, endAngle: 90) }
      outline.line(to: NSPoint(x: rect.minX + bl, y: rect.maxY))
      if bl > 0 { outline.appendArc(withCenter: NSPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: 90, endAngle: 180) }
      outline.close()
      if row.isHeader {
        Theme.codeBackground.setFill()
        outline.fill()
      }
      Theme.separator.setStroke()
      outline.lineWidth = 1
      outline.stroke()
      Theme.separator.setFill()
      for x in row.columnX.dropFirst().dropLast() {
        NSRect(x: origin.x + x - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
      }
      // A wrapped table's cells (the row's own text takes no room).
      for (column, text) in (row.cells ?? []).enumerated() where column + 1 < row.columnX.count {
        if let hidden = hiddenCell, hidden.row == range.location, hidden.column == column { continue }
        text.draw(with: row.cellRect(column, in: cells), options: [.usesLineFragmentOrigin, .usesFontLeading])
      }
      NSGraphicsContext.restoreGraphicsState()
    }

    storage.enumerateAttribute(.gleaImage, in: chars) { value, range, _ in
      guard let info = value as? MarkdownImage else { return }
      let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let last = max(glyphs.location, NSMaxRange(glyphs) - 1)
      let used = lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
      let rect = NSRect(x: origin.x + info.indent, y: origin.y + used.maxY + 6, width: info.size.width, height: info.size.height)
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
      info.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}

// MARK: - Folding

/// Lays out collapsed sections (`.gleaFolded`) as nothing: their glyphs are
/// null, their line breaks don't break, and the one line fragment they end
/// up in has no height.
final class FoldingLayoutDelegate: NSObject, NSLayoutManagerDelegate {
  private func isFolded(_ layoutManager: NSLayoutManager, _ index: Int) -> Bool {
    guard let storage = layoutManager.textStorage, index < storage.length else { return false }
    return storage.attribute(.gleaFolded, at: index, effectiveRange: nil) != nil
  }

  func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                     properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                     font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
    var props = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
    var changed = false
    for i in props.indices where isFolded(layoutManager, characterIndexes[i]) {
      props[i] = .null
      changed = true
    }
    guard changed else { return 0 }
    layoutManager.setGlyphs(glyphs, properties: props, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
    return glyphRange.length
  }

  func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                     forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
    isFolded(layoutManager, charIndex) ? .zeroAdvancement : action
  }

  func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                     lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                     in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
    let start = layoutManager.characterIndexForGlyph(at: glyphRange.location)
    let height: CGFloat
    if isFolded(layoutManager, start) {
      height = 0
    } else if let storage = layoutManager.textStorage, start < storage.length,
              storage.attribute(.gleaFoldEnd, at: start, effectiveRange: nil) != nil {
      height = 0
    } else {
      return false
    }
    lineFragmentRect.pointee.size.height = height
    lineFragmentUsedRect.pointee.size.height = height
    baselineOffset.pointee = 0
    return true
  }
}

/// The left gutter of a note: chevrons that collapse and expand sections
/// (always shown), and a grip on the hovered block to drag it elsewhere.
final class NoteGutterView: NSView {
  struct Item {
    let key: String
    /// The heading's line, and the vertical center of its text.
    let line: NSRect
    let centerY: CGFloat
    let collapsed: Bool
    /// How far the heading's section indents it: the chevron sits next to it.
    var indent: CGFloat = 0
    /// How open the section is, from 0 to 1: turns the chevron.
    var openness: CGFloat = 1
  }

  /// A draggable block: the band of lines it covers, and the center of its
  /// first line's text.
  struct Handle {
    let block: Int
    let band: ClosedRange<CGFloat>
    let centerY: CGFloat
  }

  static let width: CGFloat = 48
  var items: [Item] = [] {
    didSet { needsDisplay = true }
  }
  var handles: [Handle] = [] {
    didSet {
      if let hovered, !handles.contains(where: { $0.block == hovered.block }) { self.hovered = nil }
      needsDisplay = true
    }
  }
  /// Where a dragged block would go, as a line across the text.
  var dropY: CGFloat? {
    didSet { needsDisplay = true }
  }
  /// Where a dragged block was lifted from (or is landing): its grip and
  /// chevrons there aren't drawn, the lifted copy has its own.
  var liftedBand: ClosedRange<CGFloat>? {
    didSet { needsDisplay = true }
  }
  private var drawingLifted = false

  /// Draws what the lifted copy shows: the dragged block's grip and chevrons.
  func drawLifted(_ rect: NSRect) {
    drawingLifted = true
    defer { drawingLifted = false }
    draw(rect)
  }
  var onToggle: ((String) -> Void)?
  /// Dragging a block: began (returns whether it can), moved (pointer y),
  /// ended (whether to drop it).
  var onDragBegin: ((Int, CGFloat) -> Bool)?
  var onDragMove: ((CGFloat) -> Void)?
  var onDragEnd: ((Bool) -> Void)?
  private var hovered: Handle?
  private var dragging = false {
    didSet { dragging ? startAutoscroll() : stopAutoscroll() }
  }
  private var tracking: NSTrackingArea?
  private var autoscrollTimer: Timer?

  override var isFlipped: Bool { true }

  /// Chevrons turning as their section folds or unfolds: from how open, to
  /// how open, since when.
  private var turns: [String: (from: CGFloat, to: CGFloat, start: CFTimeInterval)] = [:]
  private var turnTimer: Timer?

  func turnChevron(_ key: String, open: Bool) {
    let to: CGFloat = open ? 1 : 0
    turns[key] = (turnedOpenness(key) ?? 1 - to, to, CACurrentMediaTime())
    guard turnTimer == nil, !Motion.reduceMotion else { return }
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.stepTurns() }
    }
    RunLoop.main.add(timer, forMode: .common)
    turnTimer = timer
  }

  private func turnedOpenness(_ key: String) -> CGFloat? {
    guard let turn = turns[key] else { return nil }
    let t = min(1, (CACurrentMediaTime() - turn.start) / Motion.foldDuration)
    return turn.from + (turn.to - turn.from) * CGFloat(CubicBezier.fold(t))
  }

  /// Redraws just the turning chevrons.
  private func stepTurns() {
    let now = CACurrentMediaTime()
    for item in items where turns[item.key] != nil {
      setNeedsDisplay(chevronRect(item).insetBy(dx: -4, dy: -4))
    }
    turns = turns.filter { now - $0.value.start < Motion.foldDuration + 0.05 }
    if turns.isEmpty {
      turnTimer?.invalidate()
      turnTimer = nil
    }
  }

  private func chevronRect(_ item: Item) -> NSRect {
    NSRect(x: NoteGutterView.width - 23 + item.indent, y: item.centerY - 9, width: 18, height: 18)
  }

  private func gripRect(_ handle: Handle) -> NSRect {
    NSRect(x: 6, y: handle.centerY - 9, width: 14, height: 18)
  }

  private func chevron(at point: NSPoint) -> Item? {
    items.first { chevronRect($0).insetBy(dx: -3, dy: -3).contains(point) }
  }

  private func grip(at point: NSPoint) -> Handle? {
    guard let hovered, gripRect(hovered).insetBy(dx: -3, dy: -3).contains(point) else { return nil }
    return hovered
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, let superview else { return nil }
    let local = convert(point, from: superview)
    return chevron(at: local) != nil || grip(at: local) != nil ? self : nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate],
                              owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseMoved(with event: NSEvent) { trackMouse(event) }
  override func mouseEntered(with event: NSEvent) { trackMouse(event) }

  override func mouseExited(with event: NSEvent) {
    guard !dragging else { return }
    setHovered(nil)
  }

  override func cursorUpdate(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if dragging { NSCursor.closedHand.set() } else if grip(at: point) != nil { NSCursor.openHand.set() } else { super.cursorUpdate(with: event) }
  }

  private func trackMouse(_ event: NSEvent) {
    guard !dragging else { return }
    let point = convert(event.locationInWindow, from: nil)
    // The innermost block under the pointer (a list item, not its list's
    // heading section).
    let hit = handles.filter { $0.band.contains(point.y) && point.x >= 0 }
      .min { $0.band.upperBound - $0.band.lowerBound < $1.band.upperBound - $1.band.lowerBound }
    setHovered(hit)
    if grip(at: point) != nil { NSCursor.openHand.set() }
  }

  private func setHovered(_ handle: Handle?) {
    guard handle?.block != hovered?.block || handle?.centerY != hovered?.centerY else { return }
    hovered = handle
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let item = chevron(at: point) {
      onToggle?(item.key)
    } else if let handle = grip(at: point), onDragBegin?(handle.block, point.y) ?? false {
      // The block lifts as soon as it is pressed.
      dragging = true
      NSCursor.closedHand.set()
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard dragging else { return }
    onDragMove?(convert(event.locationInWindow, from: nil).y)
  }

  // MARK: Autoscroll

  /// How close to the page's top or bottom edge the pointer starts
  /// scrolling it, and the fastest it scrolls (points per second).
  private static let autoscrollZone: CGFloat = 56
  private static let autoscrollSpeed: CGFloat = 1400

  private func startAutoscroll() {
    stopAutoscroll()
    var last = CACurrentMediaTime()
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        let now = CACurrentMediaTime()
        self?.autoscrollStep(min(now - last, 0.05))
        last = now
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    autoscrollTimer = timer
  }

  private func stopAutoscroll() {
    autoscrollTimer?.invalidate()
    autoscrollTimer = nil
  }

  /// The page scrolls while the pointer is near or past its edges, faster
  /// the closer it gets, even when the pointer holds still.
  private func autoscrollStep(_ elapsed: CFTimeInterval) {
    guard dragging, let window, let scrollView = enclosingScrollView else { return }
    let clip = scrollView.contentView
    let pointer = window.mouseLocationOutsideOfEventStream
    let inClip = clip.convert(pointer, from: nil)
    let visible = clip.bounds
    let zone = min(Self.autoscrollZone, visible.height / 4)
    // Flipped: minY is the top edge.
    var pull: CGFloat = 0
    if inClip.y < visible.minY + zone {
      pull = -min(1, (visible.minY + zone - inClip.y) / zone)
    } else if inClip.y > visible.maxY - zone {
      pull = min(1, (inClip.y - (visible.maxY - zone)) / zone)
    }
    guard pull != 0, let document = scrollView.documentView else { return }
    let maxY = max(0, document.frame.height - visible.height)
    let step = pull * abs(pull) * Self.autoscrollSpeed * CGFloat(elapsed)
    let y = min(max(0, visible.minY + step), maxY)
    guard abs(y - visible.minY) > 0.01 else { return }
    clip.scroll(to: NSPoint(x: visible.minX, y: y))
    scrollView.reflectScrolledClipView(clip)
    // The text moved under a still pointer: follow it.
    onDragMove?(convert(pointer, from: nil).y)
  }

  override func mouseUp(with event: NSEvent) {
    guard dragging else { return }
    dragging = false
    onDragEnd?(true)
    trackMouse(event)
    NSCursor.arrow.set()
  }

  /// The chevron, plain and hovered (made once: making symbol images is
  /// slow, and pages have many headings).
  private var chevronImages: [Bool: NSImage] = [:]
  private var chevronAppearance: NSAppearance.Name?

  private func chevronImage(over: Bool) -> NSImage? {
    let appearance = effectiveAppearance.name
    if chevronAppearance != appearance {
      chevronImages = [:]
      chevronAppearance = appearance
    }
    if let image = chevronImages[over] { return image }
    var image: NSImage?
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        .applying(.init(paletteColors: [(over ? Theme.text : Theme.secondaryText).usingColorSpace(.sRGB) ?? .gray]))
      image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
    chevronImages[over] = image
    return image
  }

  override func draw(_ dirtyRect: NSRect) {
    let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    if let dropY {
      Theme.accent.setFill()
      let x = NoteGutterView.width
      NSBezierPath(roundedRect: NSRect(x: x - 4, y: dropY - 1, width: bounds.width - x + 4, height: 2), xRadius: 1, yRadius: 1).fill()
      NSBezierPath(ovalIn: NSRect(x: x - 7, y: dropY - 3, width: 6, height: 6)).fill()
    }
    let hiddenBand = drawingLifted ? nil : liftedBand
    if let hovered, !(hiddenBand?.contains(hovered.centerY) ?? false) {
      let rect = gripRect(hovered)
      let over = dragging || (mouse.map { rect.insetBy(dx: -3, dy: -3).contains($0) } ?? false)
      (over ? Theme.secondaryText : Theme.tertiaryText).setFill()
      for row in 0..<3 {
        for column in 0..<2 {
          let dot = NSRect(x: rect.midX - 3.5 + CGFloat(column) * 5, y: rect.midY - 6 + CGFloat(row) * 5, width: 2.5, height: 2.5)
          NSBezierPath(ovalIn: dot).fill()
        }
      }
    }
    for item in items where !(hiddenBand?.contains(item.centerY) ?? false) {
      let rect = chevronRect(item)
      guard rect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }
      let over = mouse.map { rect.insetBy(dx: -3, dy: -3).contains($0) } ?? false
      guard let image = chevronImage(over: over) else { continue }
      let size = image.size
      NSGraphicsContext.saveGraphicsState()
      // Turns from right (collapsed) to down (open) as the section opens.
      let turn = NSAffineTransform()
      turn.translateX(by: rect.midX, yBy: rect.midY)
      turn.rotate(byDegrees: 90 * (turnedOpenness(item.key) ?? item.openness))
      turn.concat()
      image.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}

// MARK: - Text view

final class MarkdownTextView: NSTextView {
  /// A click in a wrapped table's cell (its row's location, its column):
  /// the cell's own field takes it.
  var onEditCell: ((_ row: Int, _ column: Int, _ event: NSEvent) -> Void)?
  var onSearch: ((URL) -> Void)?

  /// Kept between the cursor and the page's top or bottom edge as it moves.
  private static let caretMargin: CGFloat = 40

  /// The page (not this view) scrolls: just enough to keep the cursor in
  /// view with a margin, one line at a time as it moves (AppKit's own jumps
  /// half a page, re-centering the cursor, each time it leaves the view).
  override func scrollRangeToVisible(_ range: NSRange) {
    guard let scrollView = enclosingScrollView, let layout = layoutManager, let container = textContainer else {
      return super.scrollRangeToVisible(range)
    }
    let clip = scrollView.contentView
    let length = (string as NSString).length
    var rect: NSRect
    if range.location >= length, !layout.extraLineFragmentRect.isEmpty {
      rect = layout.extraLineFragmentRect  // the empty last line
    } else {
      let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: min(range.location, max(0, length - 1)),
                                                                length: max(range.length, 1)), actualCharacterRange: nil)
      rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    }
    rect.origin.x += textContainerOrigin.x
    rect.origin.y += textContainerOrigin.y
    let target = convert(rect, to: clip)
    let visible = clip.bounds
    let margin = min(Self.caretMargin, visible.height / 4)
    // (Too tall to show whole, like a long selection: AppKit's way.)
    guard clip.isFlipped, target.height < visible.height - 2 * margin else { return super.scrollRangeToVisible(range) }
    var y = visible.minY
    if target.maxY > visible.maxY - margin {
      y = target.maxY + margin - visible.height
    } else if target.minY < visible.minY + margin {
      y = target.minY - margin
    }
    let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - visible.height)
    y = min(max(0, y), maxY)
    guard abs(y - visible.minY) > 0.5 else { return }
    clip.scroll(to: NSPoint(x: visible.minX, y: y))
    scrollView.reflectScrolledClipView(clip)
  }

  var noteNames: () -> [String] = { [] }
  var onFocusChange: ((Bool) -> Void)?
  /// While undoing or redoing a move: the cursor stays a cursor instead of
  /// selecting the text that comes back.
  var keepsSelectionThroughUndo = false

  override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
    defer {
      slashMenu.selectionDidChange()
      linkMenu.selectionDidChange()
    }
    guard keepsSelectionThroughUndo, let first = ranges.first?.rangeValue else {
      super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
      return
    }
    super.setSelectedRanges([NSValue(range: NSRange(location: first.location, length: 0))], affinity: affinity, stillSelecting: stillSelecting)
  }

  /// The blocks menu "/" opens.
  private(set) lazy var slashMenu = SlashMenu(textView: self, kind: .blocks)
  /// The notes menu "[[" opens.
  private(set) lazy var linkMenu = SlashMenu(textView: self, kind: .noteLink)

  /// While a menu shows, it takes ↑/↓, Return, Tab and Esc.
  override func doCommand(by selector: Selector) {
    if slashMenu.handle(selector) || linkMenu.handle(selector) { return }
    super.doCommand(by: selector)
  }

  // Dropped or pasted images become Markdown images stored in assets/.
  override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
    super.acceptableDragTypes + [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let images = imageMarkdown(from: sender.draggingPasteboard) {
      // (Where the drop caret was: a point in this view.)
      let point = convert(sender.draggingLocation, from: nil)
      insertImages(images, at: characterIndexForInsertion(at: point), afterLine: true)
      return true
    }
    return super.performDragOperation(sender)
  }

  override func paste(_ sender: Any?) {
    if let images = imageMarkdown(from: .general, preferText: true) {
      insertImages(images, at: selectedRange().location)
      return
    }
    super.paste(sender)
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { onFocusChange?(true) }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      slashMenu.close()
      linkMenu.close()
      onFocusChange?(false)
    }
    return result
  }

  /// A click inside a rendered table cell puts the cursor in that cell. (The
  /// hidden pipes and padding sit in the column's empty space, so the plain
  /// hit test would often land in the next cell.)
  private func handleTableClick(_ event: NSEvent) -> Bool {
    guard event.clickCount == 1, !event.modifierFlags.contains(.shift),
          let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return false }
    let point = convert(event.locationInWindow, from: nil)
    let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    let glyph = layoutManager.glyphIndex(for: p, in: textContainer)
    let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    guard lineRect.contains(p) else { return false }
    var charIndex = layoutManager.characterIndexForGlyph(at: glyph)
    // Past the last cell the hit is the row's newline, just outside the row.
    if charIndex > 0, charIndex < storage.length || charIndex == storage.length,
       charIndex == storage.length || (string as NSString).character(at: charIndex) == 0x0A {
      charIndex -= 1
    }
    var rowRange = NSRange()
    guard charIndex < storage.length,
          let row = storage.attribute(.gleaTableRow, at: charIndex, longestEffectiveRange: &rowRange,
                                      in: NSRange(location: 0, length: storage.length)) as? MarkdownTableRow,
          let column = row.columnX.indices.dropLast().last(where: { row.columnX[$0] <= p.x }) else { return false }
    let s = string as NSString
    let line = s.lineRange(for: NSRange(location: rowRange.location, length: 0))
    var text = s.substring(with: line)
    if text.hasSuffix("\n") { text.removeLast() }
    let cells = MarkdownStyler.tableCells(in: text as NSString).map { NSRange(location: $0.location + line.location, length: $0.length) }
    guard column < cells.count else { return false }
    // A link in a wrapped cell opens; elsewhere the click edits the table.
    if row.cells != nil {
      let rowRect = NSRect(x: row.columnX[0], y: lineRect.minY, width: (row.columnX.last ?? 0) - row.columnX[0], height: lineRect.height)
      let cellRect = row.cellRect(column, in: rowRect)
      let local = NSPoint(x: p.x - cellRect.minX, y: p.y - cellRect.minY)
      if let link = row.link(inCell: column, at: local, width: cellRect.width) {
        _ = delegate?.textView?(self, clickedOnLink: link, at: rowRange.location)
        return true
      }
    }
    // A wrapped cell: its field places the cursor where it was clicked (and
    // drags select), without this view's cursor showing in the row first.
    if row.cells != nil, let onEditCell {
      onEditCell(line.location, column, event)
      return true
    }
    let cell = cells[column]
    window?.makeFirstResponder(self)
    let hit = characterIndexForInsertion(at: point)
    let inCell = NSRange(location: hit >= cell.location && hit <= NSMaxRange(cell) ? hit : NSMaxRange(cell), length: 0)
    if row.cells == nil {
      // A table that fits: AppKit's own click handling, so dragging selects
      // text; a plain click then lands in the cell that was clicked.
      super.mouseDown(with: event)
      if selectedRange().length == 0 { setSelectedRange(inCell) }
      return true
    }
    setSelectedRange(inCell)
    return true
  }

  // Clicking a drawn checkbox toggles the task.
  /// Whether the pointer is over another view laid over the text (a media
  /// block): the text view's tracking still fires there, and its I-beam would
  /// override the view's own cursor.
  private func isCovered(_ event: NSEvent) -> Bool {
    guard let content = window?.contentView else { return false }
    let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
    return hit != nil && hit !== self && !(hit?.isDescendant(of: self) ?? false)
  }

  override func mouseMoved(with event: NSEvent) {
    if isCovered(event) { return }
    super.mouseMoved(with: event)
  }

  override func cursorUpdate(with event: NSEvent) {
    if isCovered(event) { return }
    super.cursorUpdate(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    if handleTableClick(event) { return }
    if let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 {
      let point = convert(event.locationInWindow, from: nil)
      let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
      let glyph = layoutManager.glyphIndex(for: p, in: textContainer)
      let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
      let index = layoutManager.characterIndexForGlyph(at: glyph)
      if rect.insetBy(dx: -4, dy: -3).contains(p), index < storage.length {
        var range = NSRange()
        if storage.attribute(.gleaTaskDrawn, at: index, effectiveRange: nil) != nil,
           let done = storage.attribute(.gleaTask, at: index, effectiveRange: &range) as? NSNumber {
          let inner = NSRange(location: range.location + 1, length: 1)
          let replacement = done.boolValue ? " " : "x"
          if shouldChangeText(in: inner, replacementString: replacement) {
            storage.replaceCharacters(in: inner, with: replacement)
            didChangeText()
          }
          return
        }
      }
    }
    super.mouseDown(with: event)
  }

  // MARK: Lists

  private static let listPrefix = try! NSRegularExpression(pattern: "^(\\s*(?:>\\s?)*)(\\s*)([-*+]|(\\d+)([.)]))\\s+(\\[[ xX]\\]\\s+)?")
  private static let quotePrefix = try! NSRegularExpression(pattern: "^(\\s*>\\s?)+")

  private var currentLine: (range: NSRange, text: String) {
    let s = string as NSString
    let range = s.lineRange(for: NSRange(location: selectedRange().location, length: 0))
    var text = s.substring(with: range)
    if text.hasSuffix("\n") { text.removeLast() }
    return (range, text)
  }

  /// ⌘⌫: delete back to the start of the current line, never further.
  /// Text goes first, then the line's marker ("- ", "> ", "## "...); at the
  /// very start of a line it only joins it with the previous one.
  override func deleteToBeginningOfLine(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length > 0 {
      replace(selection, with: "")
      return
    }
    let s = string as NSString
    let caret = selection.location
    let line = s.lineRange(for: NSRange(location: caret, length: 0))
    if caret == line.location {
      guard caret > 0 else { return }
      replace(NSRange(location: caret - 1, length: 1), with: "")
      return
    }
    // Stop at the start of the visual line when the paragraph wraps.
    var start = line.location
    if let layoutManager, let textContainer {
      layoutManager.ensureLayout(for: textContainer)
      var fragment = NSRange()
      let glyph = layoutManager.glyphIndexForCharacter(at: max(line.location, caret - 1))
      layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragment)
      start = max(start, layoutManager.characterRange(forGlyphRange: fragment, actualGlyphRange: nil).location)
    }
    // Keep the line's Markdown marker while there is text after it.
    var lineText = s.substring(with: line)
    if lineText.hasSuffix("\n") { lineText.removeLast() }
    let local = NSRange(location: 0, length: (lineText as NSString).length)
    var markerEnd = 0
    for pattern in [MarkdownTextView.listPrefix, MarkdownTextView.quotePrefix, MarkdownTextView.headingPrefix] {
      if let m = pattern.firstMatch(in: lineText, range: local) { markerEnd = max(markerEnd, m.range.length) }
    }
    let contentStart = line.location + markerEnd
    if start < contentStart && caret > contentStart { start = contentStart }
    replace(NSRange(location: start, length: caret - start), with: "")
  }

  private static let headingPrefix = try! NSRegularExpression(pattern: "^#{1,6} ")

  // MARK: Searching the web

  /// ⌘↩ searches the web for the word at the cursor (or the selection),
  /// ⌥⌘↩ for the sentence; the searched text becomes a link to the search.
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
      let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
      if flags == .command || flags == [.command, .option], searchWeb(sentence: flags.contains(.option)) { return }
    }
    super.keyDown(with: event)
  }

  private func searchWeb(sentence: Bool) -> Bool {
    let selection = selectedRange()
    guard let range = selection.length > 0 ? selection : (sentence ? sentenceAtCursor() : wordAtCursor()), range.length > 0 else {
      return false
    }
    let raw = (string as NSString).substring(with: range)
    // What reads on screen, not its Markdown.
    let query = MarkdownPreview.render(raw).string.trimmingCharacters(in: .whitespacesAndNewlines)
    // (Parentheses would end the Markdown link early.)
    let address = SearchEngine.current.searchURL(query).replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    guard !query.isEmpty, let url = URL(string: address) else { return false }
    // Already a link (or in one): just searched.
    let linked = (range.location..<NSMaxRange(range)).contains { textStorage?.attribute(.link, at: $0, effectiveRange: nil) != nil }
      || raw.contains("](") || raw.contains("[[")
    if !linked, !raw.contains("\n") {
      let label = raw.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
      replace(range, with: "[\(label)](\(url.absoluteString))")
    }
    onSearch?(url)
    return true
  }

  /// The line's text after its Markdown marker ("- ", "> ", "## "...).
  private var currentLineContent: NSRange {
    let line = currentLine
    let local = NSRange(location: 0, length: (line.text as NSString).length)
    var markerEnd = 0
    for pattern in [MarkdownTextView.listPrefix, MarkdownTextView.quotePrefix, MarkdownTextView.headingPrefix] {
      if let m = pattern.firstMatch(in: line.text, range: local) { markerEnd = max(markerEnd, m.range.length) }
    }
    return NSRange(location: line.range.location + markerEnd, length: local.length - markerEnd)
  }

  /// The word the cursor is in or just after (skipping spaces back to it).
  private func wordAtCursor() -> NSRange? {
    let s = string as NSString
    let content = currentLineContent
    let isWord: (Int) -> Bool = { index in
      guard let scalar = Unicode.Scalar(s.character(at: index)) else { return true }
      return CharacterSet.alphanumerics.contains(scalar) || "'’-_".unicodeScalars.contains(scalar)
    }
    var end = min(max(selectedRange().location, content.location), NSMaxRange(content))
    while end < NSMaxRange(content), isWord(end) { end += 1 }
    while end > content.location, !isWord(end - 1) { end -= 1 }
    var start = end
    while start > content.location, isWord(start - 1) { start -= 1 }
    return end > start ? NSRange(location: start, length: end - start) : nil
  }

  /// The sentence the cursor is in, on its line.
  private func sentenceAtCursor() -> NSRange? {
    let s = string as NSString
    let content = currentLineContent
    let caret = min(max(selectedRange().location, content.location), NSMaxRange(content))
    var found: NSRange?
    s.enumerateSubstrings(in: content, options: .bySentences) { _, range, _, stop in
      if caret >= range.location && caret <= NSMaxRange(range) {
        found = range
        stop.pointee = true
      }
    }
    guard var range = found else { return nil }
    // Without the space and closing punctuation around it.
    let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".!?;:"))
    while range.length > 0, let c = Unicode.Scalar(s.character(at: NSMaxRange(range) - 1)), trim.contains(c) { range.length -= 1 }
    while range.length > 0, let c = Unicode.Scalar(s.character(at: range.location)), CharacterSet.whitespaces.contains(c) {
      range.location += 1
      range.length -= 1
    }
    return range
  }

  private func replace(_ range: NSRange, with text: String) {
    guard shouldChangeText(in: range, replacementString: text) else { return }
    textStorage?.replaceCharacters(in: range, with: text)
    didChangeText()
    setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
  }

  /// Enter continues lists, tasks and quotes; on an empty item it ends them.
  /// In a table it adds a row (and a typed header row becomes a table).
  override func insertNewline(_ sender: Any?) {
    // Enter on a fence that opens a block with no end closes it, the cursor
    // going inside.
    if selectedRange().length == 0, let opener = unclosedFence,
       selectedRange().location == NSMaxRange(opener), currentLine.range.location == opener.location {
      let location = selectedRange().location
      replace(NSRange(location: location, length: 0), with: "\n\n" + closingFence(for: (string as NSString).substring(with: opener)))
      setSelectedRange(NSRange(location: location + 1, length: 0))
      return
    }
    if selectedRange().length == 0 {
      if completeTableHeader() { return }
      if let row = tableRowAtCursor(), !(string as NSString).substring(with: row.line).contains("---") {
        if isEmptyTableRow(row) && !isHeaderRow(row) {
          leaveTable(removing: row)
        } else {
          addTableRow(after: row)
        }
        return
      }
    }
    let (range, text) = currentLine
    let local = NSRange(location: 0, length: (text as NSString).length)
    if selectedRange().length == 0, let m = MarkdownTextView.listPrefix.firstMatch(in: text, range: local) {
      if m.range.length == local.length {
        replace(NSRange(location: range.location, length: m.range.length), with: "")
        return
      }
      let ns = text as NSString
      var marker = ns.substring(with: m.range(at: 3))
      if m.range(at: 4).location != NSNotFound, let n = Int(ns.substring(with: m.range(at: 4))) {
        marker = "\(n + 1)" + ns.substring(with: m.range(at: 5))
      }
      let task = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
      insertText("\n" + ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + marker + " " + task, replacementRange: selectedRange())
      return
    }
    if selectedRange().length == 0, let m = MarkdownTextView.quotePrefix.firstMatch(in: text, range: local) {
      if m.range.length == local.length {
        replace(NSRange(location: range.location, length: m.range.length), with: "")
        return
      }
      insertText("\n" + (text as NSString).substring(with: m.range), replacementRange: selectedRange())
      return
    }
    super.insertNewline(sender)
  }

  override func insertTab(_ sender: Any?) {
    if moveTableCell(forward: true) { return }
    let (range, text) = currentLine
    if MarkdownTextView.listPrefix.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
      let selection = selectedRange()
      replace(NSRange(location: range.location + quotePrefixLength(text), length: 0), with: "  ")
      setSelectedRange(NSRange(location: selection.location + 2, length: selection.length))
      return
    }
    super.insertTab(sender)
  }

  override func insertBacktab(_ sender: Any?) {
    if moveTableCell(forward: false) { return }
    let (range, text) = currentLine
    let start = quotePrefixLength(text)
    let spaces = min(2, (text as NSString).substring(from: start).prefix { $0 == " " }.count)
    guard spaces > 0 else { return }
    let selection = selectedRange()
    replace(NSRange(location: range.location + start, length: spaces), with: "")
    setSelectedRange(NSRange(location: max(range.location + start, selection.location - spaces), length: selection.length))
  }

  /// Length of the line's quote markers ("> ", "> > "): list items in a
  /// quote are indented after them.
  private func quotePrefixLength(_ text: String) -> Int {
    MarkdownTextView.quotePrefix.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range.length ?? 0
  }


  // MARK: [[Wiki link]] completion

  /// Range of the partial note name when the cursor is inside `[[...`.
  var wikiLinkContext: NSRange? {
    let selection = selectedRange()
    guard selection.length == 0 else { return nil }
    let s = string as NSString
    let lineStart = s.lineRange(for: NSRange(location: selection.location, length: 0)).location
    let before = s.substring(with: NSRange(location: lineStart, length: selection.location - lineStart)) as NSString
    let open = before.range(of: "[[", options: .backwards)
    guard open.location != NSNotFound else { return nil }
    let partial = before.substring(from: open.upperBound)
    guard !partial.contains("]") else { return nil }
    let start = lineStart + open.upperBound
    return NSRange(location: start, length: selection.location - start)
  }


  // MARK: Task shortcut

  /// "[] ", "[ ] " or "[x] " typed at the start of a line, or of a list
  /// item ("- [] "), becomes a task.
  private static let taskShortcut = try! NSRegularExpression(pattern: "^((?:\\s*>\\s?)*\\s*)((?:[-*+]|\\d+[.)])\\s+)?\\[( ?|[xX])\\] $")

  private static let fence = try! NSRegularExpression(pattern: "^\\s*(```|~~~)")

  /// The ranges of the fence lines ("```", "~~~"), openers and closers alternating.
  private var fenceLines: [NSRange] {
    var fences: [NSRange] = []
    (string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (string as NSString).length),
                                             options: [.byLines, .substringNotRequired]) { _, line, _, _ in
      if MarkdownTextView.fence.firstMatch(in: self.string, range: line) != nil { fences.append(line) }
    }
    return fences
  }

  /// Whether the line in `range` closes a fenced code block.
  private func isClosingFence(_ range: NSRange) -> Bool {
    guard let index = fenceLines.firstIndex(where: { $0.location == range.location }) else { return false }
    return index % 2 == 1
  }

  /// The opening fence of a block that is never closed (it runs to the end).
  private var unclosedFence: NSRange? {
    let fences = fenceLines
    return fences.count % 2 == 1 ? fences.last : nil
  }

  /// The cursor sits at the end of a code block's closing fence.
  private var isAfterClosingFence: Bool {
    let selection = selectedRange()
    guard selection.length == 0 else { return false }
    let (range, text) = currentLine
    return selection.location == range.location + (text as NSString).length
      && isClosingFence(NSRange(location: range.location, length: (text as NSString).length))
  }

  /// The fence that closes the block opened by the fence line `text`.
  private func closingFence(for text: String) -> String {
    let indent = text.prefix { $0 == " " || $0 == "\t" }
    return indent + (text.trimmingCharacters(in: .whitespaces).hasPrefix("~") ? "~~~" : "```")
  }

  /// ↓ on the last line of the note, when it ends a code block, leaves the
  /// block: it adds a line after a closing fence, or closes an unclosed block.
  override func moveDown(_ sender: Any?) {
    let (range, text) = currentLine
    let length = (string as NSString).length
    if selectedRange().length == 0, NSMaxRange(range) == length, !string.hasSuffix("\n") || text.isEmpty {
      if !text.isEmpty, isClosingFence(NSRange(location: range.location, length: (text as NSString).length)) {
        replace(NSRange(location: length, length: 0), with: "\n")
        return
      }
      if let opener = unclosedFence, range.location > opener.location {
        let fence = closingFence(for: (string as NSString).substring(with: opener))
        replace(NSRange(location: length, length: 0), with: (text.isEmpty ? "" : "\n") + fence + "\n")
        return
      }
    }
    super.moveDown(sender)
  }

  /// Esc in a code block leaves it: the cursor goes to the line after its
  /// closing fence (added at the end of the note if the block has none).
  override func cancelOperation(_ sender: Any?) {
    let fences = fenceLines
    let line = currentLine.range.location
    let length = (string as NSString).length
    for open in stride(from: 0, to: fences.count, by: 2) where fences[open].location <= line {
      guard open + 1 < fences.count else {
        let fence = closingFence(for: (string as NSString).substring(with: fences[open]))
        replace(NSRange(location: length, length: 0), with: (string.hasSuffix("\n") ? "" : "\n") + fence + "\n")
        scrollRangeToVisible(selectedRange())
        return
      }
      let close = fences[open + 1]
      guard line <= close.location else { continue }
      if NSMaxRange(close) == length {
        replace(NSRange(location: length, length: 0), with: "\n")
      } else {
        setSelectedRange(NSRange(location: NSMaxRange(close) + 1, length: 0))
      }
      scrollRangeToVisible(selectedRange())
      return
    }
    // Inside "[[…" whose menu was closed: Esc brings it back.
    if let context = wikiLinkContext { linkMenu.open(at: context.location - 2) }
  }

  override func insertText(_ string: Any, replacementRange: NSRange) {
    // Text typed right after a closing fence goes on a new line: appended
    // to the fence, it would turn it into an opening one.
    if let typed = string as? String ?? (string as? NSAttributedString)?.string,
       !typed.hasPrefix("\n"), !typed.hasPrefix("`"), !typed.hasPrefix("~"),
       replacementRange.location == NSNotFound || replacementRange == selectedRange(), isAfterClosingFence {
      super.insertText("\n" + typed, replacementRange: replacementRange)
      return
    }
    super.insertText(string, replacementRange: replacementRange)
    guard (string as? String ?? (string as? NSAttributedString)?.string) == " " else { return }
    let (range, text) = currentLine
    let caret = selectedRange().location - range.location
    let before = (text as NSString).substring(to: min(caret, (text as NSString).length))
    guard let m = MarkdownTextView.taskShortcut.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { return }
    let done = (before as NSString).substring(with: m.range(at: 3)).lowercased() == "x"
    let box = done ? "[x] " : "[ ] "
    if m.range(at: 2).location != NSNotFound {
      // Already a list item: only the box is normalized ("[]" → "[ ]").
      let start = range.location + NSMaxRange(m.range(at: 2))
      replace(NSRange(location: start, length: range.location + m.range.upperBound - start), with: box)
      return
    }
    let start = range.location + m.range(at: 1).length
    replace(NSRange(location: start, length: m.range.length - m.range(at: 1).length), with: "- " + box)
  }

  override func didChangeText() {
    super.didChangeText()
    slashMenu.textDidChange()
    linkMenu.textDidChange()
  }
}

// MARK: - Editor view

enum BlockDragDebug {
  /// A variable so automated checks can slow it down.
  static var liftDuration: CFTimeInterval = 0.2
}

/// What covers the page while it slides (see `slidePage`): only seen, the
/// pointer goes through to the text under it.
final class SlideOverlayView: FlippedView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NSView {
  func snapshot(of rect: NSRect) -> NSImage {
    let image = NSImage(size: rect.size)
    if let rep = bitmapImageRepForCachingDisplay(in: rect) {
      cacheDisplay(in: rect, to: rep)
      image.addRepresentation(rep)
    }
    return image
  }
}

/// A self-sizing Markdown editor bound to one note. Saves automatically.
final class MarkdownEditorView: NSView, NSTextViewDelegate {
  private static let live = NSHashTable<MarkdownEditorView>.weakObjects()

  /// Saves every editor with unsaved changes.
  static func flushAll() {
    for editor in live.allObjects { editor.flush() }
  }

  private(set) var ref: NoteRef
  let textView: MarkdownTextView
  var onOpenLink: ((URL) -> Void)?
  /// A web search started from the text (⌘↩).
  var onSearch: ((URL) -> Void)?
  /// Called after the text changes (typing or an external edit).
  var onTextChange: (() -> Void)?

  private let layoutManager = MarkdownLayoutManager()
  private let foldingDelegate = FoldingLayoutDelegate()
  private let storage = NSTextStorage()
  private let gutter = NoteGutterView()
  /// Collapsed sections by note, kept while the app runs.
  private static var foldedByNote: [String: Set<String>] = [:]
  private var folded: Set<String> {
    get { MarkdownEditorView.foldedByNote[ref.id] ?? [] }
    set { MarkdownEditorView.foldedByNote[ref.id] = newValue }
  }
  /// What follows a change of height sliding into place (see `slidePage`).
  private var slide: Slide?
  /// Media blocks of a section closing, kept where they were open (in the
  /// page) until it's closed.
  private var closingMedia: [String: NSRect] = [:]
  private var saveWork: DispatchWorkItem?
  private var styledSelection: NSRange?
  /// Floating formatting bar, hosted in the window's content view.
  let formatBar = FormatBar()
  /// Media blocks by key, laid out over the text.
  private var mediaViews: [String: MediaBlockView] = [:]
  private var mediaLines: [String: NSRange] = [:]
  private var pendingMediaRestyle: Set<String> = []
  /// Bottom of the lowest media block, in text container coordinates.
  private var mediaBottom: CGFloat = 0
  private var styledWidth: CGFloat = 0
  private let observedAncestors = NSHashTable<NSView>.weakObjects()
  private var isDirty = false

  init(ref: NoteRef, placeholder: String = "Start writing…") {
    self.ref = ref
    let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layoutManager)
    layoutManager.delegate = foldingDelegate
    // Only what changed is laid out again: an embed growing or a section
    // folding doesn't retypeset the whole note below it.
    layoutManager.allowsNonContiguousLayout = true
    layoutManager.addTextContainer(container)
    textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 30), textContainer: container)
    super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 30))

    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.minSize = NSSize(width: 0, height: 30)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainerInset = NSSize(width: 0, height: 2)
    textView.font = Theme.bodyFont
    textView.insertionPointColor = Theme.accent
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
    textView.typingAttributes = MarkdownStyler.baseAttributes
    textView.delegate = self
    textView.onEditCell = { [weak self] row, column, event in self?.editCell(row: row, column: column, clicked: event) }
    textView.onSearch = { [weak self] url in self?.onSearch?(url) }
    // (Not this note: a link to itself goes nowhere.)
    textView.noteNames = { [weak self] in NoteStore.shared.noteNames.filter { $0 != self?.ref.name } }
    textView.onFocusChange = { [weak self] focused in
      // Once focus has moved: while resigning, the window still counts the
      // text view as focused, and restyling then restarts its caret (two
      // would blink in the journal).
      // Only around the cursor, where syntax shows or hides (the whole of a
      // long note took a while).
      DispatchQueue.main.async {
        guard let self else { return }
        let current = self.textView.selectedRange()
        self.restyle(limit: self.styledSelection.map { NSUnionRange($0, current) } ?? current)
      }
      if !focused { self?.formatBar.hide() }
    }
    formatBar.textView = textView
    gutter.onToggle = { [weak self] key in self?.toggleFold(key) }
    gutter.onDragBegin = { [weak self] block, y in self?.beginBlockDrag(block, at: y) ?? false }
    gutter.onDragMove = { [weak self] y in self?.moveBlockDrag(to: y) }
    gutter.onDragEnd = { [weak self] drop in self?.endBlockDrag(drop: drop) }
    if textView.responds(to: NSSelectorFromString("setPlaceholderAttributedString:")) {
      textView.setValue(NSAttributedString(string: placeholder, attributes: [
        .font: Theme.bodyFont, .foregroundColor: Theme.tertiaryText,
      ]), forKey: "placeholderAttributedString")
    }
    textView.postsFrameChangedNotifications = true
    addSubview(textView)

    NotificationCenter.default.addObserver(self, selector: #selector(textFrameChanged), name: NSView.frameDidChangeNotification, object: textView)
    NotificationCenter.default.addObserver(self, selector: #selector(notesChanged(_:)), name: .notesDidChange, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(imageLoaded), name: ImageCache.didLoad, object: nil)
    MarkdownEditorView.live.add(self)

    textView.string = NoteStore.shared.content(of: ref)
    restyle()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // The table toggle shows while the pointer is over a table, or over the
    // toggle itself (in the page's gutter, outside this view).
    if let hoverArea {
      hoverAreaHost?.removeTrackingArea(hoverArea)
      self.hoverArea = nil
    }
    if window != nil, let host = mediaHost {
      let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                owner: self)
      host.addTrackingArea(area)
      hoverArea = area
      hoverAreaHost = host
    }
    if window == nil {
      for view in mediaViews.values { view.removeFromSuperview() }
      mediaViews = [:]
      gutter.removeFromSuperview()
    } else {
      // Blocks live in the page, so follow this view and every ancestor up
      // to the page (the column recenters when the window resizes).
      for observed in observedAncestors.allObjects {
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observed)
      }
      observedAncestors.removeAllObjects()
      var view: NSView? = self
      while let current = view, current !== enclosingScrollView?.documentView {
        current.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorMoved), name: NSView.frameDidChangeNotification, object: current)
        observedAncestors.add(current)
        view = current.superview
      }
      DispatchQueue.main.async { [weak self] in self?.restyle() }
    }
    if let host = window?.appRootView {
      if formatBar.superview !== host { host.addSubview(formatBar) }
    } else {
      formatBar.removeFromSuperview()
    }
    // Selected blocks go gray with the text's selection when the window
    // isn't key.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      NotificationCenter.default.removeObserver(self, name: name, object: nil)
      if let window { NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window) }
    }
    // The bar follows the text when the page scrolls.
    NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    if let clip = enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(self, selector: #selector(pageScrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }
  }

  @objc private func pageScrolled() {
    formatBar.reposition(animated: false)
    // Scrolled under a still pointer.
    if let window, hoverArea != nil { updateTableHover(window.mouseLocationOutsideOfEventStream) }
  }

  private var hoverArea: NSTrackingArea?
  private weak var hoverAreaHost: NSView?

  override func mouseMoved(with event: NSEvent) { updateTableHover(event.locationInWindow) }
  override func mouseEntered(with event: NSEvent) { updateTableHover(event.locationInWindow) }
  override func mouseExited(with event: NSEvent) { updateTableHover(nil) }

  var content: String { textView.string }

  override var isFlipped: Bool { true }

  private var contentHeight: CGFloat = 30

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
  }

  override func layout() {
    super.layout()
    if abs(styledWidth - bounds.width) > 1 {
      textView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
      restyle()
    }
  }

  @objc private func textFrameChanged() {
    updateHeight()
  }

  /// Sizes the text view to its laid-out text, including an image drawn
  /// below the last paragraph.
  private func updateHeight() {
    guard let container = textView.textContainer else { return }
    layoutManager.ensureLayout(for: container)
    var height = layoutManager.usedRect(for: container).height
    let glyphCount = layoutManager.numberOfGlyphs
    if glyphCount > 0 {
      // usedRect leaves out the paragraph spacing reserved for a trailing image.
      let last = layoutManager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: nil)
      height = max(height, last.maxY)
    }
    // Media blocks hang below their line; the last paragraph's spacing
    // doesn't count in text layout, so make room for them explicitly.
    height = max(height, mediaBottom + 12)
    height = max(30, ceil(height + textView.textContainerInset.height * 2))
    if textView.frame.height != height || textView.frame.width != bounds.width {
      textView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
    }
    if abs(contentHeight - height) > 0.5 {
      contentHeight = height
      invalidateIntrinsicContentSize()
    }
  }

  func focus(atEnd: Bool = true) {
    window?.makeFirstResponder(textView)
    if atEnd { textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0)) }
  }

  // MARK: Styling

  /// Restyles everything, or only the lines around `limit`.
  func restyle(limit: NSRange? = nil) {
    guard !textView.hasMarkedText() else { return }
    let focused = window?.firstResponder === textView
    let selection = focused ? textView.selectedRange() : nil
    styledSelection = selection
    styledWidth = bounds.width
    let length = storage.length
    var clampedLimit = limit.map { NSRange(location: min($0.location, length), length: min($0.length, length - min($0.location, length))) }
    // Layout can't restart inside a collapsed section (its line breaks
    // don't break): restyle whole when the lines start or end in one.
    let collapsed = folded
    if let limit = clampedLimit, !collapsed.isEmpty {
      let lines = (storage.string as NSString).paragraphRange(for: limit)
      if MarkdownStyler.headingSections(in: storage.string as NSString).contains(where: {
        let body = NSRange(location: $0.body.location, length: $0.body.length + 1)
        return collapsed.contains($0.key) && NSIntersectionRange(body, lines).length > 0
          && !(lines.location <= $0.heading.location && NSMaxRange(lines) >= NSMaxRange(body))
      }) {
        clampedLimit = nil
      }
    }
    var styler = MarkdownStyler(
      baseDirectory: NoteStore.shared.fileURL(for: ref).deletingLastPathComponent(),
      width: max(100, bounds.width),
      selection: selection)
    styler.mediaHeight = { [weak self] key in self?.mediaViews[key]?.blockHeight }
    styler.folded = folded
    styler.tableAsMarkdown = tableAsMarkdown
    styler.editingCell = cellEditing
    layoutManager.hiddenCell = cellEditing
    styler.apply(to: storage, limit: clampedLimit)
    textView.typingAttributes = MarkdownStyler.baseAttributes
    updateHeight()
    if layoutMediaViews() {
      // New blocks: reserve their real height.
      styler.apply(to: storage, limit: clampedLimit)
      updateHeight()
      _ = layoutMediaViews()
    }
    layoutFoldGutter()
    textView.needsDisplay = true
    layoutTableEditing()
    placedFrame = mediaHost.map { convert(bounds, to: $0) }
    updateMediaSelection()
  }

  /// Media blocks whose line is in the selection show selected.
  private func updateMediaSelection() {
    let selection = textView.selectedRange()
    let emphasized = window?.isKeyWindow == true && window?.firstResponder === textView
    for (key, view) in mediaViews {
      view.setSelected(selection.length > 0 && mediaLines[key].map { NSIntersectionRange(selection, $0).length > 0 } == true,
                       emphasized: emphasized)
    }
  }

  @objc private func windowKeyChanged() { updateMediaSelection() }

  // MARK: Folding

  func toggleFold(_ key: String) {
    let collapsing = !folded.contains(key)
    let section = MarkdownStyler.headingSections(in: storage.string as NSString).first(where: { $0.key == key })
    gutter.turnChevron(key, open: !collapsing)
    guard !Motion.reduceMotion, window != nil, let host = mediaHost, let section, section.body.length > 0,
          let before = lineTopAfter(section, in: screenLayout) else {
      if collapsing { folded.insert(key) } else { folded.remove(key) }
      restyle()
      return
    }
    // Closing: what the section shows stays as a snapshot over the page,
    // fading, its blocks where they are, until what follows slides over it.
    var overlays: [NSView] = []
    var cut: [MediaBlockView] = []
    if collapsing, let open = bodyRect(section, in: screenLayout) {
      let rect = textView.convert(open, to: host)
      overlays.append(pageSnapshot(of: NSRect(x: gutter.frame.minX, y: rect.minY, width: gutter.frame.width, height: rect.height),
                                   in: host, opaque: false))
      for (key, view) in mediaViews where view.alphaValue > 0 {
        guard let line = mediaLines[key], NSLocationInRange(line.location, section.body) else { continue }
        closingMedia[key] = view.frame
        cut.append(view)
      }
    }
    if collapsing { folded.insert(key) } else { folded.remove(key) }
    // Just the section: the rest of the page doesn't change.
    restyle(limit: NSRange(location: section.heading.location,
                           length: min(storage.length, NSMaxRange(section.body) + 1) - section.heading.location))
    host.layoutSubtreeIfNeeded()
    guard let after = lineTopAfter(section, in: screenLayout) else {
      closingMedia = [:]
      layoutMediaViews()
      return
    }
    // Opening: the section shows where it goes, under a veil that fades, its
    // blocks revealed as what follows slides down past them.
    if !collapsing, let open = bodyRect(section, in: screenLayout) {
      let rect = textView.convert(open, to: host)
      let veil = SlideOverlayView(frame: NSRect(x: gutter.frame.minX, y: rect.minY, width: gutter.frame.width, height: rect.height))
      veil.wantsLayer = true
      veil.layer?.backgroundColor = resolvedCGColor(Theme.background)
      overlays.append(veil)
      for (key, view) in mediaViews {
        guard let line = mediaLines[key], NSLocationInRange(line.location, section.body) else { continue }
        cut.append(view)
      }
    }
    for overlay in overlays {
      overlay.wantsLayer = true
      overlay.alphaValue = 0
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.toValue = 0
      fade.duration = Motion.foldDuration
      fade.timingFunction = CubicBezier.fold.timingFunction
      overlay.layer?.add(fade, forKey: "glea.fold.fade")
    }
    slidePage(below: after, from: before - after, duration: Motion.foldDuration, curve: .fold,
              overlays: overlays, cut: cut, fadingIn: !collapsing) { [weak self] in
      guard let self, !self.closingMedia.isEmpty else { return }
      self.closingMedia = [:]
      self.layoutMediaViews()
    }
  }

  /// The page's text as laid out: on screen, or a copy off screen.
  private struct TextLayout {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let textView: NSTextView
    /// Keeps the copy's layout delegate alive.
    var delegate: FoldingLayoutDelegate?
  }

  private var screenLayout: TextLayout {
    TextLayout(storage: storage, layoutManager: layoutManager, textView: textView)
  }

  /// The section's content, laid out open, in text view coordinates: from
  /// below its heading down to the top of the next line (or the end).
  private func bodyRect(_ section: HeadingSection, in layout: TextLayout) -> NSRect? {
    let layoutManager = layout.layoutManager, textView = layout.textView
    guard let container = textView.textContainer, let bottom = lineTopAfter(section, in: layout) else { return nil }
    let heading = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: section.heading.location), effectiveRange: nil)
    let origin = textView.textContainerOrigin
    guard bottom > origin.y + heading.maxY else { return nil }
    return NSRect(x: origin.x, y: origin.y + heading.maxY, width: container.size.width, height: bottom - origin.y - heading.maxY)
  }

  /// The top of what follows a section (the next line, or the end of the
  /// text), in text view coordinates.
  private func lineTopAfter(_ section: HeadingSection, in layout: TextLayout) -> CGFloat? {
    let layoutManager = layout.layoutManager, storage = layout.storage, textView = layout.textView
    guard let container = textView.textContainer, storage.length > 0 else { return nil }
    layoutManager.ensureLayout(for: container)
    let next = NSMaxRange(section.body) + 1
    let top: CGFloat
    if next < storage.length {
      top = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: next), effectiveRange: nil).minY
    } else if !layoutManager.extraLineFragmentRect.isEmpty {
      top = layoutManager.extraLineFragmentRect.minY
    } else {
      top = layoutManager.usedRect(for: container).maxY
    }
    return textView.textContainerOrigin.y + top
  }


  /// Expands the collapsed sections containing the character at `index`.
  func reveal(_ index: Int) {
    unfold(around: NSRange(location: index, length: 0))
  }

  /// Expands the collapsed sections containing `range` (the cursor went in,
  /// or the page jumps to a heading inside).
  private func unfold(around range: NSRange) {
    let current = folded
    guard !current.isEmpty else { return }
    let opened = MarkdownStyler.headingSections(in: storage.string as NSString).filter {
      current.contains($0.key) && $0.body.length > 0
        && range.location >= $0.body.location && NSMaxRange(range) <= NSMaxRange($0.body)
    }
    guard !opened.isEmpty else { return }
    folded.subtract(opened.map(\.key))
    restyle()
  }

  private func layoutFoldGutter() {
    guard let host = mediaHost, let container = textView.textContainer else {
      gutter.removeFromSuperview()
      return
    }
    if gutter.superview !== host {
      // Over the page's column, under the blocks (and what slides, see
      // `slidePage`).
      var column: NSView = self
      while let superview = column.superview, superview !== host { column = superview }
      host.addSubview(gutter, positioned: .above, relativeTo: column.superview === host ? column : nil)
    }
    let rect = convert(bounds, to: host)
    gutter.frame = NSRect(x: rect.minX - NoteGutterView.width, y: rect.minY,
                              width: rect.width + NoteGutterView.width, height: rect.height)
    layoutManager.ensureLayout(for: container)
    gutter.items = gutterItems()
    layoutBlockHandles()
  }

  // MARK: Dragging blocks

  private var blocks: [MarkdownBlock] = []
  /// Each line's range, by index.
  private var lineRanges: [NSRange] = []
  private var blockDrag: BlockDrag?

  /// A place to drop a block: before a line, shown at `y`.
  private struct DropPlace {
    let line: Int
    let y: CGFloat
  }

  /// The top of a line's text, in this view's coordinates.
  private func lineTop(_ line: Int) -> CGFloat? {
    let range = lineRanges[line]
    if range.location >= storage.length {
      // The empty line after a final line break.
      let extra = layoutManager.extraLineFragmentRect
      return extra.isEmpty ? nil : textView.textContainerOrigin.y + extra.minY
    }
    let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
    return textView.textContainerOrigin.y + layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).minY
  }

  /// The bottom of the last visible text.
  private func lastLineBottom() -> CGFloat? {
    guard let container = textView.textContainer, storage.length > 0 else { return nil }
    return textView.textContainerOrigin.y + layoutManager.usedRect(for: container).maxY
  }

  private final class BlockDrag {
    let block: MarkdownBlock
    let preview: NSView
    /// Covers its place in the text.
    let blank: NSView
    /// From the pointer to the top of the block.
    let grab: CGFloat
    /// Where it can go, and where it would.
    let targets: [DropPlace]
    var target: DropPlace?
    /// Its media blocks, by key, and where each sits from the copy's origin:
    /// their views can't be snapshotted, so they travel with it.
    var media: [String: NSPoint] = [:]
    /// How each grows with the copy. AppKit resets a view's layer transform
    /// when it moves the view, so it's set again after each move.
    var mediaTransforms: [String: CATransform3D] = [:]

    init(block: MarkdownBlock, preview: NSView, blank: NSView, grab: CGFloat, targets: [DropPlace]) {
      self.block = block
      self.preview = preview
      self.blank = blank
      self.grab = grab
      self.targets = targets
    }
  }

  private func computeLineRanges() -> [NSRange] {
    var ranges: [NSRange] = []
    var location = 0
    for line in storage.string.components(separatedBy: "\n") {
      let length = (line as NSString).length
      ranges.append(NSRange(location: location, length: length))
      location += length + 1
    }
    return ranges
  }

  private func isHidden(line: Int) -> Bool {
    let range = lineRanges[line]
    return range.location < storage.length && storage.attribute(.gleaFolded, at: range.location, effectiveRange: nil) != nil
  }

  /// The visible lines of a block, in this view's coordinates (the text
  /// view's).
  private func blockRect(_ block: MarkdownBlock) -> NSRect? {
    let first = lineRanges[block.lines.lowerBound], last = lineRanges[block.lines.upperBound - 1]
    let chars = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    guard storage.length > 0 else { return nil }
    let glyphs = layoutManager.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
    var rect = NSRect.null
    layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, _, _ in
      if used.height > 0 { rect = rect.union(NSRect(x: 0, y: used.minY, width: fragment.width, height: used.height)) }
    }
    // Media blocks hang over (or below) their line.
    storage.enumerateAttribute(.gleaMedia, in: chars) { value, _, _ in
      guard let media = value as? MediaDescriptor, let view = mediaViews[media.key], view.alphaValue > 0 else { return }
      rect = rect.union(textView.convert(view.frame, from: view.superview).offsetBy(dx: 0, dy: -textView.textContainerOrigin.y))
    }
    guard !rect.isNull else { return nil }
    return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
  }

  private func layoutBlockHandles() {
    guard blockDrag == nil else { return }
    lineRanges = computeLineRanges()
    blocks = MarkdownStyler.blocks(in: storage.string)
    guard storage.length > 0 else {
      gutter.handles = []
      return
    }
    gutter.handles = blocks.indices.compactMap { index in
      let block = blocks[index]
      guard !isHidden(line: block.lines.lowerBound), let rect = blockRect(block) else { return nil }
      let line = lineRanges[block.lines.lowerBound]
      let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
      let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y
      let font = storage.attribute(.font, at: max(line.location, NSMaxRange(line) - 1), effectiveRange: nil) as? NSFont ?? Theme.bodyFont
      let center = textView.textContainerOrigin.y + baseline - font.capHeight / 2
      return NoteGutterView.Handle(block: index, band: rect.minY...rect.maxY, centerY: center)
    }
  }

  private func beginBlockDrag(_ index: Int, at y: CGFloat) -> Bool {
    guard blocks.indices.contains(index), let host = mediaHost, let textRect = blockRect(blocks[index]) else { return false }
    let block = blocks[index]
    // Where it can go: before any visible line that starts a block or is
    // blank (not inside a code block, table, quote or list item), or at the
    // end.
    let text = storage.string as NSString
    let starts = Set(blocks.map(\.lines.lowerBound))
    var inside = Set<Int>()
    for other in blocks where !(MarkdownStyler.isHeading(text.substring(with: lineRanges[other.lines.lowerBound]))) {
      inside.formUnion(other.lines.dropFirst())
    }
    var targets: [DropPlace] = []
    for line in lineRanges.indices where !isHidden(line: line) && !inside.subtracting(starts).contains(line) {
      let isBlank = text.substring(with: lineRanges[line]).trimmingCharacters(in: .whitespaces).isEmpty
      guard starts.contains(line) || isBlank, let top = lineTop(line) else { continue }
      targets.append(DropPlace(line: line, y: top - 2))
    }
    if let bottom = lastLineBottom() { targets.append(DropPlace(line: lineRanges.count, y: bottom + 2)) }
    // Only places that would move it (not right before or after itself).
    targets.removeAll { target in
      guard let moved = MarkdownStyler.moving(block, before: target.line, in: text as String) else { return true }
      return moved.text == text as String
    }
    // The block lifts out of the text: a copy grows and fades as it starts
    // following the pointer, and its place stays blank until it is dropped.
    // With its gutter: the grip and chevron lift with it.
    let rect = withGutter(textRect)
    let lines = textView.snapshot(of: textRect)
    let snapshot = NSImage(size: rect.size, flipped: true) { [gutter] bounds in
      NSGraphicsContext.saveGraphicsState()
      let shift = NSAffineTransform()
      shift.translateX(by: 0, yBy: -textRect.minY)
      shift.concat()
      gutter.effectiveAppearance.performAsCurrentDrawingAppearance {
        gutter.drawLifted(NSRect(x: 0, y: textRect.minY, width: NoteGutterView.width, height: textRect.height))
      }
      NSGraphicsContext.restoreGraphicsState()
      lines.draw(in: NSRect(x: NoteGutterView.width, y: 0, width: textRect.width, height: bounds.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      return true
    }
    // Its media blocks stay above the blank and the copy.
    let chars = NSRange(location: lineRanges[block.lines.lowerBound].location,
                        length: NSMaxRange(lineRanges[block.lines.upperBound - 1]) - lineRanges[block.lines.lowerBound].location)
    var mediaBlocks: [String: MediaBlockView] = [:]
    storage.enumerateAttribute(.gleaMedia, in: chars) { value, _, _ in
      guard let media = value as? MediaDescriptor, let view = mediaViews[media.key], view.superview === host,
            view.alphaValue > 0 else { return }
      mediaBlocks[media.key] = view
    }
    let lowest = host.subviews.first { view in mediaBlocks.values.contains { $0 === view } }
    let blank = NSView(frame: textView.convert(rect, to: host))
    blank.wantsLayer = true
    blank.layer?.backgroundColor = resolvedCGColor(Theme.background)
    host.addSubview(blank, positioned: lowest == nil ? .above : .below, relativeTo: lowest)
    let preview = NSView(frame: textView.convert(rect, to: host))
    preview.wantsLayer = true
    let lifted = CALayer()
    // Grows from its left edge, at the pointer: the text stays in line.
    let grabbed = min(max(0, y - rect.minY), rect.height)
    lifted.anchorPoint = CGPoint(x: 0, y: 1 - grabbed / max(1, rect.height))
    lifted.frame = preview.bounds
    lifted.masksToBounds = true
    let content = CALayer()
    content.contents = snapshot
    content.contentsScale = window?.backingScaleFactor ?? 2
    content.frame = CGRect(origin: .zero, size: rect.size)
    lifted.addSublayer(content)
    preview.layer?.addSublayer(lifted)
    host.addSubview(preview, positioned: lowest == nil ? .above : .below, relativeTo: lowest)
    let scale = CATransform3DMakeScale(1.06, 1.06, 1)
    let grow = CABasicAnimation(keyPath: "transform")
    grow.fromValue = CATransform3DIdentity
    grow.toValue = scale
    let fadeOut = CABasicAnimation(keyPath: "opacity")
    fadeOut.fromValue = 1
    fadeOut.toValue = 0.5
    for animation in [grow, fadeOut] {
      animation.duration = BlockDragDebug.liftDuration
      animation.timingFunction = Motion.standard
    }
    lifted.transform = scale
    lifted.opacity = 0.5
    lifted.add(grow, forKey: "grow")
    lifted.add(fadeOut, forKey: "fade")
    liftedLayer = lifted
    let drag = BlockDrag(block: block, preview: preview, blank: blank, grab: y - rect.minY, targets: targets)
    for (key, view) in mediaBlocks {
      let offset = NSPoint(x: view.frame.minX - preview.frame.minX, y: view.frame.minY - preview.frame.minY)
      drag.media[key] = offset
      // Grows with the copy, from the same point (its layer's origin is its
      // top-left corner, so it also moves away from that point).
      let grown = CATransform3DConcat(scale, CATransform3DMakeTranslation(0.06 * offset.x, 0.06 * (offset.y - grabbed), 0))
      let animation = CABasicAnimation(keyPath: "transform")
      animation.fromValue = CATransform3DIdentity
      animation.toValue = grown
      animation.duration = BlockDragDebug.liftDuration
      animation.timingFunction = Motion.standard
      drag.mediaTransforms[key] = grown
      view.layer?.transform = grown
      view.layer?.add(animation, forKey: "grow")
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = BlockDragDebug.liftDuration
      context.timingFunction = Motion.standard
      for view in mediaBlocks.values { view.animator().alphaValue = 0.5 }
    }
    blockDrag = drag
    gutter.liftedBand = textRect.minY...textRect.maxY
    moveBlockDrag(to: y)
    return true
  }

  private func moveBlockDrag(to y: CGFloat) {
    guard let drag = blockDrag, let host = mediaHost else { return }
    var frame = drag.preview.frame
    frame.origin.y = convert(NSPoint(x: 0, y: y - drag.grab), to: host).y
    drag.preview.frame = frame
    for (key, offset) in drag.media {
      guard let view = mediaViews[key] else { continue }
      view.setFrameOrigin(NSPoint(x: frame.minX + offset.x, y: frame.minY + offset.y))
      if let grown = drag.mediaTransforms[key] {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.transform = grown
        CATransaction.commit()
      }
    }
    // The nearest place to the dragged block's top; none while that is
    // where it already is.
    let top = y - drag.grab
    let here = drag.blank.frame.minY
    let nearest = drag.targets.min { abs($0.y - top) < abs($1.y - top) }
    let stay = nearest.map { abs(convert(NSPoint(x: 0, y: top), to: mediaHost).y - here) < abs($0.y - top) } ?? true
    drag.target = stay ? nil : nearest
    gutter.dropY = stay ? nil : nearest?.y
  }

  private var liftedLayer: CALayer?

  /// A rect of the text widened to include the gutter on its left.
  private func withGutter(_ rect: NSRect) -> NSRect {
    NSRect(x: rect.minX - NoteGutterView.width, y: rect.minY, width: rect.width + NoteGutterView.width, height: rect.height)
  }

  /// Drops the block: the text changes, and the copy glides into the block's
  /// new place (or back to its old one), turning back into it.
  private func endBlockDrag(drop: Bool) {
    guard let drag = blockDrag, let host = mediaHost else { return }
    blockDrag = nil
    gutter.dropY = nil
    let lifted = liftedLayer
    liftedLayer = nil
    var destination = drag.blank.frame
    let draggedMedia = drag.media.keys.compactMap { key in mediaViews[key].map { (view: $0, from: $0.frame) } }
    // The note takes focus, so ⌘Z goes to it (not to whatever had focus).
    if drop, drag.target != nil { window?.makeFirstResponder(textView) }
    if drop, let target = drag.target, let line = moveBlock(drag.block, before: target.line) {
      layoutBlockHandles()
      // The block's new place stays blank until the copy gets there.
      if let moved = blocks.first(where: { $0.lines.lowerBound == line }), let rect = blockRect(moved) {
        destination = textView.convert(withGutter(rect), to: host)
        drag.blank.frame = destination
        gutter.liftedBand = rect.minY...rect.maxY
      }
    } else {
      layoutBlockHandles()
    }
    // Media blocks glide from where they were dragged to their place.
    _ = layoutMediaViews()
    let landing = draggedMedia.map { ($0.view, $0.view.frame) }
    for (view, from) in draggedMedia { view.frame = from }
    let duration = BlockDragDebug.liftDuration * 1.25
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = duration
      context.timingFunction = Motion.standard
      drag.preview.animator().setFrameOrigin(destination.origin)
      for (view, to) in landing {
        view.animator().frame = to
        view.animator().alphaValue = 1
      }
      for (view, _) in landing {
        guard let layer = view.layer else { continue }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = layer.presentation()?.transform ?? layer.transform
        shrink.toValue = CATransform3DIdentity
        shrink.duration = duration
        shrink.timingFunction = Motion.standard
        layer.transform = CATransform3DIdentity
        layer.add(shrink, forKey: "grow")
      }
    }, completionHandler: { [weak self] in
      // Unless another drag has started since.
      if self?.blockDrag == nil { self?.gutter.liftedBand = nil }
      drag.preview.removeFromSuperview()
      drag.blank.removeFromSuperview()
    })
    if let lifted {
      let shrink = CABasicAnimation(keyPath: "transform")
      shrink.fromValue = lifted.presentation()?.transform ?? lifted.transform
      shrink.toValue = CATransform3DIdentity
      let fadeIn = CABasicAnimation(keyPath: "opacity")
      fadeIn.fromValue = lifted.presentation()?.opacity ?? lifted.opacity
      fadeIn.toValue = 1
      for animation in [shrink, fadeIn] {
        animation.duration = duration
        animation.timingFunction = Motion.standard
      }
      lifted.transform = CATransform3DIdentity
      lifted.opacity = 1
      lifted.add(shrink, forKey: "grow")
      lifted.add(fadeIn, forKey: "fade")
    }
  }

  /// Moves a block as one edit (undoable), replacing only what changed.
  /// Returns the line it starts on in its new place.
  @discardableResult
  func moveBlock(_ block: MarkdownBlock, before target: Int) -> Int? {
    guard let (text, line) = MarkdownStyler.moving(block, before: target, in: storage.string),
          text != storage.string else { return nil }
    replaceText(with: text, actionName: "Move")
    // The cursor goes to the moved block, if the note has focus.
    if window?.firstResponder === textView {
      let lines = computeLineRanges()
      if lines.indices.contains(line) { textView.setSelectedRange(NSRange(location: lines[line].location, length: 0)) }
    }
    return line
  }

  /// Replaces the text as one undoable edit, changing only what differs.
  /// The text view records it like typing (by range, so undo and redo stay
  /// right whatever else is on the stack), between two markers that keep
  /// undo and redo from selecting the text they bring back.
  private func replaceText(with text: String, actionName: String) {
    let old = storage.string as NSString, new = text as NSString
    var prefix = 0
    while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
    var suffix = 0
    while suffix < min(old.length, new.length) - prefix,
          old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
    let range = NSRange(location: prefix, length: old.length - prefix - suffix)
    let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
    let selection = textView.selectedRange()
    let undoManager = textView.undoManager
    textView.breakUndoCoalescing()
    undoManager?.beginUndoGrouping()
    // Undo runs a group's actions last-registered first: this marker runs
    // after the text comes back, the one below before.
    registerSelectionMarker(keepsSelection: false)
    if textView.shouldChangeText(in: range, replacementString: replacement) {
      storage.replaceCharacters(in: range, with: replacement)
      textView.didChangeText()
    }
    registerSelectionMarker(keepsSelection: true)
    undoManager?.setActionName(actionName)
    undoManager?.endUndoGrouping()
    textView.breakUndoCoalescing()
    textView.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
  }

  /// An undo action that turns on (or off) the text view's keeping of its
  /// selection, and registers the opposite for redo.
  private func registerSelectionMarker(keepsSelection: Bool) {
    textView.undoManager?.registerUndo(withTarget: textView) { [weak self] textView in
      MainActor.assumeIsolated {
        textView.keepsSelectionThroughUndo = keepsSelection
        self?.registerSelectionMarker(keepsSelection: !keepsSelection)
      }
    }
  }

  /// For automated checks: drags the nth block (begin, move by dy, end).
  func debugBeginDrag(_ index: Int) {
    layoutBlockHandles()
    guard let handle = gutter.handles.first(where: { $0.block == index }) else { return }
    debugDragY = handle.centerY
    _ = beginBlockDrag(index, at: handle.centerY)
  }

  func debugMoveDrag(by dy: CGFloat) {
    debugDragY += dy
    moveBlockDrag(to: debugDragY)
  }

  func debugEndDrag() { endBlockDrag(drop: true) }
  private var debugDragY: CGFloat = 0

  /// For automated checks: moves the nth block before line `target`.
  func debugMoveBlock(_ index: Int, before target: Int) {
    let blocks = MarkdownStyler.blocks(in: storage.string)
    if blocks.indices.contains(index) { moveBlock(blocks[index], before: target) }
  }

  /// Chevrons for the visible headings with something to collapse, in this
  /// view's coordinates. `within` limits them to headings inside a range.
  private func gutterItems(within range: NSRange? = nil, in layout: TextLayout? = nil) -> [NoteGutterView.Item] {
    let layout = layout ?? screenLayout
    let layoutManager = layout.layoutManager, storage = layout.storage, textView = layout.textView
    let origin = textView.textContainerOrigin
    let current = folded
    return MarkdownStyler.headingSections(in: storage.string as NSString).compactMap { section in
      guard section.body.length > 0, storage.attribute(.gleaFolded, at: section.heading.location, effectiveRange: nil) == nil,
            range.map({ NSLocationInRange(section.heading.location, $0) }) ?? true
      else { return nil }
      let glyph = layoutManager.glyphIndexForCharacter(at: section.heading.location)
      let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let baseline = line.minY + layoutManager.location(forGlyphAt: glyph).y
      let font = storage.attribute(.font, at: NSMaxRange(section.heading) - 1, effectiveRange: nil) as? NSFont ?? Theme.bodyFont
      let y = origin.y + textView.frame.minY
      let indent = (storage.attribute(.gleaSectionIndent, at: section.heading.location, effectiveRange: nil) as? NSNumber)
        .map { CGFloat($0.doubleValue) } ?? 0
      return NoteGutterView.Item(
        key: section.key,
        line: NSRect(x: 0, y: y + line.minY, width: gutter.frame.width, height: line.height),
        centerY: y + baseline - font.capHeight / 2,
        collapsed: current.contains(section.key),
        indent: indent,
        openness: current.contains(section.key) ? 0 : 1)
    }
  }

  /// Creates, positions and removes media block views. Returns whether new
  /// views were created (their height isn't reserved yet).
  @discardableResult
  private func layoutMediaViews() -> Bool {
    guard let container = textView.textContainer else { return false }
    layoutManager.ensureLayout(for: container)
    var seen = Set<String>()
    var created = false
    var lines: [String: NSRange] = [:]
    var bottom: CGFloat = 0
    storage.enumerateAttribute(.gleaMedia, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      guard let media = value as? MediaDescriptor, !seen.contains(media.key) else { return }
      seen.insert(media.key)
      lines[media.key] = range
      let view: MediaBlockView
      if let existing = mediaViews[media.key] {
        view = existing
      } else {
        view = MediaBlockView(descriptor: media, noteID: ref.id)
        let key = media.key
        view.onHeightChange = { [weak self] old in self?.mediaHeightChanged(key, from: old) }
        view.onOpenURL = { [weak self] url in
          // (After the event: opening a note may free this editor and its embeds.)
          guard let open = self?.onOpenLink else { return }
          DispatchQueue.main.async { open(url) }
        }
        mediaViews[media.key] = view
        (mediaHost ?? textView).addSubview(view)
        created = true
      }
      // In a collapsed section the block stays loaded, transparent and out of
      // the way (not hidden: a hidden embed stops drawing, and would take a
      // moment to show again). While the section closes, it stays where it
      // was, fading and cut off with the text (see `toggleFold`).
      let isFolded = storage.attribute(.gleaFolded, at: range.location, effectiveRange: nil) != nil
      if isFolded, let open = closingMedia[media.key] {
        view.alphaValue = 0
        view.frame = open
        return
      }
      // Being dragged: it follows the pointer.
      if blockDrag?.media[media.key] != nil { return }
      view.alphaValue = isFolded ? 0 : 1
      let rect = mediaFrame(media, line: range, in: screenLayout)
      let top = rect.minY - textView.textContainerOrigin.y
      view.availableWidth = rect.width - MediaBlockView.gutterWidth
      if let host = mediaHost, view.superview !== host { host.addSubview(view) }
      view.frame = mediaHost.map { textView.convert(rect, to: $0) } ?? rect
      if isFolded { view.frame.origin.x = -100_000 }
      if !isFolded { bottom = max(bottom, top + max(view.blockHeight, MediaBlockView.rowHeight)) }
    }
    for (key, view) in mediaViews where !seen.contains(key) {
      view.removeFromSuperview()
      mediaViews[key] = nil
    }
    mediaLines = lines
    if abs(bottom - mediaBottom) > 0.5 {
      mediaBottom = bottom
      updateHeight()
    }
    return created
  }

  /// Where a media block goes, in text view coordinates: over its line, or
  /// below it while its source is edited.
  private func mediaFrame(_ media: MediaDescriptor, line range: NSRange, in layout: TextLayout) -> NSRect {
    let layoutManager = layout.layoutManager, storage = layout.storage, textView = layout.textView
    let width = max(80, (textView.textContainer?.size.width ?? 0) - media.indent)
    // A long source line wraps: the block hangs below its last fragment.
    let glyph = layoutManager.glyphIndexForCharacter(at: max(range.location, NSMaxRange(range) - 1))
    let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
    let below = storage.attribute(.gleaMediaBelow, at: range.location, effectiveRange: nil) != nil
    let origin = textView.textContainerOrigin
    let top = below ? used.maxY + 8 : used.minY
    // The block also covers the right gutter, where its toggle lives.
    return NSRect(x: origin.x + media.indent, y: origin.y + top, width: width + MediaBlockView.gutterWidth,
                  height: max(mediaViews[media.key]?.blockHeight ?? 0, MediaBlockView.rowHeight))
  }

  /// Blocks live in the page (not the text view) so their gutter toggle isn't
  /// clipped; they follow the editor as it moves.
  private var mediaHost: NSView? { enclosingScrollView?.documentView }

  /// Where this editor was in the page when its blocks, gutter and table
  /// toggle were last placed.
  private var placedFrame: NSRect?

  @objc private func editorMoved() {
    guard let host = mediaHost else { return }
    let frame = convert(bounds, to: host)
    // Only moved (something above it changed height): its views move along,
    // nothing is laid out again.
    if let placed = placedFrame, placed.size == frame.size, slide == nil {
      let dx = frame.minX - placed.minX, dy = frame.minY - placed.minY
      guard dx != 0 || dy != 0 else { return }
      for view in mediaViews.values where view.frame.minX > -50_000 {
        view.frame = view.frame.offsetBy(dx: dx, dy: dy)
      }
      gutter.frame = gutter.frame.offsetBy(dx: dx, dy: dy)
      tableToggle.frame = tableToggle.frame.offsetBy(dx: dx, dy: dy)
      placedFrame = frame
      return
    }
    _ = layoutMediaViews()
    layoutFoldGutter()
    layoutTableEditing()
    placedFrame = frame
  }

  /// A block resized. Animating: the page is laid out at its new height at
  /// once, and what follows slides there (see `slidePage`). Otherwise
  /// (loaded, measured): its line reflows, once per run loop turn.
  private func mediaHeightChanged(_ key: String, from old: CGFloat?) {
    if old != nil, let host = mediaHost, let view = mediaViews[key], view.superview === host,
       let range = mediaLines[key], range.location < storage.length,
       storage.attribute(.gleaFolded, at: range.location, effectiveRange: nil) == nil {
      pendingMediaRestyle.remove(key)
      let before = view.frame
      restyle(limit: range)
      host.layoutSubtreeIfNeeded()
      let after = view.frame
      slidePage(below: textView.convert(after, from: host).maxY, from: before.maxY - after.maxY,
                duration: MediaBlockView.resizeDuration, curve: .media)
      return
    }
    let first = pendingMediaRestyle.isEmpty
    pendingMediaRestyle.insert(key)
    guard first else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let keys = self.pendingMediaRestyle
      self.pendingMediaRestyle = []
      for key in keys {
        guard let range = self.mediaLines[key], range.location < self.storage.length,
              self.storage.attribute(.gleaFolded, at: range.location, effectiveRange: nil) == nil else { continue }
        self.restyle(limit: range)
      }
    }
  }

  // MARK: Sliding

  /// Where what follows a change of height starts (text view coordinates,
  /// in the final layout), and how much lower it was (negative: higher).
  private struct SlideBreak {
    var top: CGFloat
    var offset: CGFloat
  }

  /// A change of height animating. The page is laid out in its final state
  /// at once, and what follows each change slides there from where it was,
  /// run by the render server, so it stays smooth however long the note:
  /// the text and gutter as snapshots, the blocks and what's below the
  /// editor as themselves.
  private final class Slide {
    let breaks: [SlideBreak]
    let duration: CFTimeInterval
    let curve: CubicBezier
    let start = CACurrentMediaTime()
    /// Snapshots and covers over the page, removed at the end.
    var overlays: [NSView] = []
    /// Views sliding, and blocks cut off where what slides begins.
    var moved: [NSView] = []
    var cut: [NSView] = []
    var completion: (() -> Void)?

    init(breaks: [SlideBreak], duration: CFTimeInterval, curve: CubicBezier) {
      self.breaks = breaks
      self.duration = duration
      self.curve = curve
    }

    /// How much of the way is left, from 1 to 0.
    var remaining: CGFloat {
      CGFloat(1 - curve(min(1, (CACurrentMediaTime() - start) / duration)))
    }
  }

  /// Slides what follows `top` (text view coordinates, in the final layout)
  /// from `offset` points lower (negative: higher) into place. `overlays`
  /// (in the page) go between the text and what slides; the `cut` blocks
  /// show only above what slides, fading in or out.
  private func slidePage(below top: CGFloat, from offset: CGFloat, duration: CFTimeInterval, curve: CubicBezier,
                         overlays: [NSView] = [], cut: [MediaBlockView] = [], fadingIn: Bool = false,
                         completion: (() -> Void)? = nil) {
    var breaks = [SlideBreak(top: top, offset: offset)]
    // A slide under way goes on from where things are on screen.
    if let running = slide {
      let left = running.remaining
      for old in running.breaks where abs(old.offset * left) > 0.5 {
        // Where it is now: past the change it moved with what follows, in
        // a part that went away it's where that part was.
        let moved = old.top >= top + offset - 0.5 ? old.top - offset : old.top > top ? top : old.top
        breaks.append(SlideBreak(top: moved, offset: old.offset * left))
      }
      endSlide(running)
    }
    guard let host = mediaHost, window != nil, !Motion.reduceMotion, breaks.contains(where: { abs($0.offset) > 0.5 }) else {
      overlays.forEach { $0.removeFromSuperview() }
      completion?()
      return
    }
    // (One break per place: what follows it moves by their sum.)
    breaks.sort { $0.top < $1.top }
    breaks = breaks.reduce(into: []) { merged, next in
      if let last = merged.last, abs(last.top - next.top) < 0.5 {
        merged[merged.count - 1].offset += next.offset
      } else {
        merged.append(next)
      }
    }
    let slide = Slide(breaks: breaks, duration: duration, curve: curve)
    slide.completion = completion
    self.slide = slide

    let editor = convert(bounds, to: host)
    let left = gutter.superview === host ? min(gutter.frame.minX, editor.minX) : editor.minX
    let width = editor.maxX - left
    // Each break in the page, and how far what follows it is from its place.
    var tops: [CGFloat] = [], offsets: [CGFloat] = []
    for b in breaks {
      tops.append(textView.convert(NSPoint(x: 0, y: b.top), to: host).y)
      offsets.append((offsets.last ?? 0) + b.offset)
    }
    func shift(at y: CGFloat) -> CGFloat {
      Array(zip(tops, offsets)).last(where: { y >= $0.0 - 0.5 })?.1 ?? 0
    }
    // What can show while it slides: what's on screen, and what slides
    // into it (from above when it moves down, from below when it moves up).
    let screen = host.visibleRect
    let above = max(0, offsets.max() ?? 0), below = max(0, -(offsets.min() ?? 0))
    let visible = NSRect(x: screen.minX, y: screen.minY - above - 40, width: screen.width, height: screen.height + above + below + 80)

    func move(_ view: NSView, by dy: CGFloat) {
      guard let layer = view.layer, let superview = view.superview else { return }
      let shift = superview.convert(NSPoint(x: 0, y: dy), from: host).y - superview.convert(NSPoint.zero, from: host).y
      let animation = CABasicAnimation(keyPath: "position")
      animation.isAdditive = true
      animation.fromValue = NSValue(point: NSPoint(x: 0, y: shift))
      animation.toValue = NSValue(point: .zero)
      animation.duration = duration
      animation.timingFunction = curve.timingFunction
      layer.add(animation, forKey: "glea.slide")
      slide.moved.append(view)
    }
    // Over the gutter (over the text), under the blocks: covers first, then
    // the overlays, then what slides, top to bottom.
    var anchor: NSView = gutter
    func place(_ view: NSView) {
      host.addSubview(view, positioned: .above, relativeTo: anchor)
      anchor = view
      slide.overlays.append(view)
    }
    // Where what follows moves up, the final layout stays covered until it
    // gets there.
    var previous: CGFloat = 0
    for (index, (top, offset)) in zip(tops, offsets).enumerated() {
      defer { previous = offset }
      guard offset > previous else { continue }
      // Up to where the content before starts (above it, the page is as is).
      let minY = max(top + min(previous, 0), index > 0 ? tops[index - 1] : top)
      let gap = NSRect(x: left, y: minY, width: width, height: min(top + max(offset, 0), editor.maxY) - minY).intersection(visible)
      guard !gap.isEmpty else { continue }
      let cover = SlideOverlayView(frame: gap)
      cover.wantsLayer = true
      cover.layer?.backgroundColor = resolvedCGColor(Theme.background)
      place(cover)
    }
    overlays.forEach(place)
    // The text and gutter after each break, as laid out now.
    for (index, (top, offset)) in zip(tops, offsets).enumerated() where abs(offset) > 0.5 {
      let bottom = index + 1 < tops.count ? tops[index + 1] : editor.maxY
      let band = NSRect(x: left, y: top, width: width, height: bottom - top).intersection(visible)
      guard !band.isEmpty else { continue }
      let snapshot = pageSnapshot(of: band, in: host, opaque: true)
      place(snapshot)
      move(snapshot, by: offset)
    }
    // Blocks and what's below the editor, as themselves.
    var column: NSView = self
    while let superview = column.superview, superview !== host { column = superview }
    let skipped = Set((slide.overlays + cut + [column, gutter]).map(ObjectIdentifier.init))
    for view in host.subviews where !skipped.contains(ObjectIdentifier(view)) && view.frame.minX > -50_000 {
      let offset = shift(at: view.frame.minY)
      if abs(offset) > 0.5, view.frame.intersects(visible) { move(view, by: offset) }
    }
    var child: NSView = self
    while let parent = child.superview, parent !== host {
      for sibling in parent.subviews where sibling !== child {
        let frame = sibling.convert(sibling.bounds, to: host)
        let offset = shift(at: frame.minY)
        if frame.minY >= editor.maxY - 0.5, abs(offset) > 0.5, frame.intersects(visible) { move(sibling, by: offset) }
      }
      child = parent
    }
    // Blocks of a section opening or closing: cut off where what follows it
    // is, fading.
    let edge = textView.convert(NSPoint(x: 0, y: top), to: host).y
    let edgeOffset = shift(at: edge)
    for view in cut {
      guard let layer = view.layer else { continue }
      let frame = view.frame
      let flipped = layer.contentsAreFlipped()
      var bounds: [NSValue] = [], positions: [NSValue] = []
      let steps = 30
      for step in 0...steps {
        let left = CGFloat(1 - curve(Double(step) / Double(steps)))
        let shown = min(frame.height, max(0, edge + edgeOffset * left - frame.minY))
        let rect = CGRect(x: 0, y: flipped ? 0 : frame.height - shown, width: frame.width, height: shown)
        bounds.append(NSValue(rect: CGRect(origin: .zero, size: rect.size)))
        positions.append(NSValue(point: CGPoint(x: rect.midX, y: rect.midY)))
      }
      let mask = CALayer()
      mask.backgroundColor = NSColor.black.cgColor
      Motion.withoutAnimation {
        mask.bounds = bounds.last!.rectValue
        mask.position = positions.last!.pointValue
      }
      for (key, values) in [("bounds", bounds), ("position", positions)] {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.duration = duration
        mask.add(animation, forKey: key)
      }
      layer.mask = mask
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = fadingIn ? 0 : 1
      fade.toValue = fadingIn ? 1 : 0
      fade.duration = duration
      fade.timingFunction = curve.timingFunction
      layer.add(fade, forKey: "glea.slide.fade")
      slide.cut.append(view)
    }
    // (A little after: the render server starts a moment after this.)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self, weak slide] in
      guard let self, let slide, self.slide === slide else { return }
      self.endSlide(slide)
    }
  }

  private func endSlide(_ slide: Slide) {
    if self.slide === slide { self.slide = nil }
    for view in slide.moved { view.layer?.removeAnimation(forKey: "glea.slide") }
    for view in slide.cut {
      view.layer?.mask = nil
      view.layer?.removeAnimation(forKey: "glea.slide.fade")
    }
    slide.overlays.forEach { $0.removeFromSuperview() }
    let completion = slide.completion
    slide.completion = nil
    completion?()
  }

  /// What the text and gutter show in `rect` (in the page), as a view to
  /// put over it.
  private func pageSnapshot(of rect: NSRect, in host: NSView, opaque: Bool) -> NSView {
    let view = SlideOverlayView(frame: rect)
    view.wantsLayer = true
    if opaque { view.layer?.backgroundColor = resolvedCGColor(Theme.background) }
    for source in [gutter, textView] as [NSView] where source.superview != nil {
      let part = source.convert(rect, from: host).intersection(source.bounds)
      guard !part.isEmpty else { continue }
      let inHost = source.convert(part, to: host)
      let image = NSImageView(frame: inHost.offsetBy(dx: -rect.minX, dy: -rect.minY))
      image.imageScaling = .scaleAxesIndependently
      image.image = source.snapshot(of: part)
      view.addSubview(image)
    }
    return view
  }

  /// The text's change under way: where its new text is, and the headings
  /// and code fences its lines had (they style what follows them).
  private var pendingEdit: (range: NSRange, structure: [String]?)?
  private static let structuralLine = try! NSRegularExpression(pattern: "^(#{1,6})(\\s|$)|^\\s*(```|~~~)")

  /// The heading levels and code fences of `text`'s lines, in order.
  private static func structure(of text: String) -> [String] {
    text.components(separatedBy: "\n").compactMap { line in
      guard let m = structuralLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
      return m.range(at: 1).location != NSNotFound ? "h\(m.range(at: 1).length)" : "fence"
    }
  }

  func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
    guard textView === self.textView else { return true }
    let s = storage.string as NSString
    let replaced = s.substring(with: s.paragraphRange(for: range))
    // (Several changes before the text says it changed: restyle it all.)
    pendingEdit = (NSRange(location: range.location, length: ((replacementString ?? "") as NSString).length),
                   pendingEdit == nil ? MarkdownEditorView.structure(of: replaced) : nil)
    return true
  }

  func textDidChange(_ notification: Notification) {
    isDirty = true
    if let slide { endSlide(slide) }
    hoveredTable = nil
    if let window { updateTableHover(window.mouseLocationOutsideOfEventStream) }
    // Typing restyles just its lines; a heading or fence coming, going or
    // changing level changes the sections or code below it: everything.
    let s = storage.string as NSString
    if let edit = pendingEdit, let before = edit.structure, NSMaxRange(edit.range) <= s.length,
       MarkdownEditorView.structure(of: s.substring(with: s.paragraphRange(for: edit.range))) == before {
      restyle(limit: edit.range)
    } else {
      restyle()
    }
    pendingEdit = nil
    onTextChange?()
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.flush() }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
  }

  // Tables: the wrapped cell being edited (by its row's location and column)
  // in its field, and the table / Markdown toggle.
  private var cellField: TableCellField?
  private var cellEditing: (row: Int, column: Int)?
  private var cellGeneration = 0
  private var tableAsMarkdown = false
  /// The table under the pointer (its first row's location): its toggle
  /// shows.
  private var hoveredTable: Int?
  /// The cell's text when its editing began (its change becomes one undo
  /// step in the note once it's left).
  private var cellOriginal: String?
  private lazy var tableToggle: MediaToggleButton = {
    let toggle = MediaToggleButton()
    toggle.looks = (collapsed: .init(symbol: "tablecells", label: "table", tooltip: "Edit as a table"),
                    expanded: .init(symbol: "chevron.left.forwardslash.chevron.right", label: "markdown", tooltip: "Edit as Markdown"))
    toggle.centersIconOnCapitals = true
    // (After the click: it changes what the page shows.)
    toggle.onClick = { [weak self] in DispatchQueue.main.async { self?.toggleTableMode() } }
    toggle.alphaValue = 0
    toggle.isHidden = true
    return toggle
  }()

  /// Its own undo history, which goes away with it. In the window's shared
  /// one, typing in a note left there after the note closed would point at
  /// a freed editor: ⌘Z then crashed.
  private let undoHistory = UndoManager()

  func undoManager(for view: NSTextView) -> UndoManager? { undoHistory }

  /// Syntax follows the cursor: restyle the lines it left and entered.
  func textViewDidChangeSelection(_ notification: Notification) {
    guard window?.firstResponder === textView, !textView.hasMarkedText() else { return }
    let selection = textView.selectedRange()
    updateMediaSelection()
    // Out of the table shown as Markdown: back to tables.
    if tableAsMarkdown, textView.tableRowAtCursor() == nil { tableAsMarkdown = false }
    defer { beginCellEditingIfNeeded() }
    // Typing: the change restyles its lines (the cursor's) right after.
    guard selection != styledSelection, pendingEdit == nil else { return }
    if selection.length == 0 { unfold(around: selection) }
    let previous = styledSelection
    restyle(limit: selection)
    if let previous { restyle(limit: previous) }
    formatBar.selectionChanged()
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
    // Once the click is over: opening another note frees this editor (and
    // the text holding the link) while AppKit is still handling it.
    if let url, let open = onOpenLink { DispatchQueue.main.async { open(url) } }
    return true
  }

  /// The line containing `index`, in this view's coordinates.
  func lineRect(forCharacterAt index: Int) -> NSRect? {
    guard let container = textView.textContainer, storage.length > 0 else { return nil }
    layoutManager.ensureLayout(for: container)
    let glyph = layoutManager.glyphIndexForCharacter(at: min(max(0, index), storage.length - 1))
    var rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
    rect.origin.x += textView.textContainerOrigin.x
    rect.origin.y += textView.textContainerOrigin.y
    return textView.convert(rect, to: self)
  }

  // MARK: Persistence

  func flush() {
    saveWork?.cancel()
    saveWork = nil
    guard isDirty else { return }
    isDirty = false
    NoteStore.shared.save(ref, content: textView.string)
    ActivityLog.shared.edited(ref)
  }

  /// Points the editor at another note (after a rename, for example).
  func rebind(to newRef: NoteRef) {
    flush()
    ref = newRef
  }

  @objc private func notesChanged(_ note: Notification) {
    guard let ids = note.userInfo?["ids"] as? Set<String>, ids.contains(ref.id), !isDirty else { return }
    let fresh = NoteStore.shared.content(of: ref)
    guard fresh != textView.string else { return }
    let selection = textView.selectedRange()
    textView.string = fresh
    let length = (fresh as NSString).length
    textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    restyle()
    onTextChange?()
  }

  @objc private func imageLoaded() {
    restyle()
  }
}

extension MarkdownStyler {
  /// One link object per address, kept for good. Clicking a link moves the
  /// cursor into it, which restyles it (its syntax shows): a fresh object
  /// there would free the one AppKit is still holding to report the click.
  @MainActor private static var links: [String: NSURL] = [:]

  @MainActor static func linkValue(_ string: String) -> NSURL? {
    if let url = links[string] { return url }
    guard let url = NSURL(string: string) else { return nil }
    links[string] = url
    return url
  }
}

// MARK: - Table editing

/// Edits one cell of a wrapped table, over the cell: its raw Markdown,
/// wrapping at the cell's width. What it holds goes straight into the note.
final class TableCellField: NSTextView {
  weak var owner: MarkdownEditorView?

  /// The typing in this cell, undone in runs like any text. Once it's left,
  /// the cell's change is one step in the note's own history; ⌘Z with
  /// nothing left here goes on there.
  let typing = UndoManager()
  override var undoManager: UndoManager? { typing }

  @objc func undo(_ sender: Any?) {
    if typing.canUndo { typing.undo() } else { owner?.cellUndo(redo: false) }
  }

  @objc func redo(_ sender: Any?) {
    if typing.canRedo { typing.redo() } else { owner?.cellUndo(redo: true) }
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(undo(_:))?: return typing.canUndo || (owner?.textView.undoManager?.canUndo ?? false)
    case #selector(redo(_:))?: return typing.canRedo || (owner?.textView.undoManager?.canRedo ?? false)
    default: return super.validateUserInterfaceItem(item)
    }
  }

  override func doCommand(by selector: Selector) {
    if owner?.cellCommand(selector) == true { return }
    super.doCommand(by: selector)
  }

  override func didChangeText() {
    super.didChangeText()
    owner?.cellTextDidChange()
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { owner?.cellFieldDidResign() }
    return result
  }
}

extension MarkdownEditorView {
  private static let tableSeparator = try! NSRegularExpression(pattern: "^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$")

  /// The line at `location` without its line break.
  private func line(at location: Int) -> NSRange {
    let s = storage.string as NSString
    let range = s.lineRange(for: NSRange(location: min(location, s.length), length: 0))
    var length = range.length
    if length > 0, s.character(at: NSMaxRange(range) - 1) == 0x0A { length -= 1 }
    return NSRange(location: range.location, length: length)
  }

  private func cells(ofRow row: NSRange) -> [NSRange] {
    let text = (storage.string as NSString).substring(with: row) as NSString
    return MarkdownStyler.tableCells(in: text).map { NSRange(location: $0.location + row.location, length: $0.length) }
  }

  /// The table's rows around `location` (the separator row left out), top
  /// to bottom.
  private func tableRows(around location: Int) -> [NSRange] {
    let s = storage.string as NSString
    func isRow(_ line: NSRange) -> Bool { s.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("|") }
    var start = line(at: location)
    guard isRow(start) else { return [] }
    while start.location > 0 {
      let previous = line(at: start.location - 1)
      guard isRow(previous) else { break }
      start = previous
    }
    var rows: [NSRange] = []
    var current = start
    while isRow(current) {
      let text = s.substring(with: current)
      if MarkdownEditorView.tableSeparator.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) == nil {
        rows.append(current)
      }
      let next = NSMaxRange(current) + 1
      guard next < s.length else { break }
      current = line(at: next)
    }
    return rows
  }

  /// The wrapped table cell at `location`: its row and column.
  private func wrappedCell(at location: Int) -> (row: NSRange, column: Int)? {
    guard storage.length > 0 else { return nil }
    let row = line(at: location)
    guard row.length > 0, storage.attribute(.gleaTableWrapped, at: row.location, effectiveRange: nil) != nil else { return nil }
    let cells = cells(ofRow: row)
    guard !cells.isEmpty else { return nil }
    return (row, cells.lastIndex { $0.location <= location } ?? 0)
  }

  /// The range of the cell being edited, in the note.
  private var editedCellRange: NSRange? {
    guard let editing = cellEditing, editing.row < storage.length else { return nil }
    let cells = cells(ofRow: line(at: editing.row))
    return cells.indices.contains(editing.column) ? cells[editing.column] : nil
  }

  private func isHeaderRow(_ row: NSRange) -> Bool {
    tableRows(around: row.location).first == row
  }

  // MARK: Editing a wrapped cell

  /// The cursor landed in a wrapped table (a click, an arrow key): edit
  /// that cell over it.
  func beginCellEditingIfNeeded() {
    guard !tableAsMarkdown, cellEditing == nil, window?.firstResponder === textView else { return }
    let selection = textView.selectedRange()
    guard let cell = wrappedCell(at: selection.location) else { return }
    beginCellEditing(row: cell.row.location, column: cell.column, selection: selection)
  }

  /// A click in a wrapped cell: its field opens over it and takes the
  /// click.
  private func editCell(row: Int, column: Int, clicked event: NSEvent) {
    if cellEditing.map({ $0.row != row || $0.column != column }) ?? false { endCellEditing(focusText: false) }
    if cellEditing == nil {
      beginCellEditing(row: row, column: column, selection: NSRange(location: 0, length: 0))
      // The note's own selection follows, out of sight (it isn't focused).
      if let range = editedCellRange { textView.setSelectedRange(NSRange(location: range.location, length: 0)) }
    }
    guard let field = cellField, cellEditing != nil else { return }
    window?.makeFirstResponder(field)
    field.mouseDown(with: event)
  }

  private func beginCellEditing(row: Int, column: Int, selection: NSRange) {
    cellGeneration += 1
    cellEditing = (row, column)
    guard let range = editedCellRange else {
      cellEditing = nil
      return
    }
    let field = cellField ?? makeCellField()
    let attributes = MarkdownStyler.cellEditingAttributes(header: isHeaderRow(line(at: row)))
    cellOriginal = (storage.string as NSString).substring(with: range)
    field.typing.removeAllActions()
    field.textStorage?.setAttributedString(NSAttributedString(string: cellOriginal ?? "", attributes: attributes))
    field.typingAttributes = attributes
    field.isHidden = false
    restyle(limit: tableRange(around: row))
    let start = max(range.location, min(selection.location, NSMaxRange(range)))
    let end = max(start, min(NSMaxRange(selection), NSMaxRange(range)))
    window?.makeFirstResponder(field)
    field.setSelectedRange(NSRange(location: start - range.location, length: end - start))
  }

  private func makeCellField() -> TableCellField {
    let field = TableCellField(frame: .zero)
    field.owner = self
    field.isRichText = false
    field.allowsUndo = true
    field.drawsBackground = false
    field.textContainerInset = .zero
    field.textContainer?.lineFragmentPadding = 0
    field.textContainer?.widthTracksTextView = true
    field.insertionPointColor = Theme.accent
    field.focusRingType = .none
    field.isAutomaticQuoteSubstitutionEnabled = false
    field.isAutomaticDashSubstitutionEnabled = false
    field.isAutomaticTextReplacementEnabled = false
    field.isContinuousSpellCheckingEnabled = false
    textView.addSubview(field)
    cellField = field
    return field
  }

  /// Puts the field over its cell (the row may have grown or moved), and
  /// takes in changes made to the cell from elsewhere (undo).
  private func layoutCellField() {
    guard let editing = cellEditing, let field = cellField else { return }
    guard editing.row < storage.length, let container = textView.textContainer,
          let row = storage.attribute(.gleaTableRow, at: editing.row, effectiveRange: nil) as? MarkdownTableRow,
          row.cells != nil, editing.column + 1 < row.columnX.count, let range = editedCellRange else {
      endCellEditing(focusText: false)
      return
    }
    layoutManager.ensureLayout(for: container)
    let glyphs = layoutManager.glyphRange(forCharacterRange: line(at: editing.row), actualCharacterRange: nil)
    var lineRect = NSRect.null
    layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in lineRect = lineRect.union(rect) }
    guard !lineRect.isNull else { return }
    let origin = textView.textContainerOrigin
    let rowRect = NSRect(x: origin.x + row.columnX[0], y: origin.y + lineRect.minY,
                         width: (row.columnX.last ?? 0) - row.columnX[0], height: lineRect.height)
    let cell = row.cellRect(editing.column, in: rowRect)
    field.frame = NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: max(cell.height, 18))
    // A cell's range leaves out its padding spaces: the field's leading or
    // trailing space (typed between words) isn't a difference.
    let raw = (storage.string as NSString).substring(with: range)
    if field.string.trimmingCharacters(in: .whitespaces) != raw, !field.hasMarkedText() {
      let selection = field.selectedRange()
      field.textStorage?.setAttributedString(NSAttributedString(string: raw, attributes: field.typingAttributes))
      // Its typing history no longer matches its text.
      field.typing.removeAllActions()
      let length = (raw as NSString).length
      field.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }
  }

  private func endCellEditing(focusText: Bool) {
    guard cellEditing != nil else { return }
    commitCellSession()
    let table = cellEditing.flatMap { tableRange(around: $0.row) }
    cellOriginal = nil
    cellField?.typing.removeAllActions()
    cellEditing = nil
    cellGeneration += 1
    layoutManager.hiddenCell = nil
    cellField?.isHidden = true
    if focusText { window?.makeFirstResponder(textView) }
    restyle(limit: table)
  }

  /// The table's lines around `location` (restyling just the table: the
  /// rest of a long note doesn't change).
  private func tableRange(around location: Int) -> NSRange? {
    let s = storage.string as NSString
    func isRow(_ line: NSRange) -> Bool { s.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("|") }
    var first = line(at: location)
    guard isRow(first) else { return nil }
    while first.location > 0 {
      let previous = line(at: first.location - 1)
      guard isRow(previous) else { break }
      first = previous
    }
    var last = first
    while NSMaxRange(last) + 1 < s.length {
      let next = line(at: NSMaxRange(last) + 1)
      guard isRow(next) else { break }
      last = next
    }
    return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
  }

  /// The field changed: write it into its cell (a "|" typed in a cell is
  /// escaped, so it doesn't split it).
  func cellTextDidChange() {
    guard let field = cellField, let range = editedCellRange, !field.hasMarkedText() else { return }
    var text = field.string.replacingOccurrences(of: "\n", with: " ")
    text = text.replacingOccurrences(of: "(?<!\\\\)\\|", with: "\\\\|", options: .regularExpression)
    var caret = field.selectedRange().location
    if text != field.string {
      caret += (text as NSString).length - (field.string as NSString).length
      field.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: field.typingAttributes))
      // Its typing history no longer matches its text.
      field.typing.removeAllActions()
      field.setSelectedRange(NSRange(location: max(0, min(caret, (text as NSString).length)), length: 0))
    }
    guard (storage.string as NSString).substring(with: range) != text else { return }
    // Straight into the note: the cell's whole change becomes one undo step
    // when it's left (commitCellSession).
    storage.replaceCharacters(in: range, with: text)
    textView.didChangeText()
    textView.setSelectedRange(NSRange(location: range.location + max(0, caret), length: 0))
  }

  /// The cell's change since its editing began, as one undo step in the
  /// note (redo puts it back).
  private func commitCellSession() {
    guard let editing = cellEditing, let original = cellOriginal, let range = editedCellRange else { return }
    let current = (storage.string as NSString).substring(with: range)
    guard current != original else { return }
    registerCellChange(row: editing.row, column: editing.column, undoTo: original, redoTo: current)
    cellOriginal = current
  }

  private func registerCellChange(row: Int, column: Int, undoTo old: String, redoTo new: String) {
    guard let manager = textView.undoManager else { return }
    manager.registerUndo(withTarget: self) { editor in
      editor.setCell(row: row, column: column, to: old)
      editor.registerCellChange(row: row, column: column, undoTo: new, redoTo: old)
    }
    manager.setActionName("Typing")
  }

  private func setCell(row: Int, column: Int, to text: String) {
    let cells = cells(ofRow: line(at: row))
    guard cells.indices.contains(column) else { return }
    storage.replaceCharacters(in: cells[column], with: text)
    textView.didChangeText()
    textView.setSelectedRange(NSRange(location: cells[column].location + (text as NSString).length, length: 0))
  }

  /// Undo and redo run in the note's text view (AppKit applies them to the
  /// text view in front), then editing resumes in the cell they land in.
  func cellUndo(redo: Bool) {
    guard let manager = textView.undoManager else { return }
    endCellEditing(focusText: true)
    if redo { manager.redo() } else { manager.undo() }
    beginCellEditingIfNeeded()
  }

  func cellFieldDidResign() {
    let generation = cellGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self, self.cellGeneration == generation, self.window?.firstResponder !== self.cellField else { return }
      self.endCellEditing(focusText: false)
    }
  }

  /// Keys in the field: Tab, ⇧Tab and Enter work as in any table; Esc and
  /// the arrows past the cell's edges leave it.
  func cellCommand(_ selector: Selector) -> Bool {
    guard let field = cellField, let editing = cellEditing, let range = editedCellRange else { return false }
    let selection = field.selectedRange()
    let length = (field.string as NSString).length
    let rows = tableRows(around: editing.row)
    let rowIndex = rows.firstIndex { $0.location == editing.row } ?? 0

    // The note's own table commands, from the matching place in the note.
    func asTable(_ command: (MarkdownTextView) -> Void) {
      commitCellSession()
      textView.setSelectedRange(NSRange(location: range.location + selection.location, length: selection.length))
      command(textView)
      followTextSelection()
    }
    func moveTo(row: Int, column: Int, atEnd: Bool) {
      let cells = cells(ofRow: rows[row])
      guard !cells.isEmpty else { return }
      let target = cells[min(column, cells.count - 1)]
      endCellEditing(focusText: false)
      beginCellEditing(row: rows[row].location, column: min(column, cells.count - 1),
                       selection: NSRange(location: atEnd ? NSMaxRange(target) : target.location, length: 0))
    }
    func leave(down: Bool) {
      let s = storage.string as NSString
      let location: Int
      if down {
        location = min(s.length, NSMaxRange(rows.last ?? range) + 1)
      } else {
        location = max(0, (rows.first ?? range).location - 1)
      }
      endCellEditing(focusText: true)
      textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    func onFirstLine() -> Bool {
      guard let manager = field.layoutManager, length > 0 else { return true }
      let glyph = manager.glyphIndexForCharacter(at: min(selection.location, length - 1))
      return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY < 1
        || (selection.location == length && manager.lineFragmentRect(forGlyphAt: max(0, glyph), effectiveRange: nil).minY < 1)
    }
    func onLastLine() -> Bool {
      guard let manager = field.layoutManager, length > 0 else { return true }
      var last = NSRange()
      manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: &last)
      return manager.glyphIndexForCharacter(at: min(selection.location, length - 1)) >= last.location || selection.location == length
    }

    switch selector {
    case #selector(NSResponder.insertTab(_:)):
      asTable { $0.insertTab(nil) }
    case #selector(NSResponder.insertBacktab(_:)):
      asTable { $0.insertBacktab(nil) }
    case #selector(NSResponder.insertNewline(_:)):
      asTable { $0.insertNewline(nil) }
    case #selector(NSResponder.cancelOperation(_:)):
      leave(down: true)
    case #selector(NSResponder.moveUp(_:)) where onFirstLine():
      if rowIndex > 0 { moveTo(row: rowIndex - 1, column: editing.column, atEnd: true) } else { leave(down: false) }
    case #selector(NSResponder.moveDown(_:)) where onLastLine():
      if rowIndex + 1 < rows.count { moveTo(row: rowIndex + 1, column: editing.column, atEnd: false) } else { leave(down: true) }
    case #selector(NSResponder.moveLeft(_:)) where selection.length == 0 && selection.location == 0:
      if editing.column > 0 {
        moveTo(row: rowIndex, column: editing.column - 1, atEnd: true)
      } else if rowIndex > 0 {
        moveTo(row: rowIndex - 1, column: Int.max, atEnd: true)
      } else {
        leave(down: false)
      }
    case #selector(NSResponder.moveRight(_:)) where selection.length == 0 && selection.location == length:
      if editing.column + 1 < cells(ofRow: rows[rowIndex]).count {
        moveTo(row: rowIndex, column: editing.column + 1, atEnd: false)
      } else if rowIndex + 1 < rows.count {
        moveTo(row: rowIndex + 1, column: 0, atEnd: false)
      } else {
        leave(down: true)
      }
    default:
      return false
    }
    return true
  }

  /// After a table command ran in the note: edit the cell it moved to, or
  /// go back to the note's text when it left the table.
  private func followTextSelection() {
    let selection = textView.selectedRange()
    endCellEditing(focusText: false)
    if !tableAsMarkdown, let cell = wrappedCell(at: selection.location) {
      beginCellEditing(row: cell.row.location, column: cell.column, selection: selection)
    } else {
      window?.makeFirstResponder(textView)
      textView.setSelectedRange(selection)
    }
  }

  // MARK: Table / Markdown toggle

  private func toggleTableMode() {
    // Another table than the cursor's: the cursor goes there, to edit it as
    // Markdown.
    if let hovered = hoveredTable, !isActiveTable(hovered) {
      if cellField != nil { endCellEditing(focusText: true) }
      window?.makeFirstResponder(textView)
      tableAsMarkdown = false
      textView.setSelectedRange(NSRange(location: hovered, length: 0))
    } else if tableAsMarkdown {
      tableAsMarkdown = false
      restyle(limit: tableRange(around: textView.selectedRange().location))
      beginCellEditingIfNeeded()
      return
    }
    do {
      if let field = cellField, let range = editedCellRange {
        let caret = range.location + min(field.selectedRange().location, range.length)
        endCellEditing(focusText: true)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
      }
      tableAsMarkdown = true
      window?.makeFirstResponder(textView)
      restyle(limit: tableRange(around: textView.selectedRange().location))
    }
  }

  /// Whether the cursor (or the cell being edited) is in the table at
  /// `location`.
  private func isActiveTable(_ location: Int) -> Bool {
    guard let table = tableRange(around: location) else { return false }
    if let editing = cellEditing { return NSLocationInRange(editing.row, table) }
    return window?.firstResponder === textView && textView.tableRowAtCursor() != nil
      && NSLocationInRange(textView.selectedRange().location, NSRange(location: table.location, length: table.length + 1))
  }

  /// The table under a point in the window: over its rows, from the text's
  /// left edge to past the toggle in the gutter on the right, or over its
  /// toggle.
  private func updateTableHover(_ point: NSPoint?) {
    var table: Int?
    if let point, let host = mediaHost, let container = textView.textContainer, storage.length > 0,
       NSPointInRect(convert(point, from: nil), bounds.insetBy(dx: 0, dy: -4).union(NSRect(x: 0, y: 0, width: bounds.width + 14 + MediaBlockView.gutterWidth, height: bounds.height))) {
      if let current = hoveredTable, !tableToggle.isHidden,
         tableToggle.frame.insetBy(dx: -8, dy: -8).contains(host.convert(point, from: nil)) {
        table = current
      } else {
        let origin = textView.textContainerOrigin
        let local = textView.convert(point, from: nil)
        let inContainer = NSPoint(x: min(max(local.x - origin.x, 0), container.size.width - 1), y: local.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        if let first = tableRows(around: index).first,
           layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).contains(NSPoint(x: 1, y: inContainer.y)) {
          table = first.location
        }
      }
    }
    guard table != hoveredTable else { return }
    hoveredTable = table
    layoutTableEditing()
  }

  /// For automated checks: the pointer over the nth table's first row (or
  /// away from tables, when there's none).
  func debugHoverTable(_ n: Int) {
    let text = storage.string as NSString
    var tables: [Int] = []
    var location = 0
    while location < text.length {
      let line = text.lineRange(for: NSRange(location: location, length: 0))
      if let first = tableRows(around: line.location).first, tables.last != first.location { tables.append(first.location) }
      location = NSMaxRange(line)
    }
    guard tables.indices.contains(n) else { return updateTableHover(nil) }
    let glyph = layoutManager.glyphIndexForCharacter(at: tables[n])
    let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let origin = textView.textContainerOrigin
    updateTableHover(textView.convert(NSPoint(x: origin.x + 40, y: origin.y + rect.midY), to: nil))
  }

  func debugClickTableToggle() { tableToggle.onClick?() }

  /// The field over its cell, and the toggle next to the table under the
  /// pointer.
  func layoutTableEditing() {
    layoutCellField()
    guard let anchor = hoveredTable, anchor < storage.length, let host = mediaHost, let container = textView.textContainer,
          let top = tableRows(around: anchor).first else {
      if !tableToggle.isHidden { tableToggle.fade(in: false) }
      return
    }
    layoutManager.ensureLayout(for: container)
    let glyphs = layoutManager.glyphRange(forCharacterRange: top, actualCharacterRange: nil)
    var lineRect = NSRect.null
    layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in lineRect = lineRect.union(rect) }
    guard !lineRect.isNull else { return }
    // Level with a header row, at the same place whether the table shows as
    // a table or as Markdown (its first line's height differs).
    let origin = textView.textContainerOrigin
    let rowInHost = textView.convert(NSRect(x: origin.x, y: origin.y + lineRect.minY, width: 1, height: 34), to: host)
    // In the gutter right of the text column, like an embed's toggle; just
    // its icon when the window is too narrow for its label.
    let x = convert(NSPoint(x: bounds.width + 14, y: 0), to: host).x
    tableToggle.collapsed = tableAsMarkdown && isActiveTable(anchor)
    if tableToggle.superview !== host { host.addSubview(tableToggle) }
    if let window {
      let fits = host.convert(NSPoint(x: x + tableToggle.labelledWidth, y: 0), to: nil).x <= window.contentLayoutRect.maxX - 8
      tableToggle.setShowsLabel(fits, animated: window.isVisible && !tableToggle.isHidden) { [weak self] in self?.layoutTableEditing() }
    }
    let size = tableToggle.fittingSize
    tableToggle.frame = NSRect(x: x, y: rowInHost.midY - size.height / 2, width: size.width, height: size.height)
    if tableToggle.isHidden || tableToggle.alphaValue < 1 { tableToggle.fade(in: true) }
  }
}
