import Foundation

#if !SKIP_BRIDGE

#if SKIP
// Android implementation handled in ExoPlayerStreamPlayer.swift
#else

#if os(iOS) || os(tvOS)
import AVFoundation

// MARK: - iOS AVPlayer Implementation

extension AudioStreamPlayer {

    /// Set up the iOS audio player with AVPlayer and configure the audio session.
    func platformPlay(url: String) {
        guard let streamURL = URL(string: url) else {
            onError?("Invalid stream URL: \(url)")
            return
        }

        configureAudioSession()
        registerNotifications()

        let playerItem = AVPlayerItem(url: streamURL)
        attachMetadataOutput(to: playerItem)

        if avPlayer == nil {
            avPlayer = AVPlayer(playerItem: playerItem)
        } else {
            avPlayer?.replaceCurrentItem(with: playerItem)
        }

        observePlayerStatus()
        observeSystemVolume()

        avPlayer?.play()
        isPlaying = true
        onPlaybackStateChanged?(true)
    }

    /// Stop playback and release resources.
    func platformStop() {
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        isPlaying = false
        onPlaybackStateChanged?(false)

        removeObservers()
        unregisterNotifications()
    }

    /// Set playback volume via AVAudioSession output volume (system volume).
    func platformSetVolume(_ newVolume: Double) {
        // On iOS, app-level volume control is done through the system volume.
        // The MPVolumeView slider controls system volume directly.
        // We store the requested value for the published property.
        self.volume = newVolume
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            onError?("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    // MARK: - Metadata Output

    private func attachMetadataOutput(to playerItem: AVPlayerItem) {
        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        let delegate = MetadataOutputDelegate(player: self)
        metadataOutput.setDelegate(delegate, queue: .main)
        playerItem.add(metadataOutput)
        metadataDelegate = delegate
    }

    // MARK: - Player Status Observation

    private func observePlayerStatus() {
        statusObservation = avPlayer?.observe(\.currentItem?.status, options: [.new]) { @Sendable [weak self] player, _ in
            // Extract Sendable values here; the KVO callback isn't main-actor-isolated, so
            // hop to the main actor before touching the player's callbacks.
            guard player.currentItem?.status == .failed else { return }
            let message = player.currentItem?.error?.localizedDescription ?? "Playback failed"
            Task { @MainActor [weak self] in
                self?.onError?(message)
            }
        }

        // Also observe timeControlStatus for actual playback state
        timeControlObservation = avPlayer?.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = playing
                self.onPlaybackStateChanged?(playing)
            }
        }
    }

    // MARK: - System Volume Observation

    private func observeSystemVolume() {
        let session = AVAudioSession.sharedInstance()
        // Update the published volume to current system volume
        self.volume = Double(session.outputVolume)
        self.onVolumeChanged?(Double(session.outputVolume))

        volumeObservation = session.observe(\.outputVolume, options: [.new]) { @Sendable [weak self] session, change in
            let vol = Double(change.newValue ?? session.outputVolume)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.volume = vol
                self.onVolumeChanged?(vol)
            }
        }
    }

    // MARK: - Notification Handling

    private func registerNotifications() {
        let nc = NotificationCenter.default

        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Parse the non-Sendable notification here, then hop to the main actor
            // with only Sendable values (no notification crosses the isolation boundary).
            guard let userInfo = notification.userInfo,
                  let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
                return
            }
            let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, optionsRaw: optionsRaw)
            }
        }

        routeChangeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reason: reason)
            }
        }
    }

    private func unregisterNotifications() {
        let nc = NotificationCenter.default
        if let observer = interruptionObserver {
            nc.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            nc.removeObserver(observer)
            routeChangeObserver = nil
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType, optionsRaw: UInt) {
        switch type {
        case .began:
            avPlayer?.pause()
            isPlaying = false
            onPlaybackStateChanged?(false)
            onInterruption?(true)

        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                avPlayer?.play()
                isPlaying = true
                onPlaybackStateChanged?(true)
                onInterruption?(false)
            } else {
                // Stay paused, notify that interruption ended without resume
                onInterruption?(false)
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones/Bluetooth disconnected — pause playback per Apple guidelines
            avPlayer?.pause()
            isPlaying = false
            onPlaybackStateChanged?(false)
            onInterruption?(true)

        case .newDeviceAvailable:
            // New device connected (headphones, Bluetooth) — audio routes automatically
            break

        default:
            break
        }
    }

    // MARK: - Observer Cleanup

    private func removeObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
    }
}

// MARK: - Stored Properties via Associated Objects

// Since Swift extensions cannot add stored properties, we use associated objects
// to attach the AVPlayer and observers to the AudioStreamPlayer instance.

private nonisolated(unsafe) var avPlayerKey: UInt8 = 0
private nonisolated(unsafe) var metadataDelegateKey: UInt8 = 0
private nonisolated(unsafe) var statusObservationKey: UInt8 = 0
private nonisolated(unsafe) var timeControlObservationKey: UInt8 = 0
private nonisolated(unsafe) var volumeObservationKey: UInt8 = 0
private nonisolated(unsafe) var interruptionObserverKey: UInt8 = 0
private nonisolated(unsafe) var routeChangeObserverKey: UInt8 = 0

extension AudioStreamPlayer {

    var avPlayer: AVPlayer? {
        get { objc_getAssociatedObject(self, &avPlayerKey) as? AVPlayer }
        set { objc_setAssociatedObject(self, &avPlayerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var metadataDelegate: MetadataOutputDelegate? {
        get { objc_getAssociatedObject(self, &metadataDelegateKey) as? MetadataOutputDelegate }
        set { objc_setAssociatedObject(self, &metadataDelegateKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var statusObservation: NSKeyValueObservation? {
        get { objc_getAssociatedObject(self, &statusObservationKey) as? NSKeyValueObservation }
        set { objc_setAssociatedObject(self, &statusObservationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var timeControlObservation: NSKeyValueObservation? {
        get { objc_getAssociatedObject(self, &timeControlObservationKey) as? NSKeyValueObservation }
        set { objc_setAssociatedObject(self, &timeControlObservationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var volumeObservation: NSKeyValueObservation? {
        get { objc_getAssociatedObject(self, &volumeObservationKey) as? NSKeyValueObservation }
        set { objc_setAssociatedObject(self, &volumeObservationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var interruptionObserver: NSObjectProtocol? {
        get { objc_getAssociatedObject(self, &interruptionObserverKey) as? NSObjectProtocol }
        set { objc_setAssociatedObject(self, &interruptionObserverKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var routeChangeObserver: NSObjectProtocol? {
        get { objc_getAssociatedObject(self, &routeChangeObserverKey) as? NSObjectProtocol }
        set { objc_setAssociatedObject(self, &routeChangeObserverKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - Metadata Output Delegate

/// Delegate that receives timed metadata from the AVPlayerItem and forwards it to the
/// AudioStreamPlayer's onMetadataChanged callback.
final class MetadataOutputDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate, @unchecked Sendable {
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
        // SAFETY: AVFoundation delivers this callback serially on the main queue (the output is
        // registered with `queue: .main`), and `AVMetadataItem` is read-once immutable timed
        // metadata. It isn't Sendable and its value must be loaded asynchronously (iOS 16+), so
        // `nonisolated(unsafe)` lets us carry it into the load task; only the resulting `String`
        // crosses to the main-actor-isolated player.
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

#endif // os(iOS)

#endif // SKIP

#endif // !SKIP_BRIDGE
