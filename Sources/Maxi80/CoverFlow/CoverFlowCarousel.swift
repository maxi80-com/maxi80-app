import SwiftUI

/// The single carousel entry point `RadioPlayerView` uses.
///
/// Both platforms render the shared state-driven `CoverFlowStrip` — every SwiftUI primitive
/// it needs (ZStack, offset, scaleEffect, rotation3DEffect via Compose graphicsLayer,
/// DragGesture with predictedEndTranslation, spring animation) exists in SkipSwiftUI's
/// native Fuse API. Kept as a thin layer so the view-model wiring stays in one place if a
/// platform ever needs to diverge again.
struct CoverFlowCarousel: View {
  @Bindable var viewModel: RadioPlayerViewModel
  var coverSize: CGFloat = 260

  var body: some View {
    CoverFlowStrip(
      covers: viewModel.covers,
      selectedID: viewModel.carousel.selectedID,
      coverSize: coverSize,
      onSettled: { viewModel.carousel.userSettledOn($0) }
    )
  }
}
