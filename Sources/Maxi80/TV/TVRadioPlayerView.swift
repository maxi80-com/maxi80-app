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
    // Internal, not private: on the Android bridge path `@FocusState`/`@State` properties must be
    // bridgeable. tvOS accepts internal too, so both TV platforms share these declarations.
    @FocusState var playFocused: Bool
    @FocusState var backToLiveFocused: Bool
    #endif
    #if os(Android)
    // The Android wash color, mirrored from `viewModel.dominantColor` so `background()` can tween it
    // with a value-driven `.animation` (Compose interpolates a solid color but not a gradient's
    // colors). Internal, not private: a `@State` on the bridged Android view must be bridgeable.
    @State var androidBackgroundColor: Color?
    #endif

    public init(viewModel: RadioPlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            background().ignoresSafeArea()
            // Row 1: the hero cover beside a left-aligned title/artist (a compact top block that
            // leaves room for the history row). Row 2: the controls. Row 3: the history row. The
            // spacers differ per platform — Android's transpiled VStack collapses flexible `Spacer()`s
            // (which would top-pin and clip the content), so it uses explicit heights; tvOS uses
            // flexible spacers to vertically center the top block.
            VStack(spacing: rowSpacing) {
                #if os(Android)
                Spacer().frame(height: 40)
                #else
                Spacer()
                #endif
                HStack(spacing: 28) {
                    heroCover()
                    songLabel(alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 60)
                controlStack()
                #if os(Android)
                Spacer().frame(height: 40)
                #else
                Spacer()
                #endif
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
        #elseif os(Android)
        // Selecting a history cover on Android enters browse mode (hero + labels switch to the picked
        // song) with no other way back, so surface a focusable "Back to live" pill above the play
        // button while browsing. Uses the proven Android focus pattern (`.plain` + `.focused` +
        // `.scaleEffect`) rather than a `@Environment(\.isFocused)` ButtonStyle.
        VStack(spacing: 20) {
            if viewModel.isBrowsingHistory {
                backToLiveButtonAndroid()
            }
            playButton()
        }
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

    /// The hero's identity for the crossfade below, keyed on the artwork content. The live now slot
    /// keeps the constant id `__now__` while its artwork swaps, so `cover.id` can't be used. Keying on
    /// the artwork (not the song title) makes the crossfade fire when the image changes — the title
    /// updates before the new artwork resolves, so the two are not simultaneous.
    private func heroKey(_ cover: CoverFlowView.Cover) -> String {
        cover.artworkURL ?? cover.assetName ?? cover.id
    }

    /// The large now-playing (or focused-history) album art, sitting above the title/artist like
    /// the phone hero. Purely presentational — the focus-navigable covers live in `TVHistoryRow`.
    ///
    /// On both TV platforms, keying on the artwork makes a cover change a remove+insert, so it
    /// crossfades: the previous image fades out while the new one fades in. Keying on the artwork (not
    /// the song title) makes the rebuild coincide with the image actually changing, avoiding a flash
    /// through the placeholder. `.transition(.opacity)` + `.animation(_:value:)` are the only
    /// animation APIs used here — no `.scale`/`anchor:`, which are unavailable on Android.
    @ViewBuilder
    private func heroCover() -> some View {
        if let cover = heroCoverModel {
            let image = CoverImage(url: cover.artworkURL, assetName: cover.assetName)
                .frame(width: heroSize, height: heroSize)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

            #if os(tvOS) || os(Android)
            let key = heroKey(cover)
            image
                .id(key)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.4), value: key)
            #else
            image
            #endif
        }
    }

    private var rowSpacing: CGFloat {
        #if os(Android)
        24
        #else
        28
        #endif
    }

    private var heroSize: CGFloat {
        #if os(Android)
        160
        #else
        300
        #endif
    }

    // Frame the play glyph. Android's Material glyph fills its frame, so the frame matches the
    // reduced glyph size; tvOS keeps the larger SF Symbol box.
    private var playGlyphSize: CGFloat {
        #if os(Android)
        52
        #else
        96
        #endif
    }

    @ViewBuilder
    private func background() -> some View {
        #if os(Android)
        // Compose can't tween a gradient's colors (a value-`.animation` or `.id`+opacity crossfade both
        // snap on the transpiled path). It CAN tween a solid fill via `animateColorAsState`, so the
        // Android wash is a solid `Color` base — animated by `.animation(_:value:)`, mirrored into
        // `androidBackgroundColor` — under a STATIC top→bottom alpha gradient that keeps the wash's shape.
        // The color is resolved (never nil) so there's always a concrete value to interpolate between;
        // nil maps to the branded night color.
        ZStack {
            androidWashColor
                .animation(.easeInOut(duration: 1.0), value: androidBackgroundColor)
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .onChange(of: viewModel.dominantColor, initial: true) { _, newColor in
            androidBackgroundColor = newColor
        }
        #else
        // Apple platforms interpolate a value-driven `.animation` across the gradient's colors
        // natively, so the wash eases with no local mirror needed.
        gradient(for: viewModel.dominantColor)
            .animation(.easeInOut(duration: bgAnimationDuration), value: viewModel.dominantColor)
        #endif
    }

    #if os(Android)
    // The solid wash color for Android: the mirrored dominant color, or the branded night color when
    // there's none. Always concrete so `animateColorAsState` has two colors to interpolate between.
    private var androidWashColor: Color {
        androidBackgroundColor ?? Maxi80Palette.night
    }
    #else
    private var bgAnimationDuration: Double {
        #if os(tvOS)
        1.0
        #else
        0.6
        #endif
    }
    #endif

    /// The background wash: a soft vertical gradient of the artwork's dominant color, or the branded
    /// dusk gradient when there's no color.
    @ViewBuilder
    private func gradient(for color: Color?) -> some View {
        if let color {
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

    @ViewBuilder
    // `alignment` is `.center` for the stacked tvOS layout and `.leading` for the Android layout,
    // where the labels sit to the right of the hero.
    private func songLabel(alignment: HorizontalAlignment = .center) -> some View {
        VStack(alignment: alignment, spacing: 12) {
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
        .multilineTextAlignment(alignment == .leading ? .leading : .center)
        .padding(.horizontal, alignment == .leading ? 0 : 80)
    }

    // The tvOS 10-foot UI wants large glyphs; the Android TV emulator renders fixed point sizes
    // considerably bigger, so scale the title/artist down there to fit without wrapping.
    private var titleFontSize: CGFloat {
        #if os(Android)
        26
        #else
        56
        #endif
    }

    private var artistFontSize: CGFloat {
        #if os(Android)
        18
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
                    // The Material play/pause glyph renders larger than an equivalently-sized SF
                    // Symbol, so Android uses a smaller point size to match the tvOS visual weight.
                    AndroidIcon(symbol: viewModel.isPlaying ? .pause : .play, size: playGlyphSize, tint: .orange)
                    #else
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.orange)
                    #endif
                }
            }
            .frame(width: playGlyphSize, height: playGlyphSize)
        }
        .accessibilityLabel(viewModel.isPlaying
            ? Text("Pause", bundle: .module)
            : Text("Play", bundle: .module))

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
        // `playFocused = true` on appear grants the play button initial focus.
        //
        // SkipUI's Button draws Compose's default focus/press indication (a gray SQUARE at the min
        // 48dp touch target) that `.buttonStyle(.plain)` doesn't suppress. Clipping the button to a
        // Circle reshapes that indication into a circle that blends into our own affordance: a soft
        // blurred translucent circle behind the glyph plus a gentle scale, matching the tvOS
        // `TVGlyphButtonStyle`. The halo's tint adapts to the background luminance (light on dark, dark
        // on light) so it reads on both.
        button
            .buttonStyle(.plain)
            .clipShape(Circle())
            .background(
                Circle()
                    .fill((viewModel.isBackgroundDark ? Color.white : Color.black)
                        .opacity(playFocused ? 0.15 : 0))
                    .blur(radius: 8)
                    .scaleEffect(1.4)
            )
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
                Text("Back to live", bundle: .module)
            }
            .font(.system(size: 24, weight: .semibold))
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .buttonStyle(TVPillButtonStyle())
        .focused($backToLiveFocused)
    }
    #endif

    #if os(Android)
    /// Android TV "Back to live" pill shown while browsing history. Mirrors the tvOS pill visually
    /// but uses the SkipUI-proven pattern: `.buttonStyle(.plain)` + `.focused` + `.scaleEffect`
    /// (no `@Environment(\.isFocused)` ButtonStyle, unverified on Compose). The
    /// `dot.radiowaves.left.and.right` SF Symbol has no SkipUI mapping, so draw the extended Material
    /// broadcast icon via `AndroidIcon` (same as the phone "Back to live").
    @ViewBuilder
    private func backToLiveButtonAndroid() -> some View {
        Button {
            viewModel.returnToLive()
            playFocused = true
        } label: {
            HStack(spacing: 8) {
                AndroidIcon(symbol: .liveBroadcast, size: 15, tint: .white)
                Text("Back to live", bundle: .module)
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(backToLiveFocused ? 0.25 : 0.12)))
        }
        .buttonStyle(.plain)
        .focused($backToLiveFocused)
        .scaleEffect(backToLiveFocused ? 1.08 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: backToLiveFocused)
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
                Text(verbatim: message).font(.title3).foregroundStyle(titleColor).lineLimit(2)
                Button { viewModel.retry() } label: { Text("Retry", bundle: .module) }
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
