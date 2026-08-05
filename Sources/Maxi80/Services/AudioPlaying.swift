// Sources/Maxi80/Services/AudioPlaying.swift
import Foundation
import Maxi80Services

/// The audio-playback surface the coordinator depends on, abstracting the bridged
/// `AudioStreamPlayer` so tests can inject a recording fake.
///
/// Declared in the native module deliberately: it never crosses the JNI boundary, so the
/// `Maxi80Services` bridge is untouched. Mirrors the existing `NowPlayingPublishing` seam.
///
/// `AnyObject` because the coordinator mutates the callback properties on a shared reference and
/// relies on reference semantics for the player's lifetime.
@MainActor
public protocol AudioPlaying: AnyObject {
  /// Whether audio is currently playing, as the player last reported it. May be stale-`false` when
  /// playback was started externally (e.g. Android Auto cold start) — see `syncWithExternalPlayback()`.
  var isPlaying: Bool { get }

  var onMetadataChanged: ((String) -> Void)? { get set }
  var onError: ((String) -> Void)? { get set }
  var onInterruption: ((Bool) -> Void)? { get set }
  var onDisconnectStop: (() -> Void)? { get set }
  var onPlaybackStateChanged: ((Bool) -> Void)? { get set }
  var onVolumeChanged: ((Double) -> Void)? { get set }

  func play(url: String)
  func stop()
  func updateVolume(_ newVolume: Double)
  func setPlaybackAttenuation(_ multiplier: Double)
  func currentVolume() -> Double
  func startObservingVolume()
  func syncWithExternalPlayback() -> Bool
}

/// `AudioStreamPlayer`'s signatures already match exactly, so the conformance is empty.
extension AudioStreamPlayer: AudioPlaying {}
