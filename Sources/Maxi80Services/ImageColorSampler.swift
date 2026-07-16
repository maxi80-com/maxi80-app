import Foundation

/// Extracts a single dominant (average) color from encoded artwork image bytes, as an uppercase
/// "#RRGGBB" hex string. Lives in the transpiled `Maxi80Services` module so BOTH platforms can
/// sample on-device: the live now-playing path needs a background color immediately on a metadata
/// change, before the backend palette arrives via `/history`. History-browsing colors are handled
/// separately by the backend palette (`ArtworkColors.displayBackground`) and do not use this type.
///
/// Bridged back to the native Fuse module (`ArtworkService`), which maps the hex to its own color
/// types. Returns a hex `String` (a bridge-safe primitive) rather than a model color type, to avoid
/// a cross-module type dependency across the JNI boundary.
/* SKIP @bridge */
#if !SKIP_BRIDGE
public struct ImageColorSampler {

    public init() {}

    /// Decode `data` and return its average color as "#RRGGBB", or `nil` if the bytes can't be
    /// decoded into an image on this platform.
    public func dominantColorHex(from data: Data) -> String? {
        guard let rgb = averagedComponents(from: data) else { return nil }
        return hexString(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Format 0…1 RGB components as an uppercase "#RRGGBB" string. Built manually (no
    /// `String(format:)`) so it transpiles to Kotlin unchanged.
    ///
    /// `public` (not internal) so the test target can exercise it when compiled for Android:
    /// a transpiled (Lite) module exposes only its public surface across the module boundary, so
    /// `@testable`'s internal access — which works on Apple — does not resolve for the Android test build.
    public func hexString(red: Double, green: Double, blue: Double) -> String {
        "#" + hexComponent(red) + hexComponent(green) + hexComponent(blue)
    }

    /// One clamped, zero-padded, uppercase hex byte for a 0…1 component.
    public func hexComponent(_ value: Double) -> String {
        let scaled = (value * 255).rounded()
        let clamped = Int(max(0.0, min(255.0, scaled)))
        let hex = String(clamped, radix: 16).uppercased()
        return hex.count == 1 ? "0" + hex : hex
    }
}
#endif
