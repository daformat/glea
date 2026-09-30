// Draws the Glea app icon: wraps the square artwork (AppIcon-artwork.png) in the
// macOS icon treatment: an 824pt rounded tile (radius 186) centered in 1024, a drop
// shadow and a hairline edge. Drawn in sRGB so the artwork's colors stay as they are.
// Rebuild: swiftc -O wrap-icon.swift -o /tmp/wrap-icon && /tmp/wrap-icon AppIcon-artwork.png AppIcon-1024.png,
// then iconutil an iconset made from it into src/resources/AppIcon.icns.
// usage: wrap-icon <artwork> <out.png>
import AppKit
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(40, 10, 160)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.draw(src, in: body)
ctx.restoreGState()
ctx.addPath(bodyPath); ctx.setStrokeColor(rgb(255, 255, 255, 0.10)); ctx.setLineWidth(2); ctx.strokePath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
