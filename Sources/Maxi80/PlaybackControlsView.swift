import SwiftUI
import Maxi80Model
import Maxi80Services

/// Playback controls including play/pause toggle, share button, and donation link.
///
/// Requirements:
/// - 1.1, 1.2: Play/pause toggle
/// - 11.1: AirPlay route picker (iOS only)
/// - 15.1, 15.2: Donation link button
/// - 17.1, 17.5: Share button (disabled when no metadata)
/// - 17.2, 17.3, 17.4: Share sheet with text + artwork
struct PlaybackControlsView: View {
    @Bindable var viewModel: RadioPlayerViewModel
    @State var showShareSheet = false

    var body: some View {
        HStack(spacing: 36) {
            // Share button — presents platform share sheet
            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2)
                    .foregroundStyle(.primary.opacity(viewModel.canShare ? 1.0 : 0.35))
            }
            .disabled(!viewModel.canShare)
            .accessibilityLabel("Share current track")

            // Play/pause button — the primary control
            Button {
                viewModel.togglePlayback()
            } label: {
                Group {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(.primary)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 68))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 68, height: 68)
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            // Donation button
            if let donationUrl = viewModel.station?.donationUrl,
               !donationUrl.isEmpty,
               let url = URL(string: donationUrl) {
                Link(destination: url) {
                    Image(systemName: "heart.circle")
                        .font(.title2)
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("Support Maxi 80")
            } else {
                Image(systemName: "heart.circle")
                    .font(.title2)
                    .foregroundStyle(.primary.opacity(0.35))
                    .accessibilityHidden(true)
            }
        }
        .shareSheet(isPresented: $showShareSheet) {
            viewModel.shareCurrentTrack()
        }
    }
}

// MARK: - Preview

#if ENABLE_PREVIEWS
#Preview("Playing with Metadata") {
    PlaybackControlsView(viewModel: PreviewMocks.makeViewModel(isPlaying: true))
        .padding()
        .background(Color(red: 0.15, green: 0.1, blue: 0.3))
}

#Preview("Paused — Share Disabled") {
    PlaybackControlsView(viewModel: PreviewMocks.makeViewModel(hasMetadata: false))
        .padding()
        .background(Color(red: 0.15, green: 0.1, blue: 0.3))
}
#endif
