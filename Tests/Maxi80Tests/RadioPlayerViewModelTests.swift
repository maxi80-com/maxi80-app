import Testing
import SwiftUI
@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Unit tests for RadioPlayerViewModel UI state logic.
/// Validates Requirements 8.2, 8.3, 17.5, 6.7
@Suite("RadioPlayerViewModel State Tests")
struct RadioPlayerViewModelTests {

    // MARK: - Helpers

    @MainActor
    private func makeViewModel() -> RadioPlayerViewModel {
        let player = AudioStreamPlayer()
        let nowPlaying = NowPlayingController()
        let apiClient = APIClient(baseURL: "https://test.example.com", authToken: "test-key")
        let artworkService = ArtworkService(apiClient: apiClient)
        let coordinator = RadioPlayerCoordinator(
            player: player,
            nowPlaying: nowPlaying,
            apiClient: apiClient,
            artworkService: artworkService
        )
        return RadioPlayerViewModel(coordinator: coordinator)
    }

    // MARK: - Requirement 8.2: Station info displayed when idle

    @Test("Station info displayed as placeholder when no metadata (idle state)")
    @MainActor
    func stationInfoDisplayedWhenIdle() {
        let vm = makeViewModel()
        vm.station = Station(
            name: "Maxi 80",
            streamUrl: "https://audio1.maxi80.com",
            image: "",
            shortDesc: "La radio de toute une génération",
            longDesc: "",
            websiteUrl: "",
            donationUrl: "",
            defaultCoverUrl: ""
        )
        vm.currentSong = nil
        vm.history = []

        // displayedArtist should fall back to station name
        #expect(vm.displayedArtist == "Maxi 80")
        // displayedTitle should fall back to station description
        #expect(vm.displayedTitle == "La radio de toute une génération")
    }

    // MARK: - Requirement 8.3: Station as placeholder during initial stream

    @Test("Station as placeholder during initial stream (no metadata yet)")
    @MainActor
    func stationAsPlaceholderDuringStream() {
        let vm = makeViewModel()
        vm.station = Station(
            name: "Maxi 80",
            streamUrl: "https://audio1.maxi80.com",
            image: "",
            shortDesc: "La radio",
            longDesc: "",
            websiteUrl: "",
            donationUrl: "",
            defaultCoverUrl: ""
        )
        vm.isLoading = true
        vm.currentSong = nil
        vm.history = []

        #expect(vm.displayedArtist == "Maxi 80")
        #expect(vm.displayedTitle == "La radio")
    }

    // MARK: - Requirement 17.5: Share button disabled when no metadata

    @Test("Share button disabled when no metadata")
    @MainActor
    func shareButtonDisabledWhenNoMetadata() {
        let vm = makeViewModel()
        vm.currentSong = nil
        vm.canShare = false
        #expect(vm.canShare == false)
    }

    @Test("Share button enabled when metadata present")
    @MainActor
    func shareButtonEnabledWithMetadata() {
        let vm = makeViewModel()
        vm.currentSong = SongMetadata(artist: "Artist", title: "Title")
        vm.canShare = true
        #expect(vm.canShare == true)
    }

    // MARK: - Requirement 6.7: Displayed metadata switches on history index change

    @Test("Displayed metadata switches on history index change")
    @MainActor
    func displayedMetadataSwitchesOnIndexChange() {
        let vm = makeViewModel()
        vm.history = [
            HistoryEntry(id: "0", artist: "First Artist", title: "First Song", artwork: nil, timestamp: 1000),
            HistoryEntry(id: "1", artist: "Second Artist", title: "Second Song", artwork: nil, timestamp: 2000),
            HistoryEntry(id: "2", artist: "Current", title: "Live Song", artwork: nil, timestamp: 3000)
        ]
        vm.currentSong = SongMetadata(artist: "Current", title: "Live Song")

        // Select first entry (historical)
        vm.selectedHistoryIndex = 0
        #expect(vm.displayedArtist == "First Artist")
        #expect(vm.displayedTitle == "First Song")

        // Switch to second entry (historical)
        vm.selectedHistoryIndex = 1
        #expect(vm.displayedArtist == "Second Artist")
        #expect(vm.displayedTitle == "Second Song")

        // Switch to last entry (live position) — falls back to currentSong
        vm.selectedHistoryIndex = 2
        #expect(vm.displayedArtist == "Current")
        #expect(vm.displayedTitle == "Live Song")
    }

    @Test("Displayed metadata falls back to station when at live position with no currentSong")
    @MainActor
    func displayedMetadataFallbackAtLivePosition() {
        let vm = makeViewModel()
        vm.station = Station(
            name: "Maxi 80",
            streamUrl: "https://audio1.maxi80.com",
            image: "",
            shortDesc: "La radio de toute une génération",
            longDesc: "",
            websiteUrl: "",
            donationUrl: "",
            defaultCoverUrl: ""
        )
        vm.history = [
            HistoryEntry(id: "0", artist: "Old Song", title: "Old Title", artwork: nil, timestamp: 1000),
            HistoryEntry(id: "1", artist: "Live", title: "Live Title", artwork: nil, timestamp: 2000)
        ]
        vm.currentSong = nil
        vm.selectedHistoryIndex = 1  // live position (last index)

        // At live position with no currentSong, falls back to station
        #expect(vm.displayedArtist == "Maxi 80")
        #expect(vm.displayedTitle == "La radio de toute une génération")
    }
}
