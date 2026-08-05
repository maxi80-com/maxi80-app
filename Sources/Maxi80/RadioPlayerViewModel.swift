import Maxi80Model
import Maxi80Services
import SwiftUI

// MARK: - ShareContent

public struct ShareContent {
  public let text: String
  public let image: Image?

  public init(text: String, image: Image?) {
    self.text = text
    self.image = image
  }
}

// MARK: - RadioPlayerViewModel

@MainActor
@Observable
public final class RadioPlayerViewModel {

  // MARK: - UI-Local State
  //
  // Carousel selection is canonical in `carousel` (CarouselModel); `selectedCoverID` is a
  // computed proxy over it so the public surface is unchanged (TV files, tests). Everything
  // else is a computed passthrough to the coordinator so Observation re-renders the view when
  // coordinator state changes.

  /// Output volume (0.0–1.0). Reads through to the coordinator so the slider tracks system-volume
  /// changes from the hardware buttons (Android); writing drives `setVolume`. On iOS/tvOS the volume
  /// UI is `MPVolumeView`, so this passthrough is unused there; macOS binds its in-app `Slider` to
  /// this property (see `VolumeSliderView`).
  public var volume: Double {
    get { coordinator.volume }
    set { setVolume(newValue) }
  }
  /// The Cover Flow carousel's focused item id. Typed `AnyHashable?` to match
  /// `scrollPosition(id:)`'s binding on the transpiled Android path. A computed proxy over
  /// `carousel`: reads resolve through the model, and writes route through `userSettledOn`,
  /// which ignores ids not currently in the cover list — strictly safer than the old stored
  /// write (a stale id can no longer strand the selection).
  public var selectedCoverID: AnyHashable? {
    get { carousel.selectedID }
    set { if let newValue { carousel.userSettledOn(newValue) } }
  }

  // MARK: - Coordinator-Derived State (read-through, tracked by Observation)

  public var isPlaying: Bool {
    if case .playing = coordinator.playbackState { return true }
    return false
  }

  public var isLoading: Bool {
    switch coordinator.playbackState {
    case .loading, .reconnecting:
      return true
    default:
      return false
    }
  }

  public var currentSong: SongMetadata? {
    coordinator.currentSong
  }

  public var currentArtwork: Image? {
    coordinator.currentArtwork?.image
  }

