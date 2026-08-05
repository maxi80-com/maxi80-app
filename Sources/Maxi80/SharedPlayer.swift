import Maxi80Model
import Maxi80Services
import SkipFuse

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "SharedPlayer")

/// Process-wide owner of the single `RadioPlayerCoordinator` (and its `RadioPlayerViewModel`).
///
/// The phone's SwiftUI root and the CarPlay scene must drive the SAME coordinator — one audio
/// pipeline and one Now Playing session — so playback and metadata stay consistent across both.
/// This is the composition root; it builds the dependency graph exactly once.
@MainActor
public enum SharedPlayer {

  public static let coordinator: RadioPlayerCoordinator = {
    // 1. Platform-appropriate audio player.
    let player = AudioStreamPlayer()

    // 2. Now Playing publisher: prefer the modern NowPlaying framework, else the bridged
    //    MediaPlayer / MediaSession controller. Each sink serves its OWN transport commands —
    //    see the remote-command wiring after the coordinator is built.
    //
    //    `bridged` is held in its own `let` so the `NowPlayingController` it wraps outlives this
    //    initializer even when `publisher` is reassigned to the modern sink below: assigning
    //    `controller.onRemoteCommand` stores a closure ON the controller and does not retain it,
    //    so the wrapper is the controller's only strong owner.
    let controller = NowPlayingController()
    let bridged = BridgedNowPlayingPublisher(controller: controller)
    var publisher: any NowPlayingPublishing = bridged

    // The modern publisher's transport closures need the coordinator, which doesn't exist yet.
    // A local `var` captured by reference lets the closures resolve it after assignment below,
    // without reaching back into this `static let` while it is still initializing. Deliberately
    // strong: both objects are process-lifetime singletons owned by this never-deallocated
    // `static let`, so the resulting cycle reclaims nothing and `weak` would only add a nil path.
    var builtCoordinator: RadioPlayerCoordinator?

    // The real gate is `canImport(NowPlaying)` inside `makeModernNowPlaying`, NOT the `#if !SKIP`
    // below: `Maxi80` is a native (Fuse) module, so `SKIP` is undefined even when its Swift is
    // cross-compiled for Android and this branch is live there too. The framework is simply absent
    // from the Android SDK, so the factory returns nil and the bridged sink stands.
    #if !SKIP
      if let modern = makeModernNowPlaying(
        onPlay: { builtCoordinator?.handleRemote("play") },
        onPause: { builtCoordinator?.handleRemote("pause") }
      ) {
        publisher = modern
      }
    #endif

    // Which sink is live. Device verification reads this to tell the two paths apart — notably to
    // distinguish "metadata publishes but transport does nothing" between them.
    logger.info(
      "NowPlaying path: \(publisher === bridged ? "FALLBACK (MPNowPlayingInfoCenter / MediaSession)" : "MODERN (NowPlaying framework)")"
    )

    // 3. Load configuration and create the API client.
    let config = ConfigurationLoader.loadAPIConfiguration()
    let apiClient = APIClient(configuration: config)

    // 4. Artwork service backed by the API client.
    let artworkService = ArtworkService(apiClient: apiClient)

    // 5. Platform share chooser (Android presents the system sheet; Apple uses SwiftUI ShareSheet).
    let shareService = ShareService()

    // 6. Coordinator with all dependencies injected.
    let coordinator = RadioPlayerCoordinator(
      player: player,
      nowPlaying: publisher,
      apiClient: apiClient,
      artworkService: artworkService,
      shareService: shareService
    )
    builtCoordinator = coordinator

    // Remote commands for the BRIDGED path: MPRemoteCommandCenter on Apple, the media3
    // notification / Android Auto on Android. This is the only transport path on Android.
    //
    // It is deliberately NOT the modern path's transport: when the modern framework is the sink it
    // serves its own `.play`/`.pause` commands (wired above via `makeModernNowPlaying`), and this
    // callback stays dormant because `NowPlayingController` only installs its
    // `MPRemoteCommandCenter` targets from `platformUpdateNowPlaying`, which the modern path never
    // calls. Wiring it unconditionally anyway costs nothing and keeps the bridged path complete
    // regardless of which sink won.
    controller.onRemoteCommand = { [weak coordinator] command in
      Task { @MainActor in coordinator?.handleRemote(command) }
    }

    return coordinator
  }()

  public static let viewModel = RadioPlayerViewModel(coordinator: coordinator)

  /// Handle a background→foreground transition: reconcile the playback state with the real player
  /// so a stale `.loading` spinner clears (issue #9). The carousel needs no guard — CoverFlowStrip
  /// re-derives the centered cover from `CarouselModel.selectedID`, which lives in the process-wide
  /// view model and survives any view or Android activity recreation.
  public static func handleForeground() {
    coordinator.reconcileWithPlayer()
  }
}
