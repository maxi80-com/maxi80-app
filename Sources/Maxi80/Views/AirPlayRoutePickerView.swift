import SwiftUI

/// A "sound sharing" button that presents the system AirPlay route picker, letting the user send
/// audio to a connected speaker or AirPlay device — like the output-route button in Apple Music.
///
/// Wraps `AVRoutePickerView`, which is a `UIView` on iOS and an `NSView` on macOS with a slightly
/// different tinting API. On Android the whole use site is `#if !SKIP`, so this type is never
/// referenced there.
#if !SKIP && canImport(UIKit) && !os(tvOS)
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
#elseif !SKIP && canImport(AppKit)
  import AVKit
  import AppKit

  struct AirPlayRoutePicker: NSViewRepresentable {
    /// Tint for the button glyph. (macOS AVRoutePickerView tints via per-state button color;
    /// it has no `tintColor`/`activeTintColor` like iOS.)
    var tint: Color = .primary
    var activeTint: Color = .orange

    func makeNSView(context: Context) -> AVRoutePickerView {
      let picker = AVRoutePickerView()
      picker.isRoutePickerButtonBordered = false
      applyColors(picker)
      return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
      applyColors(nsView)
    }

    private func applyColors(_ picker: AVRoutePickerView) {
      picker.setRoutePickerButtonColor(NSColor(tint), for: .normal)
      picker.setRoutePickerButtonColor(NSColor(activeTint), for: .active)
    }
  }
#elseif !SKIP
  // Other Apple platforms without a route picker view — render nothing so the type resolves.
  struct AirPlayRoutePicker: View {
    var tint: Color = .primary
    var activeTint: Color = .orange
    var body: some View { EmptyView() }
  }
#endif