  /// The dominant color of the focused cover's artwork, or `nil` when no real artwork color is
  /// available (startup / songs with no artwork). When nil, the view paints a deliberate
  /// branded default background rather than a muddy averaged color.
  /// Tracks the focused cover: the browsed history entry's stored color while browsing, else
  /// the current artwork while playing.
  public var dominantColor: Color? {
    // While browsing history, the background must reflect the focused entry only — its stored
    // color, or nil (branded default) when it has none. Never fall through to the current
    // song's color, which would leave the last song's tint stuck under an older cover.
    if isBrowsingHistory {
      guard let rgb = focusedHistoryEntry?.backgroundColor else { return nil }
      return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    guard let artwork = coordinator.currentArtwork, !artwork.isDefault else {
      return nil
    }
    return artwork.dominantColor
  }

  /// The raw RGB behind `dominantColor`, when known — the browsed history entry's stored color
  /// while browsing, else the current artwork's sampled color. `nil` mirrors `dominantColor == nil`
  /// (no color → branded dark gradient). Kept alongside `dominantColor` so overlay text can judge
  /// contrast; `Color` itself can't be inspected for luminance cross-platform.
  public var dominantRGB: Maxi80Model.RGBColor? {
    if isBrowsingHistory {
      return focusedHistoryEntry?.backgroundColor
    }
    guard let artwork = coordinator.currentArtwork, !artwork.isDefault else {
      return nil
    }
    return artwork.rgb
  }

  /// Whether the background wash is dark enough that overlaid text should be light. `true` when
  /// there's no dominant color (the branded dark gradient) or the dominant color's perceived
  /// (Rec. 601) luminance falls below a readability threshold. Consumed by the TV UI to switch
  /// between white and dark title/artist text; the phone/CarPlay UIs keep their own color logic.
  public var isBackgroundDark: Bool {
    guard let rgb = dominantRGB else { return true }
    let luminance = 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue
    return luminance < 0.55
  }

  public var history: [HistoryEntry] {
    coordinator.history
  }

  // MARK: - Cover Flow
  //
  // Consumed only by RadioPlayerView within this module, so these stay internal
  // (Cover is an internal type).

  /// Stable id for the persistent rightmost "now" slot. It never changes between idle and
  /// playing, so the carousel stays put when the current artwork swaps in. Aliased to the
  /// model's sentinel so the two can never drift apart.
  static let nowSlotID = CarouselModel.nowSlotID

  /// Past history entries shown to the left of the now slot, oldest → newest, with trailing
  /// copies of the current song removed. The current song lives only in the now slot, and both
  /// the locally-appended live entry and the backend's own newest entry can duplicate it, so
  /// every trailing entry matching the current song is dropped.
  ///
  /// Extracted from `covers` so `isBrowsingHistory` and `coverPinToken` can consult the history
  /// set without allocating the full `Cover` array — keeping `covers` built once per render.
  private var pastEntries: [HistoryEntry] {
    var entries = coordinator.history
    if let current = coordinator.currentSong {
      // Match by normalized identity so the current program is dropped from the past list even
      // when history stores it with the `Maxi80` artist and the live current song has none.
      while entries.last?.songIdentity == current.identity {
        entries.removeLast()
      }
    }
    return entries
  }

  /// Covers for the carousel, oldest → newest. Past history grows to the left; the rightmost
  /// cover is always the persistent "now" slot — the generic image when idle, or the current
  /// song's artwork while playing.
  var covers: [Cover] {
    let past = pastEntries.map { entry in
      // Fall back to a generic cover for entries whose artwork couldn't be resolved, so no cover is
      // ever blank. Derived from the entry id so it stays put across re-renders.
      Cover(
        id: entry.id,
        artworkURL: entry.artworkURL,
        assetName: entry.artworkURL == nil
          ? PlaceholderCover.forEntry(hashValue: entry.id.hashValue).imageName : nil
      )
    }

    // The persistent "now" slot: current artwork while playing, generic cover otherwise.
    let nowArtworkURL = coordinator.currentArtwork.flatMap { $0.isDefault ? nil : $0.url }
    let nowSlot = Cover(
      id: Self.nowSlotID,
      artworkURL: nowArtworkURL,
      assetName: nowArtworkURL == nil ? coordinator.nowPlaceholderCover.imageName : nil
    )

    let all = past + [nowSlot]
    // Keep the canonical model in lockstep with what the renderer sees. Safe to call from a
    // computed property: the model no-ops (touching no observable state) when unchanged.
    carousel.syncCoverIDs(all.map(\.id))
    return all
  }

  /// The id of the live cover — always the persistent rightmost "now" slot.
  var liveCoverID: AnyHashable? {
    Self.nowSlotID
  }

  /// Whether the user has scrolled away from the now slot onto a past cover that exists.
  /// The model consults its synced `coverIDs` (past entry ids + now slot) where the old check
  /// consulted `pastEntries` directly — semantically identical.
  var isBrowsingHistory: Bool {
    carousel.isBrowsing
  }

  /// Incremented so `coverPinToken` changes when the user taps "Back to live" even though the
  /// cover set is unchanged. Only the TV UI still keys on the token (its focus-driven row
  /// re-scrolls on token change); the phone carousel re-centers from `carousel.selectedID` alone.
  private var returnToLiveNonce = 0

  /// Jump the carousel back to the now slot.
  func returnToLive() {
    carousel.returnToLive()
    returnToLiveNonce += 1
  }

  public var station: Station? {
    coordinator.station
  }

  public var errorMessage: String? {
    if let message = coordinator.errorMessage { return message }
    if case .error(let message) = coordinator.playbackState { return message }
    return nil
  }

  public var canShare: Bool {
    guard let song = coordinator.currentSong else { return false }
    return !song.artist.isEmpty && !song.title.isEmpty
  }

  // MARK: - Sleep Timer (read-through)

  /// Whether a sleep timer is currently running. Drives the moon glyph's filled/idle state and
  /// whether the countdown pill occupies the status slot.
  public var isSleepTimerActive: Bool { coordinator.sleepTimerFiresAt != nil }

  /// When the running sleep timer will fire, or `nil` when inactive. The countdown pill computes
  /// its remaining time from this against `Date()` via `TimelineView`, so no ticking state is stored.
  public var sleepTimerFiresAt: Date? { coordinator.sleepTimerFiresAt }

  /// The preset durations (minutes) offered by the picker. Presets only — no custom picker.
  public static let sleepTimerPresets: [Int] = [5, 10, 15, 30, 45, 60, 90]

  // MARK: - Computed Display Properties

  /// The history entry the display surfaces are focused on, if the user is browsing an older
  /// song. Reads the model's display-deferred id (NOT `selectedCoverID`): on Android the
  /// label/background/button recomposition follows the settle glide instead of landing in the
  /// middle of it — see `CarouselModel.displaySelectedID`.
  private var focusedHistoryEntry: HistoryEntry? {
    guard let id = carousel.focusedEntryID else { return nil }
    return coordinator.history.first { $0.id == id }
  }

  public var displayedArtist: String {
    if let entry = focusedHistoryEntry { return entry.artist }
    if let artist = currentSong?.artist, !artist.isEmpty { return artist }
    // The live stream leaves DJ programs artist-less; the backend history copy carries the
    // `Maxi80` artist, so surface it for the now slot before falling back to the station name.
    if let current = currentSong,
      let historyArtist = coordinator.history.last(where: {
        $0.songIdentity == current.identity && !$0.artist.isEmpty
      })?.artist
    {
      return historyArtist
    }
    return station?.name ?? ""
  }

  public var displayedTitle: String {
    if let entry = focusedHistoryEntry { return entry.title }
    return currentSong?.title ?? station?.shortDesc ?? ""
  }

  /// When the browsed history entry was captured, or `nil` on the live slot (or if the backend
  /// timestamp doesn't parse — the UI hides its air-time line in both cases).
  public var focusedEntryDate: Date? {
    guard let entry = focusedHistoryEntry else { return nil }
    return Self.timestampParser.date(from: entry.timestamp)
  }

  private static let timestampParser = ISO8601DateFormatter()

  // MARK: - Dependencies

  @ObservationIgnored
  private let coordinator: RadioPlayerCoordinator

  /// Canonical carousel selection state. `covers` stays computed (pull-based) and syncs the
  /// model's cover ids on every build; the public surface (`selectedCoverID`,
  /// `isBrowsingHistory`, `returnToLive`) is preserved as passthroughs over this model.
  let carousel = CarouselModel()

  // MARK: - Initialization

  public init(coordinator: RadioPlayerCoordinator) {
    self.coordinator = coordinator
    // The carousel model starts focused on the persistent "now" slot by default.
  }

  /// TV ONLY: token that changes whenever the carousel's content changes — the full ordered
  /// list of cover ids plus the now-slot artwork, and the back-to-live nonce. `TVHistoryRow`
  /// keys its focus-driven re-scroll on it. The phone/tablet `CoverFlowStrip` doesn't use it:
  /// it re-derives the centered cover from `carousel.selectedID` on every layout pass.
  var coverPinToken: String {
    let ids = pastEntries.map(\.id).joined(separator: ",")
    let nowURL = coordinator.currentArtwork.flatMap { $0.isDefault ? nil : $0.url } ?? "generic"
    return "\(ids)|\(nowURL)|\(returnToLiveNonce)"
  }

  // MARK: - Actions

  public func togglePlayback() {
    if isPlaying || isLoading {
      coordinator.pause()
    } else {
      coordinator.play()
    }
  }

  public func setVolume(_ volume: Double) {
    // Writes to the system STREAM_MUSIC level (Android); the coordinator's observable `volume`
    // is then updated by the system-volume observer, which re-renders the slider.
    coordinator.setVolume(volume)
  }

  public func retry() {
    coordinator.retryConnection()
  }

  // MARK: - Sleep Timer Actions

  public func startSleepTimer(minutes: Int) {
    coordinator.startSleepTimer(minutes: minutes)
  }

  public func cancelSleepTimer() {
    coordinator.cancelSleepTimer()
  }

  public func extendSleepTimer(minutes: Int) {
    coordinator.extendSleepTimer(minutes: minutes)
  }

  /// The localized "MM:SS remaining"-style label for the countdown pill, computed against `now`
  /// (supplied by the pill's `TimelineView`). Returns the bare `MM:SS` string; the accessibility
  /// label wraps it via the "%@ remaining" catalog string. `nil` when no timer is active.
  public func sleepCountdownText(now: Date) -> String? {
    guard let firesAt = coordinator.sleepTimerFiresAt else { return nil }
    let remaining = max(0, Int(firesAt.timeIntervalSince(now).rounded(.up)))
    let minutes = remaining / 60
    let seconds = remaining % 60
    return String(format: "%d:%02d", minutes, seconds)
  }

  public func shareCurrentTrack() -> ShareContent {
    return ShareContent(text: shareText, image: currentArtwork)
  }

  /// The localized "I'm listening to …" share message for the current track. Exposed for the iOS
  /// share sheet, which needs the text synchronously while it downloads the cover asynchronously.
  public var shareMessage: String { shareText }

  /// The displayed cover's downloaded bytes for the iOS `UIActivityViewController` (which needs a
  /// `UIImage`, not the SwiftUI `Image` the app holds, so the bytes are fetched rather than reusing
  /// `currentArtwork`). Uses the history-aware `shareArtworkURL` so a browsed cover is shared, not
  /// just the live song; a nil URL or download failure returns nil → text-only share. Mirrors the
  /// Android native-share path, which already attaches the cover.
  public func shareImageData() async -> Data? {
    guard let url = shareArtworkURL else { return nil }
    return await coordinator.shareArtworkData(urlString: url)
  }

  /// The localized "I'm listening to …" share message for the current track.
  private var shareText: String {
    let artist = displayedArtist
    let title = displayedTitle
    let format = Bundle.module.localizedString(
      forKey: "I'm listening to %@ by %@ on Maxi 80. Listen at %@", value: nil, table: nil)
    return String(format: format, title, artist, BrandConstants.websiteURL)
  }

  /// The artwork URL for the song the share text describes — the focused history entry's cover
  /// while browsing, else the live song's cover. Kept in lockstep with `shareText` (which uses the
  /// same history-aware `displayed*` fields) so the shared image and text always describe the same
  /// song. `nil` when the displayed song has no real artwork, in which case the share is text-only.
  /// Internal (not private) so tests can assert this history-aware pick, as `ShareTextPropertyTests`
  /// asserts `shareText` — the native share path itself is a fire-and-forget no-op in tests.
  var shareArtworkURL: String? {
    if let entry = focusedHistoryEntry { return entry.artworkURL }
    return coordinator.currentArtwork.flatMap { $0.isDefault ? nil : $0.url }
  }

  /// Fire the platform-native share flow (Android system chooser). The coordinator downloads the
  /// displayed cover so the share can include the artwork image; a miss falls back to text only.
  /// Apple platforms present `UIActivityViewController` via the SwiftUI `ShareSheet` instead.
  public func shareCurrentTrackNatively() {
    let text = shareText
    let artworkURL = shareArtworkURL
    Task { [weak self] in
      await self?.coordinator.shareCurrentTrack(text: text, artworkURL: artworkURL)
    }
  }
}
