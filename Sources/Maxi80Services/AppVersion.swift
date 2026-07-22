import Foundation

/// The app's user-facing version string, e.g. `v5.0.1 (2026072100)`.
///
/// Extraction is platform-specific: Apple reads the bundle's Info.plist keys
/// (`CFBundleShortVersionString` / `CFBundleVersion`); Android reads the installed `PackageInfo`
/// via the `androidContext` (`versionName` / `longVersionCode`). Both sets of values originate
/// from `Skip.env` at build time, so the two platforms report the same numbers. The display
/// format is identical on both, so it lives here and the SwiftUI footer that renders it stays
/// platform-agnostic.
///
/// Lives in the transpiled `Maxi80Services` module (like `PlatformEnvironment`) because the
/// Android branch needs the `android.*` APIs and the `ProcessInfo.processInfo.androidContext`
/// accessor that only this module imports; the native `Maxi80` UI module consumes it via bridging.
/* SKIP @bridge */
#if !SKIP_BRIDGE
  public enum AppVersion {

    /// Marketing version + build number formatted as `v<marketing> (<build>)`.
    public static let displayString: String = {
      #if SKIP
        let context = ProcessInfo.processInfo.androidContext
        let info = context.packageManager.getPackageInfo(context.packageName, 0)
        let marketing = info.versionName ?? ""
        // longVersionCode (API 28+, well below the app's minSdk) is a Long; interpolate to a String.
        let build = "\(info.longVersionCode)"
        return "v\(marketing) (\(build))"
      #else
        let dict = Bundle.main.infoDictionary
        let marketing = dict?["CFBundleShortVersionString"] as? String ?? ""
        let build = dict?["CFBundleVersion"] as? String ?? ""
        return "v\(marketing) (\(build))"
      #endif
    }()
  }
#endif
