import SwiftUI

/// A volume slider control that binds to the RadioPlayerViewModel's volume state.
/// Displays speaker icons on either side and updates in real-time when system volume changes.
struct VolumeSliderView: View {
    @Bindable var viewModel: RadioPlayerViewModel

    var body: some View {
        HStack {
            Image(systemName: "speaker.fill")
                .foregroundColor(.white.opacity(0.7))

            Slider(value: Binding(
                get: { viewModel.volume },
                set: { newValue in
                    viewModel.setVolume(newValue)
                }
            ), in: 0...1)
            .tint(.white)

            Image(systemName: "speaker.wave.3.fill")
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal)
    }
}

// MARK: - Preview

#if DEBUG && !SKIP_BRIDGE
#Preview("Volume Slider") {
    VolumeSliderView(viewModel: PreviewMocks.makeViewModel())
        .padding()
        .background(Color(red: 0.15, green: 0.1, blue: 0.3))
}
#endif
