import SwiftUI
import Maxi80Model
import Maxi80Services

/// Root view of the Maxi80 radio player.
///
/// The hero is a Cover Flow carousel of the session's song history: the live track sits at
/// the right edge; swiping right browses older covers in 3D. The background is a gradient
/// derived from the current artwork's dominant color, falling back to a colorScheme-appropriate
/// solid when no artwork color is available. Layout adapts between portrait and landscape.
public struct RadioPlayerView: View {

    @Bindable var viewModel: RadioPlayerViewModel
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.colorScheme) var colorScheme

    public init(viewModel: RadioPlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isPortrait {
                    portraitView()
                } else {
                    landscapeView()
                }
            }
            .background { dynamicBackground().ignoresSafeArea() }
            // The branded default background is always dark, so force dark text/controls when
            // it's showing (no artwork color). With artwork, respect the device scheme.
            .environment(\.colorScheme, viewModel.dominantColor == nil ? .dark : colorScheme)
        }
        .overlay(alignment: .top) {
            if let errorMessage = viewModel.errorMessage {
                errorBanner(message: errorMessage)
            }
        }
    }

    // MARK: - Layout Detection

    private var isPortrait: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .regular
    }

    // MARK: - Background

    @ViewBuilder
    private func dynamicBackground() -> some View {
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

    // MARK: - Portrait Layout

    private func portraitView() -> some View {
        VStack(spacing: 24) {
            Spacer().frame(minHeight: 40) // avoid the dynamic island

            coverFlow()

            songLabel()

            liveIndicator()

            Spacer()

            PlaybackControlsView(viewModel: viewModel)

            volumeControl()

            Spacer().frame(minHeight: 20)
        }
    }

    // MARK: - Landscape Layout

    private func landscapeView() -> some View {
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

    // MARK: - Cover Flow Hero

    @ViewBuilder
    private func coverFlow() -> some View {
        CoverFlowView(
            covers: viewModel.covers,
            selection: $viewModel.selectedCoverID,
            // Pin to the now slot unless the user is browsing history; re-pin whenever the
            // cover set changes (history loads to the left, shifting the viewport).
            pinTarget: viewModel.isBrowsingHistory ? nil : viewModel.liveCoverID,
            pinToken: viewModel.coverPinToken
        )
        .accessibilityLabel(Text("Song history. Swipe to browse previously played tracks.", bundle: .module))
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
#endif
