import Foundation

#if SKIP
  import android.content.res.Configuration
  import android.content.Context
#endif

/// Whether the app is running in a 10-foot TV context (Apple TV or Android TV).
///
/// Lives in the transpiled `Maxi80Services` module because reading the Android UI mode needs the
/// `android.*` APIs and the `ProcessInfo.processInfo.androidContext` accessor, which only this
/// module imports. The native `Maxi80` UI module consumes it to pick the TV vs phone root view.
/* SKIP @bridge */
#if !SKIP_BRIDGE
  public enum PlatformEnvironment {

    /// `true` on tvOS; on Android `true` when the device UI mode is television; `false` otherwise.
    public static let isTVMode: Bool = computeIsTVMode()

    private static func computeIsTVMode() -> Bool {
      #if os(tvOS)
        return true
      #elseif SKIP
        let context = ProcessInfo.processInfo.androidContext
        let uiModeManager =
          context.getSystemService(Context.UI_MODE_SERVICE) as! android.app.UiModeManager
        return uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
      #else
        return false
      #endif
    }
  }
#endif
