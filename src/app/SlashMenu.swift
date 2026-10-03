import AppKit
import UniformTypeIdentifiers

// The slash menu: typing "/" at the start of a line or after a space offers
// the blocks a note can have. Typing on filters it, ↑/↓ move through it,
// Return or Tab (or a click) turns what was typed into the chosen block, and
// Esc closes it, leaving the text as it is.
//
// The same menu, opened by "[[", offers the notes to link to, and by "\"
// in math (`$…$`, `$$…$$`), LaTeX commands, each shown typeset.

struct SlashItem {
  let title: String
  /// Other words it's found by.
  let keywords: [String]
  let symbol: String
  /// Its Markdown, shown faded.
  let hint: String
  let apply: @MainActor (MarkdownTextView) -> Void
  /// What it looks like (LaTeX commands), shown instead of the hint.
  var preview: NSImage? = nil

  @MainActor static let all: [SlashItem] = [
    lineItem("Heading 1", ["h1", "title"], "textformat.size.larger", "# "),
    lineItem("Heading 2", ["h2", "subtitle"], "textformat.size", "## "),
    lineItem("Heading 3", ["h3"], "textformat.size.smaller", "### "),
    lineItem("Heading 4", ["h4"], "textformat.size.smaller", "#### "),
    lineItem("Bulleted List", ["ul", "bullet", "unordered"], "list.bullet", "- "),
    lineItem("Numbered List", ["ol", "ordered", "number"], "list.number", "1. "),
    lineItem("To-do List", ["todo", "task", "checkbox", "check"], "checklist", "- [ ] "),
    lineItem("Quote", ["blockquote", "citation"], "text.quote", "> "),
    calloutItem("Callout", "note", ["note", "admonition", "info"], "text.bubble"),
    calloutItem("Tip", "tip", ["hint"], "lightbulb"),
    calloutItem("Warning", "warning", ["caution", "attention"], "exclamationmark.triangle"),
    calloutItem("Danger", "danger", ["error", "bug"], "xmark.octagon"),
    calloutItem("Success", "success", ["done", "check"], "checkmark.circle"),
    calloutItem("Question", "question", ["help", "faq"], "questionmark.circle"),
    calloutItem("Example", "example", [], "list.bullet.rectangle"),
    SlashItem(title: "Code Block", keywords: ["code", "snippet", "fence"], symbol: "chevron.left.forwardslash.chevron.right",
              hint: "```", apply: { $0.insertCodeBlock() }),
    SlashItem(title: "Math Block", keywords: ["equation", "latex", "formula", "tex"], symbol: "function", hint: "$$",
              apply: { $0.insertMathBlock() }),
    SlashItem(title: "Inline Math", keywords: ["equation", "latex", "formula", "tex"], symbol: "x.squareroot", hint: "$ $",
              apply: { $0.insertInlineMath() }),
    SlashItem(title: "Table", keywords: ["grid"], symbol: "tablecells", hint: "| |", apply: { $0.insertTable() }),
    SlashItem(title: "Image, Video or Sound", keywords: ["picture", "photo", "file", "movie", "audio", "media", "attachment"],
              symbol: "photo", hint: "![]( )", apply: { $0.chooseMedia() }),
    SlashItem(title: "Web Embed", keywords: ["youtube", "vimeo", "video", "url", "embed"], symbol: "play.rectangle", hint: "URL",
              apply: { $0.insertWebEmbed() }),
    SlashItem(title: "Divider", keywords: ["hr", "rule", "line", "separator"], symbol: "minus", hint: "---",
              apply: { $0.insertDivider() }),
    SlashItem(title: "Link", keywords: ["url", "web"], symbol: "link", hint: "[ ]( )", apply: { $0.insertLink() }),
    SlashItem(title: "Link to Note", keywords: ["note", "wiki", "page", "mention"], symbol: "doc.text", hint: "[[ ]]",
              apply: { $0.insertText("[[", replacementRange: $0.selectedRange()) }),
    SlashItem(title: "Embedded Note", keywords: ["embed", "transclude", "include", "note"], symbol: "doc.richtext", hint: "![[ ]]",
              apply: { $0.insertText("![[", replacementRange: $0.selectedRange()) }),
  ]

  /// Turns the line into a callout of `type` (its text, if any, the title).
  @MainActor private static func calloutItem(_ title: String, _ type: String, _ keywords: [String], _ symbol: String) -> SlashItem {
    SlashItem(title: title, keywords: keywords + ["callout"], symbol: symbol, hint: "> [!\(type)]") { $0.makeCallout(type) }
  }

