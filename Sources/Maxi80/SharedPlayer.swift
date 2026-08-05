import Maxi80Model
import Maxi80Services

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

    // 2. Now Playing publisher: prefer the modern NowPlaying framework (iOS 27+), else the
    //    bridged MediaPlayer / MediaSession controller. The bridged controller is also the
    //    remote-command source, so it is retained and wired below regardless.
    let controller = NowPlayingController()
    var publisher: any NowPlayingPublishing = BridgedNowPlayingPublisher(controller: controller)

    // The modern publisher's transport closures need the coordinator, which doesn't exist yet.
    // A local `var` captured by reference lets the closures resolve it after assignment below,
    // without reaching back into this `static let` while it is still initializing.
    var builtCoordinator: RadioPlayerCoordinator?

    #if !SKIP
      if let modern = makeModernNowPlaying(
        onPlay: { builtCoordinator?.handleRemote("play") },
        onPause: { builtCoordinator?.handleRemote("pause") }
      ) {
        publisher = modern
      }
    #endif

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

    // The bridged controller stays the remote-command source on every platform (lock screen,
    // media3 notification, car), even when the modern publisher is the metadata sink.
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
