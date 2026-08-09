import SwiftUI

/// The surface of the controls card, the panel that separates the song label, status slot, playback
/// controls and volume from the carousel — below it in portrait, beside it in landscape.
///
/// The color strategy:
/// - An opaque base (warm off-white in light mode, soft charcoal in dark) carries the text contrast,
///   so readability never depends on the artwork.
/// - A low-opacity tint of the artwork's dominant color sits over that base, connecting the card to
///   the album art without shifting which text color it needs.
/// - With no dominant color the brand gradient is behind the card, and the fill is a single near-black
///   panel at 0.85 rather than the base: the gradient reads faintly through it as a raised surface.
///
/// Fixed colors and opacity compositing only — no UIKit/CoreGraphics, so it is safe on Android.
enum ControlsCardStyle {

  /// Corner radius for the card panel.
  static let cornerRadius: CGFloat = 28

  /// Which screen edges the card is flush against, which is what decides its corners: the card
  /// always bleeds off the edges it touches, so only the corners facing the carousel get rounded.
  /// Named `Attachment` rather than `Edge` to stay unambiguous next to SwiftUI's own `Edge`.
  enum Attachment {
    /// Portrait: the card spans the full width along the bottom — round the top corners.
    case bottom
    /// Landscape: the card is the trailing column, flush right and bottom — round the leading
    /// corners, the pair that faces the carousel.
    case trailing
  }

  /// The card's clip shape for the edges it is attached to.
  static func shape(for attachment: Attachment) -> UnevenRoundedRectangle {
    switch attachment {
    case .bottom:
      return UnevenRoundedRectangle(
        topLeadingRadius: cornerRadius,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: cornerRadius,
        style: .continuous
      )
    case .trailing:
      return UnevenRoundedRectangle(
        topLeadingRadius: cornerRadius,
        bottomLeadingRadius: cornerRadius,
        bottomTrailingRadius: 0,
        topTrailingRadius: 0,
        style: .continuous
      )
    }
  }

  /// The safe-area edges the card fill bleeds through, so it meets the physical screen edges it is
  /// attached to rather than stopping at the safe-area inset with a strip of wash showing beyond it.
  static func ignoredSafeAreaEdges(for attachment: Attachment) -> SwiftUI.Edge.Set {
    switch attachment {
    case .bottom: return .bottom
    case .trailing: return [.bottom, .trailing]
    }
  }

  /// The card fill as a layered View: opaque base + artwork tint.
  @ViewBuilder
  static func cardFill(dominantColor: Color?, isBackgroundDark: Bool, colorScheme: ColorScheme) -> some View {
    if let color = dominantColor {
      ZStack {
        cardBaseColor(colorScheme: colorScheme)
        color.opacity(isBackgroundDark ? 0.15 : 0.12)
      }
    } else {
      // Brand gradient showing — subtle raised panel.
      Color(red: 0.12, green: 0.11, blue: 0.15).opacity(0.85)
    }
  }

  /// The opaque base under the card tint. Warm off-white in light mode; a soft dark in dark mode
  /// (lighter than the brand background so it reads as a raised surface).
  private static func cardBaseColor(colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
      ? Color(red: 0.14, green: 0.14, blue: 0.16)
      : Color(red: 0.97, green: 0.96, blue: 0.95)
  }

  /// Whether text on the card surface should be dark. The card base is always a readable surface:
  /// in light mode the base is off-white → dark text. In dark mode the base is soft charcoal →
  /// light text. The tint overlay is low-opacity so it doesn't flip the contrast.
  static func isCardTextDark(colorScheme: ColorScheme) -> Bool {
    colorScheme != .dark
  }
}
