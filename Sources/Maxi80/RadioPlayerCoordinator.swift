import SwiftUI
import Foundation
import SkipFuse
import Maxi80Model
import Maxi80Services

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "Coordinator")

/// Central coordinator for the Maxi80 radio player.
/// Lives in the native (Fuse) module — uses full Swift concurrency (async/await, Task).
/// Owns the bridged services and translates their callbacks into observable state for SwiftUI.
@MainActor
@Observable
public final class RadioPlayerCoordinator {

    // MARK: - Dependencies

    @ObservationIgnored
    private let player: AudioStreamPlayer
    @ObservationIgnored
    private let nowPlaying: NowPlayingController
    @ObservationIgnored
    private let apiClient: any APIClientProtocol
    @ObservationIgnored
    private let artworkService: ArtworkService

    // MARK: - Observable State

    public var playbackState: PlaybackState = .idle
    public var currentSong: SongMetadata?
    public var currentArtwork: ArtworkResult?
    public var history: [HistoryEntry] = []
    public var station: Station?
    public var errorMessage: String?

    /// The generic cover shown before any song has played. Chosen once per launch.
    @ObservationIgnored
    let placeholderCover: PlaceholderCover = .random()

    // MARK: - Internal State

    @ObservationIgnored
    private let reconnectionManager = ReconnectionManager()
    @ObservationIgnored
    private var cachedStation: Station?
    @ObservationIgnored
    private var historyTask: Task<Void, Never>?

    /// Default stream URL used when station hasn't loaded yet.
    private let defaultStreamURL = "https://audio1.maxi80.com"

    /// How long to wait after issuing a reconnect `play()` before checking whether the
    /// stream actually resumed.
    private let reconnectConfirmationDelay: UInt64 = 3_000_000_000

    /// Produces backend-compatible ISO-8601 timestamps for live history entries so they
    /// sort consistently against entries fetched from the API.
    private static let isoTimestampFormatter = ISO8601DateFormatter()

    // MARK: - Initialization

    public init(
        player: AudioStreamPlayer,
        nowPlaying: NowPlayingController,
        apiClient: any APIClientProtocol,
        artworkService: ArtworkService
    ) {
        self.player = player
        self.nowPlaying = nowPlaying
        self.apiClient = apiClient
        self.artworkService = artworkService

        setupCallbacks()
        setupReconnection()
    }

    // MARK: - Public API

    /// Start streaming immediately and fetch history concurrently.
    public func play() {
        // A fresh user-initiated play supersedes any in-progress reconnection cycle.
        reconnectionManager.reset()
        playbackState = .loading
        errorMessage = nil

        let streamURL = station?.streamUrl ?? defaultStreamURL
        player.play(url: streamURL)

        // Refresh history concurrently — don't block audio start.
        refreshHistory()
    }

