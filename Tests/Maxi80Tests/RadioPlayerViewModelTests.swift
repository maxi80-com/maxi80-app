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

    /// Builds a coordinator + view model pair. The view model reads through to the coordinator,
    /// so tests configure state on the returned coordinator.
    @MainActor
    private func makeViewModel() -> (vm: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator) {
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
        return (RadioPlayerViewModel(coordinator: coordinator), coordinator)
    }

    // MARK: - Requirement 8.2: Station info displayed when idle

    @Test("Station info displayed as placeholder when no metadata (idle state)")
    @MainActor
    func stationInfoDisplayedWhenIdle() {
        let (vm, coordinator) = makeViewModel()
        coordinator.station = Station(
            name: "Maxi 80",
            streamUrl: "https://audio1.maxi80.com",
            image: "",
            shortDesc: "La radio de toute une génération",
            longDesc: "",
            websiteUrl: "",
            donationUrl: "",
            defaultCoverUrl: ""
        )
        coordinator.currentSong = nil
        coordinator.history = []

        // displayedArtist should fall back to station name
        #expect(vm.displayedArtist == "Maxi 80")
        // displayedTitle should fall back to station description
        #expect(vm.displayedTitle == "La radio de toute une génération")
    }

    // MARK: - Requirement 8.3: Station as placeholder during initial stream

    @Test("Station as placeholder during initial stream (no metadata yet)")
    @MainActor
    func stationAsPlaceholderDuringStream() {
        let (vm, coordinator) = makeViewModel()
        coordinator.station = Station(
            name: "Maxi 80",
            streamUrl: "https://audio1.maxi80.com",
            image: "",
            shortDesc: "La radio",
            longDesc: "",
            websiteUrl: "",
            donationUrl: "",
            defaultCoverUrl: ""
        )
        coordinator.playbackState = .loading
        coordinator.currentSong = nil
        coordinator.history = []

        #expect(vm.isLoading == true)
        #expect(vm.displayedArtist == "Maxi 80")
        #expect(vm.displayedTitle == "La radio")
    }

    // MARK: - Requirement 17.5: Share button disabled when no metadata

    @Test("Share button disabled when no metadata")
    @MainActor
    func shareButtonDisabledWhenNoMetadata() {
        let (vm, coordinator) = makeViewModel()
        coordinator.currentSong = nil
        #expect(vm.canShare == false)
    }

    @Test("Share button enabled when metadata present")
    @MainActor
    func shareButtonEnabledWithMetadata() {
        let (vm, coordinator) = makeViewModel()
        coordinator.currentSong = SongMetadata(artist: "Artist", title: "Title")
        #expect(vm.canShare == true)
    }

    // MARK: - Requirement 6.7: Displayed metadata switches on history index change

    @Test("Displayed metadata switches when the selected cover changes")
    @MainActor
    func displayedMetadataSwitchesOnSelection() {
        let (vm, coordinator) = makeViewModel()
        let entries = [
            HistoryEntry(artist: "First Artist", title: "First Song", timestamp: "1000"),
            HistoryEntry(artist: "Second Artist", title: "Second Song", timestamp: "2000"),
            HistoryEntry(artist: "Current", title: "Live Song", timestamp: "3000")
        ]
        coordinator.history = entries
        coordinator.currentSong = SongMetadata(artist: "Current", title: "Live Song")

        // Select first cover (historical)
        vm.selectedCoverID = entries[0].id
        #expect(vm.displayedArtist == "First Artist")
        #expect(vm.displayedTitle == "First Song")

        // Switch to second cover (historical)
        vm.selectedCoverID = entries[1].id
        #expect(vm.displayedArtist == "Second Artist")
        #expect(vm.displayedTitle == "Second Song")

        // Switch to the live (last) cover — falls back to currentSong
        vm.selectedCoverID = entries[2].id
        #expect(vm.displayedArtist == "Current")
        #expect(vm.displayedTitle == "Live Song")
    }

    @Test("Displayed metadata falls back to station when at live position with no currentSong")
    @MainActor
    func displayedMetadataFallbackAtLivePosition() {
        let (vm, coordinator) = makeViewModel()
        coordinator.station = Station(
            name: "Maxi 80",
            streamUrl: "https://audio1.maxi80.com",
            image: "",
            shortDesc: "La radio de toute une génération",
            longDesc: "",
            websiteUrl: "",
            donationUrl: "",
            defaultCoverUrl: ""
        )
        let entries = [
            HistoryEntry(artist: "Old Song", title: "Old Title", timestamp: "1000"),
            HistoryEntry(artist: "Prev", title: "Prev Title", timestamp: "2000")
        ]
        coordinator.history = entries
        coordinator.currentSong = nil
        // The "now" slot (rightmost), with no current song, falls back to station info.
        vm.selectedCoverID = RadioPlayerViewModel.nowSlotID

        #expect(vm.displayedArtist == "Maxi 80")
        #expect(vm.displayedTitle == "La radio de toute une génération")
    }

    // MARK: - Current song not duplicated in the carousel

    @Test("Current song appearing in history is not duplicated as a cover (shown only in now slot)")
    @MainActor
    func currentSongNotDuplicatedInCovers() {
        let (vm, coordinator) = makeViewModel()
        let current = SongMetadata(artist: "Mtume", title: "So You Wanna Be A Star")
        coordinator.currentSong = current
        // History contains the current song at the tail (backend's own copy) AND a live-appended
        // copy with a *different timestamp* — the real-world duplicate case.
        coordinator.history = [
            HistoryEntry(artist: "Older", title: "Older Title", timestamp: "1000"),
            HistoryEntry(artist: current.artist, title: current.title, timestamp: "2000"),
            HistoryEntry(artist: current.artist, title: current.title, timestamp: "2003")
        ]

        // The current song appears once — as the rightmost now slot — never as a past cover.
        let currentSongPastCovers = vm.covers.dropLast().filter { cover in
            coordinator.history.contains {
                $0.id == cover.id && $0.songMetadata == current
            }
        }
        #expect(currentSongPastCovers.isEmpty)
        #expect(vm.covers.last?.id == RadioPlayerViewModel.nowSlotID)
        // Only the non-current past entry remains, plus the now slot.
        #expect(vm.covers.count == 2)
    }

    @Test("A Maxi80 history entry isn't shown as a past cover while the same program plays artist-less")
    @MainActor
    func stationArtistProgramNotDuplicatedInCovers() {
        let (vm, coordinator) = makeViewModel()
        // Live current song is artist-less (the stream had no " - " separator).
        coordinator.currentSong = SongMetadata(artist: "", title: "Maxi Club avec Dj Lucky")
        coordinator.history = [
            HistoryEntry(artist: "Older", title: "Older Title", timestamp: "1000"),
            // Backend copy of the now-playing program, carrying the `Maxi80` artist.
            HistoryEntry(artist: "Maxi80", title: "Maxi Club avec Dj Lucky", timestamp: "2000"),
        ]

        // The program shows only in the now slot — the Maxi80 past copy is dropped despite the
        // artist mismatch, so the carousel holds the older cover plus the now slot.
        #expect(vm.covers.count == 2)
        #expect(vm.covers.last?.id == RadioPlayerViewModel.nowSlotID)
    }

    @Test("Now-slot artist falls back to the Maxi80 history copy when the live song is artist-less")
    @MainActor
    func displayedArtistFallsBackToStationArtistFromHistory() {
        let (vm, coordinator) = makeViewModel()
        coordinator.station = Station(
            name: "Maxi 80",
            streamUrl: "https://audio1.maxi80.com",
            image: "",
            shortDesc: "La radio",
            longDesc: "",
            websiteUrl: "",
            donationUrl: "",
            defaultCoverUrl: ""
        )
        coordinator.currentSong = SongMetadata(artist: "", title: "Maxi Club avec Dj Lucky")
        coordinator.history = [
            HistoryEntry(artist: "Maxi80", title: "Maxi Club avec Dj Lucky", timestamp: "2000"),
        ]
        vm.selectedCoverID = RadioPlayerViewModel.nowSlotID

        // Surfaces the backend artist rather than falling straight through to the station name.
        #expect(vm.displayedArtist == "Maxi80")
        #expect(vm.displayedTitle == "Maxi Club avec Dj Lucky")
    }
}
