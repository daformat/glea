import AppKit
import JavaScriptCore

/// A ```mermaid block's diagram, laid out by Pele (https://pele.run, in
/// third_party/pele) in JavaScriptCore and drawn here from its SVG. Pele's
/// SVG is a small subset (groups, paths, rects, circles, ellipses, polygons,
/// text) colored with CSS variables: they're resolved as it's drawn, to the
/// note's colors, so it follows the appearance without being laid out again.
final class MermaidDiagram: NSObject {
  fileprivate let root: SVGElement
  /// The SVG's own coordinates, drawn in `size`.
  fileprivate let viewBox: NSRect
  /// As drawn: its natural size, scaled down to fit the column.
  let size: NSSize

  fileprivate init(root: SVGElement, viewBox: NSRect, size: NSSize) {
    self.root = root
    self.viewBox = viewBox
    self.size = size
  }

  /// Draws it with its top left at `origin`, in a flipped context.
  func draw(at origin: NSPoint) {
    guard let context = NSGraphicsContext.current?.cgContext, viewBox.width > 0, viewBox.height > 0 else { return }
    context.saveGState()
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: size.width / viewBox.width, y: size.height / viewBox.height)
    context.translateBy(x: -viewBox.minX, y: -viewBox.minY)
    SVGRenderer(context: context).draw(root, style: SVGStyle())
    context.restoreGState()
  }
}

/// A ```mermaid block: its diagram, or why it can't be drawn.
final class MermaidBlock: NSObject {
  let diagram: MermaidDiagram?
  let error: String?
  let indent: CGFloat
  /// Its source (between the fences), and where it starts in the note.
  let source: String
  let sourceStart: Int

  init(diagram: MermaidDiagram?, error: String?, indent: CGFloat, source: String, sourceStart: Int) {
    self.diagram = diagram
    self.error = error
    self.indent = indent
    self.source = source
    self.sourceStart = sourceStart
  }

  /// Where a click at `point` on its diagram (from its top left) points in
  /// the note: what was clicked in its source, or else its start.
  func sourceLocation(at point: NSPoint) -> Int {
    sourceStart + (diagram?.sourceOffset(at: point, in: source) ?? 0)
  }

  static let errorFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

  /// Its error, as drawn under the source while it's edited.
  var errorText: NSAttributedString? {
    error.map { NSAttributedString(string: $0, attributes: [.font: Self.errorFont, .foregroundColor: NSColor.systemRed]) }
  }

  /// What shows under its source while it's edited: the diagram, or the error.
  func previewSize(width: CGFloat) -> NSSize {
    if let diagram { return diagram.size }
    guard let text = errorText else { return .zero }
    let bounds = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
    return NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
  }

  func drawPreview(at origin: NSPoint, width: CGFloat) {
    if let diagram { return diagram.draw(at: origin) }
    errorText?.draw(with: NSRect(origin: origin, size: NSSize(width: width, height: previewSize(width: width).height)),
                    options: [.usesLineFragmentOrigin])
  }
}

@MainActor
enum Mermaid {
  /// The language after a code fence that makes it a diagram.
  static func isDiagram(language: String) -> Bool { language.lowercased() == "mermaid" }

  static let fontSize: CGFloat = 14

  /// Renders made, by source and width (the styler asks on every pass).
  private static var cache: [String: Result<MermaidDiagram, MermaidError>] = [:]

  struct MermaidError: Error { let message: String }

  /// The diagram `source` describes, at most `maxWidth` wide.
  static func render(_ source: String, maxWidth: CGFloat) -> Result<MermaidDiagram, MermaidError> {
    let width = max(120, floor(maxWidth))
    let key = "\(Int(width))\u{0}\(source)"
    if let cached = cache[key] { return cached }
    let result = make(source, maxWidth: width)
    if cache.count > 200 { cache.removeAll() }
    cache[key] = result
    return result
  }

  private static func make(_ source: String, maxWidth: CGFloat) -> Result<MermaidDiagram, MermaidError> {
    guard let render = renderFunction else { return .failure(MermaidError(message: "Diagrams can't be drawn (Pele is missing).")) }
    let options: [String: Any] = [
      "maxWidth": maxWidth, "fontSize": fontSize, "autoDirection": false, "padding": 2,
      "fontFamily": "system-ui", "fontFamilyMono": "ui-monospace",
      // Nothing is fetched or followed from a note's diagrams.
      "links": false, "images": false,
    ]
    guard let value = render.call(withArguments: [source, options]) else {
      return .failure(MermaidError(message: "The diagram couldn't be drawn."))
    }
    if let error = value.forProperty("error"), !error.isUndefined {
      return .failure(MermaidError(message: error.toString()))
    }
    guard let svg = value.forProperty("svg")?.toString(), let root = SVGParser.parse(svg) else {
      return .failure(MermaidError(message: "The diagram couldn't be drawn."))
    }
    let box = root.attributes["viewBox"].map(SVGParser.numbers) ?? []
    let natural = NSSize(width: SVGParser.number(root.attributes["width"]) ?? 0, height: SVGParser.number(root.attributes["height"]) ?? 0)
    let viewBox = box.count == 4 ? NSRect(x: box[0], y: box[1], width: box[2], height: box[3])
                                 : NSRect(origin: .zero, size: natural)
    guard natural.width > 0, natural.height > 0 else { return .failure(MermaidError(message: "The diagram is empty.")) }
    let scale = min(1, maxWidth / natural.width)
    return .success(MermaidDiagram(root: root, viewBox: viewBox,
                                   size: NSSize(width: ceil(natural.width * scale), height: ceil(natural.height * scale))))
  }

