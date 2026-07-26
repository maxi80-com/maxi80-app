import SwiftUI

// MARK: - ShareSheet ViewModifier

/// A ViewModifier that presents the platform share sheet when `isPresented` is true.
///
/// The cover artwork is downloaded when the sheet opens (`UIActivityViewController` needs raw bytes /
/// a `UIImage`, not the SwiftUI `Image` the app holds). Because the activity controller captures its
/// items at creation, the sheet shows a brief spinner while the bytes load, then presents the share
/// controller built once with text + image. A download miss degrades to a text-only share.
struct ShareSheetModifier: ViewModifier {
  @Binding var isPresented: Bool
  let shareText: () -> String
  /// Fetches the displayed cover's bytes for the share, or nil for a text-only share.
  let shareImageData: () async -> Data?

  func body(content view: Content) -> some View {
    view.sheet(isPresented: $isPresented) {
      ShareSheetLoader(shareText: shareText, shareImageData: shareImageData)
    }
  }
}

/// Resolves the share text (synchronous) and cover bytes (async) before building the share content,
/// so `UIActivityViewController` is created once with the image already attached.
struct ShareSheetLoader: View {
  let shareText: () -> String
  let shareImageData: () async -> Data?

  // Internal, not private: Skip's bridge requires @State properties to be non-private.
  @State var resolved: (text: String, imageData: Data?)?

  var body: some View {
    Group {
      if let resolved {
        ShareSheetContent(text: resolved.text, imageData: resolved.imageData)
      } else {
        // `.controlSize` isn't in SkipUI's API surface; this loader only ever renders on Apple
        // platforms (Android fires its own native chooser), so gate the modifier out there.
        let spinner = ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(Android)
          spinner
        #else
          spinner.controlSize(.large)
        #endif
      }
    }
    .task {
      let text = shareText()
      let data = await shareImageData()
      resolved = (text, data)
    }
  }
}

/// Cross-platform share content view.
struct ShareSheetContent: View {
  let text: String
  var imageData: Data? = nil

  var body: some View {
    #if canImport(UIKit) && !os(tvOS)
      ShareSheetRepresentable(text: text, imageData: imageData)
    #else
      // macOS / Android fallback
      VStack(spacing: 16) {
        Text("Share", bundle: .module)
          .font(.headline)
        Text(verbatim: text)
          .padding()
        Button {
          #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
          #endif
        } label: {
          Text("Copy", bundle: .module)
        }
      }
      .padding()
    #endif
  }
}

#if canImport(UIKit) && !os(tvOS)
  import UIKit

  /// Wraps UIActivityViewController for SwiftUI presentation on iOS. Shares the track text plus the
  /// cover image (as a `UIImage`) when its bytes are available, matching the Android native share.
  struct ShareSheetRepresentable: UIViewControllerRepresentable {
    let text: String
    var imageData: Data? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(
        activityItems: activityItems,
        applicationActivities: nil
      )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    /// Text first, then the cover image when decodable, so text stays the primary content (message
    /// body) with the artwork as an attachment.
    private var activityItems: [Any] {
      var items: [Any] = [text]
      if let imageData, let image = UIImage(data: imageData) {
        items.append(image)
      }
      return items
    }
  }
#endif

#if canImport(AppKit)
  import AppKit
#endif

// MARK: - View Extension

extension View {
  /// Presents a platform-appropriate share sheet with the given text and, on iOS, the displayed
  /// cover artwork (downloaded when the sheet opens).
  func shareSheet(
    isPresented: Binding<Bool>,
    text: @escaping () -> String,
    imageData: @escaping () async -> Data?
  ) -> some View {
    modifier(
      ShareSheetModifier(isPresented: isPresented, shareText: text, shareImageData: imageData))
  }
}
