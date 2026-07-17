// Sources/Maxi80/TV/TVRadioPlayerView.swift
import SwiftUI
import Maxi80Model

/// The 10-foot now-playing screen for tvOS and Android TV. A station-color gradient background (or
/// the branded dusk gradient when no artwork color is available), a large title/artist, a play/pause
/// control, and a focus-navigable history row beneath. Shares `RadioPlayerViewModel` with the phone
/// UI; focus and remote input diverge per platform behind `#if os(tvOS)` / `#if os(Android)`.
public struct TVRadioPlayerView: View {
    @Bindable var viewModel: RadioPlayerViewModel
    @Environment(\.colorScheme) var colorScheme
    #if os(tvOS) || os(Android)
    // Internal, not private: on the Android bridge path a `@FocusState` property must be bridgeable.
    @FocusState var playFocused: Bool
    #endif
    #if os(tvOS)
    @FocusState private var backToLiveFocused: Bool
    #endif

    public init(viewModel: RadioPlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            background().ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                heroCover()
                songLabel()
                controlStack()
                Spacer()
                TVHistoryRow(viewModel: viewModel)
                Spacer().frame(height: 40)
            }
            if let errorMessage = viewModel.errorMessage {
                errorBanner(message: errorMessage)
            }
        }
        .environment(\.colorScheme, viewModel.dominantColor == nil ? .dark : colorScheme)
    }

    /// The focusable controls (Back to live + play/pause). On tvOS they're grouped into a single
    /// `.focusSection()` so a D-pad *up* from anywhere in the history row routes here (and *down*
    /// from here routes back into the row). The section must span the FULL WIDTH — tvOS routes an
    /// up-press to the focus section that lies geometrically above the current item, so a narrow
    /// (button-width) section is only "above" the couple of covers in its column. The surrounding
    /// full-width `HStack` (with `Spacer`s) widens the section to cover every cover in the row.
    @ViewBuilder
    private func controlStack() -> some View {
        #if os(tvOS)
        HStack {
            Spacer()
            VStack(spacing: 20) {
                if viewModel.isBrowsingHistory {
                    backToLiveButton()
                }
                playButton()
            }
            Spacer()
        }
        .focusSection()
        #else
        playButton()
        #endif
    }

    /// The cover currently in focus — the history cover being browsed, or the live "now" slot
    /// (rightmost) otherwise. Drives the hero art so it tracks the title/artist labels below it.
    private var heroCoverModel: CoverFlowView.Cover? {
        let covers = viewModel.covers
        if let selectedCoverID = viewModel.selectedCoverID,
           let id = selectedCoverID.base as? String,
           let match = covers.first(where: { $0.id == id }) {
            return match
        }
        return covers.last
    }

    /// The large now-playing (or focused-history) album art, sitting above the title/artist like
    /// the phone hero. Purely presentational — the focus-navigable covers live in `TVHistoryRow`.
    @ViewBuilder
    private func heroCover() -> some View {
        if let cover = heroCoverModel {
            CoverImage(url: cover.artworkURL, assetName: cover.assetName)
                .frame(width: heroSize, height: heroSize)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        }
    }

    private var heroSize: CGFloat {
        #if os(Android)
        220
        #else
        300
        #endif
    }

    @ViewBuilder
    private func background() -> some View {
        Group {
            if let color = viewModel.dominantColor {
                LinearGradient(
                    gradient: Gradient(colors: [color, color.opacity(0.9)]),
                    startPoint: .top, endPoint: .bottom
                )
                .opacity(0.9)
            } else {
                LinearGradient(
                    colors: [Maxi80Palette.duskTop, Maxi80Palette.night, Maxi80Palette.duskBottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        .animation(.easeInOut(duration: 0.6), value: viewModel.dominantColor)
    }

    @ViewBuilder
    private func songLabel() -> some View {
        VStack(spacing: 12) {
            Text(viewModel.displayedTitle)
                .font(.system(size: titleFontSize, weight: .bold))
                .foregroundStyle(titleColor)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(viewModel.displayedArtist)
                .font(.system(size: artistFontSize, weight: .semibold))
                .foregroundStyle(subtitleColor)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 80)
    }

    // The tvOS 10-foot UI wants large glyphs; the Android TV emulator renders fixed point sizes
    // considerably bigger, so scale the title/artist down there to fit without wrapping.
    private var titleFontSize: CGFloat {
        #if os(Android)
        34
        #else
        56
        #endif
    }

    private var artistFontSize: CGFloat {
        #if os(Android)
        22
        #else
        36
        #endif
    }

    @ViewBuilder
    private func playButton() -> some View {
        let button = Button {
            viewModel.togglePlayback()
        } label: {
            Group {
                if viewModel.isLoading {
                    ProgressView().tint(.orange)
                } else {
                    #if os(Android)
                    AndroidIcon(symbol: viewModel.isPlaying ? .pause : .play, size: 96, tint: .orange)
                    #else
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.orange)
                    #endif
                }
            }
            .frame(width: 96, height: 96)
        }
        .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

        #if os(tvOS)
        // Both `.card` and `.plain` draw tvOS's opaque focus platter (the harsh white box) behind the
        // glyph. `TVGlyphButtonStyle` renders only the label, supplying a gentle focus affordance: a
        // subtle scale + soft translucent halo instead of the platter.
        button
            .buttonStyle(TVGlyphButtonStyle())
            .focused($playFocused)
            .defaultFocus($playFocused, true)
        #elseif os(Android)
        // Android TV assigns no initial focus, and SkipUI's `.defaultFocus` is a no-op there. But
        // `.focused($binding)` calls Compose `requestFocus()` when the binding matches, so seeding
        // `playFocused = true` on appear grants the play button initial focus. `.plain` drops the
        // Compose focus box; the scale supplies the 10-foot focus affordance.
        button
            .buttonStyle(.plain)
            .focused($playFocused)
            .scaleEffect(playFocused ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: playFocused)
            .task { playFocused = true }
        #else
        button
        #endif
    }

    #if os(tvOS)
    /// A focusable "Back to live" pill shown while browsing history; selecting it resets the hero
    /// and labels to the live now slot and returns focus to the play button.
    @ViewBuilder
    private func backToLiveButton() -> some View {
        Button {
            viewModel.returnToLive()
            playFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("Back to live")
            }
            .font(.system(size: 24, weight: .semibold))
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .buttonStyle(TVPillButtonStyle())
        .focused($backToLiveFocused)
    }
    #endif

    // Title/artist sit directly on the dominant-color wash, so their color tracks the background's
    // brightness via `viewModel.isBackgroundDark` (computed from its luminance; always true for the
    // branded dark gradient): white text on dark backgrounds, dark text on bright ones.
    private var titleColor: Color {
        viewModel.isBackgroundDark ? .white : .black
    }

    private var subtitleColor: Color {
        viewModel.isBackgroundDark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
    }

    @ViewBuilder
    private func errorBanner(message: String) -> some View {
        VStack {
            HStack(spacing: 16) {
                Text(message).font(.title3).foregroundStyle(titleColor).lineLimit(2)
                Button("Retry") { viewModel.retry() }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 40)
            Spacer()
        }
    }
}

#if os(tvOS)
/// A tvOS button style for a bare glyph (play/pause) that suppresses the system focus platter.
/// Focus is signalled gently: a modest scale-up plus a soft translucent halo behind the glyph,
/// rather than the opaque white box `.card`/`.plain` draw.
private struct TVGlyphButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(.white.opacity(isFocused ? 0.12 : 0))
                    .blur(radius: 8)
                    .scaleEffect(1.3)
            )
            .scaleEffect(configuration.isPressed ? 1.05 : (isFocused ? 1.15 : 1.0))
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A tvOS pill button (e.g. "Back to live") that highlights on focus with a translucent fill and a
/// gentle scale, avoiding the heavy system platter while keeping a clear 10-foot focus cue.
private struct TVPillButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Capsule().fill(.white.opacity(isFocused ? 0.25 : 0.12))
            )
            .scaleEffect(configuration.isPressed ? 1.02 : (isFocused ? 1.08 : 1.0))
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
#endif