    /// Fetch the play history off the main flow. Non-blocking: launches an unstructured
    /// `@MainActor` task and cancels any in-flight refresh so overlapping calls don't race.
    public func refreshHistory() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            await self?.fetchHistory()
        }
    }

    /// Stop streaming and update state.
    public func pause() {
        // User-initiated stop — abandon any in-progress reconnection.
        reconnectionManager.cancel()
        player.stop()
        playbackState = .paused
        nowPlaying.updatePlaybackState(isPlaying: false)
    }

    /// Set the audio output volume (0.0 to 1.0).
    public func setVolume(_ volume: Double) {
        player.updateVolume(volume)
    }

    /// Reset the reconnection cycle and attempt to play again (manual retry).
    public func retryConnection() {
        reconnectionManager.reset()
        errorMessage = nil
        play()
    }

    /// Fetch station metadata on launch with fallback chain.
    public func loadStation() async {
        logger.info("loadStation: GET /station")
        let stationJSON = try? await apiClient.fetchStation()

        if let json = stationJSON, let parsed = parseStation(from: json) {
            logger.info("loadStation: station loaded — name=\(parsed.name), streamUrl=\(parsed.streamUrl)")
            station = parsed
            cachedStation = parsed
        } else if let cached = cachedStation {
            logger.notice("loadStation: /station failed, using cached station")
            station = cached
        } else {
            logger.notice("loadStation: /station failed, using hardcoded fallback")
            // Hardcoded fallback
            station = Station(
                name: "Maxi 80",
                streamUrl: defaultStreamURL,
                image: "",
                shortDesc: "La radio de toute une génération",
                longDesc: "",
                websiteUrl: "https://www.maxi80.com",
                donationUrl: "",
                defaultCoverUrl: ""
            )
        }

        // Populate the history carousel at launch without blocking station display.
        refreshHistory()
    }

    // MARK: - Callback Setup

    private func setupCallbacks() {
        player.onMetadataChanged = { [weak self] rawMetadata in
            Task { @MainActor [weak self] in
                await self?.handleMetadataChanged(rawMetadata)
            }
        }

        player.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleError(message)
            }
        }

        player.onInterruption = { [weak self] began in
            Task { @MainActor [weak self] in
                self?.handleInterruption(began: began)
            }
        }

        nowPlaying.onRemoteCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                self?.handleRemoteCommand(command)
            }
        }
    }

    // MARK: - Metadata Handling

    private func handleMetadataChanged(_ rawMetadata: String) async {
        // Transition to playing if we were loading or reconnecting
        switch playbackState {
        case .loading, .reconnecting:
            playbackState = .playing
        default:
            break
        }

        // Successful metadata means the stream is healthy — stop any reconnection cycle.
        reconnectionManager.reset()

        let metadata = MetadataParser.parse(rawMetadata)
        logger.info("metadata received: \(metadata.artist) — \(metadata.title)")

        // Skip if same as current song
        if metadata == currentSong {
            logger.debug("metadata unchanged, skipping")
            return
        }

        currentSong = metadata

        // Fetch artwork asynchronously
        logger.info("fetching artwork for current song")
        let artwork = await artworkService.fetchArtwork(artist: metadata.artist, title: metadata.title)
        currentArtwork = artwork
        logger.info("artwork resolved — hasImage=\(artwork.image != nil), url=\(artwork.url ?? "nil")")

        // Update platform now-playing info
        nowPlaying.updateNowPlaying(
            artist: metadata.artist,
            title: metadata.title,
            artworkURL: artwork.url,
            isPlaying: true
        )

        // Append to history, carrying the already-resolved artwork URL so the carousel can
        // render this song's cover immediately.
        let entry = HistoryEntry(
            artist: metadata.artist,
            title: metadata.title,
            artworkKey: nil,
            timestamp: Self.isoTimestampFormatter.string(from: Date()),
            artworkURL: artwork.url,
            dominantColor: artwork.rgb
        )
        history.append(entry)
    }

    // MARK: - Reconnection

    private func setupReconnection() {
        reconnectionManager.onStateChanged = { [weak self] state in
            self?.playbackState = state
            if case .error(let message) = state {
                self?.errorMessage = message
            } else {
                self?.errorMessage = nil
            }
        }

        reconnectionManager.onReconnect = { [weak self] in
            guard let self else { return false }
            let streamURL = self.station?.streamUrl ?? self.defaultStreamURL
            self.player.play(url: streamURL)

            // Give the stream a moment to resume, then check whether playback recovered.
            try? await Task.sleep(nanoseconds: self.reconnectConfirmationDelay)
            return self.player.isPlaying
        }
    }

    // MARK: - Error Handling

    private func handleError(_ message: String) {
        // A stream error triggers the backoff reconnection cycle rather than failing outright.
        // ReconnectionManager drives playbackState to .reconnecting/.playing/.error via its callback.
        errorMessage = nil
        reconnectionManager.startReconnection()
    }

    // MARK: - Interruption Handling

    private func handleInterruption(began: Bool) {
        if began {
            // Interruption began — pause
            playbackState = .paused
            nowPlaying.updatePlaybackState(isPlaying: false)
        } else {
            // Interruption ended with resume option — resume playback
            play()
        }
    }

    // MARK: - Remote Command Handling

    private func handleRemoteCommand(_ command: String) {
        switch command {
        case "play":
            play()
        case "pause":
            pause()
        case "togglePlayPause":
            switch playbackState {
            case .playing, .loading:
                pause()
            default:
                play()
            }
        default:
            break
        }
    }

    // MARK: - History Fetching

    private func fetchHistory() async {
        logger.info("fetchHistory: GET /history")
        guard let json = try? await apiClient.fetchHistory(),
              let entries = parseHistoryEntries(from: json) else {
            logger.notice("fetchHistory: no data or decode failed")
            return
        }
        logger.info("fetchHistory: decoded \(entries.count) entries, resolving artwork URLs")

        // Resolve each entry's artwork (backend gives an S3 key, not a loadable URL) into a
        // lightweight presigned URL, concurrently. AsyncImage loads the image lazily — we do NOT
        // download it here. The dominant color comes from the backend `color` field (decoded on
        // the entry); if absent it simply stays nil (background falls back).
        let resolved = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask { [artworkService] in
                    let url = await artworkService.resolveArtworkURL(artist: entry.artist, title: entry.title)
                    return (index, url)
                }
            }
            var urlByIndex = [Int: String?]()
            for await (index, url) in group {
                urlByIndex[index] = url
            }
            return entries.enumerated().map { index, entry -> HistoryEntry in
                var copy = entry
                copy.artworkURL = urlByIndex[index] ?? nil
                return copy
            }
        }

        let withArtwork = resolved.filter { $0.artworkURL != nil }.count
        logger.info("fetchHistory: \(withArtwork)/\(resolved.count) entries have artwork URLs")

        // Only seed history if it's currently empty (don't overwrite live entries)
        if history.isEmpty {
            history = resolved
        } else {
            // Merge API entries with any locally-appended live entries. Dedup by SONG identity
            // (artist+title), NOT by `id`: a live entry and the backend's own copy of the same
            // song get different timestamps → different ids, so id-based dedup would keep both
            // and show a duplicate. Keep the existing (live) entries, prepend only backend
            // entries whose song isn't already present.
            let existingSongs = Set(history.map { $0.songMetadata })
            let newEntries = resolved.filter { !existingSongs.contains($0.songMetadata) }
            history = newEntries + history
        }
        logger.info("fetchHistory: history now has \(self.history.count) entries")
    }

    // MARK: - JSON Parsing Helpers

    private func parseStation(from json: String) -> Station? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Station.self, from: data)
    }

    private func parseHistoryEntries(from json: String) -> [HistoryEntry]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HistoryResponse.self, from: data).entries
    }
}