  /// Turns the line into a `prefix` line (whatever prefix it had before).
  @MainActor private static func lineItem(_ title: String, _ keywords: [String], _ symbol: String, _ prefix: String) -> SlashItem {
    SlashItem(title: title, keywords: keywords, symbol: symbol, hint: prefix.trimmingCharacters(in: .whitespaces)) { textView in
      let s = textView.string as NSString
      let line = s.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
      if s.substring(with: line).trimmingCharacters(in: .newlines).isEmpty {
        // (Toggling counts an empty line as already having the prefix.)
        textView.replace(NSRange(location: line.location, length: 0), with: prefix,
                         select: NSRange(location: line.location + (prefix as NSString).length, length: 0))
        return
      }
      if !textView.linePrefixActive(prefix) { textView.toggleLinePrefix(prefix) }
      let changed = (textView.string as NSString).lineRange(for: NSRange(location: line.location, length: 0))
      let text = (textView.string as NSString).substring(with: changed)
      textView.setSelectedRange(NSRange(location: changed.location + (text.trimmingCharacters(in: .newlines) as NSString).length, length: 0))
    }
  }

  /// Notes whose name starts with `query` first, then those containing it,
  /// and a new note named `query` when none is called that. Choosing one
  /// completes the link ("[[query" → "[[Name]]").
  @MainActor static func notes(_ query: String, names: [String]) -> [SlashItem] {
    let wanted = query.trimmingCharacters(in: .whitespaces)
    let lower = wanted.lowercased()
    let starting = names.filter { lower.isEmpty || $0.lowercased().hasPrefix(lower) }
    let containing = lower.isEmpty ? [] : names.filter { !$0.lowercased().hasPrefix(lower) && $0.lowercased().contains(lower) }
    var items = (starting + containing).prefix(8).map { name in
      SlashItem(title: name, keywords: [], symbol: "doc.text", hint: "", apply: { $0.completeNoteLink(name) })
    }
    if !wanted.isEmpty, !NoteStore.shared.hasNote(named: wanted) {
      items.append(SlashItem(title: wanted, keywords: [], symbol: "plus", hint: "new note", apply: { $0.completeNoteLink(wanted) }))
    }
    return items
  }

  /// The headings of a note to link to (`[[Note#…`): those starting with
  /// `query` first, then those containing it.
  @MainActor static func headings(_ query: String, note name: String, content: String) -> [SlashItem] {
    let lower = query.trimmingCharacters(in: .whitespaces).lowercased()
    let headings = markdownHeadings(in: content)
    let starting = headings.filter { lower.isEmpty || $0.title.lowercased().hasPrefix(lower) }
    let containing = lower.isEmpty ? [] : headings.filter { !$0.title.lowercased().hasPrefix(lower) && $0.title.lowercased().contains(lower) }
    return (starting + containing).prefix(8).map { heading in
      SlashItem(title: heading.title, keywords: [], symbol: "number", hint: "H\(heading.level)",
                apply: { $0.completeNoteLink(name + "#" + heading.title) })
    }
  }

  private static let blockID = try! NSRegularExpression(pattern: "\\s\\^([\\w-]+)$")

