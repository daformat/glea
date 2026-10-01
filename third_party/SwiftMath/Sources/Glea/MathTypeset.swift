import Foundation
import CoreText
import AppKit

/// (Glea) Typesets LaTeX like MathImage (left aligned, no insets), within a
/// width: a display formula breaks its lines (after relations and binary
/// operators) to stay within `maxWidth`. 0: no limit.
public enum MathTypeset {
  public static func image(latex: String, fontSize: CGFloat, color: NSColor, display: Bool,
                           maxWidth: CGFloat) -> (image: NSImage, descent: CGFloat)? {
    var error: NSError?
    guard let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil,
          let line = MTTypesetter.createLineForMathList(list.finalized, font: MathFont.latinModernFont.mtfont(size: fontSize),
                                                        style: display ? .display : .text, cramped: false, maxWidth: maxWidth)
    else { return nil }
    line.textColor = color
    let size = CGSize(width: ceil(line.width), height: ceil(line.ascent + line.descent))
    guard size.width > 0, size.height > 0 else { return nil }
    line.position = CGPoint(x: 0, y: baseline(of: line, fontSize: fontSize))
    let image = NSImage(size: size, flipped: false) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.saveGState()
      line.draw(context)
      context.restoreGState()
      return true
    }
    return (image, line.descent)
  }

  /// Where MathImage puts the baseline (y up from the image's bottom).
  static func baseline(of line: MTMathListDisplay, fontSize: CGFloat) -> CGFloat {
    let imageHeight = ceil(line.ascent + line.descent)
    let height = max(line.ascent + line.descent, fontSize / 2)
    return (imageHeight - height) / 2 + line.descent
  }
}
