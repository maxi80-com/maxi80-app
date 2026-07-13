import Foundation

/// A plain RGB color (components 0...1), kept UI-framework-free so it can live in the model
/// layer and travel with a `HistoryEntry`. The UI layer converts it to a SwiftUI `Color`.
///
/// `Decodable` from a `"#RRGGBB"` hex string so the backend can supply artwork dominant colors
/// directly (avoiding a client-side image download + decode, which also isn't possible on Android).
public struct RGBColor: Sendable, Equatable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(from decoder: Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Self.parse(hex: hex) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid hex color: \(hex)"
            ))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    /// Parses "#RRGGBB" or "RRGGBB".
    public static func parse(hex: String) -> RGBColor? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return RGBColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    public var hexString: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
