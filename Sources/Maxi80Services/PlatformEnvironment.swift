import Foundation

#if canImport(UIKit)
  import UIKit
#endif

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

    /// `true` when running on an iPad; `false` on iPhone, macOS, tvOS, and Android.
    public static let isPad: Bool = computeIsPad()

    /// Whether the UI should use the roomier "big canvas" treatment — enlarged hero, capped
    /// info/controls column, larger type and control sizes — instead of the compact phone layout.
    /// True on iPad and macOS (both fill a large window); iPhone and Android phones keep the phone
    /// layout. Lives here rather than on each view because `RadioPlayerView` and
    /// `PlaybackControlsView` must agree: they render one continuous column, so a view sizing its
    /// half for the phone while the other sized for the tablet is always a bug.
    public static let usesExpandedLayout: Bool = computeUsesExpandedLayout()

    private static func computeUsesExpandedLayout() -> Bool {
      #if os(macOS)
        return true
      #else
        return isPad
      #endif
    }

    private static func computeIsPad() -> Bool {
      #if os(iOS)
        #if canImport(UIKit)
          return UIDevice.current.userInterfaceIdiom == .pad
        #else
          return false
        #endif
      #else
        return false
      #endif
    }

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
