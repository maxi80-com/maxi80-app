import Foundation

#if !SKIP_BRIDGE
#if os(macOS)
import AVFoundation

// MARK: - macOS AVPlayer Implementation
//
// A minimal AVPlayer-based player for macOS. AVFoundation is available on macOS, but the iOS
// player's `AVAudioSession`, `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`, and interruption/
// route-change notifications are not — so this is a separate, self-contained implementation rather
// than reusing the iOS extension. Metadata (ICY title) is read via `AVPlayerItemMetadataOutput`,
// the same as iOS.

extension AudioStreamPlayer {

    func macPlay(url: String) {
        guard let streamURL = URL(string: url) else {
            onError?("Invalid stream URL: \(url)")
            return
        }

        let playerItem = AVPlayerItem(url: streamURL)
        macAttachMetadataOutput(to: playerItem)

        if macPlayer == nil {
            macPlayer = AVPlayer(playerItem: playerItem)
        } else {
            macPlayer?.replaceCurrentItem(with: playerItem)
        }

        macObservePlayerStatus()
        macPlayer?.volume = Float(volume)
        macPlayer?.play()
        isPlaying = true
        onPlaybackStateChanged?(true)
    }

    func macStop() {
        macPlayer?.pause()
        macPlayer?.replaceCurrentItem(with: nil)
        isPlaying = false
        onPlaybackStateChanged?(false)

        macStatusObservation?.invalidate()
        macStatusObservation = nil
        macTimeControlObservation?.invalidate()
        macTimeControlObservation = nil
    }

    func macSetVolume(_ newVolume: Double) {
        let clamped = max(0, min(1, newVolume))
        self.volume = clamped
        macPlayer?.volume = Float(clamped)
    }

    // MARK: - Metadata

    private func macAttachMetadataOutput(to playerItem: AVPlayerItem) {
        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        let delegate = MacMetadataOutputDelegate(player: self)
        metadataOutput.setDelegate(delegate, queue: .main)
        playerItem.add(metadataOutput)
        macMetadataDelegate = delegate
    }

    // MARK: - Status Observation

    private func macObservePlayerStatus() {
        macStatusObservation = macPlayer?.observe(\.currentItem?.status, options: [.new]) { @Sendable [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            let message = player.currentItem?.error?.localizedDescription ?? "Playback failed"
            Task { @MainActor [weak self] in
                self?.onError?(message)
            }
        }

        macTimeControlObservation = macPlayer?.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = playing
                self.onPlaybackStateChanged?(playing)
            }
        }
    }
}

// MARK: - Stored Properties via Associated Objects

private nonisolated(unsafe) var macPlayerKey: UInt8 = 0
private nonisolated(unsafe) var macMetadataDelegateKey: UInt8 = 0
private nonisolated(unsafe) var macStatusObservationKey: UInt8 = 0
private nonisolated(unsafe) var macTimeControlObservationKey: UInt8 = 0

extension AudioStreamPlayer {

    var macPlayer: AVPlayer? {
        get { objc_getAssociatedObject(self, &macPlayerKey) as? AVPlayer }
        set { objc_setAssociatedObject(self, &macPlayerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var macMetadataDelegate: MacMetadataOutputDelegate? {
        get { objc_getAssociatedObject(self, &macMetadataDelegateKey) as? MacMetadataOutputDelegate }
        set { objc_setAssociatedObject(self, &macMetadataDelegateKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var macStatusObservation: NSKeyValueObservation? {
        get { objc_getAssociatedObject(self, &macStatusObservationKey) as? NSKeyValueObservation }
        set { objc_setAssociatedObject(self, &macStatusObservationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var macTimeControlObservation: NSKeyValueObservation? {
        get { objc_getAssociatedObject(self, &macTimeControlObservationKey) as? NSKeyValueObservation }
        set { objc_setAssociatedObject(self, &macTimeControlObservationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// Receives timed ICY metadata from the AVPlayerItem on macOS and forwards the title string to the
/// player's `onMetadataChanged` callback. (macOS counterpart of the iOS `MetadataOutputDelegate`.)
final class MacMetadataOutputDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate, @unchecked Sendable {
    private weak var player: AudioStreamPlayer?

    init(player: AudioStreamPlayer) {
        self.player = player
        super.init()
    }

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        guard let first = groups.first?.items.first else { return }
        // SAFETY: delivered serially on the main queue; AVMetadataItem is read-once immutable
        // timed metadata. It isn't Sendable and its value loads asynchronously, so carry it into
        // the load task and forward only the resulting String to the main-actor-isolated player.
        nonisolated(unsafe) let item = first
        let player = self.player
        Task {
            let value: String?
            if let data = try? await item.load(.dataValue) {
                value = String(data: data, encoding: .utf8)
            } else {
                value = try? await item.load(.stringValue)
            }
            guard let value else { return }
            await player?.emitMetadata(value)
        }
    }
}

#endif // os(macOS)
#endif // !SKIP_BRIDGE
