#if !SKIP && canImport(CarPlay)
import CarPlay

/// Scene delegate for the CarPlay audio scene.
///
/// Maxi80 is a single live station, so there is no browse UI: connecting to CarPlay sets the root
/// to the system Now Playing template and auto-plays the stream. Playback, metadata, artwork, and
/// the play/pause controls all flow through the shared `RadioPlayerCoordinator`
/// (see `SharedPlayer`) and the Now Playing info it already publishes — the same pipeline the
/// phone UI uses, so there is only ever one audio session.
///
/// The ObjC runtime name is pinned with `@objc(CarPlaySceneDelegate)` so the bare class name in
/// `Darwin/Info.plist`'s `UISceneDelegateClassName` resolves without the Swift module prefix.
@MainActor
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        // Single-station radio: go straight to Now Playing, no list template.
        interfaceController.setRootTemplate(CPNowPlayingTemplate.shared, animated: false, completion: nil)

        // Auto-play on connect — a radio app is expected to start when the driver taps its icon.
        SharedPlayer.coordinator.play()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        // Release the interface controller only. Audio keeps playing on the phone / Now Playing;
        // disconnecting from the car must not stop the stream.
        self.interfaceController = nil
    }
}
#endif