  /// The blocks of a note to link to (`[[Note#^…`): its paragraphs, list
  /// items and quotes, found by their text. Choosing one without an id gives
  /// it one (" ^id" at the end of its line), like Obsidian.
  @MainActor static func blocks(_ query: String, note name: String, ref: NoteRef?, content: String) -> [SlashItem] {
    let lower = query.trimmingCharacters(in: .whitespaces).lowercased()
    var items: [SlashItem] = []
    var inFence = false
    let body = Frontmatter.body(of: content)
    for line in body.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      guard !inFence, !trimmed.isEmpty, !MarkdownStyler.isHeading(trimmed), !trimmed.hasPrefix("|"), trimmed != "---" else { continue }
      let ns = line as NSString
      let idMatch = blockID.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
      let existing = idMatch.map { ns.substring(with: $0.range(at: 1)) }
      let text = NoteStore.plainText(idMatch.map { ns.substring(to: $0.range.location) } ?? line)
        .trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty, lower.isEmpty || text.lowercased().contains(lower) || existing?.lowercased().hasPrefix(lower) == true else { continue }
      items.append(SlashItem(title: text, keywords: [], symbol: "text.alignleft", hint: existing.map { "^" + $0 } ?? "",
                             apply: { textView in
        let id = existing ?? blockIDs()
        if existing == nil { textView.addBlockID(id, toLine: line, of: ref) }
        textView.completeNoteLink(name + "#^" + id)
      }))
      if items.count == 8 { break }
    }
    return items
  }

  /// A new block id, like Obsidian's: six lowercase letters and digits.
  private static func blockIDs() -> String {
    String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
  }

  /// Tags the notes use, starting with `query` first, then containing it,
  /// the most used first. Nothing until a letter is typed (a "#" alone may
  /// start a heading).
  @MainActor static func tags(_ query: String) -> [SlashItem] {
    let lower = query.lowercased()
    guard !lower.isEmpty else { return [] }
    let all = NoteStore.shared.tagCounts().sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    let starting = all.filter { $0.tag.lowercased().hasPrefix(lower) && $0.tag.lowercased() != lower }
    let containing = all.filter { !$0.tag.lowercased().hasPrefix(lower) && $0.tag.lowercased().contains(lower) }
    return (starting + containing).prefix(8).map { entry in
      SlashItem(title: "#" + entry.tag, keywords: [], symbol: "number", hint: "\(entry.count)", apply: { textView in
        let location = textView.selectedRange().location
        let s = textView.string as NSString
        let spaced = location < s.length && [0x20, 0x0A, 0x09].contains(s.character(at: location))
        let text = entry.tag + (spaced ? "" : " ")
        textView.replace(NSRange(location: location, length: 0), with: text,
                         select: NSRange(location: location + (entry.tag as NSString).length + 1, length: 0))
      })
    }
  }

  /// LaTeX commands: the command, what it inserts ("|" is where the cursor
  /// goes), and an example to show typeset.
  private static let latex: [(command: String, insert: String, example: String)] = {
    let structures: [(String, String, String)] = [
      ("frac", "\\frac{|}{}", "\\frac{a}{b}"), ("sqrt", "\\sqrt{|}", "\\sqrt{x}"), ("sum", "\\sum_{|}^{}", "\\sum_{i=1}^{n}"),
      ("int", "\\int_{|}^{}", "\\int_{a}^{b}"), ("prod", "\\prod_{|}^{}", "\\prod_{i=1}^{n}"), ("lim", "\\lim_{|}", "\\lim_{x \\to 0}"),
      ("infty", "\\infty|", "\\infty"), ("partial", "\\partial|", "\\partial"), ("nabla", "\\nabla|", "\\nabla"),
      ("binom", "\\binom{|}{}", "\\binom{n}{k}"), ("vec", "\\vec{|}", "\\vec{v}"), ("hat", "\\hat{|}", "\\hat{x}"),
      ("bar", "\\bar{|}", "\\bar{x}"), ("dot", "\\dot{|}", "\\dot{x}"), ("overline", "\\overline{|}", "\\overline{AB}"),
      ("mathbb", "\\mathbb{|}", "\\mathbb{R}"), ("mathbf", "\\mathbf{|}", "\\mathbf{x}"), ("mathrm", "\\mathrm{|}", "\\mathrm{d}"),
      ("text", "\\text{|}", "\\text{text}"), ("left(", "\\left( | \\right)", "\\left(\\frac{a}{b}\\right)"),
      ("begin{pmatrix}", "\\begin{pmatrix} | \\end{pmatrix}", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
      ("cdot", "\\cdot |", "a \\cdot b"), ("times", "\\times |", "a \\times b"), ("div", "\\div |", "a \\div b"),
      ("pm", "\\pm |", "\\pm"), ("leq", "\\leq |", "\\leq"), ("geq", "\\geq |", "\\geq"), ("neq", "\\neq |", "\\neq"),
      ("approx", "\\approx |", "\\approx"), ("equiv", "\\equiv |", "\\equiv"), ("propto", "\\propto |", "\\propto"),
      ("to", "\\to |", "\\to"), ("rightarrow", "\\rightarrow |", "\\rightarrow"), ("Rightarrow", "\\Rightarrow |", "\\Rightarrow"),
      ("Leftrightarrow", "\\Leftrightarrow |", "\\Leftrightarrow"), ("mapsto", "\\mapsto |", "\\mapsto"),
      ("in", "\\in |", "\\in"), ("notin", "\\notin |", "\\notin"), ("subset", "\\subset |", "\\subset"),
      ("subseteq", "\\subseteq |", "\\subseteq"), ("cup", "\\cup |", "\\cup"), ("cap", "\\cap |", "\\cap"),
      ("emptyset", "\\emptyset|", "\\emptyset"), ("forall", "\\forall |", "\\forall"), ("exists", "\\exists |", "\\exists"),
      ("neg", "\\neg |", "\\neg"), ("ldots", "\\ldots|", "1, \\ldots, n"), ("cdots", "\\cdots|", "\\cdots"),
      ("log", "\\log|", "\\log"), ("ln", "\\ln|", "\\ln"), ("exp", "\\exp|", "\\exp"), ("sin", "\\sin|", "\\sin"),
      ("cos", "\\cos|", "\\cos"), ("tan", "\\tan|", "\\tan"), ("max", "\\max|", "\\max"), ("min", "\\min|", "\\min"),
      ("hbar", "\\hbar|", "\\hbar"), ("quad", "\\quad |", "a \\quad b"),
    ]
    let greek = ["alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu",
                 "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "varphi", "chi", "psi", "omega",
                 "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Phi", "Psi", "Omega"]
      .map { ($0, "\\\($0)|", "\\\($0)") }
    return (structures + greek).map { (command: $0.0, insert: $0.1, example: $0.2) }
  }()

  /// The LaTeX commands starting with `query` (exact case first), then
  /// those containing it; the first few.
  @MainActor static func math(_ query: String) -> [SlashItem] {
    let lower = query.lowercased()
    let exact = latex.filter { $0.command.hasPrefix(query) }
    let starting = latex.filter { !$0.command.hasPrefix(query) && $0.command.lowercased().hasPrefix(lower) }
    let containing = lower.isEmpty ? [] : latex.filter { !$0.command.lowercased().hasPrefix(lower) && $0.command.lowercased().contains(lower) }
    return (exact + starting + containing).prefix(8).map { entry in
      SlashItem(title: "\\" + entry.command, keywords: [], symbol: "function", hint: "", apply: { textView in
        let caret = (entry.insert as NSString).range(of: "|").location
        let text = entry.insert.replacingOccurrences(of: "|", with: "")
        let location = textView.selectedRange().location
        textView.replace(NSRange(location: location, length: 0), with: text, select: NSRange(location: location + caret, length: 0))
      }, preview: MathRender.render(entry.example, display: false)?.image)
    }
  }

  /// The items `query` finds: those whose title or a keyword starts with it
  /// first, then those containing it.
  @MainActor static func matching(_ query: String) -> [SlashItem] {
    let query = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return all }
    func words(_ item: SlashItem) -> [String] {
      [item.title.lowercased()] + item.title.lowercased().split(separator: " ").map(String.init) + item.keywords
    }
    let starting = all.filter { words($0).contains { $0.hasPrefix(query) } }
    let containing = all.filter { item in !starting.contains { $0.title == item.title } && words(item).contains { $0.contains(query) } }
    return starting + containing
  }
}

