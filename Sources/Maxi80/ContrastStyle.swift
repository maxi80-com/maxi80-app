import SwiftUI

/// Resolves title/subtitle/control colors based on the background luminance.
///
/// The same dark-on-light / light-on-dark pattern is used across `RadioPlayerView`,
/// `TVRadioPlayerView`, `PlaybackControlsView`, and `VolumeSliderView`. This struct
/// centralizes the logic so each view can call `ContrastStyle.resolve(isBackgroundDark:)`
/// instead of duplicating the conditions.
///
/// Extracted per issue #68 item 3.
struct ContrastStyle {
  let title: Color
  let subtitle: Color
  let isDark: Bool

  /// Resolve contrast colors for the given background luminance.
  static func resolve(isBackgroundDark: Bool) -> ContrastStyle {
    if isBackgroundDark {
      return ContrastStyle(
        title: .white,
        subtitle: Color.white.opacity(0.7),
        isDark: true
      )
    } else {
      return ContrastStyle(
        title: .black,
        subtitle: Color.black.opacity(0.6),
        isDark: false
      )
    }
  }
}
