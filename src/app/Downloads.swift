import AppKit
import GleaBridge

/// This session's downloads, newest first: what the bars' downloads button
/// shows (its ring while they run) and lists.
@MainActor
final class Downloads {
  static let shared = Downloads()
  /// A download started, moved on, finished or went away.
  static let didChange = Notification.Name("GleaDownloadsDidChange")
  /// A download finished (the object is its id): the button bounces.
  static let didFinish = Notification.Name("GleaDownloadDidFinish")
  /// A download started (the object is its id): it flies to the button.
  static let didStart = Notification.Name("GleaDownloadDidStart")

  struct Item {
    enum State { case downloading, done, failed }
    let id: UInt32
    var path: String
    var received: Int64
    /// -1 while unknown.
    var total: Int64
    var state: State
    var paused = false
    /// Bytes per second, now.
    var speed: Int64 = 0
    /// Stopped from the list (rather than by an error).
    var canceled = false
    var name: String { (path as NSString).lastPathComponent }
    var fraction: Double? { total > 0 ? Double(received) / Double(total) : nil }
  }

  private(set) var items: [Item] = []

  var isDownloading: Bool { items.contains { $0.state == .downloading } }

  /// How far the running downloads are (0...1), or nil while one's size is
  /// unknown.
  var progress: Double? {
    let running = items.filter { $0.state == .downloading }
    guard !running.isEmpty, running.allSatisfy({ $0.total > 0 }) else { return nil }
    let total = running.reduce(0) { $0 + $1.total }
    return Double(running.reduce(0) { $0 + $1.received }) / Double(total)
  }

  private init() {
    NotificationCenter.default.addObserver(forName: .GleaDownloadDidUpdate, object: nil, queue: .main) { note in
      guard let download = note.object as? GleaDownload else { return }
      MainActor.assumeIsolated { Downloads.shared.update(download) }
    }
  }

  /// Starts listening (the first window does, before any download).
  static func start() { _ = shared }

  private func update(_ download: GleaDownload) {
    let state: Item.State = download.complete ? .done : download.failed ? .failed : .downloading
    var item = Item(id: download.identifier, path: download.path, received: download.receivedBytes,
                    total: download.totalBytes, state: state, paused: download.paused, speed: download.speed)
    item.canceled = canceled.contains(item.id)
    var finished = false
    var started = false
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      finished = items[index].state == .downloading && state == .done
      items[index] = item
    } else {
      // Canceled before it ever showed: nothing to list.
      guard state != .failed else { return }
      items.insert(item, at: 0)
      finished = state == .done
      started = true
    }
    NotificationCenter.default.post(name: Self.didChange, object: nil)
    if started { NotificationCenter.default.post(name: Self.didStart, object: item.id) }
    if finished { NotificationCenter.default.post(name: Self.didFinish, object: item.id) }
  }

  /// Downloads stopped from the list: they say Canceled, not Failed.
  private var canceled: Set<UInt32> = []

  func cancel(_ id: UInt32) {
    canceled.insert(id)
    GleaDownload.cancel(withIdentifier: id)
  }

  func pause(_ id: UInt32) { GleaDownload.pause(withIdentifier: id) }
  func resume(_ id: UInt32) { GleaDownload.resumeDownload(withIdentifier: id) }

  /// The list keeps only the downloads still running.
  func clear() {
    items.removeAll { $0.state != .downloading }
    NotificationCenter.default.post(name: Self.didChange, object: nil)
  }

  func open(_ item: Item) {
    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
  }

  func reveal(_ item: Item) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
  }

  func showFolder() {
    if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
      NSWorkspace.shared.open(folder)
    }
  }

  static func status(of item: Item) -> String {
    let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    switch item.state {
    case .done: return item.total > 0 ? format(item.total) : "Downloaded"
    case .failed: return item.canceled ? "Canceled" : "Failed"
    case .downloading:
      let amount = item.total > 0 ? "\(format(item.received)) of \(format(item.total))" : format(item.received)
      if item.paused { return "Paused · " + amount }
      guard item.total > 0, item.speed > 0 else { return amount }
      let left = DateComponentsFormatter()
      left.unitsStyle = .abbreviated
      left.maximumUnitCount = 1
      left.allowedUnits = [.hour, .minute, .second]
      let seconds = max(1, Double(item.total - item.received) / Double(item.speed))
      return amount + (left.string(from: seconds).map { " · \($0) left" } ?? "")
    }
  }
}

/// The downloads button's menu, a card like the extensions': each download
/// (with its progress, and buttons to pause, resume or cancel it, then to
/// open it or show it in Finder; a click opens it too), then the folder and
/// Clear. Kept up to date while it's open.
final class DownloadsMenu: OverlayView {
  private enum Row {
    case download(Downloads.Item)
    case folder, clear
  }

  private let list = PickerList(rowHeight: 32)
  private let anchor: NSRect
  private var rows: [Row] = []
  private var observer: NSObjectProtocol?

