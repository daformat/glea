import AppKit

// Markdown formatting commands for the editor, and the floating format bar
// shown above a text selection. Every command edits the Markdown text itself
// (through the text view, so it's undoable).

extension MarkdownTextView {
  // MARK: Inline

  /// Wraps the selection in `marker` (e.g. "**"), or unwraps it if it
  /// already is. With no selection, inserts a pair and puts the cursor inside.
  func toggleInline(_ marker: String) {
    let s = string as NSString
    var selection = selectedRange()
    let m = (marker as NSString).length

    guard selection.length > 0 else {
      replace(selection, with: marker + marker, select: NSRange(location: selection.location + m, length: 0))
      return
    }
    // Markdown emphasis can't start or end with spaces: trim them out.
    while selection.length > 0, s.character(at: selection.location) == 0x20 {
      selection.location += 1
      selection.length -= 1
    }
    while selection.length > 0, s.character(at: NSMaxRange(selection) - 1) == 0x20 { selection.length -= 1 }
    let text = s.substring(with: selection)

    if isWrapped(selection, marker: marker) {
      let outer = NSRange(location: selection.location - m, length: selection.length + 2 * m)
      replace(outer, with: text, select: NSRange(location: outer.location, length: selection.length))
    } else if text.count >= 2 * marker.count, text.hasPrefix(marker), text.hasSuffix(marker) {
      let inner = (text as NSString).substring(with: NSRange(location: m, length: (text as NSString).length - 2 * m))
      replace(selection, with: inner, select: NSRange(location: selection.location, length: (inner as NSString).length))
    } else {
      replace(selection, with: marker + text + marker,
              select: NSRange(location: selection.location + m, length: selection.length))
    }
  }

  /// Whether `range` is directly surrounded by `marker` (and, for "*", not
  /// just part of a "**").
  func isWrapped(_ range: NSRange, marker: String) -> Bool {
    let s = string as NSString
    let m = (marker as NSString).length
    guard range.location >= m, NSMaxRange(range) + m <= s.length else { return false }
    let before = s.substring(with: NSRange(location: range.location - m, length: m))
    let after = s.substring(with: NSRange(location: NSMaxRange(range), length: m))
    guard before == marker, after == marker else { return false }
    if marker == "*" {
      let outerBefore = range.location - m - 1 >= 0 ? s.substring(with: NSRange(location: range.location - m - 1, length: 1)) : ""
      let outerAfter = NSMaxRange(range) + m < s.length ? s.substring(with: NSRange(location: NSMaxRange(range) + m, length: 1)) : ""
      // "***x***" is bold + italic; "**x**" alone is only bold.
      if (outerBefore == "*") != (outerAfter == "*") { return false }
      if outerBefore == "*" && outerAfter == "*" {
        let twoBefore = range.location - m - 2 >= 0 ? s.substring(with: NSRange(location: range.location - m - 2, length: 1)) : ""
        return twoBefore == "*"
      }
    }
    return true
  }

  func isInlineActive(_ marker: String) -> Bool {
    let selection = selectedRange()
    guard selection.length > 0 else { return false }
    if isWrapped(selection, marker: marker) { return true }
    let text = (string as NSString).substring(with: selection)
    return text.count > 2 * marker.count && text.hasPrefix(marker) && text.hasSuffix(marker)
  }

  /// `[selection](url)`: uses a URL from the clipboard when there is one,
  /// and selects the URL so it can be typed over.
  func insertLink() {
    let selection = selectedRange()
    let text = (string as NSString).substring(with: selection)
    let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let url = clipboard.hasPrefix("http://") || clipboard.hasPrefix("https://") ? clipboard : "https://"
    let label = text.isEmpty ? "link" : text
    let markdown = "[\(label)](\(url))"
    let urlStart = selection.location + (("[\(label)](") as NSString).length
    replace(selection, with: markdown, select: NSRange(location: urlStart, length: (url as NSString).length))
  }

  // MARK: Lines

  private var selectedLines: NSRange {
    (string as NSString).lineRange(for: selectedRange())
  }