extension MarkdownTextView {
  /// Writes `name` at the cursor (just after "[["), and closes the link:
  /// the cursor goes after "]]", which is added unless it's already there.
  /// Before an alias ("|alias]]"), the link keeps it, and the cursor goes
  /// after the name.
  func completeNoteLink(_ name: String) {
    let location = selectedRange().location
    let s = string as NSString
    let closed = location + 2 <= s.length && s.substring(with: NSRange(location: location, length: 2)) == "]]"
    let aliased = location < s.length && s.character(at: location) == 0x7C
    let text = closed || aliased ? name : name + "]]"
    replace(NSRange(location: location, length: 0), with: text,
            select: NSRange(location: location + (name as NSString).length + (aliased ? 0 : 2), length: 0))
  }

  /// Ends `line` with " ^id": in this text when `ref` is nil (a link within
  /// the note), otherwise in that note's file. The first line written that
  /// way, other than the one the cursor is on.
  func addBlockID(_ id: String, toLine line: String, of ref: NoteRef?) {
    let suffix = " ^" + id
    if let ref {
      var lines = NoteStore.shared.content(of: ref).components(separatedBy: "\n")
      guard let index = lines.firstIndex(of: line) else { return }
      lines[index] = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + suffix
      NoteStore.shared.save(ref, content: lines.joined(separator: "\n"))
      return
    }
    let s = string as NSString
    let caret = selectedRange().location
    var target: NSRange?
    s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: .byLines) { text, range, _, stop in
      if text == line, !(caret >= range.location && caret <= NSMaxRange(range)) {
        target = range
        stop.pointee = true
      }
    }
    guard let target else { return }
    let trailing = (line as NSString).length - (line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) as NSString).length
    let end = NSRange(location: NSMaxRange(target) - trailing, length: trailing)
    let shift = NSMaxRange(target) <= caret ? (suffix as NSString).length - trailing : 0
    replace(end, with: suffix, select: NSRange(location: caret + shift, length: 0))
  }

  /// A fenced code block at the cursor, with the cursor inside it.
  func insertCodeBlock() {
    let s = string as NSString
    let location = selectedRange().location
    let lineStart = s.lineRange(for: NSRange(location: location, length: 0)).location
    let before = location == lineStart ? "" : "\n"
    let after = location < s.length && s.character(at: location) != 0x0A ? "\n" : ""
    let block = before + "```\n\n```" + after
    replace(NSRange(location: location, length: 0), with: block,
            select: NSRange(location: location + (before as NSString).length + 4, length: 0))
  }

  /// A horizontal rule on its own line, below a blank line (otherwise the
  /// text above would become a heading), and the cursor on the line after it.
  func insertDivider() {
    let s = string as NSString
    let location = selectedRange().location
    let lineStart = s.lineRange(for: NSRange(location: location, length: 0)).location
    var before = ""
    if location > lineStart {
      before = "\n\n"
    } else if lineStart > 0 {
      let above = s.lineRange(for: NSRange(location: lineStart - 1, length: 0))
      if !s.substring(with: above).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { before = "\n" }
    }
    let after = location < s.length && s.character(at: location) == 0x0A ? "" : "\n"
    let caret = location + (before as NSString).length + 4
    replace(NSRange(location: location, length: 0), with: before + "---" + after, select: NSRange(location: caret, length: 0))
  }

  /// The line becomes a callout's first line: "> [!type] " before its text
  /// (after its "> " if it's already quoted), the cursor at its end.
  func makeCallout(_ type: String) {
    let s = string as NSString
    var line = s.lineRange(for: NSRange(location: selectedRange().location, length: 0))
    if NSMaxRange(line) > line.location, s.character(at: NSMaxRange(line) - 1) == 0x0A { line.length -= 1 }
    let text = s.substring(with: line)
    let quoted = text.hasPrefix("> ")
    let insert = (quoted ? "" : "> ") + "[!\(type)] "
    let at = line.location + (quoted ? 2 : 0)
    replace(NSRange(location: at, length: 0), with: insert,
            select: NSRange(location: NSMaxRange(line) + (insert as NSString).length, length: 0))
  }

  /// A `$$` block on lines of its own, the cursor between them.
  func insertMathBlock() {
    let s = string as NSString
    let location = selectedRange().location
    let lineStart = s.lineRange(for: NSRange(location: location, length: 0)).location
    let before = location == lineStart ? "" : "\n"
    let after = location < s.length && s.character(at: location) != 0x0A ? "\n" : ""
    replace(NSRange(location: location, length: 0), with: before + "$$\n\n$$" + after,
            select: NSRange(location: location + (before as NSString).length + 3, length: 0))
  }

  /// `$x$`, the x selected to type over. (A bare `$$` would open a block.)
  func insertInlineMath() {
    let location = selectedRange().location
    replace(NSRange(location: location, length: 0), with: "$x$", select: NSRange(location: location + 1, length: 1))
  }

  /// Images, videos or sounds chosen from disk, copied into assets/ like
  /// dropped ones, each on its own line.
  func chooseMedia() {
    guard let window else { return }
    let location = selectedRange().location
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.image, .movie, .audio]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, !panel.urls.isEmpty else { return }
      let board = NSPasteboard(name: NSPasteboard.Name("app.glea.media-" + UUID().uuidString))
      board.clearContents()
      board.writeObjects(panel.urls as [NSURL])
      if let images = self.imageMarkdown(from: board), !images.isEmpty { self.insertImages(images, at: location) }
      board.releaseGlobally()
    }
  }

  /// A web page or video (YouTube, Vimeo...) on its own line: the URL on the
  /// clipboard, or "https://" to finish.
  func insertWebEmbed() {
    let s = string as NSString
    let location = selectedRange().location
    let lineStart = s.lineRange(for: NSRange(location: location, length: 0)).location
    let before = location == lineStart ? "" : "\n"
    let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let start = location + (before as NSString).length
    if (clipboard.hasPrefix("http://") || clipboard.hasPrefix("https://")) && !clipboard.contains(where: \.isWhitespace) {
      let text = before + clipboard + "\n"
      replace(NSRange(location: location, length: 0), with: text,
              select: NSRange(location: location + (text as NSString).length, length: 0))
    } else {
      replace(NSRange(location: location, length: 0), with: before + "https://", select: NSRange(location: start + 8, length: 0))
    }
  }
}

