import Testing
@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests for incremental history merging in RadioPlayerCoordinator.fetchHistory().
/// Reproduces the bug where songs played while playback was stopped didn't appear near the
/// now-slot after resuming (they were blind-prepended to the oldest end).
@Suite("History Merge Tests")
struct HistoryMergeTests {

    /// Fake API client returning a fixed `/history` payload and, optionally, a resolvable artwork
    /// URL for every song (so tests can exercise artwork resolution / healing).
    actor HistoryMockAPIClient: APIClientProtocol {
        private let historyJSON: String
        private let servesArtwork: Bool
        init(historyJSON: String, servesArtwork: Bool = false) {
            self.historyJSON = historyJSON
            self.servesArtwork = servesArtwork
        }

        func fetchStation() async throws(APIClientError) -> String { throw .noContent }
        func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
            guard servesArtwork else { throw .noContent }
            return "{\"url\":\"https://art.example/\(title).jpg\"}"
        }
        func fetchHistory() async throws(APIClientError) -> String { historyJSON }
    }

    /// Builds a `/history` response body from (artist, title, timestamp) tuples.
    static func historyJSON(_ entries: [(String, String, String)]) -> String {
        let items = entries.map { artist, title, ts in
            "{\"artist\":\"\(artist)\",\"title\":\"\(title)\",\"artwork\":\"k/\(title)/artwork.jpg\",\"timestamp\":\"\(ts)\"}"
        }.joined(separator: ",")
        return "{\"entries\":[\(items)]}"
    }

    @MainActor
    private func makeCoordinator(historyJSON: String, servesArtwork: Bool = false) -> RadioPlayerCoordinator {
        let apiClient = HistoryMockAPIClient(historyJSON: historyJSON, servesArtwork: servesArtwork)
        return RadioPlayerCoordinator(
            player: AudioStreamPlayer(),
            nowPlaying: NowPlayingController(),
            apiClient: apiClient,
            artworkService: ArtworkService(apiClient: apiClient)
        )
    }

    @Test("New backend entries merge in timestamp order, newest nearest the now-slot")
    @MainActor
    func newEntriesMergeInOrder() async {
        // Backend now has an older song plus two NEW ones (played while stopped).
        let json = Self.historyJSON([
            ("Old", "Old Song", "2026-07-15T10:00:00Z"),
            ("Mid", "Mid Song", "2026-07-15T10:30:00Z"),
            ("New", "New Song", "2026-07-15T10:45:00Z"),
        ])
        let coordinator = makeCoordinator(historyJSON: json)

        // Pre-existing in-memory list holds only the old song (as if fetched earlier).
        coordinator.history = [
            HistoryEntry(artist: "Old", title: "Old Song", timestamp: "2026-07-15T10:00:00Z")
        ]

        await coordinator.fetchHistory()

        // All three present, sorted oldest → newest (carousel renders left → right).
        #expect(coordinator.history.map(\.title) == ["Old Song", "Mid Song", "New Song"])
        // The newest sits last (nearest the now-slot), not buried at the front.
        #expect(coordinator.history.last?.title == "New Song")
    }

    @Test("No new entries → history is left unchanged")
    @MainActor
    func noNewEntriesIsNoOp() async {
        let json = Self.historyJSON([("Old", "Old Song", "2026-07-15T10:00:00Z")])
        let coordinator = makeCoordinator(historyJSON: json)

        let existing = HistoryEntry(
            artist: "Old", title: "Old Song", timestamp: "2026-07-15T10:00:00Z", artworkURL: "already-resolved"
        )
        coordinator.history = [existing]

        await coordinator.fetchHistory()

        // Same single entry, and its already-resolved URL was preserved (not rebuilt).
        #expect(coordinator.history.count == 1)
        #expect(coordinator.history.first?.artworkURL == "already-resolved")
    }

    @Test("Empty in-memory history seeds from the backend")
    @MainActor
    func emptyHistorySeeds() async {
        let json = Self.historyJSON([
            ("A", "Song A", "2026-07-15T10:00:00Z"),
            ("B", "Song B", "2026-07-15T10:10:00Z"),
        ])
        let coordinator = makeCoordinator(historyJSON: json)
        coordinator.history = []

        await coordinator.fetchHistory()

        #expect(coordinator.history.map(\.title) == ["Song A", "Song B"])
    }

    @Test("An existing entry missing artwork is healed from the backend on refresh")
    @MainActor
    func missingArtworkIsHealedOnRefresh() async {
        // Backend has the song and can resolve its artwork now.
        let json = Self.historyJSON([("Change", "A Lover's Holiday", "2026-07-15T10:24:27Z")])
        let coordinator = makeCoordinator(historyJSON: json, servesArtwork: true)

        // In-memory entry was live-appended earlier WITHOUT artwork (collector hadn't produced it).
        coordinator.history = [
            HistoryEntry(
                artist: "Change", title: "A Lover's Holiday",
                timestamp: "2026-07-15T10:24:27Z", artworkURL: nil
            )
        ]

        await coordinator.fetchHistory()

        // The stale nil-artwork entry is healed in place — not duplicated, not left blank.
        #expect(coordinator.history.count == 1)
        #expect(coordinator.history.first?.artworkURL == "https://art.example/A Lover's Holiday.jpg")
    }

    @Test("A live artist-less program collapses with its backend Maxi80 copy into one entry")
    @MainActor
    func stationArtistProgramCollapses() async {
        // Backend serves the program with the `Maxi80` artist and resolvable artwork.
        let json = Self.historyJSON([("Maxi80", "Maxi Club avec Dj Lucky", "2026-07-15T19:24:00Z")])
        let coordinator = makeCoordinator(historyJSON: json, servesArtwork: true)

        // In-memory copy was live-appended artist-less (the stream metadata had no " - " separator).
        coordinator.history = [
            HistoryEntry(artist: "", title: "Maxi Club avec Dj Lucky", timestamp: "2026-07-15T19:24:00Z")
        ]

        await coordinator.fetchHistory()

        // One entry, not two: the live copy healed into the backend copy.
        #expect(coordinator.history.count == 1)
        // Keeps the `Maxi80` artist (backend wins the empty live one) and gains the artwork.
        #expect(coordinator.history.first?.artist == "Maxi80")
        #expect(coordinator.history.first?.artworkURL == "https://art.example/Maxi Club avec Dj Lucky.jpg")
    }

    @Test("Genuine repeat plays of the same song are preserved (not collapsed)")
    @MainActor
    func repeatPlaysArePreserved() async {
        // Backend reports the song once; in-memory has two real plays at different timestamps.
        let json = Self.historyJSON([("Change", "A Lover's Holiday", "2026-07-15T10:00:00Z")])
        let coordinator = makeCoordinator(historyJSON: json, servesArtwork: true)
        coordinator.history = [
            HistoryEntry(artist: "Change", title: "A Lover's Holiday",
                         timestamp: "2026-07-15T10:00:00Z", artworkURL: "url-1"),
            HistoryEntry(artist: "Change", title: "A Lover's Holiday",
                         timestamp: "2026-07-15T11:30:00Z", artworkURL: "url-2"),
        ]

        await coordinator.fetchHistory()

        // Both plays survive — dedup heals/appends, it never collapses distinct timestamps.
        #expect(coordinator.history.count == 2)
        #expect(coordinator.history.map(\.artworkURL) == ["url-1", "url-2"])
    }

    @Test("An existing entry that already has artwork is not re-resolved")
    @MainActor
    func existingArtworkIsPreserved() async {
        let json = Self.historyJSON([("Change", "A Lover's Holiday", "2026-07-15T10:24:27Z")])
        let coordinator = makeCoordinator(historyJSON: json, servesArtwork: true)

        coordinator.history = [
            HistoryEntry(
                artist: "Change", title: "A Lover's Holiday",
                timestamp: "2026-07-15T10:24:27Z", artworkURL: "live-resolved-url"
            )
        ]

        await coordinator.fetchHistory()

        // Left untouched (no reload/flicker) since it already had artwork.
        #expect(coordinator.history.count == 1)
        #expect(coordinator.history.first?.artworkURL == "live-resolved-url")
    }
}
