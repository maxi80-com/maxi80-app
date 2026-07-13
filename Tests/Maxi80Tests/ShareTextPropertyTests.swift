import Testing
import SwiftCheck
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

        property("share text matches expected template") <- forAll { (artist: String, title: String) in
            // Skip empty strings — property only applies to non-empty artist and title
            guard !artist.isEmpty && !title.isEmpty else { return true }

            // Set up live song state (empty history = live position)
            coordinator.currentSong = SongMetadata(artist: artist, title: title)
            coordinator.history = []
            vm.selectedHistoryIndex = 0

            let shareContent = vm.shareCurrentTrack()
            let expected = "I'm listening to \(title) by \(artist) on Maxi 80 via Maxi80 for iOS. Check it out at https://www.maxi80.com"

            return shareContent.text == expected
        }
    }
}
