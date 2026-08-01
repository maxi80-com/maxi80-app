import SwiftUI

/// The single carousel entry point `RadioPlayerView` uses; it hides the platform split.
///
/// Android keeps the legacy `CoverFlowView` (ScrollView + pin/guard machinery, byte-identical
/// call to what `RadioPlayerView` made before) until the native Compose renderer lands; Apple
/// gets the state-driven `AppleCoverFlow`, which follows `CarouselModel.selectedID` and needs
/// none of the guards. Takes the whole view model so the Android leg can reach the legacy
/// pin/guard plumbing without the Apple leg ever touching it.
struct CoverFlowCarousel: View {
  @Bindable var viewModel: RadioPlayerViewModel
  var coverSize: CGFloat = 260

  // Skip Fuse rule: the `#if os(Android)` branch must be inlined in `body`, not extracted
  // into computed @ViewBuilder vars, or the bridge generator mishandles it.
  var body: some View {
    #if os(Android)
      CoverFlowView(
        covers: viewModel.covers,
        // The carousel reads `selectedCoverID` but writes through the view model, which drops
        // writes during a recreation so the transient leftmost-cover relayout can't lose the
        // browsed cover.
        selection: Binding(
          get: { viewModel.selectedCoverID },
          set: { viewModel.setSelectionFromCarousel($0) }
        ),
        // Pin to the now slot unless the user is browsing history; re-pin whenever the
        // cover set changes (history loads to the left, shifting the viewport).
        pinTarget: viewModel.isBrowsingHistory ? nil : viewModel.liveCoverID,
        pinToken: viewModel.coverPinToken,
        coverSize: coverSize
      )
    #else
      AppleCoverFlow(
        covers: viewModel.covers,
        selectedID: viewModel.carousel.selectedID,
        coverSize: coverSize,
        onSettled: { viewModel.carousel.userSettledOn($0) }
      )
    #endif
  }
}
