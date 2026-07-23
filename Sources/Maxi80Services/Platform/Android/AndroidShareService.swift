import Foundation

#if !SKIP_BRIDGE

  #if SKIP
    import android.content.Context
    import android.content.Intent
    import androidx.core.content.FileProvider
    import skip.foundation.ProcessInfo

    // MARK: - AndroidShareService (Android Implementation)

    extension ShareService {

      private var context: Context {
        ProcessInfo.processInfo.androidContext
      }

      /// Present the system share chooser via `Intent.ACTION_SEND`. When artwork bytes are supplied
      /// they're written to a private cache file and exposed through the app's FileProvider as a
      /// `content://` URI (a raw `file://` URI would throw `FileUriExposedException` on API 24+); the
      /// intent then shares `image/*` with the text as `EXTRA_TEXT`. Without bytes it shares
      /// `text/plain` only. Any failure writing the image degrades to a text-only share rather than
      /// dropping the share entirely.
      func androidShare(text: String, imageData: Data?) {
        let ctx = context
        let intent = Intent(Intent.ACTION_SEND)
        intent.putExtra(Intent.EXTRA_TEXT, text)

        if let imageData, let uri = writeSharedImage(imageData, context: ctx) {
          intent.setType("image/*")
          intent.putExtra(Intent.EXTRA_STREAM, uri)
          intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
          // EXTRA_STREAM + the grant flag alone do NOT reach the chooser's preview renderer or
          // targets that read from the clip — the URI must also ride as ClipData for the read grant
          // to propagate. Without this the cover fails to load ("Invalid album art uri" / preview
          // load failure) even though the file and content:// URI are valid.
          intent.setClipData(
            android.content.ClipData.newUri(ctx.getContentResolver(), "artwork", uri))
        } else {
          intent.setType("text/plain")
        }

        let chooser = Intent.createChooser(intent, nil)
        // startActivity from a non-Activity context (we only hold the application context) requires
        // NEW_TASK. The chooser also needs read-grant flags to hand the URI permission to the target.
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        ctx.startActivity(chooser)
      }

      /// Write `imageData` to a file under the app's cache and return a FileProvider `content://` URI
      /// for it, or nil on any failure. Each share uses a unique filename so a still-pending read of
      /// a previous share's URI can't be clobbered by the next share writing the same slot; the OS
      /// reclaims this cache directory under pressure. The `shared_images` subdirectory and the
      /// authority must match `res/xml/file_paths.xml` and the `<provider>` in AndroidManifest.xml.
      /// `getUriForFile` throws (IllegalArgumentException) when the file isn't under a configured
      /// path, so it's inside the do/catch too — a throw degrades to a text-only share, never a crash.
      private func writeSharedImage(_ imageData: Data, context: Context) -> android.net.Uri? {
        let dir = java.io.File(context.cacheDir, "shared_images")
        dir.mkdirs()
        let file = java.io.File(dir, "share-\(java.lang.System.currentTimeMillis()).jpg")
        do {
          let stream = java.io.FileOutputStream(file)
          // Close on every exit path (including a write throw), not just the success path.
          defer { stream.close() }
          stream.write(imageData.platformValue)
          let authority = context.packageName + ".fileprovider"
          return FileProvider.getUriForFile(context, authority, file)
        } catch {
          return nil
        }
      }
    }

  #else
    // Apple platforms present UIActivityViewController via the SwiftUI ShareSheet; no platform
    // implementation is needed here.
  #endif

#endif  // !SKIP_BRIDGE