/// The menu's state for one text view: where the "/" (or "[[") is, what it
/// matches, and the panel showing it.
@MainActor
final class SlashMenu {
  enum Kind {
    /// "/": the blocks a note can have.
    case blocks
    /// "[[": the notes to link to.
    case noteLink
    /// "\" in math: LaTeX commands.
    case math
    /// "#": the tags the notes use.
    case tag
  }

  private unowned let textView: MarkdownTextView
  private let kind: Kind
  /// What opens it.
  private var trigger: String {
    switch kind {
    case .blocks: return "/"
    case .noteLink: return "[["
    case .math: return "\\"
    case .tag: return "#"
    }
  }
  /// Where the trigger is, while the menu is open (it may have no matches,
  /// and then shows nothing until typing finds some again).
  private var start: Int?
  private var items: [SlashItem] = []
  private var selected = 0
  private var panel: SlashMenuPanel?
  private var observers: [NSObjectProtocol] = []

  init(textView: MarkdownTextView, kind: Kind) {
    self.textView = textView
    self.kind = kind
  }

  var isOpen: Bool { start != nil }

  func textDidChange() {
    guard !choosing else { return }
    if isOpen {
      update()
      return
    }
    let caret = textView.selectedRange()
    let s = textView.string as NSString
    let length = (trigger as NSString).length
    // Typing (or deleting) in a link or tag written earlier: the menu comes
    // back for it.
    if let earlier = earlierTrigger(before: caret), !isInCodeBlock(earlier) {
      start = earlier
      update()
      return
    }
    guard caret.length == 0, caret.location >= length, caret.location <= s.length,
          s.substring(with: NSRange(location: caret.location - length, length: length)) == trigger else { return }
    // A "/" at the start of a line or after a space (not in a URL); "[["
    // anywhere. Neither in a code block.
    if kind == .blocks || kind == .tag, caret.location >= 2 {
      let before = s.character(at: caret.location - 2)
      guard before == 0x20 || before == 0x09 || before == 0x0A else { return }
    }
    guard !isInCodeBlock(caret.location - length) else { return }
    // "\" in math (not a "\\" line break).
    if kind == .math {
      guard textView.isInMath(caret.location - 1), caret.location < 2 || s.character(at: caret.location - 2) != 0x5C else { return }
    }
    start = caret.location - length
    update()
  }

