import SwiftUI

/// A "sound sharing" button that presents the system AirPlay route picker, letting the user send
/// audio to a connected speaker or AirPlay device — like the output-route button in Apple Music.
///
/// iOS-only: wraps UIKit's `AVRoutePickerView`. On macOS it renders nothing; on Android the whole
/// use site is `#if !SKIP`, so this type is never referenced there.
#if !SKIP && canImport(UIKit)
import AVKit

struct AirPlayRoutePicker: UIViewRepresentable {
    /// Tint for the button glyph in its normal (no active external route) state.
    var tint: Color = .primary
    /// Tint when audio is actively routed to an external device.
    var activeTint: Color = .orange

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor(tint)
        picker.activeTintColor = UIColor(activeTint)
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(tint)
        uiView.activeTintColor = UIColor(activeTint)
    }
}
#elseif !SKIP
// macOS: no AirPlay route picker — render nothing so the type still resolves.
struct AirPlayRoutePicker: View {
    var tint: Color = .primary
    var activeTint: Color = .orange
    var body: some View { EmptyView() }
}
#endif
