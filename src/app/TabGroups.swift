import AppKit

/// A named, colored group of tabs, shown in the tab bar as a capsule before
/// its tabs with a colored underline beneath them (like Beam's). Collapsing it
/// hides its tabs behind the capsule.
@MainActor
final class TabGroup {
  let id: UUID
  var title: String
  var colorIndex: Int
  var collapsed: Bool

  init(id: UUID = UUID(), title: String = "", colorIndex: Int, collapsed: Bool = false) {
    self.id = id
    self.title = title
    self.colorIndex = colorIndex
    self.collapsed = collapsed
  }

  var color: NSColor { TabGroupPalette.color(colorIndex) }

  /// What the capsule says: the title, with the tab count when collapsed.
  func label(count: Int) -> String {
    if collapsed { return title.isEmpty ? "\(count)" : "\(title) (\(count))" }
    return title
  }

  /// Beam's default name for an unnamed group (used when captured to a note).
  func suggestedTitle(for tabs: [Tab]) -> String {
    if !title.isEmpty { return title }
    guard let first = tabs.first else { return "Empty Tab Group" }
    let name = first.displayTitle.count > 25 ? String(first.displayTitle.prefix(25)) + "…" : first.displayTitle
    return tabs.count > 1 ? "“\(name)” & \(tabs.count - 1) more" : "“\(name)”"
  }
}

/// Tab group colors (light / dark), after Beam's palette.
enum TabGroupPalette {
  static let names = ["Red", "Yellow", "Green", "Cyan", "Blue", "Pink", "Purple", "Violet", "Gray"]
  private static let light: [UInt32] = [0xDC3F2C, 0xDA860C, 0x318909, 0x097A96, 0x1B67E5, 0xD7278C, 0xC03FCB, 0x8447D7, 0x70778C]
  private static let dark: [UInt32] = [0xFD7160, 0xFC9054, 0x79BF5B, 0x4CB2CB, 0x79ABFD, 0xE46CB0, 0xD273DA, 0xAF79F8, 0xA6AAB4]

  static var count: Int { light.count }

  static func color(_ index: Int) -> NSColor {
    let i = ((index % count) + count) % count
    return NSColor(name: nil) { appearance in
      let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark[i] : light[i]
      return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                     blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }

  /// A color no group uses yet, if any (in palette order).
  static func unused(besides used: [Int]) -> Int {
    (0..<count).first { !used.contains($0) } ?? Int.random(in: 0..<count)
  }
}

extension TabGroupPalette {
  /// A filled circle in a group's color (menus).
  static func dot(_ index: Int, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      color(index).setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
      return true
    }
    return image
  }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, action handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError() }

  @objc private func run() { handler() }
}

/// The top of a group's menu (as in Beam): its name, editable in place, and
/// its color, one of the palette's dots.
final class GroupEditorView: NSView, NSTextFieldDelegate {
  private let group: TabGroup
  private let onChange: () -> Void
  private let onDone: () -> Void
  private let field = NSTextField()
  private var dots: [NSButton] = []

  init(group: TabGroup, onChange: @escaping () -> Void, onDone: @escaping () -> Void) {
    self.group = group
    self.onChange = onChange
    self.onDone = onDone
    super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 66))
    field.stringValue = group.title
    field.placeholderString = "Name this group"
    field.font = .systemFont(ofSize: 13)
    field.focusRingType = .none
    field.bezelStyle = .roundedBezel
    field.delegate = self
    field.frame = NSRect(x: 14, y: 34, width: 222, height: 24)
    addSubview(field)
    for index in 0..<TabGroupPalette.count {
      let dot = NSButton(image: TabGroupPalette.dot(index, size: 16), target: self, action: #selector(pick(_:)))
      dot.isBordered = false
      dot.tag = index
      dot.toolTip = TabGroupPalette.names[index]
      dot.frame = NSRect(x: 14 + CGFloat(index) * 24, y: 8, width: 20, height: 20)
      dot.wantsLayer = true
      addSubview(dot)
      dots.append(dot)
    }
    updateSelection()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Type straight away.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      window.makeFirstResponder(self.field)
      self.field.currentEditor()?.selectAll(nil)
    }
  }

  private func updateSelection() {
    for dot in dots {
      let selected = dot.tag == group.colorIndex
      dot.layer?.borderWidth = selected ? 2 : 0
      dot.layer?.cornerRadius = 10
      dot.layer?.borderColor = TabGroupPalette.color(dot.tag).withAlphaComponent(0.45).cgColor
    }
  }

  @objc private func pick(_ sender: NSButton) {
    group.colorIndex = sender.tag
    updateSelection()
    onChange()
  }

  func controlTextDidChange(_ obj: Notification) {
    group.title = field.stringValue.trimmingCharacters(in: .whitespaces)
    onChange()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
      onDone()
      return true
    }
    return false
  }
}
