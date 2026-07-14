import SwiftUI
import Maxi80Model
import Maxi80Services

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
    // These are genuine view state, not derived from the coordinator: `volume` mirrors the
    // slider's input and `selectedCoverID` is the Cover Flow carousel's focused item (bound via
    // `$viewModel.selectedCoverID` through `scrollPosition(id:)`). Everything else is a computed
    // passthrough to the coordinator so Observation re-renders the view when coordinator state changes.

    public var volume: Double = 1.0
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
        if isBrowsingHistory, let rgb = focusedHistoryEntry?.dominantColor {
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        guard let artwork = coordinator.currentArtwork, !artwork.isDefault else {
            return nil
        }
        return artwork.dominantColor
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
            while entries.last?.songMetadata == current {
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
              let id = selectedCoverID.base as? String else { return false }
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
              let id = selectedCoverID.base as? String else { return nil }
        return coordinator.history.first { $0.id == id }
    }

    public var displayedArtist: String {
        if let entry = focusedHistoryEntry { return entry.artist }
        return currentSong?.artist ?? station?.name ?? ""
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
        coordinator.setVolume(volume)
        self.volume = volume
    }

    public func retry() {
        coordinator.retryConnection()
    }

    public func shareCurrentTrack() -> ShareContent {
        let artist = displayedArtist
        let title = displayedTitle
        let text = "I'm listening to \(title) by \(artist) on Maxi 80 via Maxi80 for iOS. Check it out at https://www.maxi80.com"
        return ShareContent(text: text, image: currentArtwork)
    }
}
