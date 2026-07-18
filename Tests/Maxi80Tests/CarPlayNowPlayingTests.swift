import SwiftUI
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests the placeholder-artwork decision on the coordinator.
///
/// Every system Now Playing surface — Lock Screen, Control Center, and CarPlay (whose template
/// mirrors the system Now Playing info) — carries only a real remote cover URL. When no cover
/// exists (idle, or a coverless song) the coordinator publishes the bundled generic placeholder
/// instead so none of those surfaces shows blank artwork. A present cover is never overridden.
@Suite("Now Playing placeholder")
struct CarPlayNowPlayingTests {

  @MainActor
  private func makeCoordinator() -> RadioPlayerCoordinator {
    let player = AudioStreamPlayer()
    let nowPlaying = NowPlayingController()
    let apiClient = APIClient(baseURL: "https://test.example.com", authToken: "test-key")
    let artworkService = ArtworkService(apiClient: apiClient)
    return RadioPlayerCoordinator(
      player: player,
      nowPlaying: nowPlaying,
      apiClient: apiClient,
      artworkService: artworkService
    )
  }

  @Test("Placeholder is published for missing artwork")
  @MainActor
  func placeholderForMissingArtwork() {
    let coordinator = makeCoordinator()
    // Missing cover (nil or empty) → publish the generic placeholder.
    #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: nil) == true)
    #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: "") == true)
  }

  @Test("A present cover is never overridden by the placeholder")
  @MainActor
  func realCoverNotOverridden() {
    let coordinator = makeCoordinator()
    #expect(
      coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: "https://cover.example/x.jpg")
        == false)
  }
}
