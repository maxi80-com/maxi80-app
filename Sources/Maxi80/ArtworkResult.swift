import SwiftUI
import Maxi80Model

/// Result of an artwork fetch operation, containing the image and its extracted dominant color.
/// Lives in the native (Fuse) module since it uses platform-specific SwiftUI image types.
public struct ArtworkResult: Sendable {
    public let image: Image?
    public let dominantColor: Color
    public let isDefault: Bool
    /// Source URL of the remote artwork, if any. Used by the history carousel to
    /// load each cover via `AsyncImage`. `nil` for the default/placeholder cover.
    public let url: String?
    /// Framework-free dominant color, suitable for storing on a `HistoryEntry`.
    public let rgb: Maxi80Model.RGBColor?

    public init(image: Image?, dominantColor: Color, isDefault: Bool, url: String? = nil, rgb: Maxi80Model.RGBColor? = nil) {
        self.image = image
        self.dominantColor = dominantColor
        self.isDefault = isDefault
        self.url = url
        self.rgb = rgb
    }
}

/// Decodes the `/artwork` endpoint response: `{"url": "..."}`.
public struct ArtworkURLResponse: Decodable, Sendable {
    public let url: String
}
