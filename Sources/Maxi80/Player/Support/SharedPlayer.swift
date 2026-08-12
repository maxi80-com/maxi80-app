import Maxi80Model
import Maxi80Services
import SkipFuse

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "SharedPlayer")

/// Process-wide owner of the single `RadioPlayerCoordinator` (and its `RadioPlayerViewModel`).
///
/// The phone's SwiftUI root and the CarPlay scene must drive the SAME coordinator — one audio
/// pipeline and one Now Playing session — so playback and metadata stay consistent across both.
/// This is the composition root; it builds the dependency graph exactly once.
///
/// A `static enum` rather than an injectable `AppDependencies` container (issue #68 item 11 raised the
/// idea) because the two reasons to prefer a container don't apply here. Testability isn't blocked: the
/// coordinator takes every dependency through its `public init`, so tests build their own graph with
/// fakes (`makeTestCoordinator`) and never touch this type — a container would give them nothing they
/// don't already have. And "exactly one" is a hard requirement, not a default: the phone root and the
/// CarPlay scene are separate entry points into the same process, so anything they could each construct
/// for themselves would be two audio pipelines. The staticness is what makes that impossible.
@MainActor
public enum SharedPlayer {

  /// The bridged MediaPlayer / MediaSession publisher, owned here rather than as a local so its
  /// `NowPlayingController` genuinely lives for the process — a local `let` inside `coordinator`'s
  /// initializer would be released when that initializer returned, taking the controller with it
  /// whenever the modern sink won (nothing else retains it: assigning `onRemoteCommand` stores a
  /// closure ON the controller without owning it). That would silently kill the remote-command
  /// wiring below on the modern path. Structural ownership here makes the lifetime independent of
  /// which sink was selected.
  private static let bridgedNowPlaying = BridgedNowPlayingPublisher(
    controller: NowPlayingController())

  public static let coordinator: RadioPlayerCoordinator = {
    // 1. Platform-appropriate audio player.
    let player = AudioStreamPlayer()

    // 2. Now Playing publisher: prefer the modern NowPlaying framework, else the bridged
    //    MediaPlayer / MediaSession controller. Each sink serves its OWN transport commands —
    //    see the remote-command wiring after the coordinator is built.
    let bridged = bridgedNowPlaying
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
    // regardless of which sink won — `bridgedNowPlaying` owns the controller for the process, so
    // this callback survives even when it isn't the selected sink.
    bridged.controller.onRemoteCommand = { [weak coordinator] command in
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

  /// Build the pipeline at PROCESS start, before any UI exists.
  ///
  /// Why this exists: on Android the process can start for the media service alone — Android Auto
  /// connecting and pressing play never creates an Activity. The native Swift half *is* loaded in
  /// that process (the bridge initializes from `Application.onCreate`), but nothing referenced this
  /// composition root, whose only other caller is `Maxi80RootView.init()`. So `MetadataParser`,
  /// `ArtworkService` and the Now Playing publish all sat dormant behind a UI that never appeared,
  /// and the car card was left to the service's deliberately display-only Kotlin listener: raw
  /// unsplit "ARTIST - TITLE" text and the station logo for every song, however much real artwork
  /// existed. Touching `coordinator` here runs that same existing Swift pipeline in the service
  /// process, so no parsing or artwork logic is duplicated in Kotlin.
  ///
  /// `reconcileWithPlayer()` rather than a bare `coordinator` reference: adopting the shared
  /// ExoPlayer is what ATTACHES the native ICY listener (`syncWithExternalPlayback`), which is the
  /// actual subscription to song changes. It also promotes `playbackState` when the car already
  /// started audio, and is a no-op when the player is genuinely idle — so this is safe on a plain
  /// app launch, where it runs just before `Maxi80RootView` resolves the same singletons.
  ///
  /// Deliberately does NOT start playback or load the station: a process started for a *bind*
  /// (Android Auto browsing, the media-app scanner) must not begin streaming. Artwork resolution
  /// needs only `APIConfiguration`, which `ConfigurationLoader` reads from the bundle.
  public static func handleProcessStart() {
    coordinator.reconcileWithPlayer()
  }
}
