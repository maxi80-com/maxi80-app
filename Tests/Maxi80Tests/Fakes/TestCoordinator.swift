// Tests/Maxi80Tests/Fakes/TestCoordinator.swift
@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Builds a coordinator wired to fakes. Replaces the near-identical `makeCoordinator()` helpers
/// that were duplicated across nine test files, so future seam changes touch one place.
///
/// Returns the player as the concrete `FakeAudioPlayer` (not `any AudioPlaying`) so callers can
/// stage `isPlaying`/`syncResult` and assert against `commands`.
///
/// The three timing parameters default to the production constants, so a plain
/// `makeTestCoordinator()` behaves exactly like the shipping coordinator; tests that exercise a
/// real-time path (the sleep-timer fade ramp, the reconnect backoff + confirmation wait) scale them
/// down so the suite stays in milliseconds instead of seconds.
@MainActor
func makeTestCoordinator(
  apiClient: (any APIClientProtocol)? = nil,
  player: FakeAudioPlayer? = nil,
  shareService: FakeSharing? = nil,
  nowPlaying: FakeNowPlayingPublisher? = nil,
  reconnectConfirmationDelay: UInt64 = 3_000_000_000,
  reconnectTimeScale: Double = 1.0,
  sleepFadeDuration: UInt64 = 2_500_000_000
) -> (coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer) {
  let fakePlayer = player ?? FakeAudioPlayer()
  let client = apiClient ?? StubAPIClient()
  let coordinator = RadioPlayerCoordinator(
    player: fakePlayer,
    nowPlaying: nowPlaying ?? FakeNowPlayingPublisher(),
    apiClient: client,
    artworkService: ArtworkService(apiClient: client),
    shareService: shareService ?? FakeSharing(),
    reconnectConfirmationDelay: reconnectConfirmationDelay,
    reconnectTimeScale: reconnectTimeScale,
    sleepFadeDuration: sleepFadeDuration
  )
  return (coordinator, fakePlayer)
}
