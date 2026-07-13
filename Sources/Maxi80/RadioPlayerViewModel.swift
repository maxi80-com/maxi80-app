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

    private static let defaultDominantColor = Color(red: 0.15, green: 0.15, blue: 0.25)

    // MARK: - UI-Local State
    //
    // These are genuine view state, not derived from the coordinator: `volume` mirrors the
    // slider's input and `selectedHistoryIndex` is the carousel's selection (bound via
    // `$viewModel.selectedHistoryIndex`). Everything else is a computed passthrough to the
    // coordinator so the Observation framework re-renders the view when coordinator state changes.

    public var volume: Double = 1.0
    public var selectedHistoryIndex: Int = 0

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

    public var dominantColor: Color {
        coordinator.currentArtwork?.dominantColor ?? Self.defaultDominantColor
    }

    public var history: [HistoryEntry] {
        coordinator.history
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

    public var displayedArtist: String {
        if !history.isEmpty,
           selectedHistoryIndex >= 0,
           selectedHistoryIndex < history.count,
           selectedHistoryIndex != history.count - 1 {
            return history[selectedHistoryIndex].artist
        }
        return currentSong?.artist ?? station?.name ?? ""
    }

    public var displayedTitle: String {
        if !history.isEmpty,
           selectedHistoryIndex >= 0,
           selectedHistoryIndex < history.count,
           selectedHistoryIndex != history.count - 1 {
            return history[selectedHistoryIndex].title
        }
        return currentSong?.title ?? station?.shortDesc ?? ""
    }

    // MARK: - Dependencies

    @ObservationIgnored
    private let coordinator: RadioPlayerCoordinator

    // MARK: - Initialization

    public init(coordinator: RadioPlayerCoordinator) {
        self.coordinator = coordinator
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