  /// `render(source, options)` in Pele's context, returning `{svg}` or
  /// `{error}`. Made the first time a diagram is drawn.
  private static var renderFunction: JSValue? = {
    guard let url = Bundle.main.url(forResource: "pele", withExtension: "js"),
          let script = try? String(contentsOf: url, encoding: .utf8),
          let context = JSContext() else { return nil }
    context.name = "Pele"
    context.evaluateScript(script, withSourceURL: url)
    // Labels are measured with the fonts they're drawn in.
    let measure: @convention(block) (String, Double, Int) -> Double = { text, size, style in
      Double(SVGRenderer.width(of: text, font: SVGRenderer.font(size: CGFloat(size), bold: style & 1 != 0,
                                                                     italic: style & 2 != 0, mono: style & 4 != 0)))
    }
    context.setObject(measure, forKeyedSubscript: "__gleaMeasure" as NSString)
    context.evaluateScript("""
      function __gleaRender(source, options) {
        try {
          options.measurer = { width: __gleaMeasure };
          const result = pele.render(source, options);
          return { svg: result.svg };
        } catch (error) {
          return { error: String(error && error.message || error) };
        }
      }
      """)
    let function = context.objectForKeyedSubscript("__gleaRender")
    return function?.isObject == true ? function : nil
  }()
}

// MARK: - From a click on a diagram to its source

extension MermaidDiagram {
  /// What a click at `point` (from the diagram's top left, as drawn) is on:
  /// a label's text and where in it, and the ids (`data-id`) of the nodes
  /// and edges around it, innermost first.
  fileprivate func hit(at point: NSPoint) -> SVGHit? {
    guard size.width > 0, size.height > 0 else { return nil }
    let svgPoint = CGPoint(x: viewBox.minX + point.x * viewBox.width / size.width,
                           y: viewBox.minY + point.y * viewBox.height / size.height)
    var tester = SVGHitTester(point: svgPoint, tolerance: 4 * viewBox.width / size.width)
    tester.visit(root, style: SVGStyle(), transform: .identity, ids: [])
    return tester.text ?? tester.shape?.hit
  }

  /// Where a click at `point` points in `source` (the block's text): in the
  /// label clicked, at the character clicked; on a node, where it's named; on
  /// an edge, the line joining its ends. Nil when nothing there is found.
  func sourceOffset(at point: NSPoint, in source: String) -> Int? {
    guard let hit = hit(at: point) else { return nil }
    let s = source as NSString
    /// The lines (by range) that name `id`, first the ones that are its
    /// own (`id[…]`, `id(…)`, `participant id`).
    func lines(naming id: String) -> [NSRange] {
      var found: [NSRange] = []
      s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
        if wordRange(of: id, in: line) != nil { found.append(line) }
      }
      return found
    }
    /// `id` as a word in `range` (not inside a longer name).
    func wordRange(of id: String, in range: NSRange) -> NSRange? {
      var search = range
      while search.length > 0 {
        let found = s.range(of: id, options: [], range: search)
        guard found.location != NSNotFound else { return nil }
        func isWord(_ i: Int) -> Bool {
          guard i >= 0, i < s.length, let scalar = UnicodeScalar(s.character(at: i)) else { return false }
          return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
        if !isWord(found.location - 1), !isWord(NSMaxRange(found)) { return found }
        search = NSRange(location: NSMaxRange(found), length: NSMaxRange(range) - NSMaxRange(found))
      }
      return nil
    }
    /// The lines an id is about: a node's, or for an edge (`L_<from>_<to>_<n>`)
    /// the ones naming both its ends.
    func lines(about id: String) -> [NSRange] {
      let parts = id.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
      if parts.count >= 4, parts[0] == "L", Int(parts[parts.count - 1]) != nil {
        let ends = Array(parts[1..<(parts.count - 1)])
        for split in 1..<ends.count {
          let from = ends[..<split].joined(separator: "_"), to = ends[split...].joined(separator: "_")
          let both = lines(naming: from).filter { wordRange(of: to, in: $0) != nil }
          if !both.isEmpty { return both }
        }
      }
      return lines(naming: id)
    }
    if let text = hit.text, !text.isEmpty {
      var occurrences: [NSRange] = []
      var search = NSRange(location: 0, length: s.length)
      while search.length > 0 {
        let found = s.range(of: text, options: [], range: search)
        guard found.location != NSNotFound else { break }
        occurrences.append(found)
        search = NSRange(location: NSMaxRange(found), length: s.length - NSMaxRange(found))
      }
      // The one on a line about the clicked node or edge, if any.
      let preferred = hit.ids.lazy.map { id in
        occurrences.first { occurrence in lines(about: id).contains { NSLocationInRange(occurrence.location, $0) } }
      }.first { $0 != nil } ?? nil
      if let found = preferred ?? occurrences.first {
        return found.location + min(max(0, hit.offset), found.length)
      }
    }
    for id in hit.ids {
      guard let line = lines(about: id).first else { continue }
      if let word = wordRange(of: id, in: line) { return word.location }
      // An edge: its line, after its indent.
      var start = line.location
      while start < NSMaxRange(line), s.character(at: start) == 0x20 || s.character(at: start) == 0x09 { start += 1 }
      return start
    }
    return nil
  }
}

