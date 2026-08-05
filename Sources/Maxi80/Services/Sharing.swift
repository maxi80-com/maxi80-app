import Foundation
import Maxi80Services

/// The share surface the coordinator depends on, abstracting the bridged `ShareService`.
/// Declared in the native module so it never crosses the JNI boundary — see `AudioPlaying`.
@MainActor
public protocol Sharing: AnyObject {
  /// Present the platform share chooser. Fire-and-forget.
  func share(text: String, imageData: Data?)
}

extension ShareService: Sharing {}
