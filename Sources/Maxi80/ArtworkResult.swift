import Maxi80Model
import SwiftUI

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

  public init(
    image: Image?, dominantColor: Color, isDefault: Bool, url: String? = nil,
    rgb: Maxi80Model.RGBColor? = nil
  ) {
    self.image = image
    self.dominantColor = dominantColor
    self.isDefault = isDefault
    self.url = url
    self.rgb = rgb
  }

  /// Seed the shared decoded-image cache from this result. `ArtworkService.fetchArtwork` already
  /// decoded the SwiftUI `Image` (Apple only), so registering it under its URL lets the hero and the
  /// carousel render the cover synchronously the instant it becomes current — instead of re-loading
  /// by URL via `AsyncImage`, which flashes the generic placeholder for a frame.
  ///
  /// A no-op for default/placeholder results and on Android, which has no platform image decode.
  /// Lives here rather than on whoever happens to be holding the result: the fact that a resolved
  /// artwork carries a decoded image worth caching is a property of the artwork, and both the
  /// first-fetch and the retry path need it.
  @MainActor
  public func cacheDecodedImage() {
    #if canImport(UIKit) || canImport(AppKit)
      guard !isDefault, let url, let image else { return }
      CoverImageCache.shared.store(image, for: url)
    #endif
  }
}
