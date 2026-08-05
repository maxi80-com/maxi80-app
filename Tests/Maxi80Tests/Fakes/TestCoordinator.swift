// Tests/Maxi80Tests/Fakes/TestCoordinator.swift
@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Builds a coordinator wired to fakes. Replaces the near-identical `makeCoordinator()` helpers
/// that were duplicated across nine test files, so future seam changes touch one place.
///
/// Returns the player as the concrete `FakeAudioPlayer` (not `any AudioPlaying`) so callers can
/// stage `isPlaying`/`syncResult` and assert against `commands`.
@MainActor
func makeTestCoordinator(
  apiClient: (any APIClientProtocol)? = nil,
  player: FakeAudioPlayer? = nil
) -> (coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer) {
  let fakePlayer = player ?? FakeAudioPlayer()
  let client = apiClient ?? StubAPIClient()
  let coordinator = RadioPlayerCoordinator(
    player: fakePlayer,
    nowPlaying: NowPlayingController(),
    apiClient: client,
    artworkService: ArtworkService(apiClient: client)
  )
  return (coordinator, fakePlayer)
}
