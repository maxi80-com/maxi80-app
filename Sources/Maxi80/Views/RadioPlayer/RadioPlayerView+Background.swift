import SwiftUI

extension RadioPlayerView {

  // MARK: - Background

  /// Background wash with a fade between artwork colors — per-platform mechanisms because
  /// their animation systems fail in opposite ways:
  ///
  /// - **Apple**: the native implicit `.animation(_, value:)` over the branch interpolates
  ///   gradient colors smoothly (this is the pre-crossfade original — it never flashed).
  /// - **Android**: SkipUI renders that same modifier as a single-frame swap, so Android
  ///   runs two persistent ping-pong wash layers whose colors are only ever written while
  ///   invisible and whose opacities are only ever animated (the flash-proofing rules — see
  ///   the `washAColor` declaration). The crossfade dissolves old→new directly, no dip
  ///   through the brand base. Purely presentational here; the driver lives on the MAIN view
  ///   tree in `body`, because on SkipUI/Android lifecycle modifiers attached to
  ///   `.background {}` content never fire.
  ///
  ///   A scheme-neutral base sits UNDER the washes so a shown wash composites over the same
  ///   light/dark system background iOS uses — NOT over the dark neon-dusk brand, which
  ///   multiplied every color darker than iOS. Its opacity tracks how much wash is showing
  ///   (`max(washAFade, washBFade)`), so it covers the brand exactly while a color is
  ///   present and fades away with the wash to reveal the brand on the live slot. During a
  ///   color→color crossfade one fade rises as the other falls, so the max stays high and
  ///   the neutral base never dips (no mid-fade darkening).
  @ViewBuilder
  func dynamicBackground(isPortrait: Bool) -> some View {
    #if os(Android)
      ZStack {
        brandBackground()
        (colorScheme == .dark ? Color.black : Color.white)
          .opacity(max(washAFade, washBFade))
          .animation(.easeInOut(duration: 0.5), value: washAFade)
          .animation(.easeInOut(duration: 0.5), value: washBFade)
        if let a = washAColor {
          washGradient(a, isPortrait: isPortrait)
            .opacity(washAFade * washMaxOpacity)
            // Implicit tween per layer: the driver writes fade targets in a plain commit
            // and this animates the rendered opacity Compose-side (same mechanism as the
            // tray/play-button; must match their curve+duration so all dissolve as one).
            .animation(.easeInOut(duration: 0.5), value: washAFade)
        }
        if let b = washBColor {
          washGradient(b, isPortrait: isPortrait)
            .opacity(washBFade * washMaxOpacity)
            .animation(.easeInOut(duration: 0.5), value: washBFade)
        }
      }
    #else
      Group {
        if let color = viewModel.dominantColor {
          washGradient(color, isPortrait: isPortrait)
            .opacity(washMaxOpacity)
        } else {
          brandBackground()
        }
      }
      .animation(.easeInOut(duration: 0.5), value: viewModel.dominantColor)
    #endif
  }

  /// Artwork-driven soft wash of a cover's dominant color. Shape shared with the TV UI.
  private func washGradient(_ color: Color, isPortrait: Bool) -> some View {
    BrandedWash.wash(color, isPortrait: isPortrait)
  }

  /// Peak wash opacity over the brand base (the pre-crossfade constant, unchanged).
  private var washMaxOpacity: Double {
    colorScheme == .dark ? 0.9 : 0.4
  }

  /// Stable identity for the current artwork color, `nil` on the brand background. `Color`
  /// equality is unreliable across the Skip bridge; the raw RGB is not.
  var dominantColorKey: String? {
    guard let rgb = viewModel.dominantRGB else { return nil }
    return "\(rgb.red)-\(rgb.green)-\(rgb.blue)"
  }

  /// Default on-brand background when no artwork color is available. Shape shared with the TV UI —
  /// see `BrandedWash.brand`.
  @ViewBuilder
  private func brandBackground() -> some View {
    BrandedWash.brand()
  }
}
