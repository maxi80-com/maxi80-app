import SwiftUI
import Maxi80Model
import Maxi80Services

/// Root view of the Maxi80 radio player app.
/// Layout adapts between portrait (artwork above controls) and landscape (side-by-side).
/// Dynamic gradient background extracted from the current artwork's dominant color.
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
            if isPortrait {
                portraitView()
                    .background { dynamicBackground().ignoresSafeArea() }
            } else {
                landscapeView()
                    .background { dynamicBackground().ignoresSafeArea() }
            }
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
        let baseColor = viewModel.dominantColor
        LinearGradient(
            gradient: Gradient(colors: [baseColor, baseColor.opacity(0.9)]),
            startPoint: isPortrait ? .top : .leading,
            endPoint: isPortrait ? .bottom : .trailing
        )
        .opacity(colorScheme == .dark ? 0.9 : 0.4)
    }

    // MARK: - Portrait Layout

    private func portraitView() -> some View {
        VStack(spacing: 30) {
            Spacer().frame(minHeight: 50) // avoid dynamic island

            artwork()

            Spacer()

            songLabel()

            playButton()

            volumeControl()

            actionButtons()

            Spacer()
        }
    }

    // MARK: - Landscape Layout

    private func landscapeView() -> some View {
        HStack(spacing: 30) {
            artwork()

            VStack {
                Spacer()
                songLabel()
                    .frame(maxHeight: 80)
                Spacer()
                playButton()
                Spacer()
                volumeControl()
                actionButtons()
            }
        }
        .padding()
    }

    // MARK: - Artwork

    @ViewBuilder
    private func artwork() -> some View {
        ArtworkView(artwork: viewModel.currentArtwork)
            .frame(width: 300, height: 300)
            .shadow(
                color: colorScheme == .light ? .black.opacity(0.3) : .gray.opacity(0.3),
                radius: 100, x: 15, y: 15
            )
            .padding(.bottom)
    }

    // MARK: - Song Label

    @ViewBuilder
    private func songLabel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.displayedTitle)
                .foregroundColor(.primary)
                .font(.title2)
                .bold()
                .scaledToFill()
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text(viewModel.displayedArtist)
                .font(.title3)
                .foregroundColor(.secondary)
                .scaledToFill()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .padding(.horizontal)
    }

    // MARK: - Play Button

    @ViewBuilder
    private func playButton() -> some View {
        Button {
            viewModel.togglePlayback()
        } label: {
            if viewModel.isLoading {
                ProgressView()
                    .frame(width: 50, height: 50)
            } else {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .frame(width: 50, height: 50)
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Volume Control

    @ViewBuilder
    private func volumeControl() -> some View {
        #if !SKIP
        HStack {
            Image(systemName: "speaker.fill")
            VolumeSliderView(viewModel: viewModel)
            Image(systemName: "speaker.wave.3.fill")
        }
        .frame(height: 20)
        .padding(.horizontal)
        #endif
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons() -> some View {
        HStack {
            Spacer()

            // Share
            Button {
                // Share action handled via share sheet
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(.orange)
            }
            .disabled(!viewModel.canShare)

            #if !SKIP
            Spacer()

            // AirPlay route picker
            AirPlayButton()
                .frame(width: 24, height: 24)

            Spacer()
            #else
            Spacer()
            #endif
        }
        .padding()
    }

    // MARK: - Error Banner

    private func errorBanner(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer()

            Button("Retry") {
                viewModel.retry()
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

// MARK: - AirPlay Button

#if !SKIP && canImport(UIKit)
import AVKit

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#elseif !SKIP
struct AirPlayButton: View {
    var body: some View { EmptyView() }
}
#endif

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
