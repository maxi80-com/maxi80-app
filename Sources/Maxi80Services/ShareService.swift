import Foundation

/// Fires the platform's native share flow for the current track.
///
/// Lives in the transpiled `Maxi80Services` module because the Android implementation needs the
/// `android.content.Intent` APIs and the `ProcessInfo.processInfo.androidContext` accessor, which
/// only this module imports. Apple platforms present `UIActivityViewController` from the native
/// `Maxi80` UI layer (see `ShareSheet`), so this service is a no-op there — it exists to give the
/// Android UI a real system share chooser instead of a dead-end fallback sheet.
///
/// The share text is produced natively by `RadioPlayerViewModel.shareCurrentTrack()`; the optional
/// artwork bytes are fetched by `ArtworkService`. When `imageData` is nil (no artwork, or the
/// download failed) the Android path degrades to a text-only share.
/* SKIP @bridge */
#if !SKIP_BRIDGE
  public final class ShareService {
    public init() {}

    /// Present the native share chooser with `text` and, when available, `imageData` as an image
    /// attachment. Fire-and-forget: control returns immediately and the OS drives the chooser.
    public func share(text: String, imageData: Data?) {
      #if SKIP
        androidShare(text: text, imageData: imageData)
      #elseif os(iOS) || os(tvOS) || os(macOS)
        // Apple platforms present UIActivityViewController via the SwiftUI `ShareSheet`; nothing to
        // do here. Retained for API parity so the native call site can be platform-agnostic.
      #endif
    }
  }
#endif