  /// Applies `transform` to each selected line (keeping the selection on them).
  private func transformLines(_ transform: ([String]) -> [String]) {
    let range = selectedLines
    var text = (string as NSString).substring(with: range)
    let trailingNewline = text.hasSuffix("\n")
    if trailingNewline { text.removeLast() }
    let lines = transform(text.components(separatedBy: "\n"))
    let result = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    let resultLength = (result as NSString).length - (trailingNewline ? 1 : 0)
    // Put the cursor at the end of the text (after the new marker).
    let select = lines.count == 1
      ? NSRange(location: range.location + resultLength, length: 0)
      : NSRange(location: range.location, length: resultLength)
    replace(range, with: result, select: select)
  }

  private static let linePrefix = try! NSRegularExpression(pattern: "^(#{1,6} |> |- \\[[ xX]\\] |[-*+] |\\d+[.)] )")

  private func strippedPrefix(_ line: String) -> (prefix: String, body: String) {
    let ns = line as NSString
    guard let m = MarkdownTextView.linePrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
      return ("", line)
    }
    return (ns.substring(with: m.range), ns.substring(from: m.range.upperBound))
  }

  /// Turns the selected lines into `prefix` lines ("# ", "> ", "- ", "- [ ] "),
  /// or back to plain text when they all already are.
  func toggleLinePrefix(_ prefix: String) {
    transformLines { lines in
      let allHave = lines.allSatisfy { strippedPrefix($0).prefix == prefix || $0.isEmpty }
      return lines.map { line in
        if line.isEmpty && lines.count > 1 { return line }
        let body = strippedPrefix(line).body
        return allHave ? body : prefix + body
      }
    }
  }

  func linePrefixActive(_ prefix: String) -> Bool {
    let line = (string as NSString).substring(with: selectedLines)
    return strippedPrefix(line).prefix == prefix
  }

  // MARK: Tables

  /// Inserts a 3×2 table and selects the first header.
  func insertTable() {
    let selection = selectedRange()
    let s = string as NSString
    let lineStart = s.lineRange(for: NSRange(location: selection.location, length: 0)).location
    let atLineStart = selection.location == lineStart
    let prefix = (atLineStart ? "" : "\n") + (lineStart > 0 && atLineStart && s.character(at: lineStart - 1) != 0x0A ? "\n" : "")
    let table = "| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n|  |  |  |\n"
    let start = selection.location + (prefix as NSString).length + 2
    replace(selection, with: prefix + table, select: NSRange(location: start, length: 8))
  }

  /// The table row around the cursor: its range and cell content ranges.
  func tableRowAtCursor() -> (line: NSRange, cells: [NSRange])? {
    let s = string as NSString
    let lineRange = s.lineRange(for: NSRange(location: selectedRange().location, length: 0))
    var line = s.substring(with: lineRange)
    if line.hasSuffix("\n") { line.removeLast() }
    guard MarkdownStyler.isTableRow(line) else { return nil }
    let cells = MarkdownStyler.tableCells(in: line as NSString).map {
      NSRange(location: $0.location + lineRange.location, length: $0.length)
    }
    guard !cells.isEmpty else { return nil }
    return (NSRange(location: lineRange.location, length: (line as NSString).length), cells)
  }

  private func isSeparator(_ line: NSRange) -> Bool {
    MarkdownStyler.isTableSeparator((string as NSString).substring(with: line).trimmingCharacters(in: .newlines))
  }

  /// Tab / Shift-Tab move between cells; Tab in the last cell adds a row.
  func moveTableCell(forward: Bool) -> Bool {
    guard let row = tableRowAtCursor() else { return false }
    let location = selectedRange().location
    if forward {
      if let next = row.cells.first(where: { $0.location > location }) {
        setSelectedRange(next)
        return true
      }
      // Last column. An empty last row means "done with the table": remove
      // it and go back to text (like Enter on an empty row).
      let s = string as NSString
      let nextLineStart = NSMaxRange(row.line) + 1
      let isLastRow = nextLineStart >= s.length
        || !MarkdownStyler.isTableRow(s.substring(with: s.lineRange(for: NSRange(location: nextLineStart, length: 0))))
      if isLastRow && isEmptyTableRow(row) && !isHeaderRow(row) {
        leaveTable(removing: row)
        return true
      }
      // Next row (skipping the separator), or a new one.
      var lineEnd = nextLineStart
      while lineEnd < s.length {
        setSelectedRange(NSRange(location: lineEnd, length: 0))
        guard let nextRow = tableRowAtCursor() else { break }
        if isSeparator(nextRow.line) {
          lineEnd = NSMaxRange(nextRow.line) + 1
          continue
        }
        setSelectedRange(nextRow.cells[0])
        return true
      }
      setSelectedRange(NSRange(location: NSMaxRange(row.line), length: 0))
      addTableRow(after: row)
      return true
    }
    // Backwards: the previous cell in this row, else the last cell of the
    // previous row (skipping the separator row).
    let current = row.cells.lastIndex { $0.location <= location } ?? 0
    if current > 0 {
      setSelectedRange(row.cells[current - 1])
      return true
    }
    var lineStart = row.line.location
    let s = string as NSString
    while lineStart > 0 {
      let previousLine = s.lineRange(for: NSRange(location: lineStart - 1, length: 0))
      setSelectedRange(NSRange(location: previousLine.location, length: 0))
      guard let previousRow = tableRowAtCursor() else { break }
      if isSeparator(previousRow.line) {
        lineStart = previousRow.line.location
        continue
      }
      setSelectedRange(previousRow.cells[previousRow.cells.count - 1])
      return true
    }
    setSelectedRange(row.cells[0])
    return true
  }

  /// Whether the row is a table's header (the row above the separator).
  func isHeaderRow(_ row: (line: NSRange, cells: [NSRange])) -> Bool {
    let s = string as NSString
    let next = NSMaxRange(row.line) + 1
    guard next < s.length else { return false }
    return isSeparator(s.lineRange(for: NSRange(location: next, length: 0)))
  }

  /// Whether every cell of the row is empty.
  func isEmptyTableRow(_ row: (line: NSRange, cells: [NSRange])) -> Bool {
    row.cells.allSatisfy { $0.length == 0 }
  }

  /// Enter on an empty row: remove it and continue as normal text below the
  /// table (in its quote, if it's in one).
  func leaveTable(removing row: (line: NSRange, cells: [NSRange])) {
    let quote = MarkdownStyler.quotePrefix((string as NSString).substring(with: row.line))
    replace(row.line, with: quote, select: NSRange(location: row.line.location + (quote as NSString).length, length: 0))
  }

  /// Enter in a table adds an empty row below with the cursor in its first cell.
  func addTableRow(after row: (line: NSRange, cells: [NSRange])) {
    let columns = max(1, row.cells.count)
    let quote = MarkdownStyler.quotePrefix((string as NSString).substring(with: row.line))
    let newRow = "\n" + quote + "|" + String(repeating: "  |", count: columns)
    let insertAt = NSMaxRange(row.line)
    replace(NSRange(location: insertAt, length: 0), with: newRow,
            select: NSRange(location: insertAt + (quote as NSString).length + 3, length: 0))
  }

  /// Typing a header row ("| a | b |") and pressing Enter turns it into a table.
  func completeTableHeader() -> Bool {
    guard let row = tableRowAtCursor(), row.cells.count >= 2 else { return false }
    let s = string as NSString
    let line = s.substring(with: row.line)
    guard line.trimmingCharacters(in: .whitespaces).hasSuffix("|") else { return false }
    let quote = MarkdownStyler.quotePrefix(line)
    // Only when this isn't already part of a table.
    let nextStart = NSMaxRange(row.line) + 1
    if nextStart < s.length {
      let nextLine = s.lineRange(for: NSRange(location: nextStart, length: 0))
      if MarkdownStyler.isTableRow(s.substring(with: nextLine)) { return false }
    }
    if row.line.location > 0 {
      let previousLine = s.lineRange(for: NSRange(location: row.line.location - 1, length: 0))
      if MarkdownStyler.isTableRow(s.substring(with: previousLine)) { return false }
    }
    let columns = row.cells.count
    let separator = "\n" + quote + "|" + String(repeating: " --- |", count: columns)
    let empty = "\n" + quote + "|" + String(repeating: "  |", count: columns)
    let insertAt = NSMaxRange(row.line)
    replace(NSRange(location: insertAt, length: 0), with: separator + empty,
            select: NSRange(location: insertAt + (separator as NSString).length + (quote as NSString).length + 3, length: 0))
    return true
  }

  // MARK: Images (drop and paste)

  private static let imageExtensions: Set<String> = MediaDescriptor.imageExtensions.union(MediaDescriptor.videoExtensions).union(["pdf"])

  /// Markdown for images on a pasteboard (files, or image data such as a
  /// picture dragged from a web page), each copied into assets/.
  func imageMarkdown(from pasteboard: NSPasteboard, preferText: Bool = false) -> [String]? {
    // (Links relative to the note's folder, a group's or notes/.)
    imageMarkdownFromNotes(pasteboard, preferText: preferText)?.map { markdown in
      var view: NSView? = self
      while let current = view, !(current is MarkdownEditorView) { view = current.superview }
      guard let editor = view as? MarkdownEditorView else { return markdown }
      return NoteStore.rebasingLinks(in: markdown, from: NoteStore.shared.notesDirectory,
                                     to: NoteStore.shared.fileURL(for: editor.ref).deletingLastPathComponent())
    }
  }

  /// The images' Markdown, linked from notes/.
  private func imageMarkdownFromNotes(_ pasteboard: NSPasteboard, preferText: Bool) -> [String]? {
    let store = NoteStore.shared
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
      // Images, PDFs, and anything that plays (video, sound).
      let images = urls.filter { MarkdownTextView.imageExtensions.contains($0.pathExtension.lowercased()) || MediaDescriptor.isPlayable($0) }
      if !images.isEmpty && images.count == urls.count {
        return images.compactMap { url in
          guard let data = try? Data(contentsOf: url),
                let path = store.saveImageAsset(data: data, fileExtension: url.pathExtension) else { return nil }
          let alt = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "]", with: ")")
          return "![\(alt)](\(path))"
        }
      }
      if !urls.isEmpty { return nil }  // Other files: default behaviour.
    }
    // Image data (e.g. dragged from a browser or copied from Preview). When
    // pasting, text wins: some apps add a picture preview to copied text.
    if preferText && pasteboard.string(forType: .string) != nil { return nil }
    for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg")] {
      guard var data = pasteboard.data(forType: type) else { continue }
      var fileExtension = ext
      if ext == "tiff", let image = NSImage(data: data), let tiff = image.tiffRepresentation,
         let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        data = png
        fileExtension = "png"
      }
      guard let path = store.saveImageAsset(data: data, fileExtension: fileExtension) else { return nil }
      return ["![](\(path))"]
    }
    return nil
  }

  /// Inserts images at `index`, each on its own line. With `afterLine`, they
  /// go after the paragraph containing `index` (drops) instead of splitting it.
  func insertImages(_ images: [String], at index: Int, afterLine: Bool = false) {
    let s = string as NSString
    var location = min(max(0, index), s.length)
    if afterLine {
      let line = s.lineRange(for: NSRange(location: location, length: 0))
      location = NSMaxRange(line)
      if location > line.location, s.character(at: location - 1) == 0x0A { location -= 1 }
    }
    let before = location > 0 && s.character(at: location - 1) != 0x0A ? "\n" : ""
    let atEnd = location >= s.length
    let text = before + images.joined(separator: "\n") + (atEnd ? "\n" : "")
    // Leave the cursor on the line after the image(s), ready to type.
    let end = location + (text as NSString).length + (atEnd ? 0 : 1)
    window?.makeFirstResponder(self)
    replace(NSRange(location: location, length: 0), with: text, select: NSRange(location: min(end, (string as NSString).length), length: 0))
  }

  /// Whether a pasteboard holds images this editor can insert.
  static func hasImages(_ pasteboard: NSPasteboard) -> Bool {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
      return urls.allSatisfy { imageExtensions.contains($0.pathExtension.lowercased()) || MediaDescriptor.isPlayable($0) }
    }
    return pasteboard.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]) != nil
  }

  // MARK: Editing

  func replace(_ range: NSRange, with text: String, select: NSRange) {
    guard shouldChangeText(in: range, replacementString: text) else { return }
    textStorage?.replaceCharacters(in: range, with: text)
    didChangeText()
    setSelectedRange(select)
  }

  // MARK: Menu actions (Format menu)

  @objc func formatBold(_ sender: Any?) { toggleInline("**") }
  @objc func formatItalic(_ sender: Any?) { toggleInline("*") }
  @objc func formatStrikethrough(_ sender: Any?) { toggleInline("~~") }
  @objc func formatCode(_ sender: Any?) { toggleInline("`") }
  @objc func formatLink(_ sender: Any?) { insertLink() }
  @objc func formatHeading1(_ sender: Any?) { toggleLinePrefix("# ") }
  @objc func formatHeading2(_ sender: Any?) { toggleLinePrefix("## ") }
  @objc func formatHeading3(_ sender: Any?) { toggleLinePrefix("### ") }
  @objc func formatQuote(_ sender: Any?) { toggleLinePrefix("> ") }
  @objc func formatBulletList(_ sender: Any?) { toggleLinePrefix("- ") }
  @objc func formatTaskList(_ sender: Any?) { toggleLinePrefix("- [ ] ") }
  @objc func formatInsertTable(_ sender: Any?) { insertTable() }
}

