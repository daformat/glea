import AppKit
import SwiftMath

/// A LaTeX formula typeset by SwiftMath, drawn over its hidden source: `$…$`
/// in a line of text, `$$…$$` as a block of its own.
final class MathRender: NSObject {
  let image: NSImage
  /// How far the formula goes below its baseline.
  let descent: CGFloat
  let latex: String
  let fontSize: CGFloat
  let display: Bool

  var size: NSSize { image.size }
  var ascent: CGFloat { image.size.height - descent }

  private init(image: NSImage, descent: CGFloat, latex: String, fontSize: CGFloat, display: Bool) {
    self.image = image
    self.descent = descent
    self.latex = latex
    self.fontSize = fontSize
    self.display = display
  }

  private static var cache: [String: MathRender] = [:]
  private static var failures: Set<String> = []

  /// The formula, or nil when it isn't valid LaTeX (its source shows), in
  /// the text's color for the app's appearance (SwiftMath sets its color
  /// once: notes with formulas restyle when the appearance changes).
  @MainActor
  static func render(_ latex: String, display: Bool) -> MathRender? {
    let appearance = NSApp.effectiveAppearance
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let key = (display ? "d" : "t") + (dark ? "D:" : "L:") + latex
    if let cached = cache[key] { return cached }
    if failures.contains(key) { return nil }
    var color = Theme.text
    appearance.performAsCurrentDrawingAppearance { color = Theme.text.usingColorSpace(.sRGB) ?? Theme.text }
    let fontSize = Theme.bodySize * (display ? 1.25 : 1.1)
    var math = MathImage(latex: latex, fontSize: fontSize, textColor: color,
                         labelMode: display ? .display : .text, textAlignment: .left)
    let (error, image, layout) = math.asImage()
    guard error == nil, let image, let layout, image.size.width > 0 else {
      failures.insert(key)
      return nil
    }
    if cache.count > 500 { cache.removeAll() }
    let render = MathRender(image: image, descent: layout.descent, latex: latex, fontSize: fontSize, display: display)
    cache[key] = render
    return render
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
    MathHitTest.sourceOffset(latex: latex, fontSize: fontSize, display: display, x: point.x, y: point.y)
      ?? MathRender.sourceOffset(in: latex, display: display, x: point.x)
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
