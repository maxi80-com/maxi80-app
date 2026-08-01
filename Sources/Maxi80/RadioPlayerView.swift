import Maxi80Model
import Maxi80Services
import SwiftUI

/// Root view of the Maxi80 radio player.
///
/// The hero is a Cover Flow carousel of the session's song history: the live track sits at
/// the right edge; swiping right browses older covers in 3D. The background is a gradient
/// derived from the current artwork's dominant color, falling back to a colorScheme-appropriate
/// solid when no artwork color is available. Layout adapts between portrait and landscape.
public struct RadioPlayerView: View {

  @Bindable var viewModel: RadioPlayerViewModel
  @Environment(\.colorScheme) var colorScheme
  @Environment(\.scenePhase) var scenePhase

  public init(viewModel: RadioPlayerViewModel) {
    self.viewModel = viewModel
  }

  public var body: some View {
    NavigationStack {
      // Detect orientation from the actual container size rather than size class: on iPad the
      // horizontal size class is `.regular` in both orientations, so a size-class test never
      // reports portrait. Width-vs-height also tracks iPad split-view / Slide Over pane sizes.
      GeometryReader { geo in
        let isPortrait = geo.size.height > geo.size.width
        Group {
          if isPortrait {
            portraitView(containerWidth: geo.size.width)
          } else {
            landscapeView(containerWidth: geo.size.width)
          }
        }
        // GeometryReader top-left-aligns its child; expand so the layout fills the pane as before.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { dynamicBackground(isPortrait: isPortrait).ignoresSafeArea() }
        // The branded default background is always dark, so force dark text/controls when
        // it's showing (no artwork color). With artwork, respect the device scheme.
        .environment(\.colorScheme, viewModel.dominantColor == nil ? .dark : colorScheme)
        // Android only: a rotation recreates the legacy CoverFlowView; open a short window where
        // its selection write-back is dropped so the browsed cover survives the recreation. The
        // Apple renderer is state-driven and survives recreation with no guard.
        #if os(Android)
          .onChange(of: isPortrait) { _, _ in viewModel.beginReorientation() }
        #endif
        // Returning to the foreground recreates the view tree (esp. the Android activity) the same
        // way; reconcile playback + guard the carousel. The Android activity's onResume also drives
        // this via the app delegate, so both entry paths (icon and notification) are covered. #9
        .onChange(of: scenePhase) { _, newPhase in
          if newPhase == .active { SharedPlayer.handleForeground() }
        }
        .overlay(alignment: .bottom) { versionFooter }
      }
    }
    .overlay(alignment: .top) {
      if let errorMessage = viewModel.errorMessage {
        errorBanner(message: errorMessage)
      }
    }
  }

  // MARK: - Background

  @ViewBuilder
  private func dynamicBackground(isPortrait: Bool) -> some View {
    Group {
      if let color = viewModel.dominantColor {
        // Artwork-driven: a soft wash of the cover's dominant color.
        LinearGradient(
          gradient: Gradient(colors: [color, color.opacity(0.9)]),
          startPoint: isPortrait ? .top : .leading,
          endPoint: isPortrait ? .bottom : .trailing
        )
        .opacity(colorScheme == .dark ? 0.9 : 0.4)
      } else {
        brandBackground()
      }
    }
    .animation(.easeInOut(duration: 0.6), value: viewModel.dominantColor)
  }

