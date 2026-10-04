import AppKit
import Security
import Sparkle

extension Notification.Name {
  /// An update finished downloading (or went away): the top bars show or
  /// hide their pill (`Updater.readyVersion`).
  static let gleaUpdateReadyChanged = Notification.Name("GleaUpdateReadyChanged")
}

/// In-app updates, through Sparkle (third_party/sparkle), after Subtitles'
/// Updater.swift.
///
/// Sparkle does the work: the checks, the EdDSA and Developer ID checks on what
/// it downloads, the swap in /Applications, the relaunch. Checks are on from the
/// start (SUEnableAutomaticChecks), and updates download in the background
/// (SUAutomaticallyUpdate): nothing interrupts. Once one is ready, Sparkle would
/// install it when Glea quits; Glea also offers it now, with a pill in every
/// window's top bar that relaunches onto it.
///
/// A check asked from the menu shows in UpdateWindow, Subtitles' update window:
/// this object is Sparkle's user driver, and each moment of an update becomes
/// one of the window's states. (Not SPUStandardUpdaterController: it wraps
/// Sparkle's own windows, the thing being replaced.)
///
/// The feed is the latest release's appcast on github.com/daformat/glea,
/// proxied by glea.app (SUFeedURL), and published by scripts/release.sh.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate, SPUUserDriver {
  static let shared = Updater()

  /// The version downloaded and waiting, or nil.
  private(set) var readyVersion: String? {
    didSet {
      guard readyVersion != oldValue else { return }
      NotificationCenter.default.post(name: .gleaUpdateReadyChanged, object: nil)
    }
  }

  private var updater: SPUUpdater?
  private let window = UpdateWindow()
  private var installNow: (() -> Void)?
  /// The update in progress, for the version in the window's headlines.
  private var current: SUAppcastItem?
  private var expectedBytes: UInt64 = 0
  private var receivedBytes: UInt64 = 0
  /// Bumped on every state, so a delayed follow-up can tell whether the
  /// state it was scheduled for is still the one showing.
  private var generation = 0

  /// Whether "Check for Updates…" can run (off in builds that don't update,
  /// and while a check runs).
  var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

  func start() {
    let environment = ProcessInfo.processInfo.environment
    // Only Developer ID builds: a local build (signed ad hoc) would otherwise
    // replace itself with the release. GLEA_UPDATER=1 tries it anyway, with
    // GLEA_UPDATE_FEED for a local appcast.
    guard Self.isDeveloperIDSigned || environment["GLEA_UPDATER"] == "1" else { return }
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    do {
      try updater.start()
    } catch {
      // No feed URL, no public key: not a build that can be updated, and not
      // worth a dialog.
      NSLog("Glea: updater not started: \(error.localizedDescription)")
      return
    }
    self.updater = updater
  }

  /// From the menu: the update window, whatever the check finds. An update
  /// already downloaded shows as ready to install.
  func checkForUpdates() {
    guard let updater else { return }
    NSApp.activate(ignoringOtherApps: true)
    updater.checkForUpdates()
  }

  /// The pill: installs the downloaded update and relaunches.
  func installAndRelaunch() {
    guard let installNow else { return }
    self.installNow = nil
    readyVersion = nil
    installNow()
  }

  /// For automated checks: a scheduled check, now.
  func checkInBackground() {
    updater?.checkForUpdatesInBackground()
  }

  /// For automated checks: shows the pill as if `version` were ready.
  func simulateReady(_ version: String?) {
    installNow = nil
    readyVersion = version
  }

  // MARK: SPUUpdaterDelegate

  func feedURLString(for updater: SPUUpdater) -> String? {
    ProcessInfo.processInfo.environment["GLEA_UPDATE_FEED"]
  }

  /// Downloaded in the background, and set to install on quit: offered now
  /// too, by the pill (true: Glea says so itself).
  func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
               immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
    installNow = immediateInstallHandler
    readyVersion = item.displayVersionString
    return true
  }

  // MARK: SPUUserDriver — the question (never asked: checks are on in Info.plist)

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  // MARK: SPUUserDriver — checking

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    generation += 1
    window.show(.checking(cancel: cancellation))
  }

  func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
    current = item
    generation += 1
    // Already downloaded in the background: straight to installing.
    if state.stage == .downloaded {
      window.show(.ready(version: item.displayVersionString,
                         install: { [weak self] in self?.readyVersion = nil; reply(.install) },
                         later: { reply(.dismiss) }))
      return
    }
    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let size = item.contentLength > 0
      ? ByteCountFormatter.string(fromByteCount: Int64(item.contentLength), countStyle: .file)
      : nil
    let notes = item.itemDescription.map { ReleaseNotes(html: $0) }
    window.show(.found(
      version: item.displayVersionString, current: installed, size: size, notes: notes,
      critical: item.isCriticalUpdate,
      install: { reply(.install) },
      later: { reply(.dismiss) },
      skip: item.isCriticalUpdate ? nil : { reply(.skip) }))
  }

  func showUpdateInFocus() {
    NSApp.activate(ignoringOtherApps: true)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    // Notes are embedded in the appcast; a linked page is never fetched.
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    generation += 1
    let info = (error as NSError).userInfo
    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let onLatest = (info[SPUNoUpdateFoundReasonKey] as? Int)
      .map { $0 == SPUNoUpdateFoundReason.onLatestVersion.rawValue } ?? true
    let dismiss: () -> Void = { [weak self] in acknowledgement(); self?.window.close() }
    if onLatest {
      window.show(.upToDate(version: installed, dismiss: dismiss))
    } else {
      // Newer than what this Mac can run, most likely. Sparkle's text says which.
      window.show(.failed(title: "No update for this Mac", message: error.localizedDescription,
                          retry: nil, dismiss: dismiss))
    }
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    generation += 1
    let nsError = error as NSError
    // A cancel is not a failure, and not worth a window saying so.
    if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.installationCanceledError.rawValue) {
      acknowledgement()
      window.close()
      return
    }
    var message = error.localizedDescription
    if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
      message += " " + suggestion
    }
    window.show(.failed(
      title: "Couldn’t update",
      message: message,
      retry: { [weak self] in
        acknowledgement()
        self?.window.close()
        self?.checkForUpdates()
      },
      dismiss: { [weak self] in acknowledgement(); self?.window.close() }))
  }

  // MARK: SPUUserDriver — downloading and unpacking

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    generation += 1
    expectedBytes = 0
    receivedBytes = 0
    window.show(.downloading(version: current?.displayVersionString, cancel: cancellation))
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    expectedBytes = expectedContentLength
    showDownloadProgress()
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    receivedBytes += length
    showDownloadProgress()
  }

  private func showDownloadProgress() {
    let got = ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file)
    guard expectedBytes > 0 else {
      window.progress(fraction: nil, detail: got)
      return
    }
    let total = ByteCountFormatter.string(fromByteCount: Int64(expectedBytes), countStyle: .file)
    window.progress(fraction: min(1, Double(receivedBytes) / Double(expectedBytes)), detail: "\(got) of \(total)")
  }

  func showDownloadDidStartExtractingUpdate() {
    generation += 1
    window.show(.extracting(version: current?.displayVersionString))
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    window.progress(fraction: progress, detail: nil)
  }

  // MARK: SPUUserDriver — installing

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    generation += 1
    window.show(.ready(
      version: current?.displayVersionString,
      install: { [weak self] in self?.readyVersion = nil; reply(.install) },
      later: { reply(.dismiss) }))
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
    generation += 1
    let version = current?.displayVersionString
    window.show(.installing(version: version, retry: nil))
    guard !applicationTerminated else { return }
    // Asked to quit: still here in a few seconds, something is holding it
    // open, and a button tries again rather than a bar that never fills.
    let expected = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, self.generation == expected else { return }
      self.window.show(.installing(version: version, retry: retryTerminatingApplication))
    }
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func dismissUpdateInstallation() {
    generation += 1
    current = nil
    window.close()
  }

  // MARK: Signature

  /// Signed with a Developer ID (a team), as releases are.
  private static let isDeveloperIDSigned: Bool = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any] else { return false }
    return values[kSecCodeInfoTeamIdentifier as String] != nil
  }()
}
