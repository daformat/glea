import AppKit

/// One line of Markdown rendered for display outside the editor (linked and
/// unlinked references): the syntax goes, the styling stays. Links show in
/// the accent color; list markers, tasks, headings and quotes become their
/// rendered look.
@MainActor
enum MarkdownPreview {
  /// Marks the span to `highlight` in the raw line (private-use characters
  /// no Markdown construct uses), so it can be found again once rendered.
  private static let highlightStart = "\u{E000}"
  private static let highlightEnd = "\u{E001}"

  static func render(_ line: String, size: CGFloat = 13, color: NSColor = Theme.secondaryText,
                     highlight: NSRange? = nil, highlightAttributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
    var raw = line as NSString
    if let highlight, NSMaxRange(highlight) <= raw.length {
      raw = raw.replacingCharacters(in: NSRange(location: highlight.upperBound, length: 0), with: highlightEnd) as NSString
      raw = raw.replacingCharacters(in: NSRange(location: highlight.location, length: 0), with: highlightStart) as NSString
    }
    var text = (raw as String).trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "\\s\\^[\\w-]+$", with: "", options: .regularExpression)
      .replacingOccurrences(of: "%%.*?%%", with: "", options: .regularExpression)
    let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]
    var attributes = base
    let result = NSMutableAttributedString()

    // A table row: its cells, separated by dots.
    if text.hasPrefix("|") {
      let cells = MarkdownStyler.tableCells(in: text as NSString).map { (text as NSString).substring(with: $0) }
      if !cells.isEmpty { text = cells.filter { !$0.isEmpty }.joined(separator: "  ·  ") }
    }
    // The line's block: heading, quote, task, list item.
    if let m = text.range(of: "^#{1,6}\\s+", options: .regularExpression) {
      text.removeSubrange(m)
      attributes[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
    }
    if let m = text.range(of: "^(>\\s?)+", options: .regularExpression) {
      text.removeSubrange(m)
      attributes[.font] = NSFontManager.shared.convert(attributes[.font] as! NSFont, toHaveTrait: .italicFontMask)
    }
    if let m = text.range(of: "^[-*+]\\s+\\[([ xX])\\]\\s+", options: .regularExpression) {
      let done = text[m].contains("x") || text[m].contains("X")
      text.removeSubrange(m)
      result.append(NSAttributedString(string: done ? "☑ " : "☐ ", attributes: base))
      if done { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    } else if let m = text.range(of: "^[-*+]\\s+", options: .regularExpression) {
      text.removeSubrange(m)
      result.append(NSAttributedString(string: "• ", attributes: base))
    } else if let m = text.range(of: "^\\d{1,9}[.)]\\s+", options: .regularExpression) {
      let number = text[m].trimmingCharacters(in: .whitespaces)
      text.removeSubrange(m)
      result.append(NSAttributedString(string: number + " ", attributes: base))
    }

    // Wrapped lines line up with the text after a list or task marker,
    // like in a note.
    let marker = result.size().width
    result.append(inline(text, attributes))
    if marker > 0 {
      let paragraph = NSMutableParagraphStyle()
      paragraph.headIndent = ceil(marker)
      result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
    }
    applyHighlight(result, highlightAttributes)
    return result
  }

  // Inline constructs, left to right; emphasis can contain links.
  private static let inlinePattern = try! NSRegularExpression(pattern: [
    "`([^`]+)`",                                               // 1 code
    "!\\[([^\\]]*)\\]\\([^)]*\\)",                             // 2 image
    "!?\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]",               // 3, 4 wiki link or embed (alias)
    "\\[([^\\]]+)\\]\\(([^)\\s]+)[^)]*\\)",                    // 5, 6 link
    "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\7",                      // 7, 8 bold
    "~~(?=\\S)(.+?)(?<=\\S)~~",                                // 9 strikethrough
    "(?<![*\\w])\\*(?=\\S)([^*]+?)(?<=\\S)\\*(?![*\\w])",      // 10 italic *
    "(?<![_\\w])_(?=\\S)([^_]+?)(?<=\\S)_(?![_\\w])",          // 11 italic _
    "\\bhttps?://[^\\s<>()\\[\\]]*[^\\s<>()\\[\\].,;:!?'\"]",  // bare URL
  ].joined(separator: "|"))

  private static func inline(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
    let ns = text as NSString
    let result = NSMutableAttributedString()
    var position = 0
    for m in inlinePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      if m.range.location > position {
        result.append(NSAttributedString(string: ns.substring(with: NSRange(location: position, length: m.range.location - position)), attributes: attributes))
      }
      position = NSMaxRange(m.range)
      func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
      var link = attributes
      link[.foregroundColor] = Theme.accent
      let font = attributes[.font] as! NSFont
      if let code = group(1) {
        var a = attributes
        a[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
        result.append(NSAttributedString(string: code, attributes: a))
      } else if m.range(at: 2).location != NSNotFound {
        let alt = group(2) ?? ""
        result.append(NSAttributedString(string: alt.isEmpty ? "Image" : alt, attributes: link))
      } else if let name = group(3) {
        // "Note#Heading" reads "Note › Heading"; "#Heading", "Heading".
        let target = WikiTarget(name)
        let anchor = target.anchor.map { $0.hasPrefix("^") ? String($0.dropFirst()) : $0 }
        let shown = anchor.map { target.name.isEmpty ? $0 : "\(target.name) › \($0)" } ?? name
        var a = link
        a[.link] = URL(string: "glea-note:" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))
        result.append(NSAttributedString(string: group(4) ?? shown, attributes: a))
      } else if let label = group(5) {
        var a = link
        a[.link] = group(6).flatMap { URL(string: $0) }
        result.append(inline(label, a))
      } else if let bold = group(8) {
        var a = attributes
        a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        result.append(inline(bold, a))
      } else if let struck = group(9) {
        var a = attributes
        a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        result.append(inline(struck, a))
      } else if let italic = group(10) ?? group(11) {
        var a = attributes
        a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        result.append(inline(italic, a))
      } else {
        var a = link
        a[.link] = URL(string: ns.substring(with: m.range))
        result.append(NSAttributedString(string: ns.substring(with: m.range), attributes: a))
      }
    }
    if position < ns.length {
      result.append(NSAttributedString(string: ns.substring(from: position), attributes: attributes))
    }
    return result
  }

  /// Applies `attributes` between the highlight markers, and removes them.
  private static func applyHighlight(_ text: NSMutableAttributedString, _ attributes: [NSAttributedString.Key: Any]) {
    let string = text.string as NSString
    let start = string.range(of: highlightStart)
    let end = string.range(of: highlightEnd)
    guard start.location != NSNotFound, end.location != NSNotFound, end.location > start.location else {
      for marker in [highlightEnd, highlightStart] {
        let r = (text.string as NSString).range(of: marker)
        if r.location != NSNotFound { text.deleteCharacters(in: r) }
      }
      return
    }
    let span = NSRange(location: NSMaxRange(start), length: end.location - NSMaxRange(start))
    // Keep each run's traits (a bold word stays bold), only the highlight's
    // own keys change.
    text.addAttributes(attributes, range: span)
    text.deleteCharacters(in: end)
    text.deleteCharacters(in: start)
  }
}
