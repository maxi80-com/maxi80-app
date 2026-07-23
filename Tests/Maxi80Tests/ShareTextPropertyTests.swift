import SwiftCheck
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// **Validates: Requirements 17.2**
@Suite("Share Text Property Tests — P7: Share Text Formatting")
struct ShareTextPropertyTests {

  /// Property 7: For any SongMetadata with non-empty artist and non-empty title,
  /// the generated share text equals the expected template with substituted values.
  @Test("P7: Share text matches template with artist and title")
  @MainActor
  func shareTextFormatting() {
    let player = AudioStreamPlayer()
    let nowPlaying = NowPlayingController()
    let apiClient = APIClient(baseURL: "https://test.com", authToken: "test-key")
    let artworkService = ArtworkService(apiClient: apiClient)
    let coordinator = RadioPlayerCoordinator(
      player: player,
      nowPlaying: nowPlaying,
      apiClient: apiClient,
      artworkService: artworkService
    )
    let vm = RadioPlayerViewModel(coordinator: coordinator)

    property("share text matches expected template")
      <- forAll { (artist: String, title: String) in
        // Skip empty strings — property only applies to non-empty artist and title
        guard !artist.isEmpty && !title.isEmpty else { return true }

        // Set up live song state (empty history = live position, no cover selected)
        coordinator.currentSong = SongMetadata(artist: artist, title: title)
        coordinator.history = []
        vm.selectedCoverID = nil

        let shareContent = vm.shareCurrentTrack()
        let expected =
          "I'm listening to \(title) by \(artist) on Maxi 80. Listen at \(BrandConstants.websiteURL)"

        return shareContent.text == expected
      }
  }

  @MainActor
  private func makeViewModel() -> (RadioPlayerViewModel, RadioPlayerCoordinator) {
    let apiClient = APIClient(baseURL: "https://test.com", authToken: "test-key")
    let coordinator = RadioPlayerCoordinator(
      player: AudioStreamPlayer(),
      nowPlaying: NowPlayingController(),
      apiClient: apiClient,
      artworkService: ArtworkService(apiClient: apiClient)
    )
    return (RadioPlayerViewModel(coordinator: coordinator), coordinator)
  }

  /// The shared image must describe the same song as the shared text: the live cover at the now
  /// slot, the focused entry's cover while browsing history, and nil (text-only) for the default
  /// cover. Mirrors `shareText`'s history-awareness so the two never diverge.
  @Test("shareArtworkURL returns the live cover at the now slot")
  @MainActor
  func shareArtworkURL_liveSlot_returnsCurrentCover() {
    let (vm, coordinator) = makeViewModel()
    coordinator.currentArtwork = ArtworkResult(
      image: nil, dominantColor: .black, isDefault: false, url: "https://cdn/live.jpg")
    vm.selectedCoverID = RadioPlayerViewModel.nowSlotID

    #expect(vm.shareArtworkURL == "https://cdn/live.jpg")
  }

  @Test("shareArtworkURL returns the focused history entry's cover while browsing")
  @MainActor
  func shareArtworkURL_browsingHistory_returnsFocusedCover() {
    let (vm, coordinator) = makeViewModel()
    coordinator.currentArtwork = ArtworkResult(
      image: nil, dominantColor: .black, isDefault: false, url: "https://cdn/live.jpg")
    let past = HistoryEntry(
      artist: "A", title: "T", timestamp: "2026-01-01T00:00:00Z", artworkURL: "https://cdn/past.jpg"
    )
    coordinator.history = [past]
    vm.selectedCoverID = AnyHashable(past.id)

    #expect(vm.shareArtworkURL == "https://cdn/past.jpg")
  }

  @Test("shareArtworkURL is nil for the default cover so the share is text-only")
  @MainActor
  func shareArtworkURL_defaultCover_isNil() {
    let (vm, coordinator) = makeViewModel()
    coordinator.currentArtwork = ArtworkResult(
      image: nil, dominantColor: .black, isDefault: true, url: nil)
    vm.selectedCoverID = RadioPlayerViewModel.nowSlotID

    #expect(vm.shareArtworkURL == nil)
  }
}
