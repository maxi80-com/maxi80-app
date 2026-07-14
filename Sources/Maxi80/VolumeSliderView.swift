import SwiftUI

/// A volume slider control that binds to the RadioPlayerViewModel's volume state.
/// Displays speaker icons on either side and updates in real-time when system volume changes.
struct VolumeSliderView: View {
    @Bindable var viewModel: RadioPlayerViewModel

    private var volume: Binding<Double> {
        Binding(
            get: { viewModel.volume },
            set: { viewModel.setVolume($0) }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)

            Slider(value: volume, in: 0...1)
                .tint(.primary)
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
}

// MARK: - Preview

#if ENABLE_PREVIEWS
#Preview("Volume Slider") {
    VolumeSliderView(viewModel: PreviewMocks.makeViewModel())
        .padding()
        .background(Color(red: 0.15, green: 0.1, blue: 0.3))
}
#endif
