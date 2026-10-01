import Foundation
import CoreText

/// (Glea) From a point of a typeset formula to its place in the LaTeX it was
/// typeset from: down into fractions, roots, scripts, limits, accents and
/// `\left…\right`, to the symbol under the point, and before or after it.
public enum MathHitTest {
  /// The UTF-16 offset in `latex` for a point of the formula as MathImage
  /// draws it (left aligned, no insets): `x` from its left edge, `y` from
  /// its top. Nil when it can't tell.
  public static func sourceOffset(latex: String, fontSize: CGFloat, display: Bool, maxWidth: CGFloat = 0,
                                  x: CGFloat, y: CGFloat) -> Int? {
    var error: NSError?
    guard let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil else { return nil }
    let finalized = list.finalized
    guard let line = MTTypesetter.createLineForMathList(finalized, font: MathFont.latinModernFont.mtfont(size: fontSize),
                                                        style: display ? .display : .text, cramped: false, maxWidth: maxWidth)
    else { return nil }
    let imageHeight = ceil(line.ascent + line.descent)
    return hit(list: line, atoms: finalized, at: CGPoint(x: x, y: imageHeight - y - MathTypeset.baseline(of: line, fontSize: fontSize)))
  }

  /// `point` in the coordinates `display` is positioned in.
  private static func hit(list display: MTMathListDisplay, atoms list: MTMathList?, at point: CGPoint) -> Int? {
    let local = CGPoint(x: point.x - display.position.x, y: point.y - display.position.y)
    let subs = display.subDisplays
    guard !subs.isEmpty else { return nil }
    func contains(_ d: MTDisplay, x: Bool, y: Bool) -> Bool {
      (!x || (local.x >= d.position.x && local.x <= d.position.x + d.width))
        && (!y || (local.y >= d.position.y - d.descent - 1 && local.y <= d.position.y + d.ascent + 1))
    }
    func isScript(_ d: MTDisplay) -> Bool { ((d as? MTMathListDisplay)?.type ?? .regular) != .regular }
    // The one under the point (a script before its base, which it
    // overlaps), or the nearest across.
    let under = subs.filter { contains($0, x: true, y: true) }
    let sub = under.first(where: isScript) ?? under.first ?? subs.first { contains($0, x: true, y: false) }
      ?? subs.min { distance(local, $0) < distance(local, $1) }!
    let atom = list?.atoms.first { $0.indexRange.location == sub.range.location }

    switch sub {
    case let line as MTCTLineDisplay:
      return hit(line: line, at: CGPoint(x: local.x - line.position.x, y: 0))
    case let fraction as MTFractionDisplay:
      let frac = atom as? MTFraction
      if let numerator = fraction.numerator, let denominator = fraction.denominator {
        let upper = local.y > (numerator.position.y - numerator.descent + denominator.position.y + denominator.ascent) / 2
        if let found = upper ? hit(list: numerator, atoms: frac?.numerator, at: local)
                             : hit(list: denominator, atoms: frac?.denominator, at: local) { return found }
      }
    case let script as MTMathListDisplay where script.type != .regular:
      // Its base: what's drawn just before it (the last symbol of a run).
      let position = subs.firstIndex { $0 === script } ?? 0
      let drawn = subs[..<position].last { !isScript($0) }
      let base = (drawn as? MTCTLineDisplay)?.atoms.last
        ?? drawn.flatMap { d in list?.atoms.first { $0.indexRange.location == d.range.location } }
      if let found = hit(list: script, atoms: script.type == .superscript ? base?.superScript : base?.subScript, at: local) { return found }
    case let inner as MTMathListDisplay:
      // `\left…\right` (its delimiters and content), or a group.
      if let found = hit(list: inner, atoms: (atom as? MTInner)?.innerList ?? list, at: local) { return found }
    case let radical as MTRadicalDisplay:
      let rad = atom as? MTRadical
      if let degree = radical.degree, let radicand = radical.radicand, local.x < radicand.position.x {
        if let found = hit(list: degree, atoms: rad?.degree, at: local) { return found }
      } else if let radicand = radical.radicand, let found = hit(list: radicand, atoms: rad?.radicand, at: local) {
        return found
      }
    case let limits as MTLargeOpLimitsDisplay:
      if let upper = limits.upperLimit, local.y > limits.position.y + (limits.nucleus?.ascent ?? 0),
         let found = hit(list: upper, atoms: atom?.superScript, at: local) { return found }
      if let lower = limits.lowerLimit, local.y < limits.position.y - (limits.nucleus?.descent ?? 0),
         let found = hit(list: lower, atoms: atom?.subScript, at: local) { return found }
    case let accent as MTAccentDisplay:
      if let accentee = accent.accentee, let found = hit(list: accentee, atoms: (atom as? MTAccent)?.innerList, at: local) { return found }
    case let line as MTLineDisplay:
      let inner = (atom as? MTOverLine)?.innerList ?? (atom as? MTUnderLine)?.innerList
      if let content = line.inner, let found = hit(list: content, atoms: inner, at: local) { return found }
    default:
      break
    }
    // A symbol on its own (∫, a delimiter…): before or after it.
    guard let range = atom?.sourceRange, range.location != NSNotFound else { return nil }
    return local.x < sub.position.x + sub.width / 2 ? range.location : NSMaxRange(range)
  }

  /// How far `p` is from `d`'s box (a formula broken over lines has
  /// pieces side by side on each).
  private static func distance(_ p: CGPoint, _ d: MTDisplay) -> CGFloat {
    let dx = p.x < d.position.x ? d.position.x - p.x : max(0, p.x - d.position.x - d.width)
    let top = d.position.y + d.ascent, bottom = d.position.y - d.descent
    let dy = p.y > top ? p.y - top : max(0, bottom - p.y)
    return dx + dy * 4
  }

  /// A run of symbols: the one under `point`, before or after it.
  private static func hit(line: MTCTLineDisplay, at point: CGPoint) -> Int? {
    // Fused atoms ("dx", "123") are made of the symbols typed.
    let atoms = line.atoms.flatMap { $0.fusedAtoms.isEmpty ? [$0] : $0.fusedAtoms }
    var index = 0
    var best: (distance: CGFloat, offset: Int)?
    for atom in atoms {
      let length = (atom.nucleus as NSString).length
      defer { index += length }
      guard atom.sourceRange.location != NSNotFound else { continue }
      let start = CTLineGetOffsetForStringIndex(line.line, index, nil)
      let end = CTLineGetOffsetForStringIndex(line.line, index + length, nil)
      for (x, offset) in [(start, atom.sourceRange.location), (end, NSMaxRange(atom.sourceRange))] {
        let d = abs(point.x - x)
        if best == nil || d < best!.distance { best = (d, offset) }
      }
    }
    return best?.offset
  }
}
