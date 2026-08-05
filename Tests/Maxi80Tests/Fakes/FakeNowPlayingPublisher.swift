// Tests/Maxi80Tests/Fakes/FakeNowPlayingPublisher.swift
import Foundation

@testable import Maxi80

/// Recording fake for `NowPlayingPublishing`.
@MainActor
final class FakeNowPlayingPublisher: NowPlayingPublishing {
  struct Update: Equatable {
    let stationName: String
    let artist: String
    let title: String
    let artworkURL: String?
    let isPlaying: Bool
  }

  /// Every call in order, so tests can assert ordering (e.g. `activate()` before the first update)
  /// and not merely presence.
  enum Call: Equatable {
    case activate
    case update(Update)
    case playbackState(Bool)
  }

  var activateCount = 0
  var updates: [Update] = []
  var playbackStates: [Bool] = []
  var calls: [Call] = []

  func activate() {
    activateCount += 1
    calls.append(.activate)
  }

  func update(
    stationName: String, artist: String, title: String, artworkURL: String?, isPlaying: Bool
  ) {
    let update = Update(
      stationName: stationName, artist: artist, title: title, artworkURL: artworkURL,
      isPlaying: isPlaying)
    updates.append(update)
    calls.append(.update(update))
  }

  func updatePlaybackState(isPlaying: Bool) {
    playbackStates.append(isPlaying)
    calls.append(.playbackState(isPlaying))
  }

  func reset() {
    activateCount = 0
    updates.removeAll()
    playbackStates.removeAll()
    calls.removeAll()
  }
}
