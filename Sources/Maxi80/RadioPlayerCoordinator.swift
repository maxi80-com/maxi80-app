import Foundation
import Maxi80Model
import Maxi80Services
import SkipFuse
import SwiftUI

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
  @ObservationIgnored
  private let shareService: ShareService

  // MARK: - Observable State

  public var playbackState: PlaybackState = .idle
  public var currentSong: SongMetadata?
  public var currentArtwork: ArtworkResult?
  public var history: [HistoryEntry] = []
  public var station: Station?
  public var errorMessage: String?

  /// The current output volume (0.0–1.0). On Android this tracks the system STREAM_MUSIC level and
  /// updates live when the hardware volume buttons are pressed. On iOS/tvOS the volume UI is driven
  /// by MPVolumeView, so this stays at its default and is unused by the view; macOS binds its in-app
  /// `Slider` to this value (through `viewModel.volume`).
  public var volume: Double = 1.0

  /// When the sleep timer will fire, or `nil` when no timer is running. Delegates to the
  /// extracted `SleepTimerManager`.
  public var sleepTimerFiresAt: Date? { sleepTimerManager.firesAt }

  /// Manages the sleep timer lifecycle (start/cancel/extend/fade).
  @ObservationIgnored
  let sleepTimerManager = SleepTimerManager()

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
  private let artworkRetryManager = ArtworkRetryManager()
  @ObservationIgnored
  private let historyReconciler = HistoryReconciler()
  @ObservationIgnored
  private var nowPlayingFacade: NowPlayingFacade!

  /// Default stream URL used when station hasn't loaded yet.
  private let defaultStreamURL = BrandConstants.streamURL

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
    artworkService: ArtworkService,
    shareService: ShareService = ShareService()
  ) {
    self.player = player
    self.nowPlaying = nowPlaying
    self.apiClient = apiClient
    self.artworkService = artworkService
    self.shareService = shareService

    setupCallbacks()
    setupReconnection()

    // Consolidate the modern (NowPlaying framework, iOS 27+) and bridged (MediaPlayer) paths
    // into a single facade so the coordinator never needs to branch on `#if !SKIP` for publishing.
    nowPlayingFacade = NowPlayingFacade(
      fallback: nowPlaying,
      onPlay: { [weak self] in self?.handleRemoteCommand("play") },
      onPause: { [weak self] in self?.handleRemoteCommand("pause") }
    )
    let nowPlayingPath =
      nowPlayingFacade.usesModernFramework
      ? "MODERN (NowPlaying framework)" : "FALLBACK (MPNowPlayingInfoCenter)"
    logger.info("NowPlaying path: \(nowPlayingPath)")

    // Seed the volume from the system's current level and start tracking hardware-button changes.
    // `startObservingVolume()` is a no-op on Apple platforms (iOS/tvOS track hardware volume through
    // MPVolumeView; macOS uses an in-app Slider). The observer lives for the coordinator's lifetime,
    // which is the app process lifetime (it's the composition root), so there is no teardown path —
    // the OS reclaims it on process death.
    volume = player.currentVolume()
    player.startObservingVolume()
  }

  // MARK: - Public API

  /// Start streaming immediately and fetch history concurrently.
  public func play() {
    // A fresh user-initiated play supersedes any in-progress reconnection cycle.
    // (No sleep-timer cancel here: the timer is only settable while already playing, and a manual
    // pause cancels it via `stopForDisconnect()`, so there is never a stale timer to clear on a
    // resume. Auto-reconnect re-plays through `player.play(url:)` directly, not this method, so a
    // brief stream drop leaves a running timer intact.)
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
    stopForDisconnect()
  }

  /// True-stop the live stream: cancel any reconnection, release the player buffer, and reflect
  /// the stopped state. Shared by the user pause button and the Bluetooth/wired disconnect path
  /// so both drop to `STATE_IDLE` and reconnect to the live edge on the next play (rather than
  /// resuming a stale buffered position).
  ///
  /// Deliberately does NOT cancel the sleep timer: a running timer is only ended by the user
  /// explicitly cancelling it or by it reaching its fire time (matching Apple Podcasts / Music).
  /// Pausing, an audio interruption, and a headphone disconnect all leave it running toward its
  /// original absolute `sleepTimerFiresAt`. If the user resumes before it fires, playback stops on
  /// schedule; if they don't, the timer simply elapses while already stopped (a harmless no-op —
  /// see `fireSleepTimer`, whose fade/stop on an already-stopped player does nothing audible).
  private func stopForDisconnect() {
    reconnectionManager.cancel()
    player.stop()
    playbackState = .paused
    publishPlaybackState(isPlaying: false)
  }

  /// Reconcile the observable `playbackState` with the player's real state.
  ///
  /// Called on foreground (background→foreground resume recreates the Android activity but the
  /// coordinator is a process-wide singleton). The foreground-service stream keeps playing across
  /// the transition, so no fresh ICY metadata arrives to promote a stale `.loading` — this reads
  /// the player's ground truth instead. Only runs when the player is really playing, so it can
  /// safely promote ANY non-playing state (`.loading`/`.reconnecting`/`.idle`/`.paused`) to
  /// `.playing`: a user pause always stops the player, so reaching here with a paused/idle state
  /// means playback was started externally (e.g. Android Auto / the car auto-resuming) while the
  /// app was in the background — the button must reflect that on return (issue #41). It never
  /// fabricates playback from a stopped player (the `guard`), so a genuine user pause is untouched.
  ///
  /// `syncWithExternalPlayback()` (not the plain `isPlaying` flag) is the ground truth here: when
  /// Android Auto starts playback on a COLD start — the service session drives the shared ExoPlayer
  /// directly and `play(url:)` never runs in this process — the flag is stale-false and the ICY
  /// metadata listener was never attached. The sync adopts the running player, attaches the
  /// listener (so song metadata starts flowing), and returns whether audio is really playing.
  public func reconcileWithPlayer() {
    guard player.syncWithExternalPlayback() else { return }
    switch playbackState {
    case .playing:
      break
    default:
      playbackState = .playing
      publishPlaybackState(isPlaying: true)
    }
    republishNowPlaying()
  }

  /// Set the audio output volume (0.0 to 1.0).
  public func setVolume(_ volume: Double) {
    // Optimistically reflect the new level so the slider tracks the drag instantly; the system
    // volume observer will also fire and confirm it (idempotent).
    self.volume = volume
    player.updateVolume(volume)
  }

  /// Reset the reconnection cycle and attempt to play again (manual retry).
  public func retryConnection() {
    reconnectionManager.reset()
    errorMessage = nil
    play()
  }

  // MARK: - Sleep Timer

  // MARK: - Sleep Timer (delegated to SleepTimerManager)

  /// Start (or restart) the sleep timer for `minutes` from now. Playback fades out and stops when it
  /// fires.
  public func startSleepTimer(minutes: Int) {
    sleepTimerManager.start(
      minutes: minutes,
      isPlaying: playbackState.isPlaying,
      setAttenuation: { [weak self] value in self?.player.setPlaybackAttenuation(value) },
      onFired: { [weak self] in self?.stopForDisconnect() }
    )
  }

  /// Cancel a running sleep timer and restore full playback volume.
  public func cancelSleepTimer() {
    sleepTimerManager.cancel(setAttenuation: { [weak self] value in self?.player.setPlaybackAttenuation(value) })
  }

  /// Extend the running timer by `minutes`, folding in whatever time is currently left.
  public func extendSleepTimer(minutes: Int) {
    sleepTimerManager.extend(
      minutes: minutes,
      isPlaying: playbackState.isPlaying,
      setAttenuation: { [weak self] value in self?.player.setPlaybackAttenuation(value) },
      onFired: { [weak self] in self?.stopForDisconnect() }
    )
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
    let artist = currentSong?.artist ?? station?.name ?? BrandConstants.name
    let title = currentSong?.title ?? station?.shortDesc ?? ""
    let url = currentArtwork.flatMap { $0.isDefault ? nil : $0.url }
    publishNowPlaying(artist: artist, title: title, artworkURL: url, isPlaying: playbackState.isPlaying)
  }

  /// Fetch station metadata on launch with fallback chain.
  public func loadStation() async {
    logger.info("loadStation: GET /station")
    let stationJSON = try? await apiClient.fetchStation()

    if let json = stationJSON, let parsed = decodeJSON(json, as: Station.self) {
      logger.info(
        "loadStation: station loaded — name=\(parsed.name), streamUrl=\(parsed.streamUrl)")
      station = parsed
      cachedStation = parsed
    } else if let cached = cachedStation {
      logger.notice("loadStation: /station failed, using cached station")
      station = cached
    } else {
      logger.notice("loadStation: /station failed, using hardcoded fallback")
      // Hardcoded fallback
      station = Station(
        name: BrandConstants.name,
        streamUrl: defaultStreamURL,
        image: "",
        shortDesc: BrandConstants.tagline,
        longDesc: "",
        websiteUrl: BrandConstants.websiteURL,
        donationUrl: "",
        defaultCoverUrl: ""
      )
    }

    // Populate the history carousel at launch without blocking station display.
    refreshHistory()
  }

  // MARK: - Sharing

  /// Present the native share chooser with the given pre-formatted `text`, attaching the cover at
  /// `artworkURL` as an image when one is supplied. The caller (the view model) passes the URL for
  /// the song the text describes — the live song, or the focused history entry while browsing — so
  /// the shared image and text always match. The bytes aren't retained after color sampling, so
  /// they're re-downloaded here; `nil` URL or a download failure degrades to a text-only share.
  /// Used by the Android share path — Apple platforms present `UIActivityViewController` via the
  /// SwiftUI `ShareSheet` instead.
  public func shareCurrentTrack(text: String, artworkURL: String?) async {
    var imageData: Data?
    if let artworkURL {
      imageData = await artworkService.fetchImageData(urlString: artworkURL)
    }
    shareService.share(text: text, imageData: imageData)
  }

  /// Download the displayed cover's raw bytes for the iOS share sheet, or nil on failure. Apple
  /// platforms attach these bytes to `UIActivityViewController`; Android instead uses
  /// `shareCurrentTrack(text:artworkURL:)`, which additionally fires the system chooser. The bytes
  /// aren't retained after color sampling, so they're re-downloaded here.
  func shareArtworkData(urlString: String) async -> Data? {
    await artworkService.fetchImageData(urlString: urlString)
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

    // Audio output permanently lost (Bluetooth / wired headset disconnect on Android). Unlike an
    // interruption this is not resumable — perform a true stop so the next play reconnects to the
    // live edge, matching iOS disconnect behavior.
    player.onDisconnectStop = { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleDisconnectStop()
      }
    }

    // External playback transitions driven by the platform. On Android the media3 notification
    // pause/play fires `onIsPlayingChanged` with no accompanying remote-command or interruption
    // event, so it's the only signal that reflects a notification pause into the app (issue #29,
    // symptom 2). This wiring is Android-only: on Apple, notification/lock-screen transport goes
    // through `MPRemoteCommandCenter` (→ `handleRemoteCommand`) and interruptions through
    // `onInterruption`; there the `onPlaybackStateChanged` callback is a noisy KVO mirror of
    // `timeControlStatus` (it fires `false` throughout buffering/stall), so driving observable
    // state from it would clobber `.loading`/`.playing`. See `handlePlaybackStateChanged`.
    #if os(Android)
      player.onPlaybackStateChanged = { [weak self] isPlaying in
        Task { @MainActor [weak self] in
          self?.handlePlaybackStateChanged(isPlaying: isPlaying)
        }
      }
    #endif

    // System volume changed (Android hardware buttons / volume panel). Mirror it into observable
    // state so the in-app volume bar tracks it. The observer fires on the main looper, but hop to
    // @MainActor explicitly so the write is isolated correctly.
    player.onVolumeChanged = { [weak self] newVolume in
      Task { @MainActor [weak self] in
        self?.volume = newVolume
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
    artworkRetryManager.cancel()

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
      artworkRetryManager.startRetry(
        for: metadata,
        currentSong: { [weak self] in self?.currentSong },
        fetchArtwork: { [weak self] artist, title in
          guard let self else {
            return ArtworkResult(image: nil, dominantColor: .gray, isDefault: true)
          }
          return await self.artworkService.fetchArtwork(artist: artist, title: title)
        },
        onResolved: { [weak self] artwork, metadata in
          self?.applyRetriedArtwork(artwork, for: metadata)
        }
      )
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
    publishNowPlaying(
      artist: metadata.artist,
      title: metadata.title,
      artworkURL: artwork.url,
      isPlaying: playbackState.isPlaying
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
  private func publishNowPlaying(
    artist: String, title: String, artworkURL: String?, isPlaying: Bool
  ) {
    // On CarPlay, substitute the bundled generic cover for a missing remote one so the car's
    // Now Playing template is never blank.
    let publishedArtworkURL =
      shouldPublishPlaceholderArtwork(forArtworkURL: artworkURL)
      ? placeholderArtworkFileURL
      : artworkURL

    nowPlayingFacade.publish(
      artist: artist,
      title: title,
      stationName: station?.name ?? BrandConstants.name,
      artworkURL: publishedArtworkURL,
      isPlaying: isPlaying
    )
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
      guard
        let image = UIImage(named: placeholderCover.imageName, in: .module, compatibleWith: nil),
        let data = image.pngData(),
        (try? data.write(to: fileURL)) != nil
      else {
        return nil
      }
      return fileURL.absoluteString
    #elseif canImport(AppKit)
      guard let image = NSImage(named: placeholderCover.imageName),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]),
        (try? data.write(to: fileURL)) != nil
      else {
        return nil
      }
      return fileURL.absoluteString
    #else
      return nil
    #endif
  }

  /// Publish only the play/pause state, via the Now Playing facade.
  private func publishPlaybackState(isPlaying: Bool) {
    nowPlayingFacade.publishState(isPlaying: isPlaying)
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

  // Internal (not private) so tests can drive the interruption flow directly — the production
  // caller is the `player.onInterruption` closure wired in `setupCallbacks()`.
  func handleInterruption(began: Bool) {
    if began {
      // Interruption began — pause. A running sleep timer is deliberately LEFT RUNNING (issue #57):
      // the timer stores an absolute fire time, so a transient interruption from another app must
      // not shorten or end the sleep session — "15 minutes" stays 15 minutes of wall-clock. Only an
      // explicit user pause / disconnect (see `stopForDisconnect()`) cancels it.
      playbackState = .paused
      publishPlaybackState(isPlaying: false)
    } else {
      // Interruption ended with resume option — resume playback
      play()
    }
  }

  // Bluetooth / wired headset disconnect (permanent output loss). Unlike an interruption this is
  // not resumable: truly stop the stream (same semantics as the user pause button) so the buffer
  // is released and the next play reconnects to the live edge instead of a stale position.
  // Internal (not private) so tests can drive the disconnect flow directly — the production caller
  // is the `player.onDisconnectStop` closure wired in `setupCallbacks()`.
  func handleDisconnectStop() {
    stopForDisconnect()
  }

  // MARK: - External Playback State Handling

  /// Reconcile the observable `playbackState` with an *external* player transition — specifically
  /// the media3 notification pause/play on Android (see the Android-only wiring in
  /// `setupCallbacks()`). This is the demotion counterpart to `reconcileWithPlayer()`, which only
  /// promotes.
  ///
  /// Deliberately conservative so it can't fight the coordinator's own state machine:
  /// - It only demotes from a *steady* `.playing` state, never from `.loading` — a `false` while
  ///   loading is an expected buffering/startup transient, not a user pause.
  /// - It never touches `.idle`/`.paused`/`.reconnecting`/`.error`: `.idle`/`.paused` are terminal
  ///   here, and the `.reconnecting`/`.error` cycle is owned by `ReconnectionManager`
  ///   (`setupReconnection()`), which emits `isPlaying=false` transients while it stops/replays.
  /// - On `isPlaying == true` it only clears a pending spinner (`.loading`/`.reconnecting` →
  ///   `.playing`), matching `reconcileWithPlayer`; it never fabricates playback from `.idle`.
  ///
  /// Internal (not private) so tests can drive it directly — the production caller is the
  /// `player.onPlaybackStateChanged` closure wired (Android-only) in `setupCallbacks()`.
  func handlePlaybackStateChanged(isPlaying: Bool) {
    if isPlaying {
      // The player is the source of truth for whether audio is playing: when it reports playing,
      // reflect `.playing` — including from `.idle`/`.paused`, not just a pending spinner. This
      // keeps the button in sync when playback is started EXTERNALLY (Android Auto / the car
      // auto-resuming while the app is foregrounded, which bypasses the app's own `play()` —
      // issue #41: button stuck on ▶ while the car played). Safe against overriding a user pause:
      // a user pause stops the player, so this callback can't arrive `true` off the back of one.
      // `.error`/`.reconnecting` are deliberately excluded — the `ReconnectionManager` owns that
      // cycle and emits `isPlaying` transients while it stops/replays the stream.
      switch playbackState {
      case .playing, .error, .reconnecting:
        break
      default:
        playbackState = .playing
        publishPlaybackState(isPlaying: true)
      }
    } else {
      // External pause (media3 notification). Demote only from a steady `.playing`; a `false`
      // while `.loading` is a buffering/startup transient, and `.reconnecting`/`.error`/`.idle`/
      // `.paused` are owned elsewhere or already terminal.
      switch playbackState {
      case .playing:
        // Audio was paused externally. A running sleep timer is deliberately LEFT RUNNING (issue
        // #57): on Android a transient audio-focus loss surfaces here (a focus loss fires both
        // `onInterruption(true)` and this `onPlaybackStateChanged(false)` — see
        // `MetadataPlayerListener`), so cancelling here would re-introduce the interruption-cancels
        // bug this callback shares with `handleInterruption`. An explicit user pause reaches
        // `stopForDisconnect()` first, which drops state to `.paused` and cancels the timer there,
        // so this branch never runs for a deliberate stop.
        playbackState = .paused
        publishPlaybackState(isPlaying: false)
      default:
        break
      }
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
    await historyReconciler.fetchAndReconcile(
      apiClient: apiClient,
      artworkService: artworkService,
      history: &history
    )
    lastHistoryFetchedAt = Date()
  }
}
