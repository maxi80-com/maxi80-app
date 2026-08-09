import Maxi80Services
import SwiftUI

extension RadioPlayerView {

  // MARK: - Layout Sizing

  /// Whether to use the roomier "big canvas" treatment (enlarged hero + capped info/controls
  /// column) instead of the phone layout. Shared with `PlaybackControlsView`, which renders the
  /// lower half of the same column and must make the same choice.
  var usesExpandedLayout: Bool { PlatformEnvironment.usesExpandedLayout }

  /// Width cap for the info/controls column in the expanded landscape layout.
  ///
  /// This is also what sizes the hero: the carousel gets the width the column leaves, and the hero is
  /// a fraction of that (see `expandedCoverSize`). Raising it therefore trades hero size for room in
  /// the column — at 520 a 38pt artist line has ~440pt of text width after the card's and the label's
  /// horizontal insets, which fits the long names that truncated at 420.
  private var expandedColumnWidth: CGFloat { 520 }
  private var expandedHPadding: CGFloat { 24 }

  /// Gap between the carousel column and the controls card in landscape (both idioms). Zero so the
  /// card butts straight against the carousel and reads as one continuous surface anchored to the
  /// trailing edge, rather than a panel floating on the wash. Feeds the two hero-size formulas as
  /// well as the HStack spacing, so the carousel's share of the width stays correct.
  private var landscapeColumnGap: CGFloat { 0 }

  /// Hero size for the expanded layouts, derived from the width actually available to the carousel
  /// so its left/right neighbor covers always peek through — a fixed size clipped them on narrower
  /// windows (macOS) even though it fit the iPad. Sized as a fraction of the carousel's own cell
  /// width and capped so it never grows absurdly large on very wide displays.
  private func expandedCoverSize(containerWidth: CGFloat, isLandscape: Bool) -> CGFloat {
    let carouselWidth: CGFloat
    if isLandscape {
      // Left cell of the HStack: total minus the (leading-only) padding, the inter-column gap,
      // and the capped column. Only one padding term — the card is flush to the trailing edge.
      carouselWidth = containerWidth - expandedHPadding - landscapeColumnGap - expandedColumnWidth
    } else {
      carouselWidth = containerWidth
    }
    // ~58% of the cell leaves ~21% on each side for the neighbor covers to show.
    let cap: CGFloat = isLandscape ? 560 : 460
    return max(260, min(cap, carouselWidth * 0.58))
  }

  // Phone-portrait column paddings/spacing — named so the same values feed both the layout and the
  // adaptive-hero chrome budget below (rather than being hardcoded in two places).
  static let phonePortraitVSpacing: CGFloat = 20
  static let phonePortraitTopPadding: CGFloat = 12

  /// Estimated height of the non-hero *subviews* in phone portrait — song labels + status slot +
  /// two-tier controls + volume row. Kept separate from the paddings/spacing (which are derived
  /// from the named constants above) so only this genuine content estimate is hand-tuned. If those
  /// subviews change materially, update this one number.
  /// (This is only the subviews estimate; the derived chrome total adds paddings + gaps below.)
  private static let phonePortraitSubviewsHeight: CGFloat = 332

  /// Total fixed chrome height the adaptive hero must leave room for: the subview estimate plus the
  /// column's own paddings and the inter-element gaps (4 children in the card VStack → 3 spacings,
  /// plus the song label's top inset and footer overlay clearance).
  private static var phonePortraitChromeHeight: CGFloat {
    phonePortraitSubviewsHeight
      + phonePortraitTopPadding  // outer top
      + phonePortraitVSpacing  // song label top padding inside card
      + footerClearance  // the clearance the card reserves for the pinned footer overlay
      + phonePortraitVSpacing * 3  // 3 gaps between 4 card children
  }

  /// Phone-portrait hero size, adapted to the container height so the spacer-free column always
  /// fills the screen exactly — the hero takes all the slack left after the fixed chrome (labels,
  /// status slot, two-tier controls, volume row, paddings, and footer clearance). The hero renders
  /// at `coverSize + 80` tall (its internal vertical margins). Capped at 320 so very tall phones
  /// don't inflate it past a sensible hero, floored at 160 so shorter phones still show a usable
  /// carousel rather than clipping.
  ///
  /// ALSO capped by width: tall-aspect Android phones have enough vertical slack to hit the 320
  /// height cap, but 320 on a ~411dp-wide screen fills it edge-to-edge and the previous/next
  /// covers can't peek through. ~62% of the width leaves ~19% per side for the neighbors (same
  /// idea as the 58% used by the landscape/expanded layouts, slightly roomier because portrait
  /// has no second column). On iPhones the height term is already the binding cap, so this
  /// doesn't change the iOS layout.
  private func phonePortraitCoverSize(
    containerWidth: CGFloat, containerHeight: CGFloat
  ) -> CGFloat {
    let heroChrome: CGFloat = 80  // CoverFlowView's verticalMargin * 2
    let available = containerHeight - Self.phonePortraitChromeHeight - heroChrome
    return max(160, min(320, min(available, containerWidth * 0.62)))
  }

  /// Hero size for the compact (phone) landscape layout. The old fixed 260pt default filled the
  /// carousel's whole cell, so the previous/next covers never peeked through. The HStack splits
  /// the width roughly in half between the strip and the info/controls column; size the hero as
  /// ~58% of the strip's share (same fraction as the expanded layouts) so ~21% shows on each side.
  private func compactLandscapeCoverSize(containerWidth: CGFloat) -> CGFloat {
    let carouselWidth = (containerWidth - landscapeColumnGap) / 2
    return max(160, min(260, carouselWidth * 0.58))
  }

