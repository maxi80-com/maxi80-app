// Tests/Maxi80Tests/Fakes/FakeAudioPlayer.swift
import Foundation

@testable import Maxi80

/// One recorded interaction the coordinator had with the player, in order.
enum PlayerCommand: Equatable {
  case play(url: String)
  case stop
  case updateVolume(Double)
  case setAttenuation(Double)
  case startObservingVolume
  case syncWithExternalPlayback
}

/// Recording fake for `AudioPlaying`.
///
/// Exists because the real `AudioStreamPlayer` spins up the platform AVPlayer path and only allows
/// pushing callbacks inward — tests could not observe what the coordinator asked the player to DO.
@MainActor
final class FakeAudioPlayer: AudioPlaying {

  /// Every command the coordinator issued, in order.
  var commands: [PlayerCommand] = []

  /// Staged state the coordinator reads.
  var isPlaying: Bool = false
  /// What `syncWithExternalPlayback()` returns — stage `true` to simulate externally-started
  /// playback (Android Auto cold start) that the `isPlaying` flag hasn't caught up with.
  var syncResult: Bool = false
  /// What `currentVolume()` returns.
  var systemVolume: Double = 1.0

  /// Whether `play(url:)` establishes playback (sets `isPlaying`). `true` mirrors the happy path.
  /// Stage `false` to simulate a `play(url:)` that does NOT recover audio — a dead stream URL, or a
  /// reconnect attempt that fails to reach the live edge. This is what makes the *positive*
  /// direction of the reconnect confirmation testable: with this `false`, `isPlaying` stays whatever
  /// the test staged, so a coordinator that declares a reconnect confirmed without consulting the
  /// player is distinguishable from one that consults it.
  var playEstablishesPlayback = true

  /// Mirrors the real player's stored values so tests can read the final state.
  var volume: Double = 1.0
  var attenuation: Double = 1.0

  var onMetadataChanged: ((String) -> Void)?
  var onError: ((String) -> Void)?
  var onInterruption: ((Bool) -> Void)?
  var onDisconnectStop: (() -> Void)?
  var onPlaybackStateChanged: ((Bool) -> Void)?
  var onVolumeChanged: ((Double) -> Void)?

  func play(url: String) {
    commands.append(.play(url: url))
    if playEstablishesPlayback {
      isPlaying = true
    }
  }

  func stop() {
    commands.append(.stop)
    isPlaying = false
  }

  func updateVolume(_ newVolume: Double) {
    commands.append(.updateVolume(newVolume))
    volume = newVolume
  }

  func setPlaybackAttenuation(_ multiplier: Double) {
    commands.append(.setAttenuation(multiplier))
    attenuation = multiplier
  }

  func currentVolume() -> Double { systemVolume }

  func startObservingVolume() {
    commands.append(.startObservingVolume)
  }

  func syncWithExternalPlayback() -> Bool {
    commands.append(.syncWithExternalPlayback)
    // Mirror the Apple platform: syncWithExternalPlayback() returns isPlaying.
    // Stage syncResult = true to simulate Android Auto externally-started playback
    // where the ExoPlayer is running but the isPlaying flag hasn't been updated yet
    // (cold start). In that case we also set isPlaying = true, mirroring what the
    // Android implementation does when it reads the live ExoPlayer state.
    if syncResult {
      isPlaying = true
    }
    return isPlaying
  }

  // MARK: - Assertion helpers

  /// The attenuation values written, in order — used to verify the sleep-timer fade ramp. Takes a
  /// slice (defaulting to everything) because the fade assertions need only the writes BEFORE the
  /// stop: the write after it is the restore-to-1.0, which would make the ramp look non-monotonic.
  func attenuations(in slice: ArraySlice<PlayerCommand>? = nil) -> [Double] {
    (slice ?? commands[...]).compactMap {
      if case .setAttenuation(let value) = $0 { return value } else { return nil }
    }
  }

  /// The commands issued before the first `stop`, i.e. everything that led up to it.
  func commandsBeforeStop() -> ArraySlice<PlayerCommand> {
    commands[..<(commands.firstIndex(of: .stop) ?? commands.endIndex)]
  }

  /// The URLs played, in order.
  func playedURLs() -> [String] {
    commands.compactMap { if case .play(let url) = $0 { return url } else { return nil } }
  }

  /// How many true-stops were issued.
  func stopCount() -> Int {
    commands.filter { $0 == .stop }.count
  }

  /// Clear the recording — useful to isolate the commands from one phase of a test.
  func reset() {
    commands.removeAll()
  }
}
