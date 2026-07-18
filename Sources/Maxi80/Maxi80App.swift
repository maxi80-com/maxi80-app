import Maxi80Model
import Maxi80Services
import SwiftUI

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
    // Resolve the process-wide coordinator/view-model from the shared composition root, so the
    // phone UI and the CarPlay scene (iOS) drive the same audio + Now Playing pipeline.
    let coord = SharedPlayer.coordinator
    let vm = SharedPlayer.viewModel

    // Store as @State for SwiftUI lifecycle management.
    _coordinator = State(wrappedValue: coord)
    _viewModel = State(wrappedValue: vm)
  }

  /// Whether to render the 10-foot TV UI. Pure passthrough to `PlatformEnvironment.isTVMode`,
  /// exposed as a static flag so the selection is unit-testable without constructing the view.
  static var shouldUseTVUI: Bool { PlatformEnvironment.isTVMode }

  public var body: some View {
    Group {
      if Self.shouldUseTVUI {
        TVRadioPlayerView(viewModel: viewModel)
      } else {
        RadioPlayerView(viewModel: viewModel)
      }
    }
    .tint(.orange)
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
