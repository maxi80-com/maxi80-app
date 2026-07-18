import SwiftUI

/// Volume + output row: a system-volume slider (controls OS output, including the AirPlay device)
/// flanked by speaker icons, with a dedicated AirPlay route picker.
struct VolumeSliderView: View {
  @Bindable var viewModel: RadioPlayerViewModel
  @Environment(\.colorScheme) var colorScheme

  var body: some View {
    HStack(spacing: 12) {
      speakerIcon("speaker.fill", android: .volumeDown)

      volumeSlider
        .accessibilityLabel(Text("Volume", bundle: .module))

      speakerIcon("speaker.wave.3.fill", android: .volumeUp)

      // AirPlay / sound-sharing output picker (iOS only). Normal state matches the row's
      // gray glyphs; it flips to orange (its activeTint) only when audio is routed out.
      AirPlayRoutePicker(tint: .secondary)
        .frame(width: 28, height: 28)
        .accessibilityLabel(Text("AirPlay output", bundle: .module))
    }
    .padding(.horizontal)
  }

  /// A speaker glyph flanking the slider. SF Symbol on Apple; on Android the `speaker.*` symbols
  /// aren't in SkipUI's core-icon map, so draw the matching extended Material volume icon.
  @ViewBuilder
  private func speakerIcon(_ systemName: String, android: MaterialSymbol) -> some View {
    #if os(Android)
      // `.secondary` doesn't adapt to the forced scheme on Android (stays dark, invisible on the
      // dark branded background), so tint with an explicit adaptive gray — matches the controls row.
      AndroidIcon(symbol: android, size: 22, tint: secondaryControlColor)
    #else
      Image(systemName: systemName)
        .foregroundStyle(.secondary)
    #endif
  }

  #if os(Android)
    /// Adaptive gray for the speaker glyphs, keyed off the same effective color scheme as the
    /// song label (dark when no artwork color is present).
    private var secondaryControlColor: Color {
      let dark = viewModel.dominantColor == nil ? true : (colorScheme == .dark)
      return dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
    }
  #endif

  @ViewBuilder
  private var volumeSlider: some View {
    #if !SKIP && canImport(UIKit) && !os(tvOS)
      // MPVolumeView drives the system output volume, so it also controls AirPlay device volume.
      // Its internal slider (thumb ~18pt tall) is top-biased inside the view's frame on device, so
      // a tall frame floats the track above the center-aligned speaker icons. Constrain the frame
      // to ~the thumb height, leaving no vertical slack for it to drift — the track then lines up
      // with the icons regardless of the internal anchoring.
      SystemVolumeSlider(tint: .secondary)
        .frame(height: 18)
    #elseif os(tvOS)
      // tvOS has no `Slider` and never renders this view (the TV UI is TVRadioPlayerView); emit
      // nothing so the phone-only VolumeSliderView still compiles into the tvOS binary.
      EmptyView()
    #else
      // macOS: no system-volume view — fall back to the app-relative player volume.
      Slider(
        value: Binding(get: { viewModel.volume }, set: { viewModel.setVolume($0) }),
        in: 0...1
      )
      .tint(Color.secondary)
    #endif
  }
}

// MARK: - Preview

#if ENABLE_PREVIEWS
  #Preview("Volume Slider") {
    VolumeSliderView(viewModel: PreviewMocks.makeViewModel())
      .padding()
      .background(Color(red: 0.15, green: 0.1, blue: 0.3))
  }
#endif
