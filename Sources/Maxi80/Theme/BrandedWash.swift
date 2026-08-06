import SwiftUI

/// The two background layers every now-playing surface draws, in one place: the branded fallback
/// gradient shown when no artwork color is available, and the soft wash of an artwork's dominant
/// color shown when one is.
///
/// Only the *shapes* live here. How a surface animates between them stays with the surface, because
/// the mechanisms are irreconcilably platform- and layout-specific: the phone UI runs a two-layer
/// ping-pong crossfade on Android and native gradient interpolation on Apple, while the TV UI tweens
/// a solid color under a static alpha gradient (Compose won't interpolate a gradient's colors). What
/// they can share, and previously each reproduced by hand, is what the gradients actually look like.
///
/// The TV UI draws the brand gradient without the radial glows, which are sized in points for a
/// hand-held canvas. That is a real difference, so it is a parameter (`glows:`) rather than something
/// this type quietly unifies — a refactoring must not restyle the 10-foot screen.
enum BrandedWash {

  /// The on-brand background for when no artwork color is available: a dark neon dusk drawn from the
  /// Maxi'80 logo (deep violet → night → warm ember) with soft violet and orange glows behind the
  /// hero. Deliberately dark in both color schemes, to match the logo's black base.
  ///
  /// - Parameter glows: pass `false` for surfaces that want the bare three-stop gradient without the
  ///   radial glows.
  @ViewBuilder
  static func brand(glows: Bool = true) -> some View {
    ZStack {
      LinearGradient(
        colors: [Maxi80Palette.duskTop, Maxi80Palette.night, Maxi80Palette.duskBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      if glows {
        // Neon glow behind the artwork, echoing the logo's violet→orange sweep.
        RadialGradient(
          colors: [Maxi80Palette.violet.opacity(0.35), .clear],
          center: .init(x: 0.5, y: 0.34),
          startRadius: 0,
          endRadius: 460
        )
        RadialGradient(
          colors: [Maxi80Palette.orange.opacity(0.16), .clear],
          center: .init(x: 0.85, y: 0.1),
          startRadius: 0,
          endRadius: 340
        )
      }
    }
  }

  /// The artwork-driven wash: a soft linear fade of `color` into a slightly transparent version of
  /// itself, so the cover's dominant color tints the screen without flattening it.
  ///
  /// - Parameter isPortrait: runs the fade top→bottom when `true`, leading→trailing when `false`, so
  ///   the gradient follows the long axis of the canvas. The TV UI is always landscape-shaped but
  ///   fades vertically, so it passes `true`.
  static func wash(_ color: Color, isPortrait: Bool) -> some View {
    LinearGradient(
      gradient: Gradient(colors: [color, color.opacity(0.9)]),
      startPoint: isPortrait ? .top : .leading,
      endPoint: isPortrait ? .bottom : .trailing
    )
  }
}
