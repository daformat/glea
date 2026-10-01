import AppKit
import SwiftMath

/// A LaTeX formula typeset by SwiftMath, drawn over its hidden source: `$…$`
/// in a line of text, `$$…$$` as a block of its own.
final class MathRender: NSObject {
  let image: NSImage
  /// How far the formula goes below its baseline (its last line's).
  let descent: CGFloat
  let latex: String
  let fontSize: CGFloat
  let display: Bool
  /// A formula too long for the column is broken into lines (a block):
  /// each line's part of the LaTeX, and where it's drawn (from the top left).
  let lines: [(range: NSRange, frame: NSRect)]

  var size: NSSize { image.size }
  var ascent: CGFloat { image.size.height - descent }

  private init(image: NSImage, descent: CGFloat, latex: String, fontSize: CGFloat, display: Bool,
               lines: [(range: NSRange, frame: NSRect)]) {
    self.image = image
    self.descent = descent
    self.latex = latex
    self.fontSize = fontSize
    self.display = display
    self.lines = lines
  }

  private static var cache: [String: MathRender] = [:]
  private static var failures: Set<String> = []

  /// The formula, or nil when it isn't valid LaTeX (its source shows), in
  /// the text's color for the app's appearance (SwiftMath sets its color
  /// once: notes with formulas restyle when the appearance changes).
  ///
  /// Within `maxWidth` (the column, when given): a formula too long breaks
  /// into lines before its relations and operators (`=`, `+`…), the next
  /// ones indented, and what still doesn't fit (a term too long to break)
  /// is typeset smaller, down to 70%. An inline formula that fits at 70%
  /// or more is just made smaller.
  @MainActor
  static func render(_ latex: String, display: Bool, maxWidth: CGFloat = 0, lead: Bool = false) -> MathRender? {
    // (A piece of an inline formula starting with an operator: an empty
    // symbol before it gives it its spacing as an operator.)
    if lead { return render(MathRender.lead + latex, display: display, maxWidth: maxWidth) }
    let appearance = NSApp.effectiveAppearance
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let width = maxWidth > 0 ? floor(maxWidth) : 0
    let key = (display ? "d" : "t") + (dark ? "D" : "L") + "\(Int(width)):" + latex
    if let cached = cache[key] { return cached }
    if failures.contains(key) { return nil }
    var color = Theme.text
    appearance.performAsCurrentDrawingAppearance { color = Theme.text.usingColorSpace(.sRGB) ?? Theme.text }
    let base = Theme.bodySize * (display ? 1.25 : 1.1)
    // (A line after the first starts with an operator: an empty symbol
    // before it, "{}^{}", gives it its spacing as an operator, not a sign.)
    func typeset(_ range: NSRange, _ size: CGFloat) -> (image: NSImage, descent: CGFloat)? {
      let part = (latex as NSString).substring(with: range)
      return MathTypeset.image(latex: range.location > 0 ? MathRender.lead + part : part, fontSize: size, color: color, display: display, maxWidth: 0)
    }
    let whole = NSRange(location: 0, length: (latex as NSString).length)
    guard let full = typeset(whole, base) else {
      failures.insert(key)
      return nil
    }
    var fontSize = base
    var lines = [(range: whole, image: full.image, descent: full.descent)]
    if width > 0, full.image.size.width > width {
      // A block breaks into lines; an inline formula only gets smaller (it
      // wraps with the text, see `inlinePieces`).
      let shrinks = !display
      if !shrinks, let broken = breakLines(latex, width: width, size: base, typeset: typeset) {
        lines = broken
      }
      // Still too wide: smaller, the lines broken again.
      let indent = base * 1.5
      let widest = lines.enumerated().map { $1.image.size.width + ($0 > 0 ? indent : 0) }.max() ?? 0
      if widest > width {
        fontSize = base * max(0.7, width / widest)
        if !shrinks, let broken = breakLines(latex, width: width, size: fontSize, typeset: typeset) {
          lines = broken
        } else if let small = typeset(whole, fontSize) {
          lines = [(whole, small.image, small.descent)]
        }
      }
    }
    if cache.count > 500 { cache.removeAll() }
    let render: MathRender
    if lines.count == 1 {
      let line = lines[0]
      render = MathRender(image: line.image, descent: line.descent, latex: latex, fontSize: fontSize, display: display,
                          lines: [(line.range, NSRect(origin: .zero, size: line.image.size))])
    } else {
      // Stacked, a little apart, the lines after the first indented.
      let indent = fontSize * 1.5, gap = fontSize * 0.35
      var frames: [NSRect] = []
      var y: CGFloat = 0
      for (index, line) in lines.enumerated() {
        frames.append(NSRect(x: index > 0 ? indent : 0, y: y, width: line.image.size.width, height: line.image.size.height))
        y += line.image.size.height + gap
      }
      let size = NSSize(width: ceil(frames.map(\.maxX).max() ?? 0), height: ceil(y - gap))
      let images = lines.map(\.image)
      let image = NSImage(size: size, flipped: true) { _ in
        for (picture, frame) in zip(images, frames) {
          picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        return true
      }
      render = MathRender(image: image, descent: lines.last?.descent ?? 0, latex: latex, fontSize: fontSize, display: display,
                          lines: zip(lines, frames).map { ($0.range, $1) })
    }
    cache[key] = render
    return render
  }

  /// Before a line starting with an operator: an empty symbol.
  static let lead = "{}^{}"

  /// An inline formula's pieces, each drawn on its own so the text can wrap
  /// between them like between words: split before its top-level
  /// relations and operators, where a space comes before them (the text
  /// only wraps at spaces).
  static func inlinePieces(of latex: String) -> [NSRange] {
    let s = latex as NSString
    let pieces = pieces(of: latex)
    var starts: [Int] = []
    for (index, piece) in pieces.enumerated() where index > 0 && piece.location > 0 {
      let text = s.substring(with: piece).trimmingCharacters(in: .whitespaces)
      let previous = s.substring(with: pieces[index - 1]).trimmingCharacters(in: .whitespaces)
      let spaced = [0x20, 0x09].contains(s.character(at: piece.location - 1))
      if spaced, breaks.contains(text), !breaks.contains(previous) { starts.append(piece.location) }
    }
    let bounds = [0] + starts + [s.length]
    return zip(bounds, bounds.dropFirst()).map { NSRange(location: $0, length: $1 - $0) }
  }

  /// Relations and operators a long formula breaks before.
  private static let breaks: Set<String> = [
    "=", "+", "-", "<", ">", "\\leq", "\\geq", "\\le", "\\ge", "\\neq", "\\approx", "\\equiv", "\\sim", "\\simeq",
    "\\cdot", "\\times", "\\pm", "\\mp", "\\to", "\\rightarrow", "\\Rightarrow", "\\Leftrightarrow", "\\iff", "\\implies",
  ]

  /// `latex` in lines no wider than `width` (the first one; the others are
  /// indented), broken before top-level relations and operators, each with
  /// as much as fits. Nil when it can't be broken.
  @MainActor private static func breakLines(_ latex: String, width: CGFloat, size: CGFloat,
                                            typeset: (NSRange, CGFloat) -> (image: NSImage, descent: CGFloat)?)
    -> [(range: NSRange, image: NSImage, descent: CGFloat)]? {
    let s = latex as NSString
    let pieces = pieces(of: latex)
    // Where lines may start: an operator, not right after another one
    // ("= -x") nor first.
    var starts: [Int] = []
    for (index, piece) in pieces.enumerated() where index > 0 {
      let text = s.substring(with: piece).trimmingCharacters(in: .whitespaces)
      let previous = s.substring(with: pieces[index - 1]).trimmingCharacters(in: .whitespaces)
      if breaks.contains(text), !breaks.contains(previous) { starts.append(piece.location) }
    }
    guard !starts.isEmpty else { return nil }
    let bounds = [0] + starts + [s.length]
    let indent = size * 1.5
    var lines: [(range: NSRange, image: NSImage, descent: CGFloat)] = []
    var lineStart = 0
    var best: (end: Int, image: NSImage, descent: CGFloat)?
    var index = 1
    while index < bounds.count {
      let range = NSRange(location: lineStart, length: bounds[index] - lineStart)
      let room = width - (lines.isEmpty ? 0 : indent)
      if let line = typeset(range, size), line.image.size.width <= room || best == nil {
        best = (bounds[index], line.image, line.descent)
        index += 1
        continue
      }
      // Full: the line ends at the last break that fit.
      guard let fitted = best else { return nil }
      lines.append((NSRange(location: lineStart, length: fitted.end - lineStart), fitted.image, fitted.descent))
      lineStart = fitted.end
      best = nil
    }
    if let last = best { lines.append((NSRange(location: lineStart, length: last.end - lineStart), last.image, last.descent)) }
    return lines.count > 1 ? lines : nil
  }
}

/// A piece of an inline formula, drawn where its source starts: its part of
/// the formula's LaTeX, and where that is in the note.
final class MathPiece: NSObject {
  let render: MathRender
  let latex: String
  /// The length of what was typeset before its LaTeX (`MathRender.lead`).
  let lead: Int
  let sourceStart: Int

