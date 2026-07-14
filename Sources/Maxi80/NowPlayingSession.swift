import Foundation

#if !SKIP
/// Abstraction the coordinator uses to publish Now Playing info without depending on the
/// iOS-27-only NowPlaying framework types. On iOS 27+ this is backed by `NowPlayingSession`
/// (the modern framework); otherwise the coordinator falls back to the bridged
/// `NowPlayingController` (MediaPlayer / MPNowPlayingInfoCenter).
@MainActor
protocol NowPlayingPublishing: AnyObject {
    /// Begin publishing the session to the system (Lock Screen, Control Center, accessories).
    func activate()
    /// Stop publishing and release the session.
    func deactivate()
    /// Update the currently-playing metadata.
    func update(stationName: String, programName: String, artworkURL: String?, isPlaying: Bool)
    /// Update only the play/pause state.
    func updatePlaybackState(isPlaying: Bool)
}

/// Creates the modern NowPlaying-framework publisher when the platform supports it, otherwise
/// `nil` (the coordinator then falls back to the bridged MediaPlayer `NowPlayingController`).
/// Returns `nil` on any SDK/OS without the NowPlaying framework.
@MainActor
func makeModernNowPlaying(onPlay: @escaping () -> Void, onPause: @escaping () -> Void) -> (any NowPlayingPublishing)? {
    #if canImport(NowPlaying)
    if #available(anyAppleOS 27, *) {
        return NowPlayingSession(onPlay: onPlay, onPause: onPause)
    }
    #endif
    return nil
}
#endif

#if !SKIP && canImport(NowPlaying)
import NowPlaying

/// Modern Now Playing integration using the NowPlaying framework (iOS 27 / macOS 27 / tvOS 27 /
/// watchOS 27 / visionOS 27). Publishes a local `MediaSession` whose `@Observable` model the
/// framework watches, replacing the dictionary-based `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`.
@available(anyAppleOS 27, *)
@Observable
@MainActor
final class NowPlayingSession: MediaSessionRepresentable, NowPlayingPublishing {
    let id: String = UUID().uuidString

    // Model state the framework observes.
    private var stationName: String = ""
    private var programName: String = ""
    private var artworkURL: String?
    private var isPlaying: Bool = false
    private var startedAt: Date = Date()

    /// Play/pause commands are routed back to the coordinator.
    private let onPlay: () -> Void
    private let onPause: () -> Void

    @ObservationIgnored
    private var session: MediaSession<NowPlayingSession>?

    init(onPlay: @escaping () -> Void, onPause: @escaping () -> Void) {
        self.onPlay = onPlay
        self.onPause = onPause
    }

    // MARK: MediaSessionRepresentable

    var content: (any MediaContentRepresentable)? {
        guard !stationName.isEmpty else { return nil }
        let url = artworkURL.flatMap(URL.init(string:))
        return RadioContent(
            id: id,
            stationName: stationName,
            programName: programName,
            type: .audio,
            duration: .live,
            artwork: url.map { artworkURL in
                Artwork(id: artworkURL.absoluteString) { _ in
                    let (data, _) = try await URLSession.shared.data(from: artworkURL)
                    return try ArtworkRepresentation(data: data)
                }
            }
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        MediaPlaybackSnapshot(
            state: isPlaying ? .playing() : .paused,
            defaultPlaybackRate: 1.0,
            elapsedTime: 0,
            timestamp: startedAt
        )
    }

    var commands: [MediaCommand] {
        [
            .play { [weak self] in self?.onPlay() },
            .pause { [weak self] in self?.onPause() },
        ]
    }

    // MARK: NowPlayingPublishing

    func activate() {
        guard session == nil else { return }
        let session = MediaSession(self)
        self.session = session
        // `requestToBecomeApplicationPrimary()` is available on all Apple OSes; the stronger
        // `requestToBecomeSystemPrimary()` (Lock Screen / Control Center takeover) is iOS-only.
        // For a single foreground radio app, application-primary is sufficient to publish, and on
        // iOS it also surfaces on the Lock Screen / Control Center.
        Task { try? await session.requestToBecomeApplicationPrimary() }
    }

    func deactivate() {
        session = nil
    }

    func update(stationName: String, programName: String, artworkURL: String?, isPlaying: Bool) {
        self.stationName = stationName
        self.programName = programName
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.startedAt = Date()
    }

    func updatePlaybackState(isPlaying: Bool) {
        self.isPlaying = isPlaying
        self.startedAt = Date()
    }
}
#endif
