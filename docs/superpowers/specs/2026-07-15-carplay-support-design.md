# CarPlay Support for Maxi80 — Design

**Date:** 2026-07-15
**Entitlement:** `com.apple.developer.carplay-audio` (assigned to Team `56U756R2L2`, follow-up 715585228)

## Goal

Let Maxi80 run on CarPlay as an audio app. Tapping the Maxi80 icon in the car **auto-plays**
the live stream and shows the system **Now Playing** screen (artwork, title/artist, play/pause).
No list/browse UI — Maxi80 is a single live station.

## Scope & platform gating

CarPlay is **iOS-only**. All new code lives in the native `Maxi80` module, gated
`#if !SKIP && canImport(CarPlay)`. Android, macOS, and the transpiled `Maxi80Services` are
untouched. It reuses the existing `RadioPlayerCoordinator` — the same audio pipeline and NowPlaying
publishing already in place — so CarPlay does not introduce a second audio session.

## Components

### 1. `CarPlaySceneDelegate` (new — `Sources/Maxi80/CarPlay/CarPlaySceneDelegate.swift`)
`NSObject`, `CPTemplateApplicationSceneDelegate`, `@MainActor`. Gated
`#if !SKIP && canImport(CarPlay)`.
- `templateApplicationScene(_:didConnect:to:)`: store the `CPInterfaceController`, set its root to
  `CPNowPlayingTemplate.shared`, and call `SharedPlayer.coordinator.play()` (auto-play on connect).
- `templateApplicationScene(_:didDisconnectInterfaceController:)`: release the stored interface
  controller. Does **not** stop audio — playback continues on the phone / Now Playing.
- No custom transport buttons: `CPNowPlayingTemplate` reads the system Now Playing info and uses the
  existing remote-command handlers. (Optionally add nothing to the template's buttons array.)

### 2. Shared coordinator accessor (`Sources/Maxi80/SharedPlayer.swift`, new)
Both the SwiftUI root and the CarPlay scene must use the **same** `RadioPlayerCoordinator` (one audio
pipeline, one NowPlaying session). Today `Maxi80RootView.init` builds the coordinator inline. Change:
- Introduce a `@MainActor enum SharedPlayer` (or small final class) exposing a lazily-created,
  process-wide `coordinator` and `viewModel`, built with the same dependency graph currently in
  `Maxi80RootView.init` (player, NowPlayingController, APIClient, ArtworkService).
- `Maxi80RootView` reads `SharedPlayer.coordinator` / `SharedPlayer.viewModel` instead of constructing
  them, so the phone UI and the CarPlay scene resolve one instance.
- Gated so non-iOS builds are unaffected in behavior; the accessor itself is plain Swift and compiles
  everywhere, but is only *also* consumed by CarPlay under the iOS gate.

### 3. Now Playing content — no new work
`CPNowPlayingTemplate` renders from `MPNowPlayingInfoCenter` / the NowPlaying-framework session the
coordinator already publishes (`publishNowPlaying` / `publishPlaybackState`). Play/pause from the car
routes through the existing `MPRemoteCommandCenter` / `handleRemoteCommand` path. Artwork updates on
song change via the metadata pipeline already in `handleMetadataChanged`.

## Configuration (highest-risk change)

CarPlay requires a **manual `UIApplicationSceneManifest`** declaring the
`CPTemplateApplicationSceneSessionRoleApplication` scene. The project currently auto-generates the
manifest via `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`, which cannot include a
CarPlay scene.

Changes:
1. **`Darwin/Maxi80.xcconfig`**: remove/disable
   `INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphone*] = YES`.
2. **`Darwin/Info.plist`**: add an explicit `UIApplicationSceneManifest` with:
   - `UIApplicationSupportsMultipleScenes = true`
   - `UISceneConfigurations` →
     - `UIWindowSceneSessionRoleApplication`: the default window scene so the SwiftUI `@main`
       app still gets its window (no custom delegate class — the SwiftUI lifecycle provides it).
     - `CPTemplateApplicationSceneSessionRoleApplication`: one configuration with
       `UISceneDelegateClassName` = the ObjC-runtime name of `CarPlaySceneDelegate`
       (`$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate` / verify the emitted name).
   - Keep existing `UIBackgroundModes: [audio]`.
3. **`Darwin/Entitlements.plist`**: add `com.apple.developer.carplay-audio = true`.

> Risk: a malformed manifest can prevent the normal app from launching. Mitigation: after the
> manifest/xcconfig change, build+run on the **iPhone simulator first** and confirm the normal app
> still launches, *before* adding CarPlay logic.

> Provisioning: the entitlement key is committed here; a device build needs the matching provisioning
> profile (CarPlay audio) in the Apple Developer account. The **CarPlay Simulator does not** require
> it.

## Data flow

```
Car: tap Maxi80 icon
   → CarPlay scene connects → CarPlaySceneDelegate.didConnect
   → root = CPNowPlayingTemplate.shared
   → SharedPlayer.coordinator.play()      (auto-play)
   → coordinator drives AudioStreamPlayer + publishNowPlaying
   → car's Now Playing screen shows art/title/artist + play/pause
Car: play/pause tap → MPRemoteCommandCenter → coordinator.handleRemoteCommand
Phone UI and CarPlay share ONE coordinator (SharedPlayer), so state stays consistent.
```

## Testing

- **CarPlay Simulator** (Xcode ▸ I/O ▸ External Displays ▸ CarPlay): icon appears; tap → stream plays;
  Now Playing shows metadata; play/pause works; artwork updates on song change.
- **Regression:** normal iPhone-simulator launch still works after the manual scene manifest; Android
  (`skip android build`) and macOS builds stay green.
- No unit tests for the scene delegate (thin UIKit glue over the already-tested coordinator).

## Out of scope (YAGNI)

- No `CPListTemplate` / browse UI, no history in CarPlay.
- No second audio pipeline.
- No CarPlay-specific artwork sizes beyond what NowPlaying already provides.

## Files touched

- **New:** `Sources/Maxi80/CarPlay/CarPlaySceneDelegate.swift`, `Sources/Maxi80/SharedPlayer.swift`.
- **Edit:** `Sources/Maxi80/Maxi80App.swift` (read from `SharedPlayer`), `Darwin/Info.plist`
  (scene manifest), `Darwin/Maxi80.xcconfig` (disable manifest auto-gen),
  `Darwin/Entitlements.plist` (CarPlay entitlement).
- **Unchanged:** `Maxi80Model`, `Maxi80Services`, Android, macOS behavior.