  init(render: MathRender, latex: String, lead: Int, sourceStart: Int) {
    self.render = render
    self.latex = latex
    self.lead = lead
    self.sourceStart = sourceStart
  }
}

/// A `$$…$$` block shown as its formula, from its section's indent.
final class MathBlock: NSObject {
  let render: MathRender
  let indent: CGFloat
  let latex: String
  /// Where its LaTeX starts in the note (after the opening `$$`).
  let sourceStart: Int

  init(render: MathRender, indent: CGFloat, latex: String, sourceStart: Int) {
    self.render = render
    self.indent = indent
    self.latex = latex
    self.sourceStart = sourceStart
  }
}

// MARK: - From a click on a formula to its source

extension MathRender {
  /// The top-level pieces of `latex`, as ranges: a symbol, a command with
  /// its arguments (`\frac{a}{b}`), a `{…}` group, `\left…\right`, each
  /// with its scripts (`x^{2}`).
  static func pieces(of latex: String) -> [NSRange] {
    let s = latex as NSString
    var pieces: [NSRange] = []
    var i = 0
    func isLetter(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    /// Past the balanced group opening at `index` (`{…}` or `[…]`).
    func skipGroup(_ index: Int, open: unichar, close: unichar) -> Int {
      var depth = 0
      var j = index
      while j < s.length {
        let c = s.character(at: j)
        if c == 0x5C { j += 2; continue }
        if c == open { depth += 1 }
        if c == close {
          depth -= 1
          if depth == 0 { return j + 1 }
        }
        j += 1
      }
      return s.length
    }
    /// Past one argument: a group, a command or a character.
    func skipArgument(_ index: Int) -> Int {
      var j = index
      while j < s.length, s.character(at: j) == 0x20 { j += 1 }
      guard j < s.length else { return j }
      let c = s.character(at: j)
      if c == 0x7B { return skipGroup(j, open: 0x7B, close: 0x7D) }
      if c == 0x5C {
        j += 1
        if j < s.length, isLetter(s.character(at: j)) {
          while j < s.length, isLetter(s.character(at: j)) { j += 1 }
          return j
        }
        return min(s.length, j + 1)
      }
      return j + 1
    }
    while i < s.length {
      let c = s.character(at: i)
      if c == 0x20 || c == 0x0A || c == 0x09 {
        i += 1
        continue
      }
      // Scripts belong to the piece before them.
      if (c == 0x5E || c == 0x5F), let last = pieces.popLast() {
        let end = skipArgument(i + 1)
        pieces.append(NSRange(location: last.location, length: end - last.location))
        i = end
        continue
      }
      let start = i
      if c == 0x7B {
        i = skipGroup(i, open: 0x7B, close: 0x7D)
      } else if c == 0x5C {
        i += 1
        if i < s.length, isLetter(s.character(at: i)) {
          while i < s.length, isLetter(s.character(at: i)) { i += 1 }
          let name = s.substring(with: NSRange(location: start + 1, length: i - start - 1))
          if name == "left" {
            // Up to its \right and that delimiter.
            let right = s.range(of: "\\right", range: NSRange(location: i, length: s.length - i))
            i = right.location == NSNotFound ? s.length : min(s.length, NSMaxRange(right) + 1)
          } else if name == "begin" {
            let end = s.range(of: "\\end", range: NSRange(location: i, length: s.length - i))
            i = end.location == NSNotFound ? s.length : skipArgument(NSMaxRange(end))
          } else {
            // Its arguments: the groups right after it.
            while i < s.length, s.character(at: i) == 0x7B || s.character(at: i) == 0x5B {
              let open = s.character(at: i)
              i = skipGroup(i, open: open, close: open == 0x7B ? 0x7D : 0x5D)
            }
          }
        } else {
          i = min(s.length, i + 1)
        }
      } else {
        i += 1
      }
      pieces.append(NSRange(location: start, length: i - start))
    }
    return pieces
  }

  /// Where a click at `point` (from the formula's top left) points in its
  /// LaTeX: before or after the symbol under it, inside fractions, roots and
  /// scripts too.
  @MainActor func sourceOffset(at point: CGPoint) -> Int {
    // The line clicked (the nearest one, between them).
    guard let line = lines.min(by: { distance(point, $0.frame) < distance(point, $1.frame) }) else { return 0 }
    let part = (latex as NSString).substring(with: line.range)
    let local = CGPoint(x: point.x - line.frame.minX, y: point.y - line.frame.minY)
    if line.range.location > 0, let offset = MathHitTest.sourceOffset(latex: MathRender.lead + part, fontSize: fontSize, display: display,
                                                                     x: local.x, y: local.y) {
      return line.range.location + max(0, offset - (MathRender.lead as NSString).length)
    }
    let offset = MathHitTest.sourceOffset(latex: part, fontSize: fontSize, display: display, x: local.x, y: local.y)
      ?? MathRender.sourceOffset(in: part, display: display, x: local.x)
    return line.range.location + offset
  }

  private func distance(_ point: CGPoint, _ rect: NSRect) -> CGFloat {
    max(0, rect.minY - point.y, point.y - rect.maxY) * 4 + max(0, rect.minX - point.x, point.x - rect.maxX)
  }

  /// The same along the formula's top-level pieces only: before or after the
  /// piece under `x`, found by typesetting the source up to each piece.
  @MainActor static func sourceOffset(in latex: String, display: Bool, x: CGFloat) -> Int {
    let s = latex as NSString
    var left: CGFloat = 0
    for piece in pieces(of: latex) {
      guard let width = render(s.substring(to: NSMaxRange(piece)), display: display)?.size.width else { continue }
      if x < width {
        return x < (left + width) / 2 ? piece.location : NSMaxRange(piece)
      }
      left = width
    }
    return s.length
  }

  /// `offset` in a formula's LaTeX, in its source in the note: the same
  /// number of non-space characters after its opening dollars (the note's
  /// source may break lines and indent where the formula's doesn't).
  static func sourceLocation(of offset: Int, in latex: String, source: NSString, contentStart: Int) -> Int {
    let wanted = (latex as NSString).substring(to: offset).filter { !$0.isWhitespace }.utf16.count
    var counted = 0
    var i = contentStart
    while i < source.length, counted < wanted {
      let c = source.character(at: i)
      if !(c == 0x20 || c == 0x0A || c == 0x09) { counted += 1 }
      i += 1
    }
    // Before a symbol that follows spaces: against it, not before the
    // spaces (after a symbol, against that one).
    let text = latex as NSString
    if offset < text.length, offset == 0 || [0x20, 0x09, 0x0A].contains(text.character(at: offset - 1)) {
      while i < source.length, source.character(at: i) == 0x20 || source.character(at: i) == 0x09 { i += 1 }
    }
    return i
  }
}

// MARK: - Moving through a formula's slots

extension MarkdownTextView {
  /// Whether `location` is in math: after an odd number of `$` on its line
  /// (`$$…$$` on one line counts as two), or in a `$$` block open above it.
  func isInMath(_ location: Int) -> Bool {
    mathSpan(around: location) != nil
  }