  /// `anchor` is the downloads button's rect in this view's (flipped) coordinates.
  init(anchor: NSRect) {
    self.anchor = anchor
    super.init(frame: .zero)
    list.onChoose = { [weak self] _ in self?.choose() }
    list.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(list)
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
      list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
      list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
      list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
    ])
    reload()
    list.select(0)
    observer = NotificationCenter.default.addObserver(forName: Downloads.didChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private func reload() {
    let downloads = Downloads.shared
    rows = downloads.items.map { .download($0) } + [.folder]
    if downloads.items.contains(where: { $0.state != .downloading }) { rows.append(.clear) }
    list.items = rows.enumerated().map { index, row in
      var item: PickerItem
      switch row {
      case .download(let download):
        let icon = NSWorkspace.shared.icon(forFileType: (download.name as NSString).pathExtension)
        icon.size = NSSize(width: 16, height: 16)
        item = PickerItem(icon: "doc", title: download.name, subtitle: Downloads.status(of: download), action: .open(url: ""),
                          image: icon)
        item.buttons = buttons(for: download)
        if download.state == .downloading {
          item.progress = download.fraction ?? 0
          item.height = 58
        }
      case .folder:
        item = PickerItem(icon: "folder", title: "Show Downloads Folder", subtitle: "", action: .open(url: ""))
      case .clear:
        item = PickerItem(icon: "clear", title: "Clear List", subtitle: "", action: .open(url: ""))
      }
      // The folder and the rest, under the downloads.
      item.dividerAbove = index > 0 && { if case .folder = row { return true } else { return false } }()
      return item
    }
    needsLayout = true
  }

  /// Running: pause (or resume) and cancel; done: open, and show in Finder.
  private func buttons(for item: Downloads.Item) -> [PickerButton] {
    let downloads = Downloads.shared
    switch item.state {
    case .downloading:
      return [
        item.paused
          ? PickerButton(symbol: "play.fill", tooltip: "Resume") { downloads.resume(item.id) }
          : PickerButton(symbol: "pause.fill", tooltip: "Pause") { downloads.pause(item.id) },
        PickerButton(symbol: "xmark", tooltip: "Cancel") { downloads.cancel(item.id) },
      ]
    case .done:
      return [
        PickerButton(symbol: "arrow.up.right.square", tooltip: "Open") { [weak self] in
          downloads.open(item)
          self?.onDismiss?()
        },
        PickerButton(symbol: "folder", tooltip: "Show in Finder") { [weak self] in
          downloads.reveal(item)
          self?.onDismiss?()
        },
      ]
    case .failed:
      return []
    }
  }

  private func choose() {
    guard rows.indices.contains(list.selectedIndex) else { return }
    let downloads = Downloads.shared
    switch rows[list.selectedIndex] {
    case .download(let item):
      // (Running or failed, it isn't there to open.)
      guard item.state == .done else { return }
      NSEvent.modifierFlags.contains(.option) ? downloads.reveal(item) : downloads.open(item)
    case .folder: downloads.showFolder()
    case .clear:
      downloads.clear()
      return
    }
    onDismiss?()
  }

  override var acceptsFirstResponder: Bool { true }

  override func layout() {
    super.layout()
    let size = NSSize(width: 360, height: list.contentHeight(limit: 10) + 12)
    cardFrame = NSRect(origin: extensionCardOrigin(size: size, anchor: anchor, in: bounds), size: size)
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 125: list.moveSelection(by: 1)  // down
    case 126: list.moveSelection(by: -1)  // up
    case 36, 76: choose()  // return
    case 53: onDismiss?()  // escape
    default: super.keyDown(with: event)
    }
  }
}

/// A download on its way to the downloads button, like Chrome's: a badge
/// rises from the middle of the page as it appears, then shrinks into the
/// button as it fades.
@MainActor
enum DownloadFlight {
  /// `from` and `to` in `host`'s coordinates (not flipped).
  static func run(in host: NSView, from: NSPoint, to target: NSRect, completion: @escaping () -> Void) {
    guard !Motion.reduceMotion, let layer = host.layer else { return completion() }
    let size: CGFloat = 52
    let badge = CALayer()
    badge.bounds = CGRect(x: 0, y: 0, width: size, height: size)
    badge.cornerRadius = size / 2
    badge.backgroundColor = host.resolvedCGColor(Theme.accent)
    badge.shadowColor = NSColor.black.cgColor
    badge.shadowOpacity = 0.25
    badge.shadowRadius = 8
    badge.shadowOffset = CGSize(width: 0, height: -2)
    let arrow = CALayer()
    if let image = Theme.symbol("arrow.down", size: 22, weight: .semibold, color: .white, in: host.effectiveAppearance) {
      arrow.contents = image
      arrow.contentsGravity = .center
      arrow.contentsScale = host.window?.backingScaleFactor ?? 2
    }
    arrow.frame = badge.bounds
    badge.addSublayer(arrow)
    let end = CGPoint(x: target.midX, y: target.midY)
    // Phase one ends 40pt off the button (Chrome's), on the page's side of
    // it: under the top bar's, over the sidebar's (at the bottom). Phase two
    // ends in it.
    let side: CGFloat = from.y > end.y ? 1 : -1
    let under = CGPoint(x: end.x, y: end.y + side * (target.height / 2 + 40))
    badge.position = end
    badge.opacity = 0
    Motion.withoutAnimation { layer.addSublayer(badge) }

    let duration: CFTimeInterval = 0.55
    let move = CAKeyframeAnimation(keyPath: "position")
    move.values = [NSValue(point: from), NSValue(point: under), NSValue(point: end)]
    move.keyTimes = [0, 0.6, 1]
    move.timingFunctions = [Motion.easeOut, Motion.easeInOut]
    let fade = CAKeyframeAnimation(keyPath: "opacity")
    fade.values = [0, 1, 0]
    fade.keyTimes = [0, 0.6, 1]
    let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
    shrink.values = [0.8, 1, target.height / size]
    shrink.keyTimes = [0, 0.6, 1]
    let group = CAAnimationGroup()
    group.animations = [move, fade, shrink]
    group.duration = duration
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      badge.removeFromSuperlayer()
      completion()
    }
    badge.add(group, forKey: "flight")
    CATransaction.commit()
  }
}
