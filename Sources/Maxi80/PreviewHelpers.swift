import SwiftUI
import Maxi80Model
import Maxi80Services

// MARK: - Preview Helpers

/// Creates a RadioPlayerViewModel with mock data for SwiftUI previews.
/// Only available in DEBUG builds.
#if DEBUG && !SKIP_BRIDGE
@MainActor
enum PreviewMocks {

    /// A ViewModel pre-populated with sample station and history data.
    static func makeViewModel(
        isPlaying: Bool = false,
        isLoading: Bool = false,
        hasMetadata: Bool = true,
        hasHistory: Bool = true,
        hasError: Bool = false
    ) -> RadioPlayerViewModel {
        let player = AudioStreamPlayer()
        let nowPlaying = NowPlayingController()
        let apiClient = APIClient(baseURL: "https://preview.example.com", authToken: "preview")
        let artworkService = ArtworkService(apiClient: apiClient)
        let coordinator = RadioPlayerCoordinator(
            player: player,
            nowPlaying: nowPlaying,
            apiClient: apiClient,
            artworkService: artworkService
        )
        let vm = RadioPlayerViewModel(coordinator: coordinator)

        // Configure state
        vm.isPlaying = isPlaying
        vm.isLoading = isLoading
        vm.station = Station(
            name: "Maxi 80",
            streamUrl: "https://audio1.maxi80.com",
            image: "",
            shortDesc: "La radio de toute une génération",
            longDesc: "Maxi 80, la radio de toute une génération",
            websiteUrl: "https://www.maxi80.com",
            donationUrl: "https://www.maxi80.com/don",
            defaultCoverUrl: ""
        )

        if hasMetadata {
            vm.currentSong = SongMetadata(artist: "Depeche Mode", title: "Enjoy the Silence")
            vm.canShare = true
        }

        if hasHistory {
            vm.history = [
                HistoryEntry(id: "1", artist: "A-ha", title: "Take On Me", artwork: nil, timestamp: 1000),
                HistoryEntry(id: "2", artist: "Tears for Fears", title: "Shout", artwork: nil, timestamp: 2000),
                HistoryEntry(id: "3", artist: "Depeche Mode", title: "Enjoy the Silence", artwork: nil, timestamp: 3000),
            ]
            vm.selectedHistoryIndex = 2
        }

        if hasError {
            vm.errorMessage = "Connection lost. Tap retry to reconnect."
        }

        vm.volume = 0.75
        vm.dominantColor = Color(red: 0.2, green: 0.1, blue: 0.4)

        return vm
    }
}
#endif
