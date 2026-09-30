import AppKit

/// What happened each day, for the journal's daily summary: the notes worked
/// on (typed in, or collected into) and the pages read, with the time spent
/// on them. Kept as JSON in Application Support for the last 30 days;
/// incognito windows leave nothing here.
@MainActor
final class ActivityLog {
  static let shared = ActivityLog()

  struct Page: Codable {
    var url: String
    var title: String
    var seconds: Double
    var lastSeen: Date
  }

  struct NoteWork: Codable {
    var name: String
    var edits: Int
    var captures: Int
    var lastEdit: Date
  }

  struct Day: Codable {
    var pages: [String: Page] = [:]
    /// By note name, lowercased (links resolve case-insensitively).
    var notes: [String: NoteWork] = [:]

    var isEmpty: Bool { pages.isEmpty && notes.isEmpty }
  }

  private(set) var days: [String: Day] = [:]
  private let file = AppPaths.support.appendingPathComponent("activity.json")
  private var saveScheduled = false
  private var readingTimer: Timer?

  /// How often the page in front is credited with reading time, and how long
  /// without any input (mouse, keys, scrolling) still counts as reading.
  private static let tick: TimeInterval = 5
  private static let idleLimit: TimeInterval = 90
  private static let keptDays = 30

  private init() {
    if let data = try? Data(contentsOf: file),
       let saved = try? JSONDecoder().decode([String: Day].self, from: data) {
      days = saved
    }
  }

  private var todayKey: String { NoteStore.dayFormatter.string(from: Date()) }

  // MARK: Recording

  /// Credits the page in front with reading time every few seconds, while
  /// Glea is active and someone is at the keyboard. `current` says which
  /// page that is (nil: the notes are in front, or an incognito window).
  func startTrackingReading(current: @escaping @MainActor () -> (url: String, title: String)?) {
    readingTimer?.invalidate()
    let timer = Timer(timeInterval: ActivityLog.tick, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard NSApp.isActive else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < ActivityLog.idleLimit, let page = current() else { return }
        ActivityLog.shared.read(url: page.url, title: page.title, seconds: ActivityLog.tick)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    readingTimer = timer
  }

  func read(url: String, title: String, seconds: Double) {
    guard url.hasPrefix("http") else { return }
    let key = url.components(separatedBy: "#")[0]
    update { day in
      var page = day.pages[key] ?? Page(url: key, title: title, seconds: 0, lastSeen: Date())
      page.seconds += seconds
      page.lastSeen = Date()
      if !title.isEmpty { page.title = title }
      day.pages[key] = page
    }
  }

  /// Typed in (a save of the note's editor).
  func edited(_ ref: NoteRef) {
    guard ref.kind == .note else { return }
    work(on: ref) { $0.edits += 1 }
  }

  /// Something collected from the web went into it.
  func collected(into ref: NoteRef) {
    guard ref.kind == .note else { return }
    work(on: ref) { $0.captures += 1 }
  }

  func renamed(_ old: NoteRef, to new: NoteRef) {
    let oldKey = old.name.lowercased()
    let newKey = new.name.lowercased()
    for (key, var day) in days {
      guard var work = day.notes.removeValue(forKey: oldKey) else { continue }
      work.name = new.name
      day.notes[newKey] = work
      days[key] = day
    }
    scheduleSave()
  }

  private func work(on ref: NoteRef, _ change: (inout NoteWork) -> Void) {
    let key = ref.name.lowercased()
    update { day in
      var work = day.notes[key] ?? NoteWork(name: ref.name, edits: 0, captures: 0, lastEdit: Date())
      change(&work)
      work.name = ref.name
      work.lastEdit = Date()
      day.notes[key] = work
    }
  }

  private func update(_ change: (inout Day) -> Void) {
    let key = todayKey
    var day = days[key] ?? Day()
    change(&day)
    days[key] = day
    scheduleSave()
  }

  private func scheduleSave() {
    guard !saveScheduled else { return }
    saveScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.save() }
  }

  func save() {
    saveScheduled = false
    // Only the last month: older days are never summarized.
    let keep = Set(days.keys.sorted().suffix(ActivityLog.keptDays))
    days = days.filter { keep.contains($0.key) }
    guard let data = try? JSONEncoder().encode(days) else { return }
    try? data.write(to: file, options: .atomic)
  }

  // MARK: Summary

  /// The last day before today when anything happened.
  var lastActiveDay: String? {
    let today = todayKey
    return days.filter { $0.key < today && !$0.value.isEmpty }.keys.max()
  }

  struct Summary {
    let day: String
    /// Most worked on first.
    let notes: [NoteWork]
    /// Longest read first; only pages read for a while.
    let pages: [Page]
    let continueNote: NoteWork?
    let continuePage: Page?
  }

  /// Pages open for less than this weren't read (a search, a redirect, a
  /// page skimmed past).
  private static let minimumReading: Double = 30

  func summary() -> Summary? {
    guard let key = lastActiveDay, let day = days[key] else { return nil }
    let today = days[todayKey] ?? Day()
    let notes = day.notes.values
      .filter { NoteStore.shared.resolve(linkName: $0.name) != nil }
      .sorted { ($0.edits + $0.captures * 3, $0.lastEdit) > ($1.edits + $1.captures * 3, $1.lastEdit) }
    let pages = day.pages.values
      .filter { $0.seconds >= ActivityLog.minimumReading }
      .sorted { $0.seconds > $1.seconds }
    guard !notes.isEmpty || !pages.isEmpty else { return nil }
    // Where to pick up: the last note worked on and the longest read page
    // that day, unless they've been gone back to since.
    let continueNote = notes.max { $0.lastEdit < $1.lastEdit }
      .flatMap { today.notes[$0.name.lowercased()] == nil ? $0 : nil }
    let continuePage = pages.first { today.pages[$0.url] == nil && !isCollected($0, on: day) }
    return Summary(day: key, notes: Array(notes.prefix(8)), pages: Array(pages.prefix(6)),
                   continueNote: continueNote, continuePage: continuePage)
  }

  /// A page some capture came from that day: already dealt with.
  private func isCollected(_ page: Page, on day: Day) -> Bool {
    day.notes.values.contains { work in
      work.captures > 0 && NoteStore.shared.resolve(linkName: work.name)
        .map { NoteStore.shared.content(of: $0).contains(page.url) } ?? false
    }
  }
}
