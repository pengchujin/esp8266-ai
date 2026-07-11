import Foundation

// Single source of truth for the app version. Bump this before cutting a
// release; the build script injects the same value into the .app Info.plist
// so Sparkle sees it.
enum AppVersion {
    static let short = "1.3.1"
    static let build = "2"

    static var display: String { "\(short) (\(build))" }

    /// Returns the version reported by Bundle.main, falling back to the
    /// compile-time constant when running outside a proper .app bundle.
    static var bundleShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? short
    }

    static var bundleBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? build
    }
}
