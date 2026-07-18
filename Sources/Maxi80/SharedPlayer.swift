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

    // 2. Platform-appropriate Now Playing controller.
    let nowPlaying = NowPlayingController()

    // 3. Load configuration and create the API client.
    let config = ConfigurationLoader.loadAPIConfiguration()
    let apiClient = APIClient(configuration: config)

    // 4. Artwork service backed by the API client.
    let artworkService = ArtworkService(apiClient: apiClient)

    // 5. Coordinator with all dependencies injected.
    return RadioPlayerCoordinator(
      player: player,
      nowPlaying: nowPlaying,
      apiClient: apiClient,
      artworkService: artworkService
    )
  }()

  public static let viewModel = RadioPlayerViewModel(coordinator: coordinator)
}