  /// The "[[" (or "#") of the link (or tag) the cursor is in, typed before
  /// what was just changed: "[[" with no "]" between it and the cursor, on
  /// its line; "#" followed by tag characters only, at a word's start.
  private func earlierTrigger(before caret: NSRange) -> Int? {
    guard caret.length == 0 else { return nil }
    switch kind {
    case .noteLink:
      return textView.wikiLinkContext.map { $0.location - 2 }
    case .tag:
      let s = textView.string as NSString
      var index = caret.location
      while index > 0, let scalar = Unicode.Scalar(s.character(at: index - 1)),
            CharacterSet.alphanumerics.contains(scalar) || "_-/".unicodeScalars.contains(scalar) {
        index -= 1
      }
      guard index > 0, index < caret.location, s.character(at: index - 1) == 0x23 else { return nil }
      let hash = index - 1
      guard hash == 0 || [0x20, 0x09, 0x0A].contains(s.character(at: hash - 1)) else { return nil }
      return hash
    case .blocks, .math:
      return nil
    }
  }

  /// Set while a choice is written: those changes don't open it again.
  private var choosing = false

  /// Opens it on a trigger typed earlier (Esc inside "[[…").
  func open(at location: Int) {
    close()
    start = location
    update()
  }

  func selectionDidChange() {
    if isOpen { update() }
  }