// MARK: - Format bar

/// Floating bar above a selection: emphasis, code, link, headings, quote,
/// lists. Appears with a small scale-up, follows the selection, and fades.
final class FormatBar: NSView {
  private struct Item {
    let symbol: String?
    let text: String?
    let tooltip: String
    let action: (MarkdownTextView) -> Void
    let isActive: (MarkdownTextView) -> Bool
  }

  weak var textView: MarkdownTextView?
  private var buttons: [(IconButton, Item)] = []
  private let background = CALayer()
  private var visible = false
  private var hideWork: DispatchWorkItem?
  private var showWork: DispatchWorkItem?

  private let items: [Item?] = [
    Item(symbol: "bold", text: nil, tooltip: "Bold (⌘B)", action: { $0.toggleInline("**") }, isActive: { $0.isInlineActive("**") }),
    Item(symbol: "italic", text: nil, tooltip: "Italic (⌘I)", action: { $0.toggleInline("*") }, isActive: { $0.isInlineActive("*") }),
    Item(symbol: "strikethrough", text: nil, tooltip: "Strikethrough (⇧⌘X)", action: { $0.toggleInline("~~") }, isActive: { $0.isInlineActive("~~") }),
    Item(symbol: "chevron.left.forwardslash.chevron.right", text: nil, tooltip: "Code (⌘E)", action: { $0.toggleInline("`") }, isActive: { $0.isInlineActive("`") }),
    Item(symbol: "link", text: nil, tooltip: "Link (⇧⌘K)", action: { $0.insertLink() }, isActive: { _ in false }),
    nil,
    Item(symbol: "textformat.size.larger", text: nil, tooltip: "Heading 1 (⌥⌘1)", action: { $0.toggleLinePrefix("# ") }, isActive: { $0.linePrefixActive("# ") }),
    Item(symbol: "textformat.size", text: nil, tooltip: "Heading 2 (⌥⌘2)", action: { $0.toggleLinePrefix("## ") }, isActive: { $0.linePrefixActive("## ") }),
    Item(symbol: "text.quote", text: nil, tooltip: "Quote (⇧⌘.)", action: { $0.toggleLinePrefix("> ") }, isActive: { $0.linePrefixActive("> ") }),
    Item(symbol: "list.bullet", text: nil, tooltip: "Bulleted list (⇧⌘8)", action: { $0.toggleLinePrefix("- ") }, isActive: { $0.linePrefixActive("- ") }),
    Item(symbol: "checklist", text: nil, tooltip: "Task list (⇧⌘9)", action: { $0.toggleLinePrefix("- [ ] ") }, isActive: { $0.linePrefixActive("- [ ] ") }),
  ]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    background.cornerRadius = 9
    background.cornerCurve = .continuous
    background.borderWidth = 0.5
    background.shadowOpacity = 0.18
    background.shadowRadius = 12
    background.shadowOffset = CGSize(width: 0, height: -4)
    layer?.addSublayer(background)

