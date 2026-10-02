import AppKit

enum Theme {
  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
  }

  static let accent = dynamic(
    light: NSColor(srgbRed: 0.33, green: 0.35, blue: 0.95, alpha: 1),
    dark: NSColor(srgbRed: 0.55, green: 0.58, blue: 1.0, alpha: 1))
  static let background = dynamic(
    light: .white,
    dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
  /// The top bar on the web: light gray in light mode (like Beam), the page's
  /// color in dark mode (like the notes).
  static let webBar = dynamic(
    light: NSColor(srgbRed: 0.951, green: 0.951, blue: 0.956, alpha: 1),
    dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
  /// The same while the window isn't focused (a slightly darker gray in light mode, like Beam).
  static let inactiveWebBar = dynamic(
    light: NSColor(srgbRed: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF3 / 255, alpha: 1),
    dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
  static let separator = dynamic(
    light: NSColor(white: 0, alpha: 0.07),
    dark: NSColor(white: 1, alpha: 0.08))
  /// Beam's active tab: the window's background (white in light mode).
  static let activeTab = dynamic(
    light: .white,
    dark: NSColor(srgbRed: 0x2B / 255, green: 0x2B / 255, blue: 0x2F / 255, alpha: 1))
  static let hover = dynamic(
    light: NSColor(white: 0, alpha: 0.05),
    dark: NSColor(white: 1, alpha: 0.07))
  static let selected = dynamic(
    light: NSColor(white: 0, alpha: 0.08),
    dark: NSColor(white: 1, alpha: 0.12))
  /// Beam's tab hairlines: hovered, active and pressed.
  static let tabStroke = dynamic(
    light: NSColor(white: 0, alpha: 0.1),
    dark: NSColor(white: 1, alpha: 0.2))
  static let activeTabStroke = dynamic(
    light: NSColor(white: 0, alpha: 0.1225),
    dark: NSColor(white: 1, alpha: 0.25))
  static let pressedTabStroke = dynamic(
    light: NSColor(white: 0, alpha: 0.1),
    dark: NSColor(white: 1, alpha: 0.45))
  static let codeBackground = dynamic(
    light: NSColor(white: 0, alpha: 0.04),
    dark: NSColor(white: 1, alpha: 0.06))
  static let searchFill = dynamic(
    light: NSColor(white: 0, alpha: 0.04),
    dark: NSColor(white: 0, alpha: 0.18))
  static let searchStroke = dynamic(
    light: NSColor(white: 0, alpha: 0.1),
    dark: NSColor(white: 1, alpha: 0.1))
  static let accentWash = dynamic(
    light: NSColor(srgbRed: 0.33, green: 0.35, blue: 0.95, alpha: 0.10),
    dark: NSColor(srgbRed: 0.55, green: 0.58, blue: 1.0, alpha: 0.18))
  /// `==highlighted==` text.
  static let highlight = dynamic(
    light: NSColor(srgbRed: 1.0, green: 0.85, blue: 0.2, alpha: 0.4),
    dark: NSColor(srgbRed: 1.0, green: 0.8, blue: 0.2, alpha: 0.3))

  /// Code block syntax colors (GitHub's palettes).
  enum Syntax {
    static let keyword = dynamic(
      light: NSColor(srgbRed: 0xCF / 255, green: 0x22 / 255, blue: 0x2E / 255, alpha: 1),
      dark: NSColor(srgbRed: 0xFF / 255, green: 0x7B / 255, blue: 0x72 / 255, alpha: 1))
    static let string = dynamic(
      light: NSColor(srgbRed: 0x0A / 255, green: 0x30 / 255, blue: 0x69 / 255, alpha: 1),
      dark: NSColor(srgbRed: 0xA5 / 255, green: 0xD6 / 255, blue: 0xFF / 255, alpha: 1))
    static let comment = dynamic(
      light: NSColor(srgbRed: 0x6E / 255, green: 0x77 / 255, blue: 0x81 / 255, alpha: 1),
      dark: NSColor(srgbRed: 0x8B / 255, green: 0x94 / 255, blue: 0x9E / 255, alpha: 1))
    static let number = dynamic(
      light: NSColor(srgbRed: 0x05 / 255, green: 0x50 / 255, blue: 0xAE / 255, alpha: 1),
      dark: NSColor(srgbRed: 0x79 / 255, green: 0xC0 / 255, blue: 0xFF / 255, alpha: 1))
    static let type = dynamic(
      light: NSColor(srgbRed: 0x95 / 255, green: 0x38 / 255, blue: 0x00 / 255, alpha: 1),
      dark: NSColor(srgbRed: 0xFF / 255, green: 0xA6 / 255, blue: 0x57 / 255, alpha: 1))
    static let function = dynamic(
      light: NSColor(srgbRed: 0x82 / 255, green: 0x50 / 255, blue: 0xDF / 255, alpha: 1),
      dark: NSColor(srgbRed: 0xD2 / 255, green: 0xA8 / 255, blue: 0xFF / 255, alpha: 1))
    static let property = dynamic(
      light: NSColor(srgbRed: 0x05 / 255, green: 0x50 / 255, blue: 0xAE / 255, alpha: 1),
      dark: NSColor(srgbRed: 0x79 / 255, green: 0xC0 / 255, blue: 0xFF / 255, alpha: 1))
    static let tag = dynamic(
      light: NSColor(srgbRed: 0x11 / 255, green: 0x63 / 255, blue: 0x29 / 255, alpha: 1),
      dark: NSColor(srgbRed: 0x7E / 255, green: 0xE7 / 255, blue: 0x87 / 255, alpha: 1))
    static let deleted = dynamic(
      light: NSColor(srgbRed: 0x82 / 255, green: 0x07 / 255, blue: 0x1E / 255, alpha: 1),
      dark: NSColor(srgbRed: 0xFF / 255, green: 0xA1 / 255, blue: 0x98 / 255, alpha: 1))
  }

  static let text = NSColor.labelColor
  static let secondaryText = NSColor.secondaryLabelColor
  static let tertiaryText = NSColor.tertiaryLabelColor

  static let bodySize: CGFloat = 15
  static let bodyFont = NSFont.systemFont(ofSize: bodySize)
  static let monoFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
  static let columnWidth: CGFloat = 700
  static let topBarHeight: CGFloat = 52
  static let tabHeight: CGFloat = 31
  /// Journal / All Notes, in the notes bar.
  static let modeButtonHeight: CGFloat = 29
  static let tabMinWidth: CGFloat = 100
  static let tabMaxWidth: CGFloat = 420

  static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: size, weight: weight))
  }
}

/// A plain flipped view, handy as a scroll view document.
class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

extension NSTextField {
  static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
  }
}

extension NSView {
  func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
      trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
      topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
      bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
    ])
  }
}