  /// Keys while the menu shows: ↑/↓ move, Return/Tab choose, Esc closes.
  func handle(_ selector: Selector) -> Bool {
    guard isOpen else { return false }
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      close()
      return true
    }
    guard !items.isEmpty else { return false }
    switch selector {
    case #selector(NSResponder.moveDown(_:)):
      select((selected + 1) % items.count)
    case #selector(NSResponder.moveUp(_:)):
      select((selected - 1 + items.count) % items.count)
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
      choose(selected)
    default:
      return false
    }
    return true
  }

  func close() {
    start = nil
    items = []
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let panel {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
  }

  private func update() {
    guard let start else { return }
    let s = textView.string as NSString
    let caret = textView.selectedRange()
    let length = (trigger as NSString).length
    guard caret.length == 0, caret.location >= start + length, start + length <= s.length,
          s.substring(with: NSRange(location: start, length: length)) == trigger else { return close() }
    let query = s.substring(with: NSRange(location: start + length, length: caret.location - start - length))
    switch kind {
    case .blocks:
      // Past a line, a space right after the "/", or a long run: just text.
      guard caret.location > start, !query.contains("\n"), !query.hasPrefix(" "), (query as NSString).length <= 24 else { return close() }
      let matches = SlashItem.matching(query)
      if matches.isEmpty && query.hasSuffix(" ") { return close() }
      items = matches
    case .math:
      // Letters only: past a space, a brace… the command is typed.
      guard !query.isEmpty || caret.location == start + length,
            query.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "(") }), (query as NSString).length <= 20 else { return close() }
      items = SlashItem.math(query)
    case .noteLink:
      // Past the line or the link's end: done.
      guard !query.contains("\n"), !query.contains("]"), (query as NSString).length <= 120 else { return close() }
      // "Note#": its headings; "Note#^": its blocks. "#" alone: this note's.
      if let hash = query.firstIndex(of: "#"), !NoteStore.shared.hasNote(named: query) {
        let name = String(query[..<hash])
        let anchor = String(query[query.index(after: hash)...])
        // A name being typed ("Rec#"): the note the menu would offer first.
        let ref = name.isEmpty ? nil : NoteStore.shared.resolve(linkName: name)
          ?? SlashItem.notes(name, names: textView.noteNames()).first { $0.symbol == "doc.text" }
            .flatMap { NoteStore.shared.resolve(linkName: $0.title) }
        if !name.isEmpty && ref == nil {
          items = []
        } else {
          let content = ref.map { NoteStore.shared.content(of: $0) } ?? textView.string
          let note = ref.map { NoteStore.shared.resolve(linkName: name) == $0 ? name : $0.name } ?? name
          items = anchor.hasPrefix("^")
            ? SlashItem.blocks(String(anchor.dropFirst()), note: note, ref: ref, content: content)
            : SlashItem.headings(anchor, note: note, content: content)
        }
      } else {
        items = SlashItem.notes(query, names: textView.noteNames())
      }
    case .tag:
      // Tag characters only: past a space or punctuation, the tag is typed.
      guard query.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-/".unicodeScalars.contains($0) }),
            (query as NSString).length <= 60 else { return close() }
      items = SlashItem.tags(query)
    }
    selected = 0
    if items.isEmpty { hidePanel() } else { showPanel() }
  }

  private func select(_ index: Int) {
    selected = index
    panel?.menuView.selected = index
  }

  /// Replaces the "/" and what follows with the item's block, or what follows
  /// "[[" with the note's name, as one undo step.
  private func choose(_ index: Int) {
    guard let start, items.indices.contains(index) else { return }
    let item = items[index]
    // "/" and "\\" go with the query; "[[" and "#" stay.
    let from = kind == .noteLink || kind == .tag ? start + (trigger as NSString).length : start
    var end = textView.selectedRange().location
    // In the middle of a link or tag: what's after the cursor goes too (a
    // link up to its "]]" or alias, keeping them).
    let s = textView.string as NSString
    let lineEnd = NSMaxRange(s.lineRange(for: NSRange(location: end, length: 0)))
    if kind == .noteLink {
      let rest = s.substring(with: NSRange(location: end, length: lineEnd - end)) as NSString
      let close = rest.range(of: "]]").location, open = rest.range(of: "[["), bar = rest.range(of: "|").location
      if close != NSNotFound, open.location == NSNotFound || open.location > close { end += min(close, bar) }
    } else if kind == .tag {
      while end < lineEnd, let scalar = Unicode.Scalar(s.character(at: end)),
            CharacterSet.alphanumerics.contains(scalar) || "_-/".unicodeScalars.contains(scalar) {
        end += 1
      }
    }
    let range = NSRange(location: from, length: end - from)
    close()
    textView.breakUndoCoalescing()
    let undo = textView.undoManager
    undo?.beginUndoGrouping()
    choosing = true
    textView.replace(range, with: "", select: NSRange(location: from, length: 0))
    item.apply(textView)
    choosing = false
    undo?.endUndoGrouping()
    undo?.setActionName(kind == .blocks ? item.title : kind == .math ? "Insert \(item.title)" : kind == .tag ? "Insert Tag" : "Link to Note")
  }

  private func isInCodeBlock(_ location: Int) -> Bool {
    let before = (textView.string as NSString).substring(to: location)
    let fences = before.components(separatedBy: "\n").filter {
      let line = $0.trimmingCharacters(in: .whitespaces)
      return line.hasPrefix("```") || line.hasPrefix("~~~")
    }
    return fences.count % 2 == 1
  }

  // MARK: Panel

  private func showPanel() {
    guard let window = textView.window, let start else { return }
    let panel = self.panel ?? SlashMenuPanel()
    self.panel = panel
    panel.appearance = window.effectiveAppearance
    panel.menuView.items = items
    panel.menuView.selected = selected
    panel.menuView.onHover = { [weak self] index in self?.select(index) }
    panel.menuView.onChoose = { [weak self] index in self?.choose(index) }
    let size = panel.menuView.fittingSize
    // Below the "/" or "[[" (above it when there's no room), its icons in line with it.
    let slash = textView.firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
    let screen = window.screen?.visibleFrame ?? .infinite
    var origin = NSPoint(x: slash.minX - SlashMenuView.padding - 6, y: slash.minY - 6 - size.height)
    if origin.y < screen.minY { origin.y = slash.maxY + 6 }
    origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
    let wasVisible = panel.isVisible
    // (The panel has room around the card for its shadow.)
    let margin = SlashMenuPanel.shadowMargin
    panel.setFrame(NSRect(x: origin.x - margin, y: origin.y - margin, width: size.width + margin * 2, height: size.height + margin * 2),
                   display: true)
    if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
    if !wasVisible {
      panel.orderFront(nil)
      panel.contentView?.animateIn(scale: 0.97, fade: 0.1, duration: 0.16, fromTopLeft: true)
    }
    guard observers.isEmpty else { return }
    // It follows the text as the page scrolls, and closes when the window
    // loses focus.
    let center = NotificationCenter.default
    if let clip = textView.enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { if self?.items.isEmpty == false { self?.showPanel() } }
      })
    }
    observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    })
  }

  private func hidePanel() {
    guard let panel else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }
}

/// A borderless panel that never takes focus (typing stays in the note). It
/// draws the card's shadow itself, so the shadow is rounded like the card and
/// scales and fades with it.
final class SlashMenuPanel: NSPanel {
  static let shadowMargin: CGFloat = 24
  let menuView = SlashMenuView()

  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    let container = SlashMenuContainer()
    // Taller than the card when there are many items: it scrolls freely.
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.automaticallyAdjustsContentInsets = false
    scroll.documentView = menuView
    scroll.translatesAutoresizingMaskIntoConstraints = false
    container.card.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: container.card.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: container.card.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: container.card.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: container.card.bottomAnchor),
    ])
    contentView = container
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The card, inset for its shadow, and the shadow behind it.
private final class SlashMenuContainer: NSView {
  let card = SlashMenuCard()
  private let shadowView = NSView()
  private static let radius: CGFloat = 10

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    shadowView.wantsLayer = true
    for view in [shadowView, card] { addSubview(view) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let rect = bounds.insetBy(dx: SlashMenuPanel.shadowMargin, dy: SlashMenuPanel.shadowMargin)
    card.frame = rect
    shadowView.frame = rect
    guard let layer = shadowView.layer else { return }
    Motion.withoutAnimation {
      layer.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }
    updateShadow()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateShadow()
  }