fileprivate struct SVGHit {
  var text: String?
  /// Where the click is in `text`.
  var offset = 0
  var ids: [String]
}

/// Finds what's under a point: the label it's on, or else the smallest
/// shape (an edge's line counts from a few points away).
fileprivate struct SVGHitTester {
  let point: CGPoint
  let tolerance: CGFloat
  var text: SVGHit?
  var shape: (area: CGFloat, hit: SVGHit)?

  mutating func visit(_ element: SVGElement, style inherited: SVGStyle, transform inheritedTransform: CGAffineTransform, ids inheritedIDs: [String]) {
    let (style, attributes) = SVGRenderer.style(of: element, inheriting: inherited)
    guard style.visible else { return }
    var transform = inheritedTransform
    if let value = attributes["transform"] { transform = SVGRenderer.transform(value).concatenating(transform) }
    let ids = (attributes["data-id"].map { [$0] } ?? []) + inheritedIDs
    let local = point.applying(transform.inverted())
    switch element.name {
    case "svg", "g", "a":
      for case .element(let child) in element.children { visit(child, style: style, transform: transform, ids: ids) }
    case "text":
      for chunk in SVGRenderer.layOutText(element, attributes: attributes, style: style) {
        let font = SVGRenderer.font(size: style.fontSize, bold: style.bold, italic: style.italic, mono: style.mono)
        let box = CGRect(x: chunk.x, y: chunk.baseline - font.ascender, width: chunk.width, height: font.ascender - font.descender)
        guard box.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(local) else { continue }
        let index = CTLineGetStringIndexForPosition(chunk.line, CGPoint(x: local.x - chunk.x, y: 0))
        text = SVGHit(text: chunk.text, offset: index == kCFNotFound ? 0 : index, ids: ids)
      }
    default:
      guard let path = SVGRenderer.shape(element, attributes) else { return }
      let filled = !["none", "transparent"].contains(style.fill.trimmingCharacters(in: .whitespaces).lowercased())
      let outline = path.copy(strokingWithWidth: max(style.strokeWidth, tolerance * 2), lineCap: .round, lineJoin: .round, miterLimit: 10)
      guard (filled && path.contains(local)) || outline.contains(local) else { return }
      let box = filled ? path.boundingBoxOfPath : outline.boundingBoxOfPath
      let area = box.width * box.height
      if shape == nil || area <= shape!.area { shape = (area, SVGHit(text: nil, ids: ids)) }
    }
  }
}

// MARK: - Colors

/// Pele's theme variables, in the note's colors.
private enum MermaidTheme {
  private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
  }
  private static func gray(_ white: CGFloat) -> NSColor { NSColor(white: white, alpha: 1) }

  static let colors: [String: NSColor] = [
    "bg": Theme.background,
    "fg": Theme.text,
    "muted": Theme.secondaryText,
    "line": dynamic(gray(0.45), gray(0.62)),
    "surface": dynamic(NSColor(srgbRed: 0.955, green: 0.955, blue: 0.965, alpha: 1), NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)),
    "surface-alt": dynamic(NSColor(srgbRed: 0.91, green: 0.91, blue: 0.925, alpha: 1), NSColor(srgbRed: 0.23, green: 0.23, blue: 0.245, alpha: 1)),
    "border": dynamic(gray(0.76), gray(0.36)),
    "accent": Theme.accent,
    "critical": .systemRed,
    "error": .systemRed,
  ]
  static let radius = "6px"
}

// MARK: - SVG

fileprivate final class SVGElement {
  let name: String
  let attributes: [String: String]
  var children: [SVGNode] = []

  init(name: String, attributes: [String: String]) {
    self.name = name
    self.attributes = attributes
  }
}

fileprivate enum SVGNode {
  case element(SVGElement)
  case text(String)
}