  /// Default on-brand background when no artwork color is available: a dark neon-dusk drawn
  /// from the Maxi'80 logo (deep violet → night → warm ember), with a soft violet glow behind
  /// the hero. Deliberately dark in both color schemes to match the logo's black base.
  @ViewBuilder
  private func brandBackground() -> some View {
    ZStack {
      LinearGradient(
        colors: [Maxi80Palette.duskTop, Maxi80Palette.night, Maxi80Palette.duskBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      // Neon glow behind the artwork, echoing the logo's violet→orange sweep.
      RadialGradient(
        colors: [Maxi80Palette.violet.opacity(0.35), .clear],
        center: .init(x: 0.5, y: 0.34),
        startRadius: 0,
        endRadius: 460
      )
      RadialGradient(
        colors: [Maxi80Palette.orange.opacity(0.16), .clear],
        center: .init(x: 0.85, y: 0.1),
        startRadius: 0,
        endRadius: 340
      )
    }
  }

  // MARK: - Layout Sizing

  /// Whether to use the roomier "big canvas" treatment (enlarged hero + capped info/controls
  /// column) instead of the phone layout. True on iPad and on macOS — both have a large window to
  /// fill; iPhone/Android phones keep the compact phone layout.
  private var usesExpandedLayout: Bool {
    #if os(macOS)
      return true
    #else
      return PlatformEnvironment.isPad
    #endif
  }

  /// Width cap for the info/controls column in the expanded landscape layout.
  private let expandedColumnWidth: CGFloat = 420
  private let expandedHSpacing: CGFloat = 24
  private let expandedHPadding: CGFloat = 24

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

  // MARK: - Portrait Layout

  @ViewBuilder
  private func portraitView(containerWidth: CGFloat) -> some View {
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
        PlaybackControlsView(viewModel: viewModel)
        Spacer().frame(height: 32)
        // The volume row would otherwise stretch edge-to-edge on iPad's wide portrait canvas;
        // cap it so it sits as a centered cluster with generous side insets.
        volumeControl()
          .frame(maxWidth: 520)
        Spacer().frame(height: 48)
      }
    } else {
      VStack(spacing: 24) {
        Spacer().frame(minHeight: 40)  // avoid the dynamic island

        coverFlow()

        songLabel()

        liveIndicator()

        Spacer()

        PlaybackControlsView(viewModel: viewModel)

        volumeControl()

        Spacer().frame(minHeight: 20)
      }
    }
  }

  // MARK: - Landscape Layout

