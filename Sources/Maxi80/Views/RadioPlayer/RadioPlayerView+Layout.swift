import Maxi80Services
import SwiftUI

extension RadioPlayerView {

  // MARK: - Layout Sizing

  /// Whether to use the roomier "big canvas" treatment (enlarged hero + capped info/controls
  /// column) instead of the phone layout. Shared with `PlaybackControlsView`, which renders the
  /// lower half of the same column and must make the same choice.
  var usesExpandedLayout: Bool { PlatformEnvironment.usesExpandedLayout }

  /// Width cap for the info/controls column in the expanded landscape layout.
  private var expandedColumnWidth: CGFloat { 420 }
  private var expandedHSpacing: CGFloat { 24 }
  private var expandedHPadding: CGFloat { 24 }

  /// Hero size for the expanded layouts, derived from the width actually available to the carousel
  /// so its left/right neighbor covers always peek through — a fixed size clipped them on narrower
  /// windows (macOS) even though it fit the iPad. Sized as a fraction of the carousel's own cell
  /// width and capped so it never grows absurdly large on very wide displays.
  private func expandedCoverSize(containerWidth: CGFloat, isLandscape: Bool) -> CGFloat {
    let carouselWidth: CGFloat
    if isLandscape {
      // Left cell of the HStack: total minus padding, inter-column spacing, and the capped column.
      carouselWidth = containerWidth - expandedHPadding * 2 - expandedHSpacing - expandedColumnWidth
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
  // Clearance for the pinned bottom footer. Sized for the brand-logo row (~22pt tall) plus a
  // small margin above it, so the volume row never sits under the logo/version stamp.
  static let phonePortraitBottomPadding: CGFloat = 36

  /// Estimated height of the non-hero *subviews* in phone portrait — song labels + status slot +
  /// two-tier controls + volume row. Kept separate from the paddings/spacing (which are derived
  /// from the named constants above) so only this genuine content estimate is hand-tuned. If those
  /// subviews change materially, update this one number. Verified against iPhone SE → Pro Max.
  /// (This is only the subviews estimate; the derived chrome total adds paddings + gaps below.)
  private static let phonePortraitSubviewsHeight: CGFloat = 332

  /// Total fixed chrome height the adaptive hero must leave room for: the subview estimate plus the
  /// column's own paddings and the 4 inter-element gaps (5 children → 4 spacings).
  private static var phonePortraitChromeHeight: CGFloat {
    phonePortraitSubviewsHeight
      + phonePortraitTopPadding + phonePortraitBottomPadding
      + phonePortraitVSpacing * 4
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
    let carouselWidth = (containerWidth - expandedHSpacing) / 2
    return max(160, min(260, carouselWidth * 0.58))
  }

  // MARK: - Portrait Layout

  @ViewBuilder
  func portraitView(containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
    if usesExpandedLayout {
      // iPad's tall canvas: anchor the enlarged hero + song info near the top and the controls
      // near the bottom, with flexible air between the two groups so the space reads as
      // intentional breathing room rather than one empty void above everything.
      VStack(spacing: 28) {
        Spacer().frame(height: 32)
        coverFlow(coverSize: expandedCoverSize(containerWidth: containerWidth, isLandscape: false))
        songLabel()
        liveIndicator()
        Spacer()
        PlaybackControlsView(
          viewModel: viewModel, contrastDarkFade: playbackControlsContrastFade)
        Spacer().frame(height: 32)
        // The volume row would otherwise stretch edge-to-edge on iPad's wide portrait canvas;
        // cap it so it sits as a centered cluster with generous side insets.
        volumeControl()
          .frame(maxWidth: 520)
        Spacer().frame(height: 48)
      }
    } else {
      // No flexible spacers: they let the column overflow on shorter phones (collapsing to 0 and
      // pushing the footer off-screen) while leaving a dead gap on taller ones. Instead the hero
      // absorbs all the slack — it's sized to exactly the height left after the fixed chrome, so the
      // column always fills the screen precisely: nothing clips, and the coverflow (the app's key
      // element) is as large as the device allows.
      VStack(spacing: Self.phonePortraitVSpacing) {
        coverFlow(
          coverSize: phonePortraitCoverSize(
            containerWidth: containerWidth, containerHeight: containerHeight))

        songLabel()

        liveIndicator()

        PlaybackControlsView(
          viewModel: viewModel, contrastDarkFade: playbackControlsContrastFade)

        volumeControl()
      }
      .padding(.top, Self.phonePortraitTopPadding)
      .padding(.bottom, Self.phonePortraitBottomPadding)  // clearance for the pinned version footer
    }
  }

  // MARK: - Landscape Layout

  @ViewBuilder
  func landscapeView(containerWidth: CGFloat) -> some View {
    if usesExpandedLayout {
      // iPad / macOS landscape: let the hero fill the left half and vertically center the info +
      // controls as one block in the right half (title/artist/back-to-live sat too high before).
      HStack(spacing: expandedHSpacing) {
        coverFlow(coverSize: expandedCoverSize(containerWidth: containerWidth, isLandscape: true))
        VStack(spacing: 24) {
          Spacer()
          songLabel(inlineHistoryTime: true)
          liveIndicator()
          Spacer().frame(height: 32)
          PlaybackControlsView(
            viewModel: viewModel, contrastDarkFade: playbackControlsContrastFade)
          Spacer().frame(height: 32)
          volumeControl()
          Spacer()
        }
        // Cap the info/controls column so the hero keeps enough horizontal room for its
        // left/right neighbor covers to stay on screen (they were clipping when the column
        // expanded to fill half the width), while still giving the title/controls real presence.
        .frame(maxWidth: expandedColumnWidth)
      }
      .padding(.horizontal, expandedHPadding)
    } else {
      HStack(spacing: 24) {
        coverFlow(coverSize: compactLandscapeCoverSize(containerWidth: containerWidth))

        VStack(spacing: 16) {
          Spacer()
          songLabel(inlineHistoryTime: true)
          liveIndicator()
          Spacer()
          PlaybackControlsView(
            viewModel: viewModel, contrastDarkFade: playbackControlsContrastFade)
          volumeControl()
          Spacer()
        }
      }
      .padding()
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
