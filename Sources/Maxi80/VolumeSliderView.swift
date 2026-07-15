import SwiftUI

/// Volume + output row: a system-volume slider (controls OS output, including the AirPlay device)
/// flanked by speaker icons, with a dedicated AirPlay route picker.
struct VolumeSliderView: View {
    @Bindable var viewModel: RadioPlayerViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)

            volumeSlider
                .accessibilityLabel("Volume")

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)

            // AirPlay / sound-sharing output picker (iOS only). Normal state matches the row's
            // gray glyphs; it flips to orange (its activeTint) only when audio is routed out.
            AirPlayRoutePicker(tint: .secondary)
                .frame(width: 28, height: 28)
                .accessibilityLabel("AirPlay output")
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var volumeSlider: some View {
        #if !SKIP && canImport(UIKit)
        // MPVolumeView drives the system output volume, so it also controls AirPlay device volume.
        // Its internal slider (thumb ~18pt tall) is top-biased inside the view's frame on device, so
        // a tall frame floats the track above the center-aligned speaker icons. Constrain the frame
        // to ~the thumb height, leaving no vertical slack for it to drift — the track then lines up
        // with the icons regardless of the internal anchoring.
        SystemVolumeSlider(tint: .secondary)
            .frame(height: 18)
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
