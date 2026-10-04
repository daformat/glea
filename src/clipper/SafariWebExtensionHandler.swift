import Foundation
import SafariServices

/// Glea Clipper in Safari: Safari loads the extension's files (manifest.json
/// and the rest, in this bundle's Resources) itself. This handler answers
/// browser.runtime.sendNativeMessage, which the extension doesn't use: it
/// reaches Glea through glea:// links. It only has to be here.
// (A fixed Objective-C name: Info.plist names it, whatever module it compiles in.)
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  func beginRequest(with context: NSExtensionContext) {
    context.completeRequest(returningItems: [], completionHandler: nil)
  }
}
