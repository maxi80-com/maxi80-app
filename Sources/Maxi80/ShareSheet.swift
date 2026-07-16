import SwiftUI

// MARK: - ShareSheet ViewModifier

/// A ViewModifier that presents the platform share sheet when `isPresented` is true.
struct ShareSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let shareText: () -> String

    func body(content view: Content) -> some View {
        view.sheet(isPresented: $isPresented) {
            ShareSheetContent(text: shareText())
        }
    }
}

/// Cross-platform share content view.
struct ShareSheetContent: View {
    let text: String

    var body: some View {
        #if canImport(UIKit) && !os(tvOS)
        ShareSheetRepresentable(text: text)
        #else
        // macOS / Android fallback
        VStack(spacing: 16) {
            Text("Share")
                .font(.headline)
            Text(text)
                .padding()
            Button("Copy") {
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #endif
            }
        }
        .padding()
        #endif
    }
}

#if canImport(UIKit) && !os(tvOS)
import UIKit

/// Wraps UIActivityViewController for SwiftUI presentation on iOS.
struct ShareSheetRepresentable: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [text],
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#if canImport(AppKit)
import AppKit
#endif

// MARK: - View Extension

extension View {
    /// Presents a platform-appropriate share sheet with the given content.
    func shareSheet(isPresented: Binding<Bool>, content: @escaping () -> ShareContent) -> some View {
        modifier(ShareSheetModifier(isPresented: isPresented, shareText: { content().text }))
    }
}