    var x: CGFloat = 5
    for item in items {
      guard let item else {
        let divider = NSBox()
        divider.boxType = .separator
        divider.frame = NSRect(x: x + 3, y: 8, width: 1, height: 18)
        addSubview(divider)
        x += 8
        continue
      }
      let button = IconButton(symbol: item.symbol ?? "textformat", size: 13, tooltip: item.tooltip, target: self, action: #selector(buttonPressed(_:)))
      button.translatesAutoresizingMaskIntoConstraints = true
      button.frame = NSRect(x: x, y: 3, width: 28, height: 28)
      addSubview(button)
      buttons.append((button, item))
      x += 28
    }
    frame.size = NSSize(width: x + 5, height: 34)
    alphaValue = 0
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    Motion.withoutAnimation {
      background.frame = bounds
      background.backgroundColor = resolvedCGColor(Theme.background)
      background.borderColor = resolvedCGColor(Theme.separator)
    }
  }

  @objc private func buttonPressed(_ sender: IconButton) {
    guard let textView, let item = buttons.first(where: { $0.0 === sender })?.1 else { return }
    item.action(textView)
    refreshStates()
    DispatchQueue.main.async { self.reposition(animated: true) }
  }

  private func refreshStates() {
    guard let textView else { return }
    for (button, item) in buttons { button.isActive = item.isActive(textView) }
  }

