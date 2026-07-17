import SwiftUI
import Foundation
import SkipFuse
import Maxi80Model
import Maxi80Services

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    /// When history was last successfully fetched, used to decide whether a `play()` should
    /// refresh it. `nil` until the first fetch.
    @ObservationIgnored
    private var lastHistoryFetchedAt: Date?
    /// Retries the artwork lookup for the current song when it wasn't available on first fetch
    /// (backend collector hadn't produced it yet). Cancelled whenever the song changes.
    @ObservationIgnored
    private var artworkRetryTask: Task<Void, Never>?

    #if !SKIP
    /// Modern NowPlaying-framework publisher (iOS 26+). `nil` on platforms/SDKs without the
    /// framework, in which case the bridged MediaPlayer `nowPlaying` is used instead.
    @ObservationIgnored
    private var modernNowPlaying: (any NowPlayingPublishing)?
    #endif

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

        #if !SKIP
        // Prefer the modern NowPlaying framework when available (iOS 26+); nil elsewhere, so the
        // bridged MediaPlayer `nowPlaying` remains the fallback.
        modernNowPlaying = makeModernNowPlaying(
            onPlay: { [weak self] in self?.handleRemoteCommand("play") },
            onPause: { [weak self] in self?.handleRemoteCommand("pause") }
        )
        #endif
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

        // Refresh history if it's gone stale. The backend collector runs every 3 minutes, so if
        // the last fetch is older than that the server may have new songs (e.g. tracks played while
        // playback was stopped). Merging picks up only the new entries — see `fetchHistory`.
        refreshHistoryIfStale()
    }

    /// Fetch the play history off the main flow. Non-blocking: launches an unstructured
    /// `@MainActor` task and cancels any in-flight refresh so overlapping calls don't race.
    public func refreshHistory() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            await self?.fetchHistory()
        }
    }

    /// How old the history may be before a `play()` refetches it. Matches the backend collector's
    /// 3-minute cadence: younger than this, no new server entries are possible.
    private static let historyStaleness: TimeInterval = 3 * 60

    /// Refresh history only if it has never been fetched or is older than `historyStaleness`.
    private func refreshHistoryIfStale() {
        if let last = lastHistoryFetchedAt, Date().timeIntervalSince(last) < Self.historyStaleness {
            logger.debug("history is fresh, skipping refresh")
            return
        }
        refreshHistory()
    }

    /// Stop streaming and update state.
    public func pause() {
        // User-initiated stop — abandon any in-progress reconnection.
        reconnectionManager.cancel()
        player.stop()
        playbackState = .paused
        publishPlaybackState(isPlaying: false)
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

    // MARK: - CarPlay

    /// Called when a CarPlay scene connects. Re-publishes the current Now Playing info so the car's
    /// Now Playing template shows artwork immediately — including the generic placeholder when no
    /// song/cover is present yet — rather than waiting for the next metadata change.
    public func carPlayDidConnect() {
        republishNowPlaying()
    }

    /// Whether the coordinator should attach the bundled generic placeholder to the system Now
    /// Playing info in place of a missing cover. True whenever no real remote artwork URL is
    /// available; a present cover is never overridden. Publishing the placeholder keeps every
    /// system Now Playing surface — Lock Screen, Control Center, and CarPlay — from showing blank
    /// artwork for coverless songs or the idle/startup state.
    func shouldPublishPlaceholderArtwork(forArtworkURL artworkURL: String?) -> Bool {
        (artworkURL?.isEmpty ?? true)
    }

    /// Re-publish the current metadata/artwork to the system, e.g. so a CarPlay connect takes
    /// effect immediately. Uses the current song when known, else the station as a placeholder
    /// title so Now Playing isn't blank before the first song.
    private func republishNowPlaying() {
        let playing = { if case .playing = playbackState { return true } else { return false } }()
        let artist = currentSong?.artist ?? station?.name ?? "Maxi 80"
        let title = currentSong?.title ?? station?.shortDesc ?? ""
        let url = currentArtwork.flatMap { $0.isDefault ? nil : $0.url }
        publishNowPlaying(artist: artist, title: title, artworkURL: url, isPlaying: playing)
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

    // Internal (not private) so tests can drive the metadata flow directly — the production caller
    // is the `player.onMetadataChanged` closure wired in `setupCallbacks()`.
    func handleMetadataChanged(_ rawMetadata: String) async {
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

        // A new song supersedes any in-flight artwork retry for the previous one.
        artworkRetryTask?.cancel()

        // Fetch artwork asynchronously
        logger.info("fetching artwork for current song")
        let artwork = await artworkService.fetchArtwork(artist: metadata.artist, title: metadata.title)
        currentArtwork = artwork
        cacheArtworkImage(artwork)
        logger.info("artwork resolved — hasImage=\(artwork.image != nil), url=\(artwork.url ?? "nil")")

        // Update system now-playing info (modern NowPlaying framework if available, else MediaPlayer).
        publishNowPlaying(
            artist: metadata.artist,
            title: metadata.title,
            artworkURL: artwork.url,
            isPlaying: true
        )

        // Record this song in history, carrying the already-resolved artwork URL so the carousel
        // can render its cover immediately.
        let entry = HistoryEntry(
            artist: metadata.artist,
            title: metadata.title,
            artworkKey: nil,
            timestamp: Self.isoTimestampFormatter.string(from: Date()),
            artworkURL: artwork.url,
            colors: artwork.rgb.map { ArtworkColors(uniform: $0) }
        )
        // The seeded backend history already ends with the song playing at launch, so the FIRST
        // metadata event is for a song already in the list. Appending would create a duplicate that
        // only surfaces once the next song starts (both copies are hidden while they're the now
        // slot). If the newest entry is already this song (by normalized identity), heal it in place
        // — filling any artwork/colors the backend copy lacked — instead of appending a second copy.
        // A genuine repeat play (A → B → A) doesn't match here: the tail is B, so it still appends.
        if history.last?.songIdentity == metadata.identity {
            history[history.count - 1] = history[history.count - 1].mergedWith(entry)
        } else {
            history.append(entry)
        }

        // If artwork wasn't ready (backend collector hadn't produced it yet), retry in the
        // background — the cover fills in once it appears, without waiting for the next song.
        if artwork.isDefault {
            startArtworkRetry(for: metadata)
        }
    }

    /// Delays between artwork retries when the first lookup found nothing. Grows so we catch up
    /// quickly then back off; the sequence spans ~65s, comfortably covering the collector's cadence.
    private static let artworkRetryDelays: [UInt64] = [5, 10, 20, 30].map { $0 * 1_000_000_000 }

    /// Retry the artwork lookup for `metadata` with backoff until it resolves or the song changes.
    /// The `ArtworkService` no longer caches misses, so each attempt actually re-queries the backend.
    private func startArtworkRetry(for metadata: SongMetadata) {
        artworkRetryTask = Task { [weak self] in
            for delay in Self.artworkRetryDelays {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                guard let self else { return }

                // Bail if the song moved on while we were waiting.
                guard self.currentSong == metadata else { return }

                let artwork = await self.artworkService.fetchArtwork(artist: metadata.artist, title: metadata.title)
                if Task.isCancelled || self.currentSong != metadata { return }
                guard !artwork.isDefault else { continue }

                logger.info("artwork retry succeeded for \(metadata.artist) — \(metadata.title)")
                self.applyRetriedArtwork(artwork, for: metadata)
                return
            }
            logger.debug("artwork retry exhausted for \(metadata.artist) — \(metadata.title)")
        }
    }

    /// Seed the shared decoded-image cache from a freshly-resolved artwork result. `fetchArtwork`
    /// already decoded the SwiftUI `Image` (Apple only), so registering it under its URL lets the
    /// hero/carousel render the new cover synchronously the instant it becomes current — instead of
    /// re-loading by URL via `AsyncImage`, which flashes the generic placeholder for a frame.
    private func cacheArtworkImage(_ artwork: ArtworkResult) {
        #if canImport(UIKit) || canImport(AppKit)
        guard !artwork.isDefault, let url = artwork.url, let image = artwork.image else { return }
        CoverImageCache.shared.store(image, for: url)
        #endif
    }

    /// Apply artwork that arrived on retry: update the current-song cover/background, the system
    /// Now Playing info, and the matching (most recent) history entry so the carousel cover fills in.
    private func applyRetriedArtwork(_ artwork: ArtworkResult, for metadata: SongMetadata) {
        currentArtwork = artwork
        cacheArtworkImage(artwork)
        let playing = { if case .playing = playbackState { return true } else { return false } }()
        publishNowPlaying(
            artist: metadata.artist,
            title: metadata.title,
            artworkURL: artwork.url,
            isPlaying: playing
        )

        // Update the newest history entry for this song (the live-appended one) in place.
        if let index = history.lastIndex(where: { $0.songIdentity == metadata.identity }) {
            let patch = HistoryEntry(
                artist: history[index].artist,
                title: metadata.title,
                timestamp: history[index].timestamp,
                artworkURL: artwork.url,
                colors: artwork.rgb.map { ArtworkColors(uniform: $0) }
            )
            history[index] = history[index].mergedWith(patch)
        }
    }

    // MARK: - Now Playing Publishing

    /// Publish current-track metadata to the system. Uses the modern NowPlaying framework when
    /// available (iOS 26+), otherwise the bridged MediaPlayer controller.
    private func publishNowPlaying(artist: String, title: String, artworkURL: String?, isPlaying: Bool) {
        // On CarPlay, substitute the bundled generic cover for a missing remote one so the car's
        // Now Playing template is never blank. Both sinks below load artwork by URL and accept a
        // `file://` URL, so the placeholder rides the same path — the phone is unaffected because
        // this only fires while CarPlay is connected.
        let publishedArtworkURL = shouldPublishPlaceholderArtwork(forArtworkURL: artworkURL)
            ? placeholderArtworkFileURL
            : artworkURL

        #if !SKIP
        if let modernNowPlaying {
            modernNowPlaying.activate()
            modernNowPlaying.update(
                stationName: station?.name ?? "Maxi 80",
                programName: "\(title) — \(artist)",
                artworkURL: publishedArtworkURL,
                isPlaying: isPlaying
            )
            return
        }
        #endif
        nowPlaying.updateNowPlaying(artist: artist, title: title, artworkURL: publishedArtworkURL, isPlaying: isPlaying)
    }

    /// A `file://` URL string for this launch's generic placeholder cover, materialized once from
    /// the asset catalog (the covers live in `.xcassets`, which have no directly loadable URL).
    /// `nil` on platforms without image APIs (Android) or if materialization fails — callers then
    /// simply publish no artwork, as before.
    @ObservationIgnored
    private lazy var placeholderArtworkFileURL: String? = materializePlaceholderArtwork()

    /// Write the placeholder cover to a temp file so it can be published to the system Now Playing
    /// info by URL. Supported on Apple platforms (UIKit for iOS/tvOS Now Playing + CarPlay, AppKit
    /// for macOS); Android has no platform image APIs so it returns `nil` and no artwork is published.
    /// Idempotent per launch: reuses the file if it already exists.
    private func materializePlaceholderArtwork() -> String? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxi80-\(placeholderCover.imageName).png")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL.absoluteString
        }

        #if canImport(UIKit)
        guard let image = UIImage(named: placeholderCover.imageName, in: .module, compatibleWith: nil),
              let data = image.pngData(),
              (try? data.write(to: fileURL)) != nil else {
            return nil
        }
        return fileURL.absoluteString
        #elseif canImport(AppKit)
        guard let image = NSImage(named: placeholderCover.imageName),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]),
              (try? data.write(to: fileURL)) != nil else {
            return nil
        }
        return fileURL.absoluteString
        #else
        return nil
        #endif
    }

    /// Publish only the play/pause state, via the same modern-or-fallback routing.
    private func publishPlaybackState(isPlaying: Bool) {
        #if !SKIP
        if let modernNowPlaying {
            modernNowPlaying.updatePlaybackState(isPlaying: isPlaying)
            return
        }
        #endif
        nowPlaying.updatePlaybackState(isPlaying: isPlaying)
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
            publishPlaybackState(isPlaying: false)
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

    /// Fetches `/history` and merges it into the in-memory list. Internal (not private) so tests
    /// can await it directly; production callers go through `refreshHistory`/`refreshHistoryIfStale`.
    func fetchHistory() async {
        logger.info("fetchHistory: GET /history")
        guard let json = try? await apiClient.fetchHistory(),
              let entries = parseHistoryEntries(from: json) else {
            logger.notice("fetchHistory: no data or decode failed")
            return
        }

        // First load (empty history): resolve artwork for every entry and seed the list.
        if history.isEmpty {
            let resolved = await resolveArtwork(for: entries)
            history = resolved
            lastHistoryFetchedAt = Date()
            logger.info("fetchHistory: seeded \(self.history.count) entries")
            return
        }

        lastHistoryFetchedAt = Date()

        // Reconcile the backend list into the in-memory one, matching by SONG identity
        // (artist+title), NOT by `id`: a live-appended entry and the backend's own copy of the same
        // song get different timestamps → different ids, so id-based matching would show a duplicate.
        //
        // Two things are resolved against the backend:
        //   1. Genuinely NEW songs not in memory yet (played while stopped/paused).
        //   2. EXISTING songs still MISSING artwork — a live entry appended before the backend had
        //      produced the cover carries `artworkURL == nil`; the backend copy now resolves one.
        //      Without this, keeping the stale nil-artwork live entry would leave it blank forever.
        // Songs already showing artwork are left untouched (no reload, no flicker). Legitimate
        // repeat plays (same song at different times) are preserved — we edit in place and append,
        // never collapse by song.
        // Identity, not raw songMetadata: a backend `Maxi80` entry and a live artist-less entry for
        // the same program collapse to one identity, so they heal into a single entry rather than
        // showing a duplicate cover.
        let existingSongs = Set(history.map(\.songIdentity))
        let songsMissingArtwork = Set(history.filter { $0.artworkURL == nil }.map(\.songIdentity))

        // Backend entries worth resolving: new songs, or songs an in-memory entry still lacks art for.
        let toResolve = entries.filter {
            !existingSongs.contains($0.songIdentity) || songsMissingArtwork.contains($0.songIdentity)
        }
        guard !toResolve.isEmpty else {
            logger.info("fetchHistory: nothing new or missing artwork to merge")
            return
        }

        let resolved = await resolveArtwork(for: toResolve)

        // Backend entry per identity, for healing existing entries (carries the `Maxi80` artist,
        // artwork URL, and color the live copy may be missing).
        var backendBySong: [SongMetadata: HistoryEntry] = [:]
        for entry in resolved {
            backendBySong[entry.songIdentity] = entry
        }

        // 1. Heal existing entries against the backend copy, in place (preserves order & repeats).
        //    Merges when the in-memory entry lacks artwork or a real artist; `mergedWith` keeps the
        //    non-empty `Maxi80` artist and fills artwork/color.
        var healed = 0
        history = history.map { entry in
            guard entry.artworkURL == nil || entry.artist.isEmpty,
                  let backend = backendBySong[entry.songIdentity] else { return entry }
            let merged = entry.mergedWith(backend)
            if merged != entry { healed += 1 }
            return merged
        }

        // 2. Append genuinely-new songs, then order by timestamp so newest sits nearest the now-slot
        //    (the carousel renders history oldest→newest, left→right).
        let newEntries = resolved.filter { !existingSongs.contains($0.songIdentity) }
        if !newEntries.isEmpty {
            history = (history + newEntries).sorted { $0.timestamp < $1.timestamp }
        }
        logger.info("fetchHistory: healed \(healed), added \(newEntries.count); history now has \(self.history.count)")
    }

    /// Resolves each entry's artwork S3 key into a lightweight presigned URL, concurrently.
    /// AsyncImage loads the image lazily — we do NOT download it here. The background color is
    /// derived from the backend `colors` palette already decoded on the entry; if absent it stays nil.
    private func resolveArtwork(for entries: [HistoryEntry]) async -> [HistoryEntry] {
        await withTaskGroup(of: (Int, String?).self) { group in
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
