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
        controls
        #if os(macOS)
        // macOS gives buttons a default bezel/background; .plain keeps them transparent like iOS.
        .buttonStyle(.plain)
        #endif
    }

    /// Point size for the two secondary (share / donate) glyphs. Both are rendered into an
    /// identical square frame so their differing symbol shapes (a stroked arrow vs a bordered
    /// circle) still occupy the same box and share one visual center.
    private let secondaryGlyphSize: CGFloat = 22
    private let secondaryFrame: CGFloat = 44

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 36) {
            // Share button — presents platform share sheet
            Button {
                showShareSheet = true
            } label: {
                secondaryIcon("square.and.arrow.up")
                    .foregroundStyle(.secondary.opacity(viewModel.canShare ? 1.0 : 0.5))
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
                    secondaryIcon("heart.circle")
                        .foregroundStyle(.secondary)
                }
                // Link tints its label with the app accent (orange) by default; override to
                // .secondary so donate matches the gray share button and the volume/AirPlay row.
                .tint(.secondary)
                .accessibilityLabel("Support Maxi 80")
            } else {
                secondaryIcon("heart.circle")
                    .foregroundStyle(.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
        }
        .shareSheet(isPresented: $showShareSheet) {
            viewModel.shareCurrentTrack()
        }
    }

    /// A secondary control glyph normalized to a fixed size and square frame so the share and
    /// donate buttons align and read as the same size despite their different symbol shapes.
    private func secondaryIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: secondaryGlyphSize))
            .frame(width: secondaryFrame, height: secondaryFrame)
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