  private func updateShadow() {
    guard let layer = shadowView.layer else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    Motion.withoutAnimation {
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = dark ? 0.5 : 0.14
      layer.shadowRadius = 12
      layer.shadowOffset = CGSize(width: 0, height: -4)
    }
  }
}

/// The menu's card: white with a hairline border in light mode, the system
/// menu material in dark mode. Rounded, material included.
private final class SlashMenuCard: NSView {
  private let material = NSVisualEffectView()
  private static let radius: CGFloat = 10

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = Self.radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    material.material = .menu
    material.state = .active
    // The material ignores its layer's corners: a mask rounds it.
    material.maskImage = Self.roundedMask
    material.frame = bounds
    material.autoresizingMask = [.width, .height]
    addSubview(material)
  }

  required init?(coder: NSCoder) { fatalError() }

  private static let roundedMask: NSImage = {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }()

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    material.isHidden = !dark
    layer?.backgroundColor = dark ? NSColor.clear.cgColor : NSColor.white.cgColor
    layer?.borderColor = dark ? NSColor.white.withAlphaComponent(0.1).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

/// The menu's rows: icon, title, and the Markdown it inserts.
final class SlashMenuView: NSView {
  static let padding: CGFloat = 5
  private static let rowHeight: CGFloat = 30
  private static let width: CGFloat = 250
  /// Rows shown at once; the others scroll into view.
  private static let maxRows = 10

  var items: [SlashItem] = [] {
    didSet {
      setFrameSize(NSSize(width: Self.width, height: CGFloat(items.count) * Self.rowHeight + Self.padding * 2))
      // (Shown again as the page scrolls: the same items stay where they are.)
      if items.map(\.title) != oldValue.map(\.title) { scroll(.zero) }
      needsDisplay = true
    }
  }
  var selected = 0 {
    didSet {
      // Chosen with the keyboard, it scrolls into view (not under the
      // pointer: the list would move under it).
      if !hoverSelecting { scrollToVisible(rowRect(selected).insetBy(dx: 0, dy: -Self.padding)) }
      needsDisplay = true
    }
  }
  private var hoverSelecting = false
  var onHover: ((Int) -> Void)?
  var onChoose: ((Int) -> Void)?
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(width: Self.width, height: CGFloat(items.count) * Self.rowHeight + Self.padding * 2)
  }

  /// The card's size: up to `maxRows` rows (the rest scroll).
  override var fittingSize: NSSize {
    NSSize(width: Self.width, height: CGFloat(min(items.count, Self.maxRows)) * Self.rowHeight + Self.padding * 2)
  }

  private func rowRect(_ index: Int) -> NSRect {
    NSRect(x: Self.padding, y: Self.padding + CGFloat(index) * Self.rowHeight, width: bounds.width - Self.padding * 2,
           height: Self.rowHeight)
  }

  private func row(at point: NSPoint) -> Int? {
    items.indices.first { rowRect($0).contains(point) }
  }

  override func draw(_ dirtyRect: NSRect) {
    for index in items.indices where rowRect(index).intersects(dirtyRect) {
      let item = items[index]
      let rect = rowRect(index)
      if index == selected {
        Theme.selected.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
      }
      let color = index == selected ? Theme.text : Theme.secondaryText
      if let icon = Theme.symbol(item.symbol, size: 13) {
        let tinted = icon.withSymbolConfiguration(.init(paletteColors: [color])) ?? icon
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.minX + 8 + (18 - size.width) / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      }
      if let preview = item.preview {
        let size = preview.size
        let scale = min(1, 20 / max(size.height, 1))
        let width = size.width * scale, height = size.height * scale
        preview.draw(in: NSRect(x: rect.maxX - 10 - width, y: rect.midY - height / 2, width: width, height: height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      }
      let hint = NSAttributedString(string: item.hint, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
        .foregroundColor: index == selected ? Theme.secondaryText : Theme.tertiaryText,
      ])
      let hintSize = hint.size()
      hint.draw(at: NSPoint(x: rect.maxX - 10 - hintSize.width, y: rect.midY - hintSize.height / 2))
      // Long titles (note names) end in "…" before the hint.
      let truncating = NSMutableParagraphStyle()
      truncating.lineBreakMode = .byTruncatingTail
      let title = NSAttributedString(string: item.title, attributes: [
        .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: Theme.text, .paragraphStyle: truncating,
      ])
      let titleHeight = title.size().height
      let titleWidth = rect.maxX - 10 - (hintSize.width > 0 ? hintSize.width + 12 : 0) - (rect.minX + 34)
      title.draw(with: NSRect(x: rect.minX + 34, y: rect.midY - titleHeight / 2, width: max(0, titleWidth), height: titleHeight),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseMoved(with event: NSEvent) {
    guard let index = row(at: convert(event.locationInWindow, from: nil)), index != selected else { return }
    hoverSelecting = true
    onHover?(index)
    hoverSelecting = false
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if let index = row(at: convert(event.locationInWindow, from: nil)) { onChoose?(index) }
  }
}
