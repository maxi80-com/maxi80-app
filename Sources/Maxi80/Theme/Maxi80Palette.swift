import SwiftUI

/// Brand palette sampled from the Maxi'80 neon logo (violet → blue → green → orange on black).
/// Used for the default app background when no artwork dominant color is available, keeping the
/// look on-brand without a muddy averaged color.
enum Maxi80Palette {
  /// Neon hues from the logo, left → right.
  static let violet = Color(red: 0.58, green: 0.24, blue: 0.90)
  static let blue = Color(red: 0.20, green: 0.48, blue: 0.98)
  static let orange = Color(red: 1.00, green: 0.42, blue: 0.06)

  /// Deep near-black base, matching the logo's background.
  static let night = Color(red: 0.05, green: 0.05, blue: 0.09)

  /// Darkened neon accents so the dusk gradient stays atmospheric and lets covers pop.
  static let duskTop = Color(red: 0.16, green: 0.07, blue: 0.24)  // deep violet
  static let duskBottom = Color(red: 0.22, green: 0.09, blue: 0.05)  // deep warm ember
}