  @ViewBuilder
  private func landscapeView(containerWidth: CGFloat) -> some View {
    if usesExpandedLayout {
      // iPad / macOS landscape: let the hero fill the left half and vertically center the info +
      // controls as one block in the right half (title/artist/back-to-live sat too high before).
      HStack(spacing: expandedHSpacing) {
        coverFlow(coverSize: expandedCoverSize(containerWidth: containerWidth, isLandscape: true))
        VStack(spacing: 24) {
          Spacer()
          songLabel()
          liveIndicator()
          Spacer().frame(height: 32)
          PlaybackControlsView(viewModel: viewModel)
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
        coverFlow()

        VStack(spacing: 16) {
          Spacer()
          songLabel()
          liveIndicator()
          Spacer()
          PlaybackControlsView(viewModel: viewModel)
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

  // MARK: - Song Label

  @ViewBuilder
  private func songLabel() -> some View {
    let label = VStack(alignment: .center, spacing: 12) {
      Text(viewModel.displayedTitle)
        .foregroundStyle(titleColor)
        .font(.system(size: titleFontSize, weight: .bold))
        .lineLimit(2)
        .minimumScaleFactor(0.5)

      Text(viewModel.displayedArtist)
        .font(.system(size: subtitleFontSize, weight: .semibold))
        .foregroundStyle(subtitleColor)
        .lineLimit(2)
        .minimumScaleFactor(0.5)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, 20)

    #if os(Android)
      label
    #else
      label.accessibilityElement(children: .combine)
    #endif
  }

  /// Song title / artist point sizes. SkipUI maps SwiftUI's semantic font styles (`.largeTitle`,
  /// `.title`) to noticeably larger Material text sizes on Android, so the title wrapped to two
  /// lines there while fitting one on iOS. Use explicit sizes per platform: a touch larger on
  /// Apple, smaller on Android, to match visually.
  private var titleFontSize: CGFloat {
    #if os(Android)
      26
    #else
      38
    #endif
  }

  private var subtitleFontSize: CGFloat {
    #if os(Android)
      19
    #else
      30
    #endif
  }

  /// The effective color scheme behind the song label: the branded background is always dark, so
  /// force dark there; otherwise follow the device. Mirrors the `.environment(\.colorScheme, …)`
  /// override applied in `body`.
  private var effectiveColorScheme: ColorScheme {
    viewModel.dominantColor == nil ? .dark : colorScheme
  }

  /// Title color. On Apple platforms the semantic `.primary` already tracks the forced scheme.
  /// On Android the forced `colorScheme` environment override does not recolor semantic text
  /// styles, so resolve an explicit high-contrast color against the effective scheme.
  private var titleColor: Color {
    #if os(Android)
      effectiveColorScheme == .dark ? .white : .black
    #else
      .primary
    #endif
  }

  /// Subtitle color — a dimmed counterpart to `titleColor`, matching `.secondary` on Apple.
  private var subtitleColor: Color {
    #if os(Android)
      effectiveColorScheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
    #else
      .secondary
    #endif
  }

  // MARK: - Back to Live

  @ViewBuilder
  private func liveIndicator() -> some View {
    // Shown only while browsing an older cover; tapping returns to the live track.
    if viewModel.isBrowsingHistory {
      Button {
        withAnimation(.easeInOut) { viewModel.returnToLive() }
      } label: {
        backToLiveLabel
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 14)
          .padding(.vertical, 7)
          .background(.orange, in: Capsule())
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    } else {
      // Reserve consistent vertical space so the layout doesn't jump.
      Color.clear.frame(height: 32)
    }
  }

  /// "Back to live" pill content. The `dot.radiowaves.left.and.right` SF Symbol has no SkipUI
  /// Material mapping, so on Android draw the closest extended icon (broadcast waves) beside the
  /// text; Apple keeps the SF Symbol label.
  @ViewBuilder
  private var backToLiveLabel: some View {
    #if os(Android)
      HStack(spacing: 6) {
        AndroidIcon(symbol: .liveBroadcast, size: 15, tint: .white)
        Text("Back to live", bundle: .module)
      }
    #else
      Label {
        Text("Back to live", bundle: .module)
      } icon: {
        Image(systemName: "dot.radiowaves.left.and.right")
      }
    #endif
  }

  // MARK: - Volume Control

  @ViewBuilder
  private func volumeControl() -> some View {
    #if !SKIP
      VolumeSliderView(viewModel: viewModel)
        .padding(.horizontal)
    #endif
  }

  // MARK: - Version Footer

  /// A tiny, discreet build stamp pinned to the very bottom edge (phone screens only — the TV,
  /// CarPlay, and Android Auto UIs are separate entry points and never render this view). The
  /// string is extracted per-platform by `AppVersion`; the styling here is identical on both.
  @ViewBuilder
  private var versionFooter: some View {
    Text(verbatim: AppVersion.displayString)
      .font(.system(size: 10))
      .foregroundStyle(subtitleColor.opacity(0.6))
      .padding(.bottom, 4)
      .accessibilityHidden(true)
  }

  // MARK: - Error Banner

  private func errorBanner(message: String) -> some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)

      Text(verbatim: message)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .lineLimit(2)

      Spacer()

      Button {
        viewModel.retry()
      } label: {
        Text("Retry", bundle: .module)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal)
    .padding(.top, 8)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}

// MARK: - Previews

#if ENABLE_PREVIEWS
  #Preview("Playing — Portrait") {
    RadioPlayerView(viewModel: PreviewMocks.makeViewModel(isPlaying: true))
      .tint(.orange)
  }

  #Preview("Idle — Station Info") {
    RadioPlayerView(viewModel: PreviewMocks.makeViewModel(hasMetadata: false, hasHistory: false))
      .tint(.orange)
  }

  #Preview("Error State") {
    RadioPlayerView(viewModel: PreviewMocks.makeViewModel(hasError: true))
      .tint(.orange)
  }

  // iPad landscape: exercises the enlarged hero + capped info/controls column. The device trait
  // makes `PlatformEnvironment.isPad` resolve true so the iPad layout branch renders.
  #Preview("iPad Landscape", traits: .landscapeLeft) {
    RadioPlayerView(viewModel: PreviewMocks.makeViewModel(isPlaying: true))
      .tint(.orange)
  }
#endif
