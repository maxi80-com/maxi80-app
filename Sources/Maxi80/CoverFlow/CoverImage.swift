import SwiftUI

/// A single cover image: a remote artwork URL for played songs, or a bundled asset for the
/// startup placeholder. Falls back to the default generic cover if neither loads.
///
/// On Apple platforms a once-loaded image is kept in a small in-memory cache and rendered
/// synchronously on reappearance, so revisiting a cover (e.g. browsing history, where a `.id()`
/// change rebuilds the view) never flashes the placeholder while `AsyncImage` re-decodes. Android
/// keeps `AsyncImage` (backed by Coil, which caches decoded bitmaps itself).
struct CoverImage: View {
  var url: String? = nil
  var assetName: String? = nil

  var body: some View {
    if let url, let imageURL = URL(string: url) {
      #if canImport(UIKit) || canImport(AppKit)
        if let cached = CoverImageCache.shared.image(for: url) {
          cached.resizable().scaledToFill()
        } else {
          AsyncImage(url: imageURL) { phase in
            switch phase {
            case .success(let image):
              image.resizable().scaledToFill()
                // Cache the SwiftUI Image keyed by URL so the next appearance is instant.
                .task(id: url) { CoverImageCache.shared.store(image, for: url) }
            case .empty:
              placeholder.overlay { ProgressView().tint(.white) }
            case .failure:
              placeholder
            @unknown default:
              placeholder
            }
          }
        }
      #else
        AsyncImage(url: imageURL) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFill()
          case .empty:
            placeholder.overlay { ProgressView().tint(.white) }
          case .failure:
            placeholder
          @unknown default:
            placeholder
          }
        }
      #endif
    } else {
      placeholder
    }
  }

  private var placeholder: some View {
    Image(assetName ?? "NoCover-a", bundle: .module)
      .resizable()
      .scaledToFill()
  }
}

#if canImport(UIKit) || canImport(AppKit)
  /// A tiny in-memory cache of decoded SwiftUI `Image`s keyed by artwork URL, so a cover that has
  /// already been shown renders synchronously on its next appearance instead of restarting an
  /// `AsyncImage` load (which flashes the placeholder for a frame). Apple-only — `Image` is a
  /// platform type; Android relies on Coil's own cache. `@MainActor` since it's touched only from view
  /// bodies/tasks.
  @MainActor
  final class CoverImageCache {
    static let shared = CoverImageCache()

    private var images: [String: Image] = [:]

    func image(for url: String) -> Image? {
      images[url]
    }

    func store(_ image: Image, for url: String) {
      images[url] = image
    }
  }
#endif