  /// Whether `range` is inside one formula (selecting in it isn't
  /// formatting: the formatting bar stays away).
  func isInMath(_ range: NSRange) -> Bool {
    guard let span = mathSpan(around: range.location) else { return false }
    return range.location >= span.location && NSMaxRange(range) <= NSMaxRange(span)
  }

  /// The math around `location`: from its opening `$` (or `$$` line) to its
  /// closing one (or the end of the line or text, still being typed).
  private func mathSpan(around location: Int) -> NSRange? {
    let s = string as NSString
    let line = s.lineRange(for: NSRange(location: location, length: 0))
    let lineEnd = line.location + (s.substring(with: line).hasSuffix("\n") ? line.length - 1 : line.length)
    func dollars(in range: NSRange) -> [Int] {
      var found: [Int] = []
      for i in range.location..<NSMaxRange(range) where s.character(at: i) == 0x24 && (i == 0 || s.character(at: i - 1) != 0x5C) {
        found.append(i)
      }
      return found
    }
    // A `$$…$$` block on one line.
    let text = s.substring(with: NSRange(location: line.location, length: lineEnd - line.location)) as NSString
    let indent = text.length - (text as String).drop { $0 == " " || $0 == "\t" }.utf16.count
    if text.length >= indent + 2, text.substring(with: NSRange(location: indent, length: 2)) == "$$", location >= line.location + indent + 2 {
      let close = s.range(of: "$$", range: NSRange(location: location, length: lineEnd - location)).location
      let end = close == NSNotFound ? lineEnd : close
      return NSRange(location: line.location + indent + 2, length: end - line.location - indent - 2)
    }
    let before = dollars(in: NSRange(location: line.location, length: location - line.location))
    if before.count % 2 == 1, let open = before.last {
      let close = dollars(in: NSRange(location: location, length: lineEnd - location)).first ?? lineEnd
      return NSRange(location: open + 1, length: close - open - 1)
    }
    var open: Int?
    var position = 0
    for text in s.substring(to: line.location).components(separatedBy: "\n") {
      let t = text.trimmingCharacters(in: .whitespaces)
      if open != nil {
        if t.hasSuffix("$$") { open = nil }
      } else if t.hasPrefix("$$"), !(t.count > 4 && t.hasSuffix("$$")) {
        open = position + (text as NSString).length + 1
      }
      position += (text as NSString).length + 1
    }
    guard let start = open else { return nil }
    let close = s.range(of: "$$", range: NSRange(location: location, length: s.length - location)).location
    let end = close == NSNotFound ? s.length : close
    return NSRange(location: start, length: end - start)
  }

