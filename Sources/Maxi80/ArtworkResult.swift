import SwiftUI

/// Result of an artwork fetch operation, containing the image and its extracted dominant color.
/// Lives in the native (Fuse) module since it uses platform-specific SwiftUI image types.
public struct ArtworkResult: Sendable {
    public let image: Image?
    public let dominantColor: Color
    public let isDefault: Bool

    public init(image: Image?, dominantColor: Color, isDefault: Bool) {
        self.image = image
        self.dominantColor = dominantColor
        self.isDefault = isDefault
    }
}
