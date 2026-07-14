import SwiftUI

/// A slider bound to the **system** audio output volume via `MPVolumeView`. Unlike an
/// `AVPlayer`-relative volume, this controls the OS output level — so it also adjusts the volume of
/// the currently-selected AirPlay device. Reflects hardware volume-button changes live.
///
/// iOS-only (MPVolumeView is unavailable on macOS/Android). The route button is hidden because the
/// app shows a dedicated `AirPlayRoutePicker`.
#if !SKIP && canImport(UIKit)
import MediaPlayer

struct SystemVolumeSlider: UIViewRepresentable {
    var tint: Color = .primary

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        view.tintColor = UIColor(tint)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.tintColor = UIColor(tint)
    }
}
#endif