fileprivate final class SVGParser: NSObject, XMLParserDelegate {
  private var stack: [SVGElement] = []
  private var root: SVGElement?

  static func parse(_ svg: String) -> SVGElement? {
    let delegate = SVGParser()
    let parser = XMLParser(data: Data(svg.utf8))
    parser.delegate = delegate
    guard parser.parse() else { return nil }
    return delegate.root
  }

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
              attributes: [String: String] = [:]) {
    let element = SVGElement(name: name, attributes: attributes)
    stack.last?.children.append(.element(element))
    if root == nil { root = element }
    stack.append(element)
  }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    stack.removeLast()
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard let current = stack.last else { return }
    if case .text(let previous) = current.children.last {
      current.children[current.children.count - 1] = .text(previous + string)
    } else {
      current.children.append(.text(string))
    }
  }

  static func number(_ value: String?) -> CGFloat? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed
    return Double(digits).map { CGFloat($0) }
  }

  /// The numbers in a list ("0 0 10 20", "1,2 3,4", "-1-2").
  static func numbers(_ value: String) -> [CGFloat] {
    var scanner = NumberScanner(value)
    var result: [CGFloat] = []
    while let n = scanner.next() { result.append(n) }
    return result
  }
}

/// Reads numbers in SVG's terse syntax, where separators are optional
/// ("M1-2.5.5" is 1, -2.5, 0.5).
fileprivate struct NumberScanner {
  let chars: [UInt8]
  var index = 0

  init(_ string: String) { chars = Array(string.utf8) }

  var atEnd: Bool { index >= chars.count }

  mutating func skipSeparators() {
    while index < chars.count, [0x20, 0x2C, 0x0A, 0x0D, 0x09].contains(chars[index]) { index += 1 }
  }

  /// The next character if it's a letter (a path command), consumed.
  mutating func command() -> Character? {
    skipSeparators()
    guard index < chars.count else { return nil }
    let c = chars[index]
    guard (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A), c != 0x65, c != 0x45 else { return nil }
    index += 1
    return Character(UnicodeScalar(c))
  }

  /// An arc's flag: a single 0 or 1, maybe with no separator after it.
  mutating func flag() -> Bool? {
    skipSeparators()
    guard index < chars.count, chars[index] == 0x30 || chars[index] == 0x31 else { return nil }
    defer { index += 1 }
    return chars[index] == 0x31
  }

  mutating func next() -> CGFloat? {
    skipSeparators()
    let start = index
    if index < chars.count, chars[index] == 0x2B || chars[index] == 0x2D { index += 1 }
    var digits = false
    var dot = false
    while index < chars.count {
      let c = chars[index]
      if c >= 0x30 && c <= 0x39 { digits = true; index += 1 }
      else if c == 0x2E, !dot { dot = true; index += 1 }
      else { break }
    }
    guard digits else { index = start; return nil }
    if index < chars.count, chars[index] == 0x65 || chars[index] == 0x45 {
      var j = index + 1
      if j < chars.count, chars[j] == 0x2B || chars[j] == 0x2D { j += 1 }
      if j < chars.count, chars[j] >= 0x30 && chars[j] <= 0x39 {
        index = j
        while index < chars.count, chars[index] >= 0x30 && chars[index] <= 0x39 { index += 1 }
      }
    }
    return Double(String(decoding: chars[start..<index], as: UTF8.self)).map { CGFloat($0) }
  }
}

/// What an element inherits, and the CSS variables in scope.
fileprivate struct SVGStyle {
  var variables: [String: String] = [:]
  var fill = "black"
  var fillOpacity: CGFloat = 1
  var stroke = "none"
  var strokeOpacity: CGFloat = 1
  var strokeWidth: CGFloat = 1
  var lineCap = CGLineCap.butt
  var lineJoin = CGLineJoin.miter
  var dashes: [CGFloat] = []
  var color = "black"
  var fontSize: CGFloat = 16
  var bold = false
  var italic = false
  var mono = false
  var anchor = "start"
  var underline = false
  var opacity: CGFloat = 1
  var visible = true
}

