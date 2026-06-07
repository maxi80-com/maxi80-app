import SwiftUI
import Foundation
import Maxi80Model
import Maxi80Services

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
    private let apiClient: APIClient
    @ObservationIgnored
    private let artworkService: ArtworkService

    // MARK: - Observable State

    public var playbackState: PlaybackState = .idle
    public var currentSong: SongMetadata?
    public var currentArtwork: ArtworkResult?
    public var history: [HistoryEntry] = []
    public var station: Station?
    public var errorMessage: String?

    // MARK: - Internal State

    @ObservationIgnored
    private var reconnectAttempts: Int = 0
    @ObservationIgnored
    private let maxReconnectAttempts = 3
    @ObservationIgnored
    private var cachedStation: Station?

    /// Default stream URL used when station hasn't loaded yet.
    private let defaultStreamURL = "https://audio1.maxi80.com"

    // MARK: - Initialization

    public init(
        player: AudioStreamPlayer,
        nowPlaying: NowPlayingController,
        apiClient: APIClient,
        artworkService: ArtworkService
    ) {
        self.player = player
        self.nowPlaying = nowPlaying
        self.apiClient = apiClient
        self.artworkService = artworkService

        setupCallbacks()
    }

    // MARK: - Public API

    /// Start streaming immediately and fetch history concurrently.
    public func play() {
        playbackState = .loading
        errorMessage = nil

        let streamURL = station?.streamUrl ?? defaultStreamURL
        player.play(url: streamURL)

        // Launch history fetch concurrently — don't block audio start
        Task { [weak self] in
            await self?.fetchHistory()
        }
    }

    /// Stop streaming and update state.
    public func pause() {
        player.stop()
        playbackState = .paused
        nowPlaying.updatePlaybackState(isPlaying: false)
    }

    /// Set the audio output volume (0.0 to 1.0).
    public func setVolume(_ volume: Double) {
        player.updateVolume(volume)
    }

    /// Reset reconnect counter and attempt to play again.
    public func retryConnection() {
        reconnectAttempts = 0
        errorMessage = nil
        play()
    }

    /// Fetch station metadata on launch with fallback chain.
    public func loadStation() async {
        let stationJSON: String? = await withCheckedContinuation { continuation in
            apiClient.fetchStation { result in
                continuation.resume(returning: result)
            }
        }

        if let json = stationJSON, let parsed = parseStation(from: json) {
            station = parsed
            cachedStation = parsed
        } else if let cached = cachedStation {
            station = cached
        } else {
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
        // Transition to playing if we were loading
        if case .loading = playbackState {
            playbackState = .playing
        }

        // Reset reconnect counter on successful metadata
        reconnectAttempts = 0

        let metadata = MetadataParser.parse(rawMetadata)

        // Skip if same as current song
        if metadata == currentSong {
            return
        }

        currentSong = metadata

        // Fetch artwork asynchronously
        let artwork = await artworkService.fetchArtwork(artist: metadata.artist, title: metadata.title)
        currentArtwork = artwork

        // Update platform now-playing info
        nowPlaying.updateNowPlaying(
            artist: metadata.artist,
            title: metadata.title,
            artworkURL: nil,
            isPlaying: true
        )

        // Append to history
        let entry = HistoryEntry(
            id: UUID().uuidString,
            artist: metadata.artist,
            title: metadata.title,
            artwork: nil,
            timestamp: Date().timeIntervalSince1970
        )
        history.append(entry)
    }

    // MARK: - Error Handling

    private func handleError(_ message: String) {
        playbackState = .error(message)
        errorMessage = message
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
        let historyJSON: String? = await withCheckedContinuation { continuation in
            apiClient.fetchHistory { result in
                continuation.resume(returning: result)
            }
        }

        guard let json = historyJSON else { return }

        if let entries = parseHistoryEntries(from: json) {
            // Only seed history if it's currently empty (don't overwrite live entries)
            if history.isEmpty {
                history = entries
            } else {
                // Prepend API entries before any live entries
                let existingIds = Set(history.map { $0.id })
                let newEntries = entries.filter { !existingIds.contains($0.id) }
                history = newEntries + history
            }
        }
    }

    // MARK: - JSON Parsing Helpers

    private func parseStation(from json: String) -> Station? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Station.self, from: data)
    }

    private func parseHistoryEntries(from json: String) -> [HistoryEntry]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([HistoryEntry].self, from: data)
    }
}