  /// Called on every selection change of the editor.
  func selectionChanged() {
    guard let textView else { return }
    let selection = textView.selectedRange()
    showWork?.cancel()
    // (In a formula, code, an embed's target…: not text to format.)
    if selection.length == 0 || textView.hasMarkedText() || !textView.allowsFormatting(selection) {
      hideWork?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self, let textView = self.textView,
              textView.selectedRange().length == 0 || !textView.allowsFormatting(textView.selectedRange()) else { return }
        self.hide()
      }
      hideWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
      return
    }
    hideWork?.cancel()
    // Already showing and not dragging: follow the selection right away
    // (e.g. extending it with Shift-arrows).
    if visible && NSEvent.pressedMouseButtons == 0 {
      refreshStates()
      reposition(animated: true)
      return
    }
    // Otherwise wait for the mouse to come up so the bar doesn't chase a drag.
    let work = DispatchWorkItem { [weak self] in self?.showIfSelected() }
    showWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (NSEvent.pressedMouseButtons != 0 ? 0.25 : 0.12), execute: work)
  }

  private func showIfSelected() {
    guard let textView, textView.selectedRange().length > 0, textView.allowsFormatting(textView.selectedRange()) else { return }
    if NSEvent.pressedMouseButtons != 0 {
      selectionChanged()
      return
    }
    refreshStates()
    if visible {
      reposition(animated: true)
    } else {
      show()
    }
  }

  private func targetFrame() -> NSRect? {
    guard let textView, let host = superview, let window = textView.window else { return nil }
    let screenRect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
    guard screenRect != .zero else { return nil }
    let windowRect = window.convertFromScreen(screenRect)
    let rect = host.convert(windowRect, from: nil)
    // Above the selection (below it if that would hit the top bar). The host
    // (the window's content view) isn't flipped: y grows upwards.
    let topLimit = host.bounds.height - Theme.topBarHeight - 6
    var y = rect.maxY + 8
    if y + frame.height > topLimit { y = rect.minY - frame.height - 8 }
    let x = min(max(8, rect.midX - frame.width / 2), host.bounds.width - frame.width - 8)
    return NSRect(origin: NSPoint(x: x, y: y), size: frame.size)
  }

  private func show() {
    guard let target = targetFrame() else { return }
    hideWork?.cancel()
    visible = true
    frame = target
    isHidden = false
    alphaValue = 1
    animateIn(scale: 0.94, offsetY: 4, fade: 0.1, duration: 0.2, timing: Motion.easeOut)
  }

  func reposition(animated: Bool) {
    guard visible, let target = targetFrame(), target != frame else { return }
    if animated { springFrame(to: target, stiffness: 520, damping: 40) } else { frame = target }
  }

  func hide() {
    guard visible else { return }
    visible = false
    animateOut(scale: 0.96, offsetY: 3, fade: 0.1, duration: 0.14) { [weak self] in
      guard let self, !self.visible else { return }
      self.isHidden = true
      self.layer?.removeAllAnimations()
    }
  }
}
