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
    #if os(tvOS)
    @FocusState private var playFocused: Bool
    #endif

    public init(viewModel: RadioPlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            background().ignoresSafeArea()
            VStack(spacing: 40) {
                Spacer()
                songLabel()
                playButton()
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
        VStack(spacing: 16) {
            Text(viewModel.displayedTitle)
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(titleColor)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(viewModel.displayedArtist)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(subtitleColor)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 80)
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
        button.focused($playFocused).defaultFocus($playFocused, true)
        #else
        button
        #endif
    }

    private var titleColor: Color {
        #if os(Android)
        (viewModel.dominantColor == nil ? true : colorScheme == .dark) ? .white : .black
        #else
        .primary
        #endif
    }

    private var subtitleColor: Color {
        #if os(Android)
        (viewModel.dominantColor == nil ? true : colorScheme == .dark)
            ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
        #else
        .secondary
        #endif
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
