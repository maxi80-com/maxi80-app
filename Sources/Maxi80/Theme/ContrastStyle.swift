import SwiftUI

/// The title/subtitle colors for text laid directly over the artwork wash.
///
/// Two ways to resolve one: `.semantic` defers to the platform's `.primary`/`.secondary`, which
/// already track the color scheme the view forces; `.explicit(isBackgroundDark:)` picks concrete
/// white/black from the *background's* measured luminance. Which one a surface wants is not a style
/// preference but a platform fact — see the two factories below.
///
/// A value type rather than three computed properties per view because the phone and TV UIs need the
/// same pair and previously each carried its own copy of the same `#if os(Android)` ladder. The
/// dimmed variants (`subtitle.opacity(0.6)` for air-time lines) stay at the call sites, which differ.
struct ContrastStyle {
  let title: Color
  let subtitle: Color

  /// Semantic colors, correct wherever the platform recolors them from the environment's color
  /// scheme — i.e. every Apple platform, given the `.environment(\.colorScheme, …)` override the
  /// views apply over the always-dark brand background.
  static let semantic = ContrastStyle(title: .primary, subtitle: .secondary)

  /// Concrete high-contrast colors chosen from the background's own luminance: white text on a dark
  /// wash, near-black on a bright one.
  ///
  /// Required on Android, where the forced `colorScheme` environment override does NOT recolor
  /// semantic text styles — and correct there for a second reason: the Android wash composites over
  /// the always-dark brand base, so what sits behind the text is governed by the artwork color's
  /// brightness, not by the device's light/dark setting. The TV UIs use it on every platform, because
  /// their text sits directly on the wash with no scheme-derived surface underneath.
  static func explicit(isBackgroundDark: Bool) -> ContrastStyle {
    ContrastStyle(
      title: isBackgroundDark ? .white : .black,
      subtitle: isBackgroundDark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
    )
  }

  /// The pair for the phone/tablet UI: explicit on Android (semantic styles don't follow the forced
  /// scheme there), semantic on Apple platforms.
  static func phone(isBackgroundDark: Bool) -> ContrastStyle {
    #if os(Android)
      return .explicit(isBackgroundDark: isBackgroundDark)
    #else
      return .semantic
    #endif
  }

  /// The pair for the 10-foot TV UIs, which sit directly on the wash on both tvOS and Android TV and
  /// so always resolve from its luminance.
  static func tv(isBackgroundDark: Bool) -> ContrastStyle {
    .explicit(isBackgroundDark: isBackgroundDark)
  }
}
