import AppKit

/// A capture sent from another browser by Glea's extensions (Chrome, Firefox,
/// Safari) as a `glea://capture` URL:
///
///     glea://capture?kind=selection&url=…&title=…&markdown=…&to=journal
///
/// - `kind`: page, selection, element, image or article (`Capture.Kind`).
/// - `markdown`, or `clipboard=1` when it was too long for the address and
///   the extension put it on the clipboard instead.
/// - `text`: a short plain-text preview, shown in the capture picker.
/// - `to`: `journal` (the default), `note` with `note=<name>` (created if
///   missing), or `ask` for the capture picker.
/// - `open=1` shows where it went; otherwise focus goes back to the browser.
///
/// Any page can open a `glea://` URL (the browser asks first), so a capture
/// only ever appends, and only web addresses are accepted as its source.
@MainActor
struct ExternalCapture {
  enum Destination: Equatable {
    case journal
    case note(String)
    case ask
  }

  var capture: Capture
  var destination: Destination
  var reveal: Bool

  static let scheme = "glea"
  private static let maxLength = 5_000_000

  init?(url: URL) {
    guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "capture",
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    var query: [String: String] = [:]
    for item in items { query[item.name] = item.value ?? "1" }

    guard let pageURL = query["url"], let source = URL(string: pageURL),
          ["http", "https"].contains(source.scheme?.lowercased() ?? "") else { return nil }
    let kind = Capture.Kind(rawValue: query["kind"] ?? "") ?? .selection

    var markdown = query["markdown"] ?? ""
    if query["clipboard"] == "1" {
      markdown = NSPasteboard.general.string(forType: .string) ?? ""
    }
    markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard markdown.count <= Self.maxLength, kind == .page || !markdown.isEmpty else { return nil }

    capture = Capture(kind: kind, markdown: markdown,
                      text: String((query["text"] ?? "").prefix(600)),
                      pageURL: pageURL, pageTitle: query["title"] ?? "")
    switch query["to"] {
    case "ask":
      destination = .ask
    case "note":
      let name = NoteStore.sanitize(query["note"] ?? "")
      destination = name.isEmpty ? .ask : .note(name)
    default:
      destination = .journal
    }
    reveal = query["open"] == "1"
  }

  /// The note it goes to, created if need be (nil: ask with the picker).
  func resolvedTarget() -> NoteRef? {
    switch destination {
    case .journal:
      return NoteStore.shared.today
    case .note(let name):
      if let ref = NoteStore.shared.resolve(linkName: name), ref.kind == .note { return ref }
      return NoteStore.shared.createNote(named: name)
    case .ask:
      return nil
    }
  }
}