  /// Tab (⇧Tab) in math: to the next (previous) `{…}` of the formula, its
  /// content selected (`\frac{1}{|}`). Past the last one, out of the
  /// formula. Returns whether it moved.
  func moveMathSlot(forward: Bool) -> Bool {
    let selection = selectedRange()
    guard let span = mathSpan(around: selection.location) else { return false }
    let s = string as NSString
    /// The content of the group opening at `brace`.
    func group(_ brace: Int) -> NSRange {
      var depth = 0
      for i in brace..<NSMaxRange(span) {
        let c = s.character(at: i)
        if c == 0x7B { depth += 1 }
        if c == 0x7D {
          depth -= 1
          if depth == 0 { return NSRange(location: brace + 1, length: i - brace - 1) }
        }
      }
      return NSRange(location: brace + 1, length: NSMaxRange(span) - brace - 1)
    }
    let braces = (span.location..<NSMaxRange(span)).filter { s.character(at: $0) == 0x7B }
    if forward {
      if let next = braces.first(where: { $0 >= NSMaxRange(selection) }) {
        setSelectedRange(group(next))
      } else {
        // Out of it: past the closing "$", or the line.
        let end = NSMaxRange(span)
        let after = end < s.length && s.character(at: end) == 0x24 ? end + 1 : end
        setSelectedRange(NSRange(location: min(after, s.length), length: 0))
      }
    } else {
      // The group before the one the cursor is in.
      let current = braces.last { $0 < selection.location } ?? span.location
      guard let previous = braces.last(where: { $0 < current }) else { return true }
      setSelectedRange(group(previous))
    }
    return true
  }
}
