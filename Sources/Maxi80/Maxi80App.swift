import SwiftUI
import Maxi80Model
import Maxi80Services

// MARK: - Maxi80App Protocol (Apple platforms only)

#if !SKIP_BRIDGE
/// The app entry point protocol for the Maxi80 radio player.
/// Darwin/Sources/Main.swift conforms to this protocol as the @main entry point.
public protocol Maxi80App: App {}

extension Maxi80App {
    public var body: some Scene {
        WindowGroup {
            Maxi80RootView()
        }
    }
}
#endif

// MARK: - Root View (Dependency Injection Container)

/// Internal root view that creates and owns all dependencies.
/// Acts as the composition root / dependency injection container for the app.
/* SKIP @bridge */public struct Maxi80RootView: View {
    @State var viewModel: RadioPlayerViewModel
    @State var coordinator: RadioPlayerCoordinator

    /* SKIP @bridge */public init() {
        // 1. Create platform-appropriate AudioStreamPlayer
        let player = AudioStreamPlayer()

        // 2. Create platform-appropriate NowPlayingController
        let nowPlaying = NowPlayingController()

        // 3. Load configuration from plist and create APIClient
        let config = ConfigurationLoader.loadAPIConfiguration()
        let apiClient = APIClient(configuration: config)

        // 4. Create ArtworkService with the API client
        let artworkService = ArtworkService(apiClient: apiClient)

        // 5. Create RadioPlayerCoordinator with all dependencies
        let coord = RadioPlayerCoordinator(
            player: player,
            nowPlaying: nowPlaying,
            apiClient: apiClient,
            artworkService: artworkService
        )

        // 6. Create RadioPlayerViewModel with the coordinator
        let vm = RadioPlayerViewModel(coordinator: coord)

        // 7. Store as @State for SwiftUI lifecycle management
        _coordinator = State(wrappedValue: coord)
        _viewModel = State(wrappedValue: vm)
    }

    public var body: some View {
        RadioPlayerView(viewModel: viewModel)
            .task {
                await coordinator.loadStation()
            }
    }
}

// MARK: - App Delegate (required by Skip scaffold)

/// Minimal app delegate providing lifecycle hooks for the Skip Darwin entry point.
/* SKIP @bridge */public final class Maxi80AppDelegate: Sendable {
    /* SKIP @bridge */public static let shared = Maxi80AppDelegate()
    private init() {}

    /* SKIP @bridge */public func onInit() {}
    /* SKIP @bridge */public func onLaunch() {}
    /* SKIP @bridge */public func onResume() {}
    /* SKIP @bridge */public func onPause() {}
    /* SKIP @bridge */public func onStop() {}
    /* SKIP @bridge */public func onDestroy() {}
    /* SKIP @bridge */public func onLowMemory() {}
}
