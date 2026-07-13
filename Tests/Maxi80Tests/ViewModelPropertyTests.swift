import Testing
import Foundation
import SwiftCheck
@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// **Validates: Requirements 6.7**
@Suite("ViewModel Property Tests — P3: Displayed Metadata Matches Index")
struct ViewModelPropertyTests {

    /// Property 3: For any non-empty history list and any valid index i
    /// where i != history.count - 1 (not the live position),
    /// displayedArtist == history[i].artist and displayedTitle == history[i].title.
    @Test("P3: displayed metadata matches history[selectedIndex] when browsing history")
    @MainActor
    func displayedMetadataMatchesIndex() {
        // Test with various history sizes and valid non-live indices
        for iteration in 0..<100 {
            let n = Int.random(in: 2...20)
            let index = Int.random(in: 0...(n - 2))  // non-live index

            let player = AudioStreamPlayer()
            let nowPlaying = NowPlayingController()
            let apiClient = APIClient(baseURL: "https://test.example.com", authToken: "test-key")
            let artworkService = ArtworkService(apiClient: apiClient)
            let coordinator = RadioPlayerCoordinator(
                player: player, nowPlaying: nowPlaying,
                apiClient: apiClient, artworkService: artworkService
            )
            let vm = RadioPlayerViewModel(coordinator: coordinator)

            // Populate history with distinct entries
            var entries: [HistoryEntry] = []
            for i in 0..<n {
                entries.append(HistoryEntry(
                    artist: "Artist_\(i)_\(iteration)",
                    title: "Title_\(i)_\(iteration)",
                    timestamp: "\(i)"
                ))
            }
            coordinator.history = entries
            vm.selectedCoverID = entries[index].id

            #expect(vm.displayedArtist == entries[index].artist,
                    "iteration \(iteration): expected \(entries[index].artist) at index \(index)")
            #expect(vm.displayedTitle == entries[index].title,
                    "iteration \(iteration): expected \(entries[index].title) at index \(index)")
        }
    }
}