fileprivate struct SVGRenderer {
  let context: CGContext

  // MARK: Styles

  /// The declarations in a `style` attribute.
  private static func declarations(_ style: String) -> [(String, String)] {
    style.split(separator: ";").compactMap { declaration in
      guard let colon = declaration.firstIndex(of: ":") else { return nil }
      let name = declaration[..<colon].trimmingCharacters(in: .whitespaces)
      let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : (name, value)
    }
  }

  /// `value` with its `var(--name, fallback)` replaced. Pele's own theme
  /// variables become `glea:<name>`, read by `color(_:)`.
  private static func resolve(_ value: String, _ variables: [String: String], depth: Int = 0) -> String {
    guard depth < 8, let start = value.range(of: "var(") else { return value }
    // Its closing parenthesis (fallbacks hold parentheses of their own).
    var level = 1
    var end = start.upperBound
    while end < value.endIndex, level > 0 {
      if value[end] == "(" { level += 1 }
      if value[end] == ")" { level -= 1 }
      if level > 0 { end = value.index(after: end) }
    }
    guard end < value.endIndex else { return value }
    let inside = value[start.upperBound..<end]
    let comma = inside.firstIndex(of: ",")
    let name = inside[..<(comma ?? inside.endIndex)].trimmingCharacters(in: .whitespaces)
    let fallback = comma.map { inside[inside.index(after: $0)...].trimmingCharacters(in: .whitespaces) }
    let replacement: String
    if let defined = variables[name] {
      replacement = resolve(defined, variables, depth: depth + 1)
    } else if name.hasPrefix("--pele-"), let themed = themed(String(name.dropFirst(7))) {
      replacement = themed
    } else {
      replacement = resolve(fallback ?? "", variables, depth: depth + 1)
    }
    let resolved = value.replacingCharacters(in: start.lowerBound...end, with: replacement)
    return resolve(resolved, variables, depth: depth + 1)
  }

  private static func themed(_ name: String) -> String? {
    if MermaidTheme.colors[name] != nil { return "glea:\(name)" }
    switch name {
    case "radius": return MermaidTheme.radius
    case "font": return "system-ui"
    case "font-mono": return "ui-monospace"
    default: return nil
    }
  }

  /// The style `element` has, from what it inherits.
  static func style(of element: SVGElement, inheriting parent: SVGStyle) -> (SVGStyle, [String: String]) {
    var style = parent
    style.opacity = 1
    var properties = element.attributes
    var custom: [(String, String)] = []
    for (name, value) in declarations(element.attributes["style"] ?? "") {
      if name.hasPrefix("--") { custom.append((name, value)) } else { properties[name] = value }
    }
    // Variables first: the element's own properties may use them.
    for (name, value) in custom { style.variables[name] = value }
    func value(_ name: String) -> String? {
      properties[name].map { resolve($0, style.variables).trimmingCharacters(in: .whitespaces) }
    }
    if let v = value("color"), v != "inherit" { style.color = v }
    if let v = value("fill"), v != "inherit" { style.fill = v }
    if let v = value("stroke"), v != "inherit" { style.stroke = v }
    if let v = value("fill-opacity").flatMap(SVGParser.number) { style.fillOpacity = v }
    if let v = value("stroke-opacity").flatMap(SVGParser.number) { style.strokeOpacity = v }
    if let v = value("opacity").flatMap(SVGParser.number) { style.opacity = v }
    if let v = value("stroke-width").flatMap(SVGParser.number) { style.strokeWidth = v }
    if let v = value("stroke-linecap") { style.lineCap = v == "round" ? .round : v == "square" ? .square : .butt }
    if let v = value("stroke-linejoin") { style.lineJoin = v == "round" ? .round : v == "bevel" ? .bevel : .miter }
    if let v = value("stroke-dasharray") { style.dashes = v == "none" ? [] : SVGParser.numbers(v) }
    if let v = value("font") {
      // The shorthand: its size ("16px sans-serif").
      if let size = v.split(separator: " ").first(where: { $0.hasSuffix("px") }).flatMap({ SVGParser.number(String($0)) }) {
        style.fontSize = size
      }
    }
    if let v = value("font-size").flatMap(SVGParser.number) { style.fontSize = v }
    if let v = value("font-weight") { style.bold = v == "bold" || v == "bolder" || (Int(v) ?? 400) >= 600 }
    if let v = value("font-style") { style.italic = v == "italic" || v == "oblique" }
    if let v = value("font-family") { style.mono = v.contains("mono") }
    if let v = value("text-anchor") { style.anchor = v }
    if let v = value("text-decoration") { style.underline = v.contains("underline") }
    if value("display") == "none" || value("visibility") == "hidden" { style.visible = false }
    return (style, properties.mapValues { resolve($0, style.variables) })
  }

  /// A paint or color: `none`, a hex or rgb() color, a named one, or one of
  /// the note's (`glea:<name>`).
  private static func color(_ value: String, current: String, opacity: CGFloat) -> CGColor? {
    var v = value.trimmingCharacters(in: .whitespaces).lowercased()
    if v == "currentcolor" { v = current.trimmingCharacters(in: .whitespaces).lowercased() }
    if v.isEmpty || v == "none" || v == "transparent" { return nil }
    var color: NSColor?
    if v.hasPrefix("glea:") {
      color = MermaidTheme.colors[String(v.dropFirst(5))]
    } else if v.hasPrefix("#") {
      var hex = String(v.dropFirst())
      if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
      if let n = UInt64(hex, radix: 16), hex.count == 6 || hex.count == 8 {
        let rgba = hex.count == 6 ? n << 8 | 0xFF : n
        color = NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                        blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
      }
    } else if v.hasPrefix("rgb") || v.hasPrefix("hsl"), let open = v.firstIndex(of: "(") {
      let parts = v[v.index(after: open)...].split(whereSeparator: { ",/ )".contains($0) }).map(String.init)
      let n = parts.map { SVGParser.number($0.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "deg", with: "")) ?? 0 }
      let alpha = n.count > 3 ? (parts[3].hasSuffix("%") ? n[3] / 100 : n[3]) : 1
      if n.count >= 3, v.hasPrefix("rgb") {
        func channel(_ i: Int) -> CGFloat { parts[i].hasSuffix("%") ? n[i] / 100 : n[i] / 255 }
        color = NSColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: alpha)
      } else if n.count >= 3 {
        let s = n[1] / 100, l = n[2] / 100
        let b = l + s * min(l, 1 - l)
        color = NSColor(hue: (n[0].truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360,
                        saturation: b == 0 ? 0 : 2 * (1 - l / b), brightness: b, alpha: alpha)
      }
    } else if let named = named[v] {
      color = NSColor(srgbRed: CGFloat(named >> 16 & 0xFF) / 255, green: CGFloat(named >> 8 & 0xFF) / 255,
                      blue: CGFloat(named & 0xFF) / 255, alpha: 1)
    }
    guard let color else { return nil }
    let resolved = color.usingColorSpace(.sRGB) ?? color
    return resolved.withAlphaComponent(resolved.alphaComponent * opacity).cgColor
  }

  private static let named: [String: UInt32] = [
    "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "yellow": 0xFFFF00,
    "orange": 0xFFA500, "purple": 0x800080, "pink": 0xFFC0CB, "gray": 0x808080, "grey": 0x808080, "brown": 0xA52A2A,
    "cyan": 0x00FFFF, "magenta": 0xFF00FF, "lime": 0x00FF00, "navy": 0x000080, "teal": 0x008080, "olive": 0x808000,
    "maroon": 0x800000, "silver": 0xC0C0C0, "gold": 0xFFD700, "violet": 0xEE82EE, "indigo": 0x4B0082,
    "lightblue": 0xADD8E6, "lightgreen": 0x90EE90, "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "darkgray": 0xA9A9A9,
    "darkgrey": 0xA9A9A9, "darkblue": 0x00008B, "darkgreen": 0x006400, "darkred": 0x8B0000, "coral": 0xFF7F50,
    "salmon": 0xFA8072, "tomato": 0xFF6347, "orchid": 0xDA70D6, "plum": 0xDDA0DD, "lavender": 0xE6E6FA,
    "beige": 0xF5F5DC, "khaki": 0xF0E68C, "tan": 0xD2B48C, "crimson": 0xDC143C, "turquoise": 0x40E0D0,
    "skyblue": 0x87CEEB, "steelblue": 0x4682B4, "slategray": 0x708090, "whitesmoke": 0xF5F5F5, "ivory": 0xFFFFF0,
  ]

  // MARK: Fonts

  static func font(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
    let key = FontKey(size: size, bold: bold, italic: italic, mono: mono)
    if let font = fonts[key] { return font }
    var font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
                    : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    fonts[key] = font
    return font
  }

  private struct FontKey: Hashable {
    let size: CGFloat
    let bold, italic, mono: Bool
  }
  private static var fonts: [FontKey: NSFont] = [:]

  static func width(of text: String, font: NSFont) -> CGFloat {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  // MARK: Drawing

  func draw(_ element: SVGElement, style inherited: SVGStyle) {
    let (style, attributes) = Self.style(of: element, inheriting: inherited)
    guard style.visible else { return }
    switch element.name {
    case "title", "desc", "defs", "style", "script", "image", "foreignObject", "clipPath", "mask", "marker":
      return
    default: break
    }
    context.saveGState()
    defer { context.restoreGState() }
    if let transform = attributes["transform"] { context.concatenate(Self.transform(transform)) }
    if style.opacity < 1 { context.setAlpha(style.opacity) }
    if style.opacity < 1, !element.children.isEmpty { context.beginTransparencyLayer(auxiliaryInfo: nil) }
    defer { if style.opacity < 1, !element.children.isEmpty { context.endTransparencyLayer() } }
    switch element.name {
    case "svg", "g", "a":
      for case .element(let child) in element.children { draw(child, style: style) }
    case "text":
      drawText(element, attributes: attributes, style: style)
    default:
      if let shape = Self.shape(element, attributes) { paint(shape, style) }
    }
  }

  /// The outline of a rect, circle, ellipse, line, polygon or path.
  static func shape(_ element: SVGElement, _ attributes: [String: String]) -> CGPath? {
    func n(_ name: String) -> CGFloat { SVGParser.number(attributes[name]) ?? 0 }
    switch element.name {
    case "rect":
      let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
      guard rect.width > 0, rect.height > 0 else { return nil }
      var rx = SVGParser.number(attributes["rx"]), ry = SVGParser.number(attributes["ry"])
      if rx == nil { rx = ry }
      if ry == nil { ry = rx }
      let cw = min(max(0, rx ?? 0), rect.width / 2), ch = min(max(0, ry ?? 0), rect.height / 2)
      return cw > 0 && ch > 0 ? CGPath(roundedRect: rect, cornerWidth: cw, cornerHeight: ch, transform: nil) : CGPath(rect: rect, transform: nil)
    case "circle":
      let r = n("r")
      guard r > 0 else { return nil }
      return CGPath(ellipseIn: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r), transform: nil)
    case "ellipse":
      let rx = n("rx"), ry = n("ry")
      guard rx > 0, ry > 0 else { return nil }
      return CGPath(ellipseIn: CGRect(x: n("cx") - rx, y: n("cy") - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    case "line":
      let path = CGMutablePath()
      path.move(to: CGPoint(x: n("x1"), y: n("y1")))
      path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
      return path
    case "polygon", "polyline":
      let values = SVGParser.numbers(attributes["points"] ?? "")
      guard values.count >= 4 else { return nil }
      let path = CGMutablePath()
      path.addLines(between: stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) })
      if element.name == "polygon" { path.closeSubpath() }
      return path
    case "path":
      return path(attributes["d"] ?? "")
    default:
      return nil
    }
  }

  private func paint(_ path: CGPath, _ style: SVGStyle) {
    if let fill = Self.color(style.fill, current: style.color, opacity: style.fillOpacity) {
      context.addPath(path)
      context.setFillColor(fill)
      context.fillPath()
    }
    if style.strokeWidth > 0, let stroke = Self.color(style.stroke, current: style.color, opacity: style.strokeOpacity) {
      context.addPath(path)
      context.setStrokeColor(stroke)
      context.setLineWidth(style.strokeWidth)
      context.setLineCap(style.lineCap)
      context.setLineJoin(style.lineJoin)
      context.setLineDash(phase: 0, lengths: style.dashes.contains(where: { $0 > 0 }) ? style.dashes : [])
      context.strokePath()
    }
  }

  // MARK: Text

  private func drawText(_ element: SVGElement, attributes: [String: String], style: SVGStyle) {
    for chunk in Self.layOutText(element, attributes: attributes, style: style) {
      context.saveGState()
      // The context is flipped: glyphs are flipped back.
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: chunk.x, y: chunk.baseline)
      CTLineDraw(chunk.line, context)
      context.restoreGState()
    }
  }

  struct TextChunk {
    let line: CTLine
    let text: String
    let x: CGFloat
    let width: CGFloat
    let baseline: CGFloat
  }

  /// A text element's lines: runs at its position, each `tspan` with an x
  /// or a y starting a new one (anchored on its own).
  static func layOutText(_ element: SVGElement, attributes: [String: String], style: SVGStyle) -> [TextChunk] {
    var chunks: [TextChunk] = []
    var position = CGPoint(x: SVGParser.number(attributes["x"]) ?? 0, y: SVGParser.number(attributes["y"]) ?? 0)
    var runs: [(String, SVGStyle)] = []
    var chunkStart = position
    func flush() {
      guard !runs.isEmpty else { return }
      if let laidOut = layOut(runs, at: chunkStart) {
        chunks.append(TextChunk(line: laidOut.line, text: laidOut.text, x: laidOut.x, width: laidOut.width, baseline: chunkStart.y))
        position = CGPoint(x: chunkStart.x + laidOut.width, y: chunkStart.y)
      }
      runs = []
    }
    func walk(_ element: SVGElement, _ style: SVGStyle) {
      for child in element.children {
        switch child {
        case .text(let text):
          let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
          if runs.isEmpty { chunkStart = position }
          runs.append((collapsed, style))
        case .element(let tspan) where tspan.name == "tspan" || tspan.name == "a":
          let (childStyle, childAttributes) = Self.style(of: tspan, inheriting: style)
          guard childStyle.visible else { continue }
          let x = SVGParser.number(childAttributes["x"]), y = SVGParser.number(childAttributes["y"])
          let dx = SVGParser.number(childAttributes["dx"]) ?? 0, dy = SVGParser.number(childAttributes["dy"]) ?? 0
          if x != nil || y != nil || dx != 0 || dy != 0 {
            flush()
            position = CGPoint(x: (x ?? position.x) + dx, y: (y ?? position.y) + dy)
            chunkStart = position
          }
          walk(tspan, childStyle)
        default:
          continue
        }
      }
    }
    walk(element, style)
    flush()
    return chunks
  }

  /// Runs as one line: its text (without the spaces at its ends, which
  /// don't count in SVG), where it starts given its anchor, and its width.
  static func layOut(_ runs: [(String, SVGStyle)], at point: CGPoint) -> (line: CTLine, text: String, x: CGFloat, width: CGFloat)? {
    let text = NSMutableAttributedString()
    for (string, style) in runs {
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font(size: style.fontSize, bold: style.bold, italic: style.italic, mono: style.mono),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(style.fill, current: style.color, opacity: style.fillOpacity) ?? CGColor.clear,
      ]
      if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      text.append(NSAttributedString(string: string, attributes: attributes))
    }
    // Spaces at the chunk's ends don't count (as in SVG).
    let trimmed = text.string.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, let range = text.string.range(of: trimmed) else { return nil }
    let line = CTLineCreateWithAttributedString(text.attributedSubstring(from: NSRange(range, in: text.string)) as CFAttributedString)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let anchor = runs.first?.1.anchor ?? "start"
    let x = anchor == "middle" ? point.x - width / 2 : anchor == "end" ? point.x - width : point.x
    return (line, trimmed, x, width)
  }

  // MARK: Geometry

  /// `translate(…) rotate(…) scale(…) matrix(…)`, applied left to right.
  static func transform(_ value: String) -> CGAffineTransform {
    var result = CGAffineTransform.identity
    var rest = Substring(value)
    while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
      let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
      let n = SVGParser.numbers(String(rest[rest.index(after: open)..<close]))
      var t = CGAffineTransform.identity
      switch name {
      case "translate" where !n.isEmpty: t = CGAffineTransform(translationX: n[0], y: n.count > 1 ? n[1] : 0)
      case "scale" where !n.isEmpty: t = CGAffineTransform(scaleX: n[0], y: n.count > 1 ? n[1] : n[0])
      case "rotate" where !n.isEmpty:
        let angle = n[0] * .pi / 180
        t = n.count >= 3
          ? CGAffineTransform(translationX: n[1], y: n[2]).rotated(by: angle).translatedBy(x: -n[1], y: -n[2])
          : CGAffineTransform(rotationAngle: angle)
      case "matrix" where n.count == 6: t = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
      case "skewX" where !n.isEmpty: t = CGAffineTransform(a: 1, b: 0, c: tan(n[0] * .pi / 180), d: 1, tx: 0, ty: 0)
      case "skewY" where !n.isEmpty: t = CGAffineTransform(a: 1, b: tan(n[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
      default: break
      }
      result = t.concatenating(result)
      rest = rest[rest.index(after: close)...]
    }
    return result
  }

  /// A path's `d`: every command, absolute and relative.
  static func path(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var scanner = NumberScanner(d)
    var current = CGPoint.zero, start = CGPoint.zero
    var lastControl: CGPoint?
    var lastCommand: Character = " "
    var command: Character?
    while !scanner.atEnd {
      if let next = scanner.command() {
        command = next
      } else if command == nil {
        break
      } else if command == "M" {
        command = "L"
      } else if command == "m" {
        command = "l"
      }
      guard let c = command else { break }
      let relative = c.isLowercase
      func point() -> CGPoint? {
        guard let x = scanner.next(), let y = scanner.next() else { return nil }
        return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
      }
      var control: CGPoint?
      switch c.uppercased() {
      case "M":
        guard let p = point() else { return path }
        path.move(to: p)
        current = p
        start = p
      case "L":
        guard let p = point() else { return path }
        if path.isEmpty { path.move(to: current) }
        path.addLine(to: p)
        current = p
      case "H":
        guard let x = scanner.next() else { return path }
        current = CGPoint(x: relative ? current.x + x : x, y: current.y)
        path.addLine(to: current)
      case "V":
        guard let y = scanner.next() else { return path }
        current = CGPoint(x: current.x, y: relative ? current.y + y : y)
        path.addLine(to: current)
      case "C":
        guard let c1 = point(), let c2 = point(), let p = point() else { return path }
        path.addCurve(to: p, control1: c1, control2: c2)
        control = c2
        current = p
      case "S":
        let c1 = "CcSs".contains(lastCommand) ? CGPoint(x: 2 * current.x - (lastControl?.x ?? current.x), y: 2 * current.y - (lastControl?.y ?? current.y)) : current
        guard let c2 = point(), let p = point() else { return path }
        path.addCurve(to: p, control1: c1, control2: c2)
        control = c2
        current = p
      case "Q":
        guard let c1 = point(), let p = point() else { return path }
        path.addQuadCurve(to: p, control: c1)
        control = c1
        current = p
      case "T":
        let c1 = "QqTt".contains(lastCommand) ? CGPoint(x: 2 * current.x - (lastControl?.x ?? current.x), y: 2 * current.y - (lastControl?.y ?? current.y)) : current
        guard let p = point() else { return path }
        path.addQuadCurve(to: p, control: c1)
        control = c1
        current = p
      case "A":
        guard let rx = scanner.next(), let ry = scanner.next(), let rotation = scanner.next(),
              let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
        addArc(to: path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
        current = p
      case "Z":
        path.closeSubpath()
        current = start
        // Z takes no numbers: a number after it would loop forever.
        command = nil
      default:
        return path
      }
      lastControl = control
      lastCommand = c
    }
    return path
  }

  /// An elliptical arc as SVG writes it (by its ends), in cubic curves.
  private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                             rotation: CGFloat, large: Bool, sweep: Bool) {
    var rx = abs(rx), ry = abs(ry)
    guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
    let phi = rotation * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var factor = sqrt(max(0, numerator / denominator))
    if large == sweep { factor = -factor }
    let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
    let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
    let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
      atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep, delta > 0 { delta -= 2 * .pi }
    if sweep, delta < 0 { delta += 2 * .pi }
    let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
    let step = delta / CGFloat(segments)
    let k = 4 / 3 * tan(step / 4)
    func pointAt(_ t: CGFloat) -> CGPoint {
      CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
    }
    func derivative(_ t: CGFloat) -> CGPoint {
      CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
    }
    var t = theta1
    for _ in 0..<segments {
      let a = pointAt(t), b = pointAt(t + step)
      let da = derivative(t), db = derivative(t + step)
      path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                    control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
      t += step
    }
  }
}
