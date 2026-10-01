import Foundation

// SwiftMath looks its fonts up in the Swift Package Manager's resource
// bundle; built into Glea, mathFonts.bundle is in the app's resources.
extension Bundle {
  static var module: Bundle { Bundle.main }
}
