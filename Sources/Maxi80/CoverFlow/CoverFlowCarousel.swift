import SwiftUI

/// The single carousel entry point `RadioPlayerView` uses.
///
/// Both platforms now render the shared state-driven `CoverFlowStrip` — every SwiftUI
/// primitive it needs (ZStack, offset, scaleEffect, rotation3DEffect via Compose
/// graphicsLayer, DragGesture with predictedEndTranslation, withTransaction, spring
/// animation) exists in SkipSwiftUI's native Fuse API. The legacy ScrollView renderer
/// (`CoverFlowView`) and the view-model guard tower it needed remain in the tree only
/// until the Android field test confirms parity; then both get deleted.
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
