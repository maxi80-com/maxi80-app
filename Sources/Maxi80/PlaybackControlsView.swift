import Maxi80Model
import Maxi80Services
import SwiftUI

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
  @Environment(\.colorScheme) var colorScheme

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

  /// Tint for the secondary (share/donate) glyphs. On Apple `.secondary` already tracks the
  /// forced color scheme. On Android that override doesn't recolor `.secondary` (it stays a fixed
  /// dark gray, invisible on the dark branded background), so resolve an explicit adaptive gray —
  /// same effective-scheme rule as `RadioPlayerView`'s song label.
  private var secondaryControlColor: Color {
    #if os(Android)
      let dark = viewModel.dominantColor == nil ? true : (colorScheme == .dark)
      return dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
    #else
      return Color.secondary
    #endif
  }

  @ViewBuilder
  private var controls: some View {
    HStack(spacing: 36) {
      // Share button — presents platform share sheet
      Button {
        showShareSheet = true
      } label: {
        secondaryIcon(
          "square.and.arrow.up", android: .share,
          tint: secondaryControlColor.opacity(viewModel.canShare ? 1.0 : 0.5))
      }
      .disabled(!viewModel.canShare)
      .accessibilityLabel(Text("Share current track", bundle: .module))

      // Play/pause button — the primary control
      Button {
        viewModel.togglePlayback()
      } label: {
        Group {
          if viewModel.isLoading {
            ProgressView()
              .tint(.orange)
          } else {
            #if os(Android)
              // SF Symbols don't exist on Android and `pause.*`/`play.circle.*` aren't in
              // SkipUI's core-icon map, so draw the extended Material icons directly.
              AndroidIcon(symbol: viewModel.isPlaying ? .pause : .play, size: 68, tint: .orange)
            #else
              Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 68))
                .foregroundStyle(.orange)
            #endif
          }
        }
        .frame(width: 68, height: 68)
      }
      .accessibilityLabel(
        viewModel.isPlaying
          ? Text("Pause", bundle: .module)
          : Text("Play", bundle: .module))

      // Donation button
      if let donationUrl = viewModel.station?.donationUrl,
        !donationUrl.isEmpty,
        let url = URL(string: donationUrl)
      {
        Link(destination: url) {
          secondaryIcon("heart.circle", android: .favorite, tint: secondaryControlColor)
        }
        // Link tints its label with the app accent (orange) by default; force the concrete
        // secondary gray so donate matches the share button and the volume/AirPlay row.
        .tint(secondaryControlColor)
        .accessibilityLabel(Text("Support Maxi 80", bundle: .module))
      } else {
        secondaryIcon("heart.circle", android: .favorite, tint: secondaryControlColor.opacity(0.5))
          .accessibilityHidden(true)
      }
    }
    .shareSheet(isPresented: $showShareSheet) {
      viewModel.shareCurrentTrack()
    }
  }

  /// A secondary control glyph normalized to a fixed size and square frame so the share and
  /// donate buttons align and read as the same size despite their different symbol shapes.
  ///
  /// On Apple platforms this renders the SF Symbol tinted via `.foregroundStyle`. On Android SF
  /// Symbols don't exist (and `heart.circle` isn't in SkipUI's core-icon map), so it draws the
  /// matching extended Material icon, which must be tinted directly rather than through the
  /// foreground style — hence the explicit `tint` parameter.
  @ViewBuilder
  private func secondaryIcon(_ systemName: String, android: MaterialSymbol, tint: Color)
    -> some View
  {
    #if os(Android)
      AndroidIcon(symbol: android, size: secondaryGlyphSize, tint: tint)
        .frame(width: secondaryFrame, height: secondaryFrame)
    #else
      Image(systemName: systemName)
        .font(.system(size: secondaryGlyphSize))
        .frame(width: secondaryFrame, height: secondaryFrame)
        .foregroundStyle(tint)
    #endif
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
