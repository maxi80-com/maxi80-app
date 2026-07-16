# tvOS Support — Design

**Date:** 2026-07-16
**Status:** Approved (brainstorming)
**Related:** [Android TV Support](2026-07-16-android-tv-support-design.md) — shares the TV UI foundation described below.

## Goal

Ship Maxi80 on Apple TV (tvOS 17+) as a 10-foot, Siri-Remote-driven radio player, reusing the existing `RadioPlayerViewModel` / `RadioPlayerCoordinator` and the audio + Now Playing pipeline unchanged. The phone/tablet `RadioPlayerView` is **not** modified.

## Scope

Maxi80 is a single live station — there is no catalog to browse. The TV screen is therefore a full-screen "now playing" hero with a focus-navigable recently-played history row beneath it.

### In scope

- A tvOS destination (scheme/target) in the existing `Darwin/Maxi80.xcodeproj`.
- A shared TV SwiftUI view tree (see **Shared TV UI Foundation**), gated for tvOS.
- Siri Remote play/pause routed into the existing coordinator command path.
- tvOS app icon asset + Info.plist/entitlements as required to launch.

### Out of scope (dropped on tvOS)

These phone features are non-idiomatic on tvOS and are gated out:

- **In-app volume slider** — TV volume is the physical remote / HDMI-CEC / AV receiver.
- **AirPlay picker** — the Apple TV is itself the AirPlay endpoint.
- **Share sheet** — awkward with a remote.

### Kept on tvOS

- **Now Playing info + remote play/pause commands** (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`) — already wired for tvOS via `#if os(iOS) || os(tvOS)` in `IOSNowPlayingController`.
- Station loading, history, reconnection — reused unchanged from the coordinator.

## Already-built foundation (reused, not rebuilt)

`.tvOS(.v17)` is already declared in `Package.swift` `platforms`. The entire services layer is already guarded for tvOS:

- `Sources/Maxi80Services/Platform/iOS/AVPlayerStreamPlayer.swift` — `#if os(iOS) || os(tvOS)`
- `Sources/Maxi80Services/Platform/iOS/IOSNowPlayingController.swift` — `#if os(iOS) || os(tvOS)`
- `Sources/Maxi80Services/AudioStreamPlayer.swift` / `NowPlayingController.swift` — dispatch branches include `os(tvOS)`.

The gap is therefore **UI + a tvOS Xcode destination only**. No new audio, session, or Now-Playing code.

## Shared TV UI Foundation

Built once in shared Swift under `Sources/Maxi80/TV/`, transpiled to Compose for Android TV. This spec covers the tvOS branches; the Android TV spec covers the Compose branches.

- `TVRadioPlayerView.swift` — now-playing hero: full-bleed current cover art with a station-color gradient background (from the existing `ArtworkService` / `Maxi80Palette` color extraction), large title/artist, and a play/pause control. A focus-navigable recently-played row sits below.
- `TVHistoryRow.swift` — a focusable horizontal row derived from the existing history data (the TV analog of `CoverFlowView`, focus-driven rather than drag-driven).

Platform divergence:

- **tvOS** (this spec): SwiftUI `@FocusState` + `.focusable()`, default focus on play/pause, Siri Remote play/pause.
- **Android** (other spec): Compose D-pad focus.

The shared view owns **layout**; the platform branches (`#if os(tvOS)` vs `#if os(Android)`) own **focus and input**.

## Root-view selection

`Maxi80RootView` chooses the TV view via a small platform helper `PlatformEnvironment.isTVMode`:

- `#if os(tvOS)` → `true`
- `#if os(Android)` → reads the Android UI mode (see Android TV spec)
- otherwise → `false`

When `isTVMode` is `true`, `Maxi80RootView.body` renders `TVRadioPlayerView(viewModel:)`; otherwise the existing `RadioPlayerView(viewModel:)`. The `.task { await coordinator.loadStation() }` and shared dependency construction are unchanged.

## tvOS destination

Add a tvOS scheme/target to `Darwin/Maxi80.xcodeproj` reusing `Darwin/Sources/Main.swift` — its `#if canImport(UIKit)` branch already covers tvOS. Requires a tvOS app icon asset and a minimal tvOS Info.plist/entitlements sufficient to launch. Top Shelf image is **out of scope** (YAGNI).

## Background audio requirement

On tvOS the Maxi80 app *is* the foreground app; the "menu" (history row, controls) is all inside the app. Audio keeps playing because the audio session is `.playback` (already configured). The only real case is the Home button sending the app to the background — handled by the existing `MPNowPlayingInfoCenter` + audio-session wiring.

**Acceptance:** audio continues playing when the app is sent to the background via the Home button, and Control Center can resume/pause it. No new code; verified by test.

## Error handling

Reuses the existing pipeline unchanged. Stream failures surface through the coordinator's `onError` → reconnection path; the TV UI shows the same error / reconnecting state the phone shows, laid out for 10-foot. Missing cover art uses the existing `PlaceholderCover` / no-cover fallback.

## Testing

- **Shared logic** (Swift Testing, `swift test`): `PlatformEnvironment.isTVMode` returns `true` on tvOS; `Maxi80RootView` selects `TVRadioPlayerView` when TV-mode is true.
- **tvOS simulator (manual acceptance):** launch on the tvOS simulator; focus-navigate the history row; Siri Remote play/pause toggles playback; audio continues after Home-button backgrounding and is controllable from Control Center.
- No new property-based tests (the only new pure logic is the tiny helper).

## Conventions

- Swift 6 strict concurrency, `@MainActor`/`@Observable`, value types by default, Swift Testing.
- `Logger` (OSLog) for any new diagnostics, not `print()`.
- New preview code, if any, stays behind the `ENABLE_PREVIEWS` gate.
- Dependencies edited in `Package.swift` directly, never via Xcode GUI.
