# Android TV Support — Design

**Date:** 2026-07-16
**Status:** Approved (brainstorming)
**Related:** [tvOS Support](2026-07-16-tvos-support-design.md) — shares the TV UI foundation described below.

## Goal

Ship Maxi80 on Android TV as a 10-foot, D-pad-driven radio player, delivered as the **same single app / AAB** as the phone Android app. Reuses the existing `RadioPlayerViewModel` / `RadioPlayerCoordinator`, the transpiled `Maxi80Services`, and the foreground `MediaSessionService` unchanged. The phone/tablet UI is **not** modified.

## Scope

Maxi80 is a single live station — no catalog to browse. The TV screen is a full-screen "now playing" hero with a focus-navigable recently-played history row beneath it (see **Shared TV UI Foundation**).

### Delivery model

One APK/AAB, one Play listing. TV support is added to the existing app:

- The existing `MainActivity` gains a `LEANBACK_LAUNCHER` category so it appears on the Android TV home screen.
- `uses-feature` declarations mark leanback and touchscreen as **not required**, keeping the single app installable on both phones and TVs.
- At runtime the app detects TV mode and picks the TV UI.

## Already-built foundation (reused, not rebuilt)

The Android app already runs playback in a foreground `MediaSessionService` (`maxi80.services.Maxi80MediaService`) exposing `MediaLibraryService` / `MediaSessionService` / `MediaBrowserService` intents — the same service that powers Android Auto — plus the `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permissions. ExoPlayer/media3 playback runs independently of the Activity/UI.

The gap is therefore **manifest entries + a TV-mode Compose UI only**. No new service, playback, or media-session code.

## Manifest changes

`Android/app/src/main/AndroidManifest.xml`:

- Add `<category android:name="android.intent.category.LEANBACK_LAUNCHER" />` to the existing `MainActivity` intent-filter (alongside the current `LAUNCHER`).
- Add `<uses-feature android:name="android.software.leanback" android:required="false" />`.
- Add `<uses-feature android:name="android.hardware.touchscreen" android:required="false" />`.
- Add `android:banner="@drawable/tv_banner"` to the `<application>` (or the leanback activity) — a 320×180 TV banner asset required by Play for the leanback launcher.

## Runtime TV detection

Because the UI is shared SwiftUI transpiled to Compose, the TV-vs-phone selection happens in Swift via the shared helper `PlatformEnvironment.isTVMode`:

- `#if os(Android)` → reads the Android UI mode: `true` when the current UI mode type is `UI_MODE_TYPE_TELEVISION` (via Android `UiModeManager` / `Configuration.uiMode`).
- `#if os(tvOS)` → `true` (see tvOS spec).
- otherwise → `false`.

When `isTVMode` is `true`, `Maxi80RootView.body` renders `TVRadioPlayerView(viewModel:)`; otherwise the existing `RadioPlayerView(viewModel:)`. Dependency construction and `.task { await coordinator.loadStation() }` are unchanged.

## Shared TV UI Foundation

Built once in shared Swift under `Sources/Maxi80/TV/`, transpiled to Compose for Android TV. This spec covers the Android/Compose branches; the tvOS spec covers the SwiftUI-focus branches.

- `TVRadioPlayerView.swift` — now-playing hero: full-bleed current cover art with a station-color gradient background (from the existing `ArtworkService` / `Maxi80Palette` color extraction), large title/artist, and a play/pause control. A focus-navigable recently-played row sits below.
- `TVHistoryRow.swift` — a focusable horizontal row derived from the existing history data (the TV analog of `CoverFlowView`, focus-driven rather than drag-driven).

Platform divergence:

- **Android** (this spec): Compose D-pad focus, initial focus on play/pause.
- **tvOS** (other spec): SwiftUI `@FocusState` + `.focusable()`, Siri Remote play/pause.

The shared view owns **layout**; the platform branches (`#if os(Android)` vs `#if os(tvOS)`) own **focus and input**.

## Background audio requirement

Playback lives in the foreground `MediaSessionService`, which is independent of the Activity and its Compose UI. Navigating the TV UI (moving focus through the history row), or the UI being torn down, never stops audio; the same is true when the app is backgrounded via the Home button.

**Acceptance:** audio continues playing while navigating the history row and while the app is backgrounded. No new code; verified by test.

## Error handling

Reuses the existing pipeline unchanged. Stream failures surface through the coordinator's `onError` → reconnection path; the TV UI shows the same error / reconnecting state the phone shows, laid out for 10-foot. Missing cover art uses the existing `PlaceholderCover` / no-cover fallback (Android returns a default color and no image, per `ArtworkService`).

## Testing

- **Shared logic** (Swift Testing via Robolectric where relevant, `swift test`): `PlatformEnvironment.isTVMode` returns the expected value for the Android UI mode; `Maxi80RootView` selects `TVRadioPlayerView` when TV-mode is true.
- **Android TV emulator (manual acceptance):** launch from the leanback home screen; D-pad-focus-navigate the history row and controls; play/pause toggles playback; audio continues while navigating the history row and after Home-button backgrounding.
- No new property-based tests (the only new pure logic is the tiny helper).

## Conventions

- Swift 6 strict concurrency, `@MainActor`/`@Observable`, value types by default, Swift Testing.
- `Logger` (OSLog via `SkipFuse`) for any new diagnostics — forwards to Logcat; not `print()`.
- SwiftUI APIs that pass iOS build but fail Android must be gated with `#if os(Android)` (not `#if !SKIP`).
- SF Symbols render as ⚠️ on Android — use `AndroidIcon` (extended Material icons) for any new TV icons.
- Dependencies edited in `Package.swift` / `skip.yml` directly, never via Xcode/Android-Studio GUI.
- Project metadata (package name, version) lives in `Skip.env`.
