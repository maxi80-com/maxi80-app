import SwiftUI

extension RadioPlayerView {

  // MARK: - Controls Card

  /// The effective color scheme for the card surface — accounts for the parent's forced `.dark`
  /// override when no artwork color is available (the brand gradient is always dark).
  private var effectiveColorScheme: ColorScheme {
    viewModel.dominantColor == nil ? .dark : colorScheme
  }

  /// The contrast fade value for card content. On the card surface the text color is determined by
  /// the card's own luminance (off-white in light mode → dark text, charcoal in dark → light text),
  /// not by the artwork wash. On Apple this is automatic (semantic colors track colorScheme). On
  /// Android it must be explicit: 0 = light/white text, 1 = dark text.
  var cardContrastDarkFade: Double {
    #if os(Android)
      ControlsCardStyle.isCardTextDark(colorScheme: effectiveColorScheme) ? 1 : 0
    #else
      0  // Unused on Apple — semantic colors handle it via the overridden colorScheme.
    #endif
  }

  /// Contrast style for text on the card surface. On Apple, semantic colors follow the forced
  /// colorScheme (.light on the off-white card, .dark on the charcoal card). On Android, explicit
  /// colors must match the card surface, not the wash.
  var cardContrast: ContrastStyle {
    #if os(Android)
      .explicit(isBackgroundDark: !ControlsCardStyle.isCardTextDark(colorScheme: effectiveColorScheme))
    #else
      .semantic
    #endif
  }

  /// Vertical room the card leaves at its bottom for the `versionFooter` overlay, which stays
  /// pinned to the screen edge on top of the card (brand logo ~22pt + its 4pt inset, plus margin).
  private var footerClearance: CGFloat { 34 }

  /// Wraps content in a rounded card with the adjacent artwork color, visually separating it from
  /// the carousel area. Forces an appropriate colorScheme on the card so text colors track the
  /// card surface (off-white → light scheme, charcoal → dark scheme). The card fills the space it
  /// is given and bleeds off the screen edges named by `attachment`, so only the corners facing the
  /// carousel are rounded — the bottom pair in portrait, the leading pair in landscape.
  ///
  /// Modifier order is load-bearing: the footer clearance insets the CONTENT, then the fill frame
  /// wraps the result. Reversing them adds the clearance on top of an already-filled height, so the
  /// card asks for more space than the container offers and the layout overflows.
  @ViewBuilder
  func controlsCard<Content: View>(
    attachedTo attachment: ControlsCardStyle.Attachment,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let scheme = effectiveColorScheme
    content()
      .padding(.bottom, footerClearance)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(alignment: .top) {
        ControlsCardStyle.cardFill(
          dominantColor: viewModel.dominantColor,
          isBackgroundDark: viewModel.isBackgroundDark,
          colorScheme: scheme
        )
        .clipShape(ControlsCardStyle.shape(for: attachment))
        .ignoresSafeArea(edges: ControlsCardStyle.ignoredSafeAreaEdges(for: attachment))
      }
      // Override colorScheme on the card so semantic text colors match the card surface.
      .environment(\.colorScheme, ControlsCardStyle.isCardTextDark(colorScheme: scheme) ? .light : .dark)
  }
}
