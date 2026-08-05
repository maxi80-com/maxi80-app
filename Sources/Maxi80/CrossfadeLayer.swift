import SwiftUI

/// A helper that renders the same content twice — once with the light tint and once with the dark —
/// cross-fading between them via an opacity blend. Eliminates the repeated ZStack pattern
/// throughout `PlaybackControlsView` on Android.
struct CrossfadeLayer<Content: View>: View {
  let contrastFade: Double
  let lightTint: Color
  let darkTint: Color
  @ViewBuilder let content: (Color) -> Content

  var body: some View {
    ZStack {
      content(lightTint).opacity(1 - contrastFade)
      content(darkTint).opacity(contrastFade)
    }
  }
}