  // MARK: - Portrait Layout

  @ViewBuilder
  func portraitView(containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
    if usesExpandedLayout {
      // iPad's tall canvas: carousel above, controls card below with breathing room.
      VStack(spacing: 0) {
        Spacer().frame(height: 32)
        coverFlow(coverSize: expandedCoverSize(containerWidth: containerWidth, isLandscape: false))
        Spacer().frame(height: 16)
        controlsCard(attachedTo: .bottom) {
          VStack(spacing: 28) {
            Spacer().frame(height: 24)
            songLabel(contrastOverride: cardContrast)
            liveIndicator()
            Spacer()
            PlaybackControlsView(
              viewModel: viewModel, contrastDarkFade: cardContrastDarkFade)
            Spacer().frame(height: 32)
            volumeControl()
              .frame(maxWidth: 520)
          }
        }
      }
    } else {
      // Phone portrait: carousel on the wash, info+controls in the card.
      VStack(spacing: 0) {
        coverFlow(
          coverSize: phonePortraitCoverSize(
            containerWidth: containerWidth, containerHeight: containerHeight))

        controlsCard(attachedTo: .bottom) {
          VStack(spacing: Self.phonePortraitVSpacing) {
            songLabel(contrastOverride: cardContrast)
              .padding(.top, Self.phonePortraitVSpacing)

            liveIndicator()

            PlaybackControlsView(
              viewModel: viewModel, contrastDarkFade: cardContrastDarkFade)

            volumeControl()

            Spacer(minLength: 0)
          }
        }
      }
      .padding(.top, Self.phonePortraitTopPadding)
    }
  }

  // MARK: - Landscape Layout

  /// Top inset holding the song label clear of the landscape card's top edge.
  ///
  /// The column relies on `Spacer`s for that clearance, and they only provide it when there is slack
  /// to distribute. The column's content fills a landscape pane on both platforms, so the spacers
  /// resolve to zero and the label would otherwise sit flush against the edge. This inset is the
  /// floor that survives that collapse.
  private var landscapeCardTopInset: CGFloat { 24 }

  /// Both landscape rows are pinned to the pane's height.
  ///
  /// An unpinned `HStack` takes the height of its tallest child and centres every child against it,
  /// which makes the carousel's vertical position a function of the card column's height — grow the
  /// column and the carousel moves. Pinning holds the row constant so the two columns are
  /// independent: the card's own `Spacer`s absorb its content instead.
  ///
  /// The `.frame` goes after the `.padding` so the inset is taken out of the pane rather than added
  /// to it.
  @ViewBuilder
  func landscapeView(containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
    if usesExpandedLayout {
      // iPad / macOS landscape: hero fills the left half, info+controls card on the right.
      HStack(spacing: landscapeColumnGap) {
        coverFlow(coverSize: expandedCoverSize(containerWidth: containerWidth, isLandscape: true))
        controlsCard(attachedTo: .trailing) {
          VStack(spacing: 24) {
            Spacer()
            // Air time on its own line: this column has the height for a third line, unlike the
            // phone's. Still capped at one line per field, to keep the label's height constant.
            songLabel(maxLines: 1, contrastOverride: cardContrast)
            liveIndicator()
            Spacer().frame(height: 32)
            PlaybackControlsView(
              viewModel: viewModel, contrastDarkFade: cardContrastDarkFade)
            Spacer().frame(height: 32)
            volumeControl()
            Spacer()
          }
          .padding(.horizontal, 20)
          .padding(.top, landscapeCardTopInset)
        }
        // Cap the info/controls column so the hero keeps enough horizontal room for its
        // left/right neighbor covers to stay on screen (they were clipping when the column
        // expanded to fill half the width), while still giving the title/controls real presence.
        .frame(maxWidth: expandedColumnWidth)
      }
      // Leading only: the card is flush to the trailing edge, so a trailing inset would leave a
      // strip of wash beside it.
      .padding(.leading, expandedHPadding)
      .frame(height: containerHeight)
    } else {
      HStack(spacing: landscapeColumnGap) {
        coverFlow(coverSize: compactLandscapeCoverSize(containerWidth: containerWidth))

        controlsCard(attachedTo: .trailing) {
          VStack(spacing: 16) {
            Spacer()
            songLabel(inlineHistoryTime: true, maxLines: 1, contrastOverride: cardContrast)
            liveIndicator()
            Spacer()
            PlaybackControlsView(
              viewModel: viewModel, contrastDarkFade: cardContrastDarkFade)
            volumeControl()
            Spacer()
          }
          .padding(.horizontal, 16)
          .padding(.top, landscapeCardTopInset)
        }
      }
      // Leading + top only: the card is flush to the trailing and bottom edges, as in portrait.
      .padding([.leading, .top])
      .frame(height: containerHeight)
    }
  }

  // MARK: - Cover Flow Hero

  /// The hero carousel. `coverSize` lets each layout size the hero for its canvas — iPad portrait
  /// and (especially) landscape have room for a much larger hero than the phone default. When a
  /// caller doesn't specify, fall back to a per-idiom default: enlarged on iPad, 260 elsewhere.
  @ViewBuilder
  private func coverFlow(coverSize: CGFloat? = nil) -> some View {
    CoverFlowCarousel(
      viewModel: viewModel,
      coverSize: coverSize ?? (PlatformEnvironment.isPad ? 380 : 260)
    )
    .accessibilityLabel(
      Text("Song history. Swipe to browse previously played tracks.", bundle: .module))
  }
}
