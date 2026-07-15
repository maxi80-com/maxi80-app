import Testing
import SwiftUI
@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests the CarPlay-gated placeholder-artwork decision on the coordinator.
///
/// CarPlay's Now Playing template mirrors the system Now Playing info, which only carries a real
/// remote cover URL. When no cover exists (idle, or a coverless song) the coordinator publishes the
/// bundled generic placeholder instead — but ONLY while CarPlay is connected, so the phone Lock
/// Screen / Control Center behavior is unchanged.
@Suite("CarPlay Now Playing placeholder")
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

    @Test("CarPlay starts disconnected")
    @MainActor
    func startsDisconnected() {
        let coordinator = makeCoordinator()
        #expect(coordinator.isCarPlayConnected == false)
    }

    @Test("Connect/disconnect toggles the CarPlay flag")
    @MainActor
    func connectDisconnectTogglesFlag() {
        let coordinator = makeCoordinator()
        coordinator.carPlayDidConnect()
        #expect(coordinator.isCarPlayConnected == true)
        coordinator.carPlayDidDisconnect()
        #expect(coordinator.isCarPlayConnected == false)
    }

    @Test("No placeholder is published while CarPlay is disconnected")
    @MainActor
    func noPlaceholderWhenDisconnected() {
        let coordinator = makeCoordinator()
        #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: nil) == false)
        #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: "https://cover") == false)
    }

    @Test("Placeholder is published only for missing artwork while CarPlay is connected")
    @MainActor
    func placeholderOnlyForMissingArtworkWhenConnected() {
        let coordinator = makeCoordinator()
        coordinator.carPlayDidConnect()
        // Missing cover (nil or empty) → publish the generic placeholder.
        #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: nil) == true)
        #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: "") == true)
        // Real cover present → never override it with the placeholder.
        #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: "https://cover.example/x.jpg") == false)
    }
}
