import SwiftUI
import Maxi80Model
import Maxi80Services

// MARK: - Preview Helpers

/// Creates a RadioPlayerViewModel with mock data for SwiftUI previews.
/// Only compiled for Xcode preview builds (ENABLE_PREVIEWS).
#if ENABLE_PREVIEWS
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

        // Configure coordinator state — the ViewModel reads through to it.
        if hasError {
            coordinator.playbackState = .error("Connection lost. Tap retry to reconnect.")
        } else if isPlaying {
            coordinator.playbackState = .playing
        } else if isLoading {
            coordinator.playbackState = .loading
        }

        coordinator.station = Station(
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
            coordinator.currentSong = SongMetadata(artist: "Depeche Mode", title: "Enjoy the Silence")
            coordinator.currentArtwork = ArtworkResult(
                image: nil,
                dominantColor: Color(red: 0.2, green: 0.1, blue: 0.4),
                isDefault: false
            )
        }

        if hasHistory {
            coordinator.history = [
                HistoryEntry(id: "1", artist: "A-ha", title: "Take On Me", artwork: nil, timestamp: 1000),
                HistoryEntry(id: "2", artist: "Tears for Fears", title: "Shout", artwork: nil, timestamp: 2000),
                HistoryEntry(id: "3", artist: "Depeche Mode", title: "Enjoy the Silence", artwork: nil, timestamp: 3000),
            ]
        }

        let vm = RadioPlayerViewModel(coordinator: coordinator)
        vm.volume = 0.75
        if hasHistory {
            vm.selectedHistoryIndex = 2
        }

        return vm
    }
}
#endif
