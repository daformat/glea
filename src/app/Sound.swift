import AppKit

// Sound across the app: web tabs (in every window) and notes' media blocks
// report whether they play sound, so the notes' top bar can show that
// something is playing and mute or unmute all of it.

/// Something that can play sound.
@MainActor
protocol SoundSource: AnyObject {
  /// Playing sound (muted or not).
  var isPlayingSound: Bool { get }
  var isSoundMuted: Bool { get }
  func setSoundMuted(_ muted: Bool)
}

@MainActor
final class SoundMonitor {
  static let shared = SoundMonitor()
  static let didChange = Notification.Name("GleaSoundDidChange")

  private let sources = NSHashTable<AnyObject>.weakObjects()

  func register(_ source: SoundSource) {
    sources.add(source)
  }

  /// A source started or stopped playing, or was muted or unmuted.
  func sourceDidChange() {
    NotificationCenter.default.post(name: Self.didChange, object: nil)
  }

  private var playing: [SoundSource] {
    sources.allObjects.compactMap { $0 as? SoundSource }.filter(\.isPlayingSound)
  }

  /// Sound plays somewhere, not muted.
  var isPlaying: Bool { playing.contains { !$0.isSoundMuted } }

  /// Sound plays, all of it muted.
  var isMuted: Bool {
    let sources = playing
    return !sources.isEmpty && sources.allSatisfy(\.isSoundMuted)
  }

  /// Mutes everything playing, or (all muted) unmutes it.
  func toggle() {
    let mute = isPlaying
    for source in playing where source.isSoundMuted != mute { source.setSoundMuted(mute) }
  }
}
