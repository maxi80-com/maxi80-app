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
  // `selectedCoverID` is the Cover Flow carousel's focused item (bound via
  // `$viewModel.selectedCoverID` through `scrollPosition(id:)`). Everything else is a computed
  // passthrough to the coordinator so Observation re-renders the view when coordinator state changes.

  /// Output volume (0.0–1.0). Reads through to the coordinator so the slider tracks system-volume
  /// changes from the hardware buttons (Android); writing drives `setVolume`. On iOS/tvOS the volume
  /// UI is `MPVolumeView`, so this passthrough is unused there; macOS binds its in-app `Slider` to
  /// this property (see `VolumeSliderView`).
  public var volume: Double {
    get { coordinator.volume }
    set { setVolume(newValue) }
  }
  /// The Cover Flow carousel's focused item id. Typed `AnyHashable?` to match
  /// `scrollPosition(id:)`'s binding on the transpiled Android path.
  public var selectedCoverID: AnyHashable?

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
  // (CoverFlowView.Cover is an internal type).

  /// Stable id for the persistent rightmost "now" slot. It never changes between idle and
  /// playing, so the carousel stays put when the current artwork swaps in.
  static let nowSlotID = "__now__"

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
  var covers: [CoverFlowView.Cover] {
    let past = pastEntries.map { entry in
      // Fall back to the launch placeholder art for entries whose artwork
      // couldn't be resolved, so no cover is ever blank.
      CoverFlowView.Cover(
        id: entry.id,
        artworkURL: entry.artworkURL,
        assetName: entry.artworkURL == nil ? coordinator.placeholderCover.imageName : nil
      )
    }

    // The persistent "now" slot: current artwork while playing, generic cover otherwise.
    let nowArtworkURL = coordinator.currentArtwork.flatMap { $0.isDefault ? nil : $0.url }
    let nowSlot = CoverFlowView.Cover(
      id: Self.nowSlotID,
      artworkURL: nowArtworkURL,
      assetName: nowArtworkURL == nil ? coordinator.placeholderCover.imageName : nil
    )

    return past + [nowSlot]
  }

  /// The id of the live cover — always the persistent rightmost "now" slot.
  var liveCoverID: AnyHashable? {
    Self.nowSlotID
  }

  /// Whether the user has scrolled away from the now slot onto a past cover that exists.
  var isBrowsingHistory: Bool {
    guard let selectedCoverID, selectedCoverID != AnyHashable(Self.nowSlotID),
      let id = selectedCoverID.base as? String
    else { return false }
    return pastEntries.contains { $0.id == id }
  }

  /// Incremented to force the carousel to re-scroll to the now slot even when the cover set
  /// is unchanged (e.g. the user taps "Back to live" — `scrollPosition` is read-only, so
  /// setting `selectedCoverID` alone can't move the scroll).
  private var returnToLiveNonce = 0

  /// Jump the carousel back to the now slot.
  func returnToLive() {
    selectedCoverID = liveCoverID
    returnToLiveNonce += 1
  }

  /// True for a short window while the carousel is being recreated and its fresh layout would
  /// otherwise report the leftmost (oldest) cover. Two events recreate the carousel:
  ///   - an orientation change (portrait and landscape host it in different structural slots), and
  ///   - a background→foreground resume on Android (the activity is destroyed and recreated).
  /// This lock lives in the view model — which survives both recreations, being a process-wide
  /// singleton — so the carousel's transient selection write-back can be dropped while set,
  /// preserving the browsed/live cover.
  public private(set) var isCarouselRecreating = false

  @ObservationIgnored
  private var carouselRecreateClearTask: Task<Void, Never>?

  /// Begin the recreation lock for an orientation change, auto-clearing once the recreated
  /// carousel has settled.
  func beginReorientation() {
    beginCarouselRecreationWindow()
  }

  /// Begin the recreation lock for a background→foreground transition. The recreated carousel's
  /// leftmost-cover write-back is dropped for the window, so the persisted selection survives the
  /// resume — the same protection rotation already had, now covering the resume path too.
  func beginForegroundTransition() {
    beginCarouselRecreationWindow()
  }

  private func beginCarouselRecreationWindow() {
    isCarouselRecreating = true
    carouselRecreateClearTask?.cancel()
    carouselRecreateClearTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 700_000_000)
      self?.isCarouselRecreating = false
    }
  }

  /// Set the selection unless a carousel recreation is in flight, so transient relayout centering
  /// during a rotation or a resume can't clobber the browsed/live cover.
  func setSelectionFromCarousel(_ newValue: AnyHashable?) {
    guard !isCarouselRecreating else { return }
    selectedCoverID = newValue
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

  // MARK: - Computed Display Properties

  /// The history entry the carousel is focused on, if the user is browsing an older song.
  private var focusedHistoryEntry: HistoryEntry? {
    guard let selectedCoverID, selectedCoverID != liveCoverID,
      let id = selectedCoverID.base as? String
    else { return nil }
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

  // MARK: - Dependencies

  @ObservationIgnored
  private let coordinator: RadioPlayerCoordinator

  // MARK: - Initialization

  public init(coordinator: RadioPlayerCoordinator) {
    self.coordinator = coordinator
    // Start focused on the persistent "now" slot (rightmost).
    self.selectedCoverID = Self.nowSlotID
  }

  /// Token that changes whenever the carousel's content changes — the full ordered list of
  /// cover ids plus the now-slot artwork. The view re-pins the scroll to the now slot when it
  /// changes, so the carousel re-centers after history loads or the current artwork swaps in.
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

  public func shareCurrentTrack() -> ShareContent {
    return ShareContent(text: shareText, image: currentArtwork)
  }

  /// The localized "I'm listening to …" share message for the current track.
  private var shareText: String {
    let artist = displayedArtist
    let title = displayedTitle
    let format = Bundle.module.localizedString(
      forKey: "I'm listening to %@ by %@ on Maxi 80. Listen at %@", value: nil, table: nil)
    return String(format: format, title, artist, BrandConstants.websiteURL)
  }

  /// Fire the platform-native share flow (Android system chooser). The coordinator re-downloads the
  /// current cover so the share can include the artwork image; a miss falls back to text only. Apple
  /// platforms present `UIActivityViewController` via the SwiftUI `ShareSheet` instead.
  public func shareCurrentTrackNatively() {
    let text = shareText
    Task { await coordinator.shareCurrentTrack(text: text) }
  }
}
