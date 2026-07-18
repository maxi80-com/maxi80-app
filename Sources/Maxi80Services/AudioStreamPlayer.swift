import Foundation

/// Platform audio stream player for live radio playback.
/// iOS uses AVPlayer; Android uses ExoPlayer (Media3).
/// Platform implementations are provided inside `#if !SKIP_BRIDGE` guards in platform files.
///
/// Note: Does NOT conform to ObservableObject because the transpiled Kotlin context
/// doesn't have SkipModel/Compose dependencies. State observation is handled via
/// callbacks (onMetadataChanged, onError, onInterruption) and the native Fuse module
/// observes state changes through those callbacks.
/* SKIP @bridge */
#if !SKIP_BRIDGE
  @MainActor
  public final class AudioStreamPlayer {
    public var isPlaying: Bool = false
    public var volume: Double = 1.0

    /// Callback invoked when new ICY metadata is received.
    public var onMetadataChanged: ((String) -> Void)?

    /// Callback invoked when an error occurs.
    public var onError: ((String) -> Void)?

    /// Callback invoked when an audio interruption occurs (true = began, false = ended with resume).
    public var onInterruption: ((Bool) -> Void)?

    /// Callback invoked when playback state changes.
    public var onPlaybackStateChanged: ((Bool) -> Void)?

    /// Callback invoked when system volume changes.
    public var onVolumeChanged: ((Double) -> Void)?

    public init() {}

    /// Forward newly-loaded metadata to the registered callback. Called from the iOS metadata
    /// delegate after asynchronously loading the value off the main actor.
    func emitMetadata(_ value: String) {
      if let callback = onMetadataChanged {
        callback(value)
      }
    }

    /// Start streaming from the given URL.
    /// Implementation provided by platform extension files.
    public func play(url: String) {
      #if SKIP
        androidPlay(url: url)
      #elseif os(iOS) || os(tvOS)
        platformPlay(url: url)
      #elseif os(macOS)
        macPlay(url: url)
      #endif
    }

    /// Stop streaming and release resources.
    /// Implementation provided by platform extension files.
    public func stop() {
      #if SKIP
        androidStop()
      #elseif os(iOS) || os(tvOS)
        platformStop()
      #elseif os(macOS)
        macStop()
      #endif
    }

    /// Set the audio output volume (0.0 to 1.0).
    /// Implementation provided by platform extension files.
    public func updateVolume(_ newVolume: Double) {
      #if SKIP
        androidSetVolume(newVolume)
      #elseif os(iOS) || os(tvOS)
        platformSetVolume(newVolume)
      #elseif os(macOS)
        macSetVolume(newVolume)
      #endif
    }
  }
#endif
