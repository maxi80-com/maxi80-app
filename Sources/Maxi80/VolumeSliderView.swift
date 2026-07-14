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

            // AirPlay / sound-sharing output picker (iOS only).
            AirPlayRoutePicker()
                .frame(width: 28, height: 28)
                .accessibilityLabel("AirPlay output")
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var volumeSlider: some View {
        #if !SKIP && canImport(UIKit)
        // MPVolumeView drives the system output volume, so it also controls AirPlay device volume.
        // Give it its natural height (~44pt): MPVolumeView centers its internal slider vertically
        // within that height, so the HStack's default .center alignment lines the track up with the
        // speaker icons. Forcing a shorter frame pins the slider to the top → misaligned.
        SystemVolumeSlider(tint: .primary)
            .frame(height: 44)
        #else
        // macOS: no system-volume view — fall back to the app-relative player volume.
        Slider(
            value: Binding(get: { viewModel.volume }, set: { viewModel.setVolume($0) }),
            in: 0...1
        )
        .tint(.primary)
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
