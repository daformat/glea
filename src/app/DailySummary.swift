import AppKit

/// The top of today's journal: what you worked on and read on the last day
/// you used Glea, and where to pick up (after Beam's daily summary). It's
/// drawn by the app, not written into the journal's Markdown.
final class DailySummaryView: NSView {
  weak var navigator: NoteNavigator?
  var onHide: (() -> Void)?

  /// The day it was hidden for: it comes back the next day.
  static var hiddenOn: String? {
    get { UserDefaults.standard.string(forKey: "dailySummaryHiddenOn") }
    set { UserDefaults.standard.set(newValue, forKey: "dailySummaryHiddenOn") }
  }

  private let stack = NSStackView()

  init(summary: ActivityLog.Summary) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 10

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    stack.pinEdges(to: self, insets: NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16))

    addHeader(for: summary.day)

    var pickUp: [NSView] = []
    if let note = summary.continueNote, let ref = NoteStore.shared.resolve(linkName: note.name) {
      pickUp.append(row(note.name, bold: true, detail: "last edited \(time(note.lastEdit))") { [weak self] in
        self?.navigator?.openNote(ref)
      })
    }
    if let page = summary.continuePage, let url = URL(string: page.url) {
      pickUp.append(row(page.title.isEmpty ? page.url : page.title, bold: true, detail: pageDetail(page)) { [weak self] in
        self?.navigator?.openLink(url)
      })
    }
    addSection("Pick up where you left off", pickUp)

    let continued = Set([summary.continueNote?.name].compactMap { $0 })
    addSection("Worked on", summary.notes.filter { !continued.contains($0.name) }.prefix(5).compactMap { note in
      guard let ref = NoteStore.shared.resolve(linkName: note.name) else { return nil }
      return row(note.name, detail: workDetail(note)) { [weak self] in self?.navigator?.openNote(ref) }
    })
    addSection("Read", summary.pages.filter { $0.url != summary.continuePage?.url }.prefix(5).compactMap { page in
      guard let url = URL(string: page.url) else { return nil }
      return row(page.title.isEmpty ? page.url : page.title, detail: pageDetail(page)) { [weak self] in
        self?.navigator?.openLink(url)
      }
    })
    if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(0, after: last) }
    updateColors()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Whether there's anything to show under the header.
  var hasContent: Bool { stack.arrangedSubviews.count > 1 }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    layer?.backgroundColor = resolvedCGColor(Theme.codeBackground)
  }

  // MARK: Building

  /// "YESTERDAY", or the weekday when the last active day was earlier, and
  /// a Hide button that shows while the pointer is over the header.
  private func addHeader(for dayKey: String) {
    let date = NoteStore.dayFormatter.date(from: dayKey) ?? Date()
    let title: String
    if Calendar.current.isDateInYesterday(date) {
      title = "Yesterday"
    } else {
      let formatter = DateFormatter()
      formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
      title = formatter.string(from: date)
    }
    let label = NSTextField.label(title.uppercased(), size: 11, weight: .semibold, color: Theme.tertiaryText)
    let hide = QuietButton(title: "Hide")
    hide.onClick = { [weak self] in self?.hide() }
    hide.alphaValue = 0
    hide.isHidden = true
    let header = HoverView()
    header.translatesAutoresizingMaskIntoConstraints = false
    header.onHover = { [weak hide] hovering in hide?.fade(in: hovering) }
    header.addSubview(label)
    header.addSubview(hide)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      header.heightAnchor.constraint(equalToConstant: 20),
      hide.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: 4),
      hide.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
    ])
    stack.addArrangedSubview(header)
    header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.setCustomSpacing(10, after: header)
  }

  private func addSection(_ title: String, _ rows: [NSView]) {
    guard !rows.isEmpty else { return }
    let label = NSTextField.label(title, size: 12, weight: .medium, color: Theme.secondaryText)
    stack.addArrangedSubview(label)
    stack.setCustomSpacing(4, after: label)
    for row in rows {
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    if let last = rows.last { stack.setCustomSpacing(14, after: last) }
  }

  /// A clickable title, truncated, and a grey detail after it.
  private func row(_ title: String, bold: Bool = false, detail: String, action: @escaping () -> Void) -> NSView {
    let link = LinkLabel(title, size: 14, weight: bold ? .semibold : .regular, color: Theme.accent)
    link.lineBreakMode = .byTruncatingTail
    link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    link.onClick = action
    let info = NSTextField.label(detail, size: 12, color: Theme.tertiaryText)
    info.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(link)
    row.addSubview(info)
    NSLayoutConstraint.activate([
      link.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      link.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
      link.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
      info.leadingAnchor.constraint(equalTo: link.trailingAnchor, constant: 8),
      info.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
      info.firstBaselineAnchor.constraint(equalTo: link.firstBaselineAnchor),
    ])
    return row
  }

  // MARK: Details

  private func pageDetail(_ page: ActivityLog.Page) -> String {
    let host = URL(string: page.url)?.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? ""
    return [host, duration(page.seconds)].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private func workDetail(_ note: ActivityLog.NoteWork) -> String {
    var parts: [String] = []
    if note.captures > 0 { parts.append("\(note.captures) capture\(note.captures == 1 ? "" : "s")") }
    parts.append("last edited \(time(note.lastEdit))")
    return parts.joined(separator: " · ")
  }

  private func duration(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 1 { return "under a minute" }
    if minutes < 60 { return "\(minutes) min" }
    return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
  }

  private func time(_ date: Date) -> String {
    DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
  }

  // MARK: Hiding

  private func hide() {
    DailySummaryView.hiddenOn = NoteStore.dayFormatter.string(from: Date())
    Motion.animate(0.2, timing: Motion.easeInOut, { animator().alphaValue = 0 }, completion: { [weak self] in
      self?.onHide?()
    })
  }
}
