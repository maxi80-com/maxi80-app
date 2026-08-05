import SwiftUI

/// One of the generic "Maxi'80" covers shown before any song has played, paired with the
/// dominant color sampled from that image (precomputed so the startup gradient is consistent
/// on both iOS and Android — Android has no runtime image-color APIs).
struct PlaceholderCover: Equatable, Sendable {
  /// Asset name in the module bundle.
  let imageName: String
  /// Dominant color of the image, driving the startup background gradient.
  let dominantColor: Color

  /// The bundled generic covers with their sampled dominant colors.
  /// When the `anniversaryCover` feature flag is enabled the anniversary cover is appended.
  @MainActor
  static var all: [PlaceholderCover] {
    var covers: [PlaceholderCover] = [
      PlaceholderCover(
        imageName: "NoCover-a",
        dominantColor: Color(red: 96 / 255, green: 81 / 255, blue: 72 / 255)),
      PlaceholderCover(
        imageName: "NoCover-b",
        dominantColor: Color(red: 69 / 255, green: 67 / 255, blue: 67 / 255)),
      PlaceholderCover(
        imageName: "NoCover-c",
        dominantColor: Color(red: 61 / 255, green: 42 / 255, blue: 28 / 255)),
    ]
    if FeatureFlags.shared.isEnabled(.anniversaryCover) {
      // Gold dominant color sampled from the anniversary artwork.
      covers.append(
        PlaceholderCover(
          imageName: "NoCover-anniversary",
          dominantColor: Color(red: 212 / 255, green: 175 / 255, blue: 55 / 255)
        ))
    }
    return covers
  }

  /// A random generic cover, used once per app launch.
  @MainActor
  static func random() -> PlaceholderCover {
    all.randomElement() ?? all[0]
  }
}
