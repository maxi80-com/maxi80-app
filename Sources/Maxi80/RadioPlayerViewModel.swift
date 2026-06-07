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

    // MARK: - UI-Bound State

    public var isPlaying: Bool = false
    public var isLoading: Bool = false
    public var currentSong: SongMetadata?
    public var currentArtwork: Image?
    public var dominantColor: Color = Color(red: 0.15, green: 0.15, blue: 0.25)
    public var history: [HistoryEntry] = []
    public var station: Station?
    public var volume: Double = 1.0
    public var errorMessage: String?
    public var canShare: Bool = false
    public var selectedHistoryIndex: Int = 0

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
        syncFromCoordinator()
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

    // MARK: - Sync from Coordinator

    public func syncFromCoordinator() {
        switch coordinator.playbackState {
        case .playing:
            isPlaying = true
            isLoading = false
            errorMessage = nil
        case .loading:
            isPlaying = false
            isLoading = true
            errorMessage = nil
        case .paused, .idle:
            isPlaying = false
            isLoading = false
        case .error(let message):
            isPlaying = false
            isLoading = false
            errorMessage = message
        case .reconnecting:
            isPlaying = false
            isLoading = true
            errorMessage = nil
        }

        currentSong = coordinator.currentSong
        if let result = coordinator.currentArtwork {
            currentArtwork = result.image
            dominantColor = result.dominantColor
        } else {
            currentArtwork = nil
            dominantColor = Color(red: 0.15, green: 0.15, blue: 0.25)
        }

        history = coordinator.history
        station = coordinator.station
        if let msg = coordinator.errorMessage {
            errorMessage = msg
        }

        updateCanShare()
    }

    // MARK: - Private Helpers

    private func updateCanShare() {
        if let song = currentSong,
           !song.artist.isEmpty,
           !song.title.isEmpty {
            canShare = true
        } else {
            canShare = false
        }
    }
}
