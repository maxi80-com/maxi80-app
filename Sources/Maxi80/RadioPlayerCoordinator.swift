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
  private let player: any AudioPlaying
  @ObservationIgnored
  private let nowPlayingPublisher: any NowPlayingPublishing
  @ObservationIgnored
  private let apiClient: any APIClientProtocol
  @ObservationIgnored
  private let artworkService: ArtworkService
  @ObservationIgnored
  private let shareService: any Sharing
  @ObservationIgnored
  private let featureFlags: FeatureFlags

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

  /// When the sleep timer will fire, or `nil` when no timer is running. Reads through to
  /// `SleepTimerManager`, which is the single source of truth for both "is a timer running" and "how
  /// long is left"; this stays on the coordinator because the view model's surface is the coordinator.
  public var sleepTimerFiresAt: Date? { sleepTimer.firesAt }

  /// Asset name of the generic cover for the current song, shown in the carousel's "now" slot and
  /// published to system Now Playing while that song has no artwork of its own.
  ///
  /// Read off the newest history entry rather than stored: that entry *is* the current song (it's
  /// appended/healed the moment the song's artwork resolves), so the cover on screen is by
  /// construction the one the song keeps as it slides left into history (issue #70) — no second copy
  /// to keep in step. Falls back to the default cover when the newest entry has real artwork or
  /// history is still empty, which is also what the now slot shows before the first song.
  var nowPlaceholderCover: String {
    guard case .generic(let imageName) = history.last?.cover else {
      return PlaceholderCover.default.imageName
    }
    return imageName
  }

  // MARK: - Internal State

  @ObservationIgnored
  private let reconnectionManager: ReconnectionManager
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
  private let artworkRetry: ArtworkRetryManager

  /// Owns the sleep timer's fire date, fade ramp, and task. `@ObservationIgnored` because the
  /// reference never changes; the manager is itself `@Observable`, so reading `sleepTimerFiresAt`
  /// through it still re-renders the views that consult it.
  @ObservationIgnored
  private let sleepTimer: SleepTimerManager

  /// Default stream URL used when station hasn't loaded yet.
  private let defaultStreamURL = BrandConstants.streamURL

  /// How long to wait after issuing a reconnect `play()` before checking whether the
  /// stream actually resumed. Injectable so tests don't pay the full 3s; production keeps the default.
  private let reconnectConfirmationDelay: UInt64

  /// Produces backend-compatible ISO-8601 timestamps for live history entries so they
  /// sort consistently against entries fetched from the API.
  private static let isoTimestampFormatter = ISO8601DateFormatter()

  // MARK: - Initialization

  public init(
    player: any AudioPlaying,
    nowPlaying: any NowPlayingPublishing,
    apiClient: any APIClientProtocol,
    artworkService: ArtworkService,
    shareService: any Sharing,
    featureFlags: FeatureFlags = .shared,
    reconnectConfirmationDelay: UInt64 = 3_000_000_000,
    reconnectTimeScale: Double = 1.0,
    sleepFadeDuration: UInt64 = 2_500_000_000,
    placeholderArtworkURL: String? = nil
  ) {
    self.player = player
    self.nowPlayingPublisher = nowPlaying
    self.apiClient = apiClient
    self.artworkService = artworkService
    self.shareService = shareService
    self.featureFlags = featureFlags
    self.reconnectConfirmationDelay = reconnectConfirmationDelay
    self.reconnectionManager = ReconnectionManager(timeScale: reconnectTimeScale)
    self.sleepTimer = SleepTimerManager(player: player, fadeDuration: sleepFadeDuration)
    self.artworkRetry = ArtworkRetryManager(artworkService: artworkService)
    self.injectedPlaceholderArtworkURL = placeholderArtworkURL

    // Assigned here rather than injected: the handlers capture `self`, which can't exist while the
    // stored properties above are still being initialized. Same shape as the player callbacks below.
    sleepTimer.onFired = { [weak self] in
      self?.stopForDisconnect()
    }
    artworkRetry.isStillCurrent = { [weak self] metadata in
      self?.currentSong == metadata
    }
    artworkRetry.onResolved = { [weak self] artwork, metadata in
      self?.applyRetriedArtwork(artwork, for: metadata)
    }

    setupCallbacks()
    setupReconnection()

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
  //
  // The timer itself — fire date, fade ramp, cancelable task — lives in `SleepTimerManager`. What
  // stays here is the one piece that isn't the timer's business: the policy on whether a timer may be
  // armed at all, which reads `playbackState`.

  /// Start (or restart) the sleep timer for `minutes` from now. Playback fades out and stops when it
  /// fires.
  public func startSleepTimer(minutes: Int) {
    // Enforce the "only settable while playing" invariant at the API boundary, not only in the UI's
    // `isEnabled`: a sleep timer with no audio is meaningless and would fire a fade/stop on an idle
    // player. Keeps any current/future caller in sync with the UI. This gate lives here, not in the
    // manager, because it reads playback state the manager deliberately knows nothing about.
    guard playbackState.isPlaying else {
      logger.info("ignoring sleep timer request while not playing")
      return
    }
    sleepTimer.start(minutes: minutes)
  }

  /// Cancel a running sleep timer and restore full playback volume. A no-op when none is running.
  public func cancelSleepTimer() {
    sleepTimer.cancel()
  }

  /// Extend the running timer by `minutes`, folding in whatever time is currently left. A no-op when
  /// no timer is running (the UI only offers extend while active).
  ///
  /// Routed through the manager rather than back through `startSleepTimer` so an extend can't be
  /// refused by the not-playing gate: extending is only reachable while a timer already runs, and a
  /// timer can outlive playback (a pause leaves it running by design — see `stopForDisconnect`).
  public func extendSleepTimer(minutes: Int) {
    sleepTimer.extend(minutes: minutes)
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
    publishNowPlaying(
      artist: artist, title: title, artworkURL: url, isPlaying: playbackState.isPlaying)
  }

  /// Fetch station metadata on launch with fallback chain.
  public func loadStation() async {
    logger.info("loadStation: GET /station")
    let stationJSON = try? await apiClient.fetchStation()

    if let json = stationJSON, let parsed = try? json.decodedJSON(as: Station.self) {
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

    // Apply the flags carried by whichever station won the fallback chain: the fresh response, or
    // the cached one (whose flags are the last known good), or the hardcoded fallback (no flags at
    // all → compiled-in defaults).
    featureFlags.update(from: station?.features)

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

    // Remote commands (lock screen, media3 notification, car) are wired at the composition root,
    // which owns the bridged `NowPlayingController` — see `SharedPlayer` and `handleRemote(_:)`.
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
    artworkRetry.cancel()

    // Fetch artwork asynchronously
    logger.info("fetching artwork for current song")
    let artwork = await artworkService.fetchArtwork(artist: metadata.artist, title: metadata.title)
    currentArtwork = artwork
    artwork.cacheDecodedImage()
    logger.info("artwork resolved — hasImage=\(artwork.image != nil), url=\(artwork.url ?? "nil")")

    // Record this song in history, carrying the cover the carousel will show — the already-resolved
    // artwork, or a generic cover picked now. That entry is the source of `nowPlaceholderCover`, so it
    // is written before the Now Playing publish below, which reads it.
    let entry = HistoryEntry(
      artist: metadata.artist,
      title: metadata.title,
      artworkKey: nil,
      timestamp: Self.isoTimestampFormatter.string(from: Date()),
      // Keyed on `isDefault`, not on the URL: a default-cover result can still carry one, and that
      // generic remote image is exactly what our own bundled covers replace.
      cover: artwork.isDefault
        ? .generic(PlaceholderCover.random().imageName)
        : artwork.url.map(CoverSource.artwork) ?? .pending,
      colors: artwork.rgb.map { ArtworkColors(uniform: $0) }
    )
    // The seeded backend history already ends with the song playing at launch, so the FIRST
    // metadata event is for a song already in the list. Appending would create a duplicate that
    // only surfaces once the next song starts (both copies are hidden while they're the now
    // slot). If the newest entry is already this song (by normalized identity), heal it in place
    // — filling any artwork/colors the backend copy lacked — instead of appending a second copy.
    // A genuine repeat play (A → B → A) doesn't match here: the tail is B, so it still appends.
    //
    // Healing also keeps the cover the seeded entry already had (`mergedWith` prefers `self`'s), so
    // the song playing at launch isn't given a second, different cover a moment after it appears.
    if history.last?.songIdentity == metadata.identity {
      history[history.count - 1] = history[history.count - 1].mergedWith(entry)
    } else {
      history.append(entry)
    }

    // Update system now-playing info (modern NowPlaying framework if available, else MediaPlayer).
    publishNowPlaying(
      artist: metadata.artist,
      title: metadata.title,
      artworkURL: artwork.url,
      isPlaying: true
    )

    // If artwork wasn't ready (backend collector hadn't produced it yet), retry in the
    // background — the cover fills in once it appears, without waiting for the next song.
    if artwork.isDefault {
      artworkRetry.start(for: metadata)
    }
  }

  /// Apply artwork that arrived on retry: update the current-song cover/background, the system
  /// Now Playing info, and the matching (most recent) history entry so the carousel cover fills in.
  /// Wired to `artworkRetry.onResolved` in `init`; only ever called with a real (non-default) result.
  private func applyRetriedArtwork(_ artwork: ArtworkResult, for metadata: SongMetadata) {
    currentArtwork = artwork
    artwork.cacheDecodedImage()
    publishNowPlaying(
      artist: metadata.artist,
      title: metadata.title,
      artworkURL: artwork.url,
      isPlaying: playbackState.isPlaying
    )

    // Update the newest history entry for this song (the live-appended one) in place.
    if let index = history.lastIndex(where: { $0.songIdentity == metadata.identity }) {
      // Only ever called with real artwork (the retry loop skips default results), so the entry's
      // generic cover gives way to it — `CoverSource.mergedWith` ranks artwork above generic.
      let patch = HistoryEntry(
        artist: history[index].artist,
        title: metadata.title,
        timestamp: history[index].timestamp,
        cover: artwork.url.map(CoverSource.artwork) ?? .pending,
        colors: artwork.rgb.map { ArtworkColors(uniform: $0) }
      )
      history[index] = history[index].mergedWith(patch)
    }
  }

  // MARK: - Now Playing Publishing

  /// Publish current-track metadata to the system through the injected publisher. Which sink that
  /// is — the modern NowPlaying framework or the bridged MediaPlayer / MediaSession controller — is
  /// decided once at the composition root (`SharedPlayer`).
  private func publishNowPlaying(
    artist: String, title: String, artworkURL: String?, isPlaying: Bool
  ) {
    // On CarPlay, substitute the bundled generic cover for a missing remote one so the car's
    // Now Playing template is never blank. Both sinks load artwork by URL and accept a `file://`
    // URL, so the placeholder rides the same path.
    let publishedArtworkURL =
      shouldPublishPlaceholderArtwork(forArtworkURL: artworkURL)
      ? placeholderArtworkFileURL
      : artworkURL

    nowPlayingPublisher.activate()
    nowPlayingPublisher.update(
      stationName: station?.name ?? BrandConstants.name,
      artist: artist,
      title: title,
      artworkURL: publishedArtworkURL,
      isPlaying: isPlaying
    )
  }

  /// A `file://` URL string for the current song's generic cover, materialized from the asset
  /// catalog (the covers live in `.xcassets`, which have no directly loadable URL). `nil` on
  /// platforms without image APIs (Android) or if materialization fails — callers then simply
  /// publish no artwork, as before.
  ///
  /// The cover follows the song (issue #70), so this materializes per cover and memoizes: each
  /// pool member is written at most once per launch, and a repeat publish for the same cover costs
  /// a dictionary lookup.
  private var placeholderArtworkFileURL: String? {
    if let injectedPlaceholderArtworkURL { return injectedPlaceholderArtworkURL }
    let imageName = nowPlaceholderCover
    if let cached = placeholderArtworkFileURLs[imageName] { return cached }
    let url = materializePlaceholderArtwork(named: imageName)
    placeholderArtworkFileURLs[imageName] = url
    return url
  }

  /// Overrides the materialized placeholder when non-nil. Injectable because materialization needs a
  /// real asset catalog: in the host test bundle `UIImage`/`NSImage(named:)` find nothing, so the
  /// production path resolves to `nil` there — indistinguishable from publishing no artwork at all,
  /// which would let a deletion of the substitution at the publish site go unnoticed. Tests stage a
  /// sentinel URL so the substitution is observable. Production passes nothing.
  @ObservationIgnored
  private let injectedPlaceholderArtworkURL: String?

  /// Materialized placeholder files by asset name. The value is `String?` so a materialization
  /// failure is remembered too, rather than retried on every publish.
  @ObservationIgnored
  private var placeholderArtworkFileURLs: [String: String?] = [:]

  /// Write a placeholder cover to a temp file so it can be published to the system Now Playing
  /// info by URL. Supported on Apple platforms (UIKit for iOS/tvOS Now Playing + CarPlay, AppKit
  /// for macOS); Android has no platform image APIs so it returns `nil` and no artwork is published.
  /// Idempotent: reuses the file if it already exists.
  private func materializePlaceholderArtwork(named imageName: String) -> String? {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("maxi80-\(imageName).png")

    if FileManager.default.fileExists(atPath: fileURL.path) {
      return fileURL.absoluteString
    }

    #if canImport(UIKit)
      guard
        let image = UIImage(named: imageName, in: .module, compatibleWith: nil),
        let data = image.pngData(),
        (try? data.write(to: fileURL)) != nil
      else {
        return nil
      }
      return fileURL.absoluteString
    #elseif canImport(AppKit)
      guard let image = NSImage(named: imageName),
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

  /// Publish only the play/pause state, through the same single publisher.
  private func publishPlaybackState(isPlaying: Bool) {
    nowPlayingPublisher.updatePlaybackState(isPlaying: isPlaying)
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

  // Internal (not private) so tests can drive the reconnection cycle directly — the production
  // caller is the `player.onError` closure wired in `setupCallbacks()`.
  func handleError(_ message: String) {
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

  /// Handle a transport command from a system surface (lock screen, notification, car).
  /// Public so the composition root can forward the bridged controller's callback, which it now
  /// owns. Values: "play", "pause", "togglePlayPause".
  public func handleRemote(_ command: String) {
    handleRemoteCommand(command)
  }

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
      let entries = try? json.decodedJSON(as: HistoryResponse.self).entries
    else {
      logger.notice("fetchHistory: no data or decode failed")
      return
    }

    // First load (empty history): resolve artwork for every entry and seed the list.
    if history.isEmpty {
      let resolved = await resolveArtwork(for: entries)
      // Re-check AFTER the await: `handleMetadataChanged` may have live-appended a song while we
      // were suspended resolving artwork (both run on @MainActor but interleave across suspension
      // points). Overwriting `history` here would either drop that live entry or, combined with a
      // later fetch, duplicate it. If the list is no longer empty, reconcile incrementally against
      // the live array instead of clobbering it.
      if history.isEmpty {
        history = resolved
      } else {
        mergeResolvedEntries(resolved)
      }
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
    //      produced the cover is showing a generic one (`cover.wantsArtwork`); the backend copy now
    //      resolves the real one. Without this, that entry would keep the generic cover forever.
    // Songs already showing artwork are left untouched (no reload, no flicker). Legitimate
    // repeat plays (same song at different times) are preserved — we edit in place and append,
    // never collapse by song.
    // Identity, not raw songMetadata: a backend `Maxi80` entry and a live artist-less entry for
    // the same program collapse to one identity, so they heal into a single entry rather than
    // showing a duplicate cover.
    let existingSongs = Set(history.map(\.songIdentity))
    let songsMissingArtwork = Set(history.filter { $0.cover.wantsArtwork }.map(\.songIdentity))

    // Backend entries worth resolving: new songs, or songs an in-memory entry still lacks art for.
    let toResolve = entries.filter {
      !existingSongs.contains($0.songIdentity) || songsMissingArtwork.contains($0.songIdentity)
    }
    guard !toResolve.isEmpty else {
      logger.info("fetchHistory: nothing new or missing artwork to merge")
      return
    }

    let resolved = await resolveArtwork(for: toResolve)

    // Heal existing entries and append genuinely-new songs, deduping against the LIVE `history`
    // read *after* the await — not the `existingSongs` snapshot taken before it. See
    // `mergeResolvedEntries` for why the post-await read is required.
    mergeResolvedEntries(resolved)
  }

  /// Merges backend-resolved entries into the live `history`: heals in-place any existing entry
  /// missing artwork/artist from its backend copy, then appends songs not already present, ordered
  /// by timestamp.
  ///
  /// The existence check keys off `history` **as read here**, at mutation time — NOT off a snapshot
  /// captured before the artwork `await` in `fetchHistory()`. `RadioPlayerCoordinator` is
  /// `@MainActor`, which prevents data races but not interleaving across suspension points: while
  /// `fetchHistory()` is suspended resolving artwork, `handleMetadataChanged(...)` can run to
  /// completion and live-append the currently-playing song. Deduping against a pre-await snapshot
  /// would then miss that live entry and append the backend's copy of the same song a second time
  /// → the duplicate reported in issue #28. Reading `history` here closes that window.
  ///
  /// Dedup is by *presence in the current array* (`songIdentity`), so genuine repeat plays (same
  /// song, different timestamps) are preserved — the backend reports each song once, so a repeat
  /// that is already in memory simply isn't re-appended.
  private func mergeResolvedEntries(_ resolved: [HistoryEntry]) {
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
      guard entry.cover.wantsArtwork || entry.artist.isEmpty,
        let backend = backendBySong[entry.songIdentity]
      else { return entry }
      let merged = entry.mergedWith(backend)
      if merged != entry { healed += 1 }
      return merged
    }

    // 2. Append genuinely-new songs, then order by timestamp so newest sits nearest the now-slot
    //    (the carousel renders history oldest→newest, left→right). Dedup against the LIVE array
    //    read on the line above — not a pre-await snapshot — so a song `handleMetadataChanged`
    //    live-appended during the artwork await is not added a second time.
    let existingSongsNow = Set(history.map(\.songIdentity))
    let newEntries = resolved.filter { !existingSongsNow.contains($0.songIdentity) }
    if !newEntries.isEmpty {
      history = (history + newEntries).sorted { $0.timestamp < $1.timestamp }
    }
    logger.info(
      "fetchHistory: healed \(healed), added \(newEntries.count); history now has \(self.history.count)"
    )
  }

  /// Resolves each entry's artwork S3 key into a lightweight presigned URL, concurrently.
  /// AsyncImage loads the image lazily — we do NOT download it here. The background color is
  /// derived from the backend `colors` palette already decoded on the entry; if absent it stays nil.
  ///
  /// Entries whose artwork doesn't resolve get a generic cover here, the other half of the rule in
  /// `handleMetadataChanged`: an entry is given one when it is created without artwork. Backend
  /// entries never pass through the now slot — on a cold start `/history` seeds ~20 past songs — so
  /// this is where their covers come from, and every coverless entry in `history` carries one.
  private func resolveArtwork(for entries: [HistoryEntry]) async -> [HistoryEntry] {
    let urlByIndex = await withTaskGroup(of: (Int, String?).self) { group in
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
      return urlByIndex
    }

    return entries.enumerated().map { index, entry -> HistoryEntry in
      var copy = entry
      let url = urlByIndex[index] ?? nil
      copy.cover = url.map(CoverSource.artwork) ?? .generic(PlaceholderCover.random().imageName)
      return copy
    }
  }

}
