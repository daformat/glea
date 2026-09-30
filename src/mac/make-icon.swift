// Draws earlier Glea app icon concepts ("c", the viewfinder, was the icon up to 0.3.1).
// The current icon comes from wrap-icon.swift.
// Renders Glea app icon concepts at 1024×1024.
// usage: icon <concept a|b|c> <out.png>
import AppKit
import CoreGraphics
import CoreImage

let concept = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

/// Apple's icon grid: an 824pt continuous-corner squircle centered in 1024.
func squircle(_ rect: CGRect) -> CGPath {
  let path = CGMutablePath()
  let n: CGFloat = 5
  let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
  let steps = 720
  for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let c = cos(t), s = sin(t)
    let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
    let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
  }
  path.closeSubpath()
  return path
}

func linear(_ colors: [CGColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
  let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
  ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ colors: [CGColor], _ locations: [CGFloat], center: CGPoint, radius: CGFloat) {
  let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
  ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
  CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Northern lights: soft ribbons of green, teal, blue, violet and pink,
/// drawn sharp on their own layer, then blurred and screened onto the tile.
func drawAurora() {
  let layer = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  // Soft horizontal ribbons filling the tile, blurred into a gradient mesh.
  let ribbons: [(CGColor, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    // color, base height, amplitude, phase, thickness
    (rgb(40, 200, 220, 0.8), 880, 60, 5.5, 110),
    (rgb(70, 255, 170, 0.85), 730, 70, 0.0, 90),
    (rgb(40, 220, 240, 0.75), 610, 90, 1.3, 90),
    (rgb(90, 110, 255, 0.8), 470, 80, 2.4, 110),
    (rgb(160, 80, 255, 0.85), 360, 70, 3.6, 100),
    (rgb(255, 80, 190, 0.8), 240, 60, 4.8, 100),
    (rgb(120, 70, 255, 0.8), 110, 50, 0.7, 120),
  ]
  layer.setLineCap(.round)
  for (color, base, amplitude, phase, thickness) in ribbons {
    let path = CGMutablePath()
    for i in 0...120 {
      let x = -60 + CGFloat(i) / 120 * (size + 120)
      let t = x / size * 2 * .pi
      let y = base + amplitude * sin(t * 1.1 + phase) + amplitude * 0.4 * sin(t * 2.3 + phase * 1.7)
      if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    layer.addPath(path)
    layer.setStrokeColor(color)
    layer.setLineWidth(thickness)
    layer.strokePath()
    // Curtains: a faint wide halo around each ribbon.
    layer.addPath(path)
    layer.setStrokeColor(color.copy(alpha: color.alpha * 0.25)!)
    layer.setLineWidth(thickness * 3)
    layer.strokePath()
  }
  let blurred = CIImage(cgImage: layer.makeImage()!)
    .clampedToExtent()
    .applyingGaussianBlur(sigma: 72)
    .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
  let image = CIContext(options: [.workingColorSpace: space]).createCGImage(blurred, from: blurred.extent)!
  ctx.saveGState()
  ctx.setBlendMode(.screen)
  ctx.setAlpha(0.15)
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
  ctx.restoreGState()
  // Two broad pockets of night sky between the lights (no small patches).
  radial([rgb(12, 10, 24, 0.9), rgb(12, 10, 24, 0.55), rgb(12, 10, 24, 0)], [0, 0.4, 1], center: CGPoint(x: 900, y: 660), radius: 340)
  radial([rgb(12, 10, 24, 0.85), rgb(12, 10, 24, 0.5), rgb(12, 10, 24, 0)], [0, 0.4, 1], center: CGPoint(x: 110, y: 300), radius: 320)
}

/// Reads an image into RGBA floats (premultiplied, 0...1), bottom row first.
func pixels(of image: CGImage) -> [Float] {
  let w = image.width, h = image.height
  var bytes = [UInt8](repeating: 0, count: w * h * 4)
  let c = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  // CGContext memory is top row first; flip to match CG's y-up coordinates.
  var out = [Float](repeating: 0, count: w * h * 4)
  for y in 0..<h {
    for x in 0..<(w * 4) { out[(y * w * 4) + x] = Float(bytes[((h - 1 - y) * w * 4) + x]) / 255 }
  }
  return out
}

/// Apple-style Liquid Glass: clear in the middle, with a curved bezel that
/// bends the backdrop (sampling from further out, with a hint of chromatic
/// dispersion), a thin specular rim and a soft floating shadow.
func drawGlass(_ rect: CGRect, radius: CGFloat) {
  let path = rounded(rect, radius)
  let backdrop = pixels(of: ctx.makeImage()!)
  let n = Int(size)

  // Floating shadow.
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 46, color: rgb(8, 4, 24, 0.5))
  ctx.addPath(path)
  ctx.setFillColor(rgb(30, 20, 60, 1))
  ctx.fillPath()
  ctx.restoreGState()

  func sample(_ x: Double, _ y: Double, _ channel: Int) -> Float {
    let cx = min(max(x, 0), Double(n - 1)), cy = min(max(y, 0), Double(n - 1))
    let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, n - 1), y1 = min(y0 + 1, n - 1)
    let fx = Float(cx - Double(x0)), fy = Float(cy - Double(y0))
    func at(_ x: Int, _ y: Int) -> Float { backdrop[(y * n + x) * 4 + channel] }
    return (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy
  }
  // Signed distance to the rounded rectangle (negative inside).
  let c = (x: Double(rect.midX), y: Double(rect.midY))
  let half = (x: Double(rect.width / 2), y: Double(rect.height / 2)), r = Double(radius)
  func sdf(_ x: Double, _ y: Double) -> Double {
    let qx = abs(x - c.x) - (half.x - r), qy = abs(y - c.y) - (half.y - r)
    return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
  }

  let bezel = 64.0      // width of the curved rim
  let strength = 110.0  // how far the rim reaches out for light
  let magnify = 0.82    // the middle is gently magnified
  let x0 = Int(rect.minX) - 2, y0 = Int(rect.minY) - 2, w = Int(rect.width) + 4, h = Int(rect.height) + 4
  var out = [UInt8](repeating: 0, count: w * h * 4)
  for j in 0..<h {
    for i in 0..<w {
      let x = Double(x0 + i) + 0.5, y = Double(y0 + j) + 0.5
      let d = sdf(x, y)
      let coverage = min(max(0.5 - d, 0), 1)
      guard coverage > 0 else { continue }
      // Outward normal from the distance field's gradient.
      let gx = sdf(x + 1, y) - sdf(x - 1, y), gy = sdf(x, y + 1) - sdf(x, y - 1)
      let len = max(hypot(gx, gy), 1e-6)
      let nx = gx / len, ny = gy / len
      let depth = max(-d, 0)
      // Circular bezel profile: steep at the very edge, flat inside.
      let t = max(0, 1 - depth / bezel)
      let bend = strength * (1 - sqrt(max(0, 1 - t * t)))
      let bx = c.x + (x - c.x) * magnify, by = c.y + (y - c.y) * magnify
      var rgba = [Float](repeating: 0, count: 3)
      for (channel, dispersion) in [(0, 1.08), (1, 1.0), (2, 0.9)] {
        rgba[channel] = sample(bx + nx * bend * dispersion, by + ny * bend * dispersion, channel)
      }
      // A touch of brightness, more toward the rim where the glass is thick.
      let lift = Float(0.06 + 0.22 * t * t * t)
      let index = ((h - 1 - j) * w + i) * 4
      for k in 0..<3 {
        let v = min(1, rgba[k] + lift * (1 - rgba[k]))
        out[index + k] = UInt8(v * Float(coverage) * 255)
      }
      out[index + 3] = UInt8(coverage * 255)
    }
  }
  let provider = CGDataProvider(data: Data(out) as CFData)!
  let glass = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  ctx.draw(glass, in: CGRect(x: x0, y: y0, width: w, height: h))

  // Specular rim: a hairline catching light at top-left and bottom-right.
  ctx.saveGState()
  ctx.addPath(rounded(rect.insetBy(dx: 1.5, dy: 1.5), radius - 1.5))
  ctx.setLineWidth(3)
  ctx.replacePathWithStrokedPath()
  ctx.clip()
  linear([rgb(255, 255, 255, 1), rgb(255, 255, 255, 0.2), rgb(255, 255, 255, 0.08), rgb(255, 255, 255, 0.8)], [0, 0.38, 0.62, 1],
         from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY))
  ctx.restoreGState()
  // Inner glow along the lit edge, as light travels through the bezel.
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  // Clear glass catches light from above: a gentle top-down sheen.
  linear([rgb(255, 255, 255, 0.2), rgb(255, 255, 255, 0.0)], [0, 1], from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.midY))
  // A ring just outside the glass casts its shadow inward: light pooling
  // along the top-left bezel.
  ctx.setShadow(offset: CGSize(width: 7, height: -7), blur: 16, color: rgb(255, 255, 255, 0.75))
  ctx.addPath(rounded(rect.insetBy(dx: -40, dy: -40), radius + 40))
  ctx.addPath(path)
  ctx.setFillColor(rgb(255, 255, 255, 1))
  ctx.fillPath(using: .evenOdd)
  ctx.restoreGState()
  // And a softer bounce on the opposite edge.
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  ctx.setShadow(offset: CGSize(width: -5, height: 5), blur: 14, color: rgb(255, 255, 255, 0.35))
  ctx.addPath(rounded(rect.insetBy(dx: -40, dy: -40), radius + 40))
  ctx.addPath(path)
  ctx.fillPath(using: .evenOdd)
  ctx.restoreGState()
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile (part of the macOS icon look).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(20, 18, 34))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()

// Background: deep ink with a violet glow rising from the bottom.
linear([rgb(30, 26, 52), rgb(12, 11, 20)], [0, 1], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

switch concept {
case "a":
  // A note page, and the purple point-and-shoot wash landing on it.
  radial([rgb(112, 88, 255, 0.45), rgb(112, 88, 255, 0)], [0, 1], center: CGPoint(x: 600, y: 380), radius: 520)
  let page = CGRect(x: 262, y: 300, width: 400, height: 470)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: rgb(0, 0, 0, 0.4))
  ctx.addPath(rounded(page, 56))
  ctx.setFillColor(rgb(245, 244, 250))
  ctx.fillPath()
  ctx.restoreGState()
  // Lines of text.
  ctx.setFillColor(rgb(40, 36, 60, 0.20))
  for (i, w) in [260.0, 310, 220].enumerated() {
    ctx.addPath(rounded(CGRect(x: 318, y: 680 - CGFloat(i) * 56, width: CGFloat(w), height: 22), 11))
    ctx.fillPath()
  }
  // The capture: a translucent violet block over the lower half.
  let wash = CGRect(x: 360, y: 250, width: 400, height: 260)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 60, color: rgb(90, 60, 255, 0.55))
  ctx.addPath(rounded(wash, 48))
  ctx.clip()
  linear([rgb(150, 125, 255, 0.92), rgb(98, 70, 255, 0.92)], [0, 1], from: CGPoint(x: 360, y: 510), to: CGPoint(x: 760, y: 250))
  ctx.restoreGState()
  ctx.addPath(rounded(wash, 48))
  ctx.setStrokeColor(rgb(255, 255, 255, 0.22))
  ctx.setLineWidth(3)
  ctx.strokePath()

case "b":
  // A beam of light crossing the tile, landing on a glowing block.
  ctx.saveGState()
  ctx.translateBy(x: 512, y: 512)
  ctx.rotate(by: -.pi / 4)
  let beam = CGRect(x: -700, y: -46, width: 1400, height: 92)
  ctx.addPath(rounded(beam, 46))
  ctx.clip()
  linear([rgb(112, 88, 255, 0), rgb(130, 105, 255, 0.9), rgb(255, 255, 255, 1)], [0, 0.55, 1],
         from: CGPoint(x: -620, y: 0), to: CGPoint(x: 40, y: 0))
  ctx.restoreGState()
  radial([rgb(255, 255, 255, 0.9), rgb(160, 140, 255, 0.5), rgb(112, 88, 255, 0)], [0, 0.25, 1],
         center: CGPoint(x: 540, y: 484), radius: 300)
  let block = CGRect(x: 470, y: 250, width: 300, height: 300)
  ctx.saveGState()
  ctx.setShadow(offset: .zero, blur: 70, color: rgb(120, 95, 255, 0.9))
  ctx.addPath(rounded(block, 70))
  ctx.setFillColor(rgb(122, 98, 255, 0.55))
  ctx.fillPath()
  ctx.restoreGState()

case "c":
  // A viewfinder: four soft corner brackets framing a glowing tile, over
  // an aurora of drifting ribbons.
  drawAurora()
  let inner = CGRect(x: 392, y: 392, width: 240, height: 240)
  drawGlass(inner, radius: 66)
  // Brackets.
  let frame = CGRect(x: 272, y: 272, width: 480, height: 480)
  let r: CGFloat = 92, arm: CGFloat = 132
  ctx.setStrokeColor(rgb(255, 255, 255, 0.9))
  ctx.setLineWidth(24)
  ctx.setLineCap(.round)
  let corners: [(CGPoint, CGFloat, CGFloat)] = [
    (CGPoint(x: frame.minX, y: frame.maxY), 1, -1), (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
    (CGPoint(x: frame.minX, y: frame.minY), 1, 1), (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
  ]
  for (p, sx, sy) in corners {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: p.x, y: p.y + sy * arm))
    path.addArc(tangent1End: p, tangent2End: CGPoint(x: p.x + sx * arm, y: p.y), radius: r)
    path.addLine(to: CGPoint(x: p.x + sx * arm, y: p.y))
    ctx.addPath(path)
    ctx.strokePath()
  }

case "d":
  // A beam: a light streak from the top-left corner landing on a glowing tile.
  radial([rgb(112, 88, 255, 0.5), rgb(112, 88, 255, 0)], [0, 1], center: CGPoint(x: 580, y: 440), radius: 440)
  ctx.saveGState()
  ctx.translateBy(x: 580, y: 440)
  ctx.rotate(by: .pi * 3 / 4)
  let beam = CGRect(x: 0, y: -26, width: 700, height: 52)
  ctx.addPath(rounded(beam, 26))
  ctx.clip()
  linear([rgb(255, 255, 255, 0.95), rgb(160, 140, 255, 0.55), rgb(112, 88, 255, 0)], [0, 0.35, 1],
         from: CGPoint(x: 0, y: 0), to: CGPoint(x: 620, y: 0))
  ctx.restoreGState()
  let tile = CGRect(x: 470, y: 330, width: 220, height: 220)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 80, color: rgb(120, 90, 255, 1))
  ctx.addPath(rounded(tile, 58))
  ctx.setFillColor(rgb(110, 82, 255))
  ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(rounded(tile, 58))
  ctx.clip()
  linear([rgb(200, 188, 255), rgb(120, 92, 255), rgb(92, 62, 245)], [0, 0.5, 1], from: CGPoint(x: 470, y: 550), to: CGPoint(x: 690, y: 330))
  ctx.restoreGState()

default: break
}

// A faint top highlight and edge, like glass.
linear([rgb(255, 255, 255, 0.10), rgb(255, 255, 255, 0)], [0, 1], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 640))
ctx.restoreGState()
ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.setLineWidth(2)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
