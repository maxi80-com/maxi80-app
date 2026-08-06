# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Maxi80 is a cross-platform iOS/Android radio player for the French 80s station "Maxi 80", built with the [Skip](https://skip.tools) framework (Swift + SwiftUI running natively on both platforms).

## Build & Test

```bash
swift build                       # macOS/iOS (Swift toolchain)
swift test                        # Run all tests (includes Android via Robolectric)
skip android build                # Build the Android app
skip app launch                   # Launch on simulator + emulator
skip verify                       # Verify project structure
skip checkup                      # Diagnose environment (JDK 21, Android SDK, Gradle, Xcode) — run first on build issues
```

Run a single test target or test:

```bash
swift test --filter Maxi80ModelTests
swift test --filter MetadataParserTests
```

To trigger the Skip transpiler/Android compilation from Xcode, **build against the macOS destination** — iOS destinations do not run the skipstone plugin.

### Configuration required before running

`Sources/Maxi80/Resources/Configuration.plist` holds the backend URL and auth token (loaded by `ConfigurationLoader` via `Bundle.module`). Seed it from the template if missing:

```bash
cp Sources/Maxi80/Resources/Configuration.plist.template Sources/Maxi80/Resources/Configuration.plist
```

Keys: `API_BASE_URL`, `API_AUTH_TOKEN`. A missing/invalid plist falls back to empty values (asserts in debug).

## Architecture

Three SwiftPM modules, each with its own `Sources/<Module>/Skip/skip.yml` declaring its Skip mode. **Always check per-module mode before applying Skip guidance** — this project deliberately mixes modes. For how the Fuse (native), Lite (transpiled), and bridging modes differ, see the official docs: https://skip.dev/docs/modes/

| Module | Mode | Contents |
|--------|------|----------|
| `Maxi80` | native (Fuse) | SwiftUI views, `RadioPlayerViewModel`, `RadioPlayerCoordinator`, `ArtworkService`, app entry point |
| `Maxi80Model` | native + `bridging: true` | Codable data models, `APIClient`, `MetadataParser`, `APIConfiguration` |
| `Maxi80Services` | transpiled (Lite) + `bridging: true` | `AudioStreamPlayer`, `NowPlayingController` and their iOS/Android platform implementations |

Dependency direction is **native → transpiled** (`Maxi80` consumes the transpiled `Maxi80Services`). This is the less common direction and requires the `SKIP_BRIDGE` conditional block at the bottom of `Package.swift`, which injects the `SkipBridge` dependency into `Maxi80Services` only when the build sets `SKIP_BRIDGE=1`. Do not remove that block. Background on the mode/bridging decisions lives in `.kiro/steering/SKIP_ARCHITECTURE.md`.

### Reference prototype

A known-good, minimal Skip prototype exercising this exact native+transpiled+bridging pattern lives at `/Users/sst/code/maxi80/skip-tutorial/hello-world` (outside this repo). When a bridging, `SKIP_BRIDGE`, or module-mode change fails to build, diff against it — its `Package.swift`, `skip.yml` files, `SKIP_ARCHITECTURE.md`, and `SKIP_CODE_REVIEW.md` are the reference for how the wiring should look.

### Data flow / composition

`Maxi80RootView` (in `Maxi80App.swift`) is the composition root — it constructs `AudioStreamPlayer`, `NowPlayingController`, `APIClient`, `ArtworkService`, then the `RadioPlayerCoordinator`, then the `RadioPlayerViewModel`, via constructor injection. `Darwin/Sources/Main.swift` is the Apple `@main` entry point and aliases into `Maxi80RootView` / `Maxi80AppDelegate`.

- **`RadioPlayerCoordinator`** (`@MainActor @Observable`) owns the bridged services, runs full Swift concurrency (`async/await`, `Task`, `withCheckedContinuation`), and holds canonical state (`playbackState`, `currentSong`, `history`, `station`).
- **`RadioPlayerViewModel`** (`@MainActor @Observable`) exposes UI-shaped state to SwiftUI and delegates actions to the coordinator; `syncFromCoordinator()` translates coordinator state into view state.

### Cross-module bridging rules (important, and easy to get wrong)

- **Transpiled → native communication is callback-based, not Combine/ObservableObject.** `AudioStreamPlayer` and `NowPlayingController` expose closures (`onMetadataChanged`, `onError`, `onInterruption`, `onRemoteCommand`); the coordinator wires them in `setupCallbacks()` and hops to `@MainActor`. Closures bridge cleanly across the Swift/Kotlin boundary — plain `@Observable`/ObservableObject do not, because the transpiled Kotlin context lacks SkipModel/Compose.
- **The coordinator depends on protocols, not the bridged classes.** `AudioPlaying`, `Sharing`, and
  `NowPlayingPublishing` are declared in the **native `Maxi80` module** (`Sources/Maxi80/`)
  and the bridged `Maxi80Services` classes conform retroactively. Declare any future service seam
  the same way — a protocol in the native module never crosses the JNI boundary, so it can't break
  the bridge. The `#if SKIP` platform dispatch stays inside the bridged class.
- Coordinator tests inject fakes via `makeTestCoordinator(...)` in `Tests/Maxi80Tests/Fakes/`.
  Never construct a real `AudioStreamPlayer()` in a test — it starts the platform audio path.
- The two bridged service classes are wrapped in `/* SKIP @bridge */` + `#if !SKIP_BRIDGE`. Platform method bodies live in separate files under `Sources/Maxi80Services/Platform/{iOS,Android}/` and are dispatched via `#if SKIP` (Android) / `#elseif os(iOS) || os(tvOS)`.
- `APIClient` is marked `// SKIP @nobridge` and uses completion handlers (`@escaping @Sendable (String?) -> Void`) that callers adapt to async with `withCheckedContinuation`. It returns raw JSON strings; JSON decoding into Codable types happens in the native coordinator, because transpiled modules can't synthesize Codable.
- `Maxi80Services` pulls in ExoPlayer/media3 Gradle deps declared directly in its `skip.yml` `build.contents` block.

### Platform-specific patterns to preserve

- **Apple-only code** (the `Maxi80App`/`App` protocol conformance, previews) is guarded with `#if !SKIP_BRIDGE`. Note: do **not** use bare `#if !SKIP` to guard Apple-only frameworks inside the native `Maxi80` module — `Maxi80` is Fuse mode, so `SKIP` is *not* defined when the Swift is cross-compiled for Android, and `#if !SKIP` evaluates to `true` there. Use `#if canImport(NowPlaying)` (or the appropriate framework) instead; `canImport` is the gate that actually keeps Apple-only symbols out of the Android build.
- **Image/color extraction** in `ArtworkService` uses `#if canImport(UIKit)` / `#elseif canImport(AppKit)`, with an Android fallback that returns a default color and no image (no platform image APIs).
- **Previews are gated behind `ENABLE_PREVIEWS`**, defined in `Package.swift` only for Xcode-driven builds (detected via the `__CFBundleIdentifier` env var), because the `#Preview` macro plugin ships only with Xcode's toolchain, not the bare `swift build` toolchain. Keep new preview code inside that gate.

## Conventions

- Follows the user's global Swift preferences: Swift 6 strict concurrency, structured concurrency over GCD, actors/`@MainActor` over locks, `@Observable` (Observation framework) over Combine, value types by default, Swift Testing (`#expect`, `@Test`) over XCTest.
- Property-based tests use **SwiftCheck** (`*PropertyTests.swift` files); example-based tests sit alongside them. Test targets depend on `SkipTest`.
- Use `Logger` (OSLog) rather than `print()` for anything that needs to surface on Android — `print()` does not appear in Logcat. (Existing `APIClient` uses `print`; prefer `Logger` for new diagnostics.)
- Add dependencies by editing `Package.swift` directly — never via Xcode's "Add Package Dependencies" GUI (it doesn't update the manifest Skip requires).
- Project-wide metadata (bundle id, version, Android package) lives in `Skip.env`.

### Feature flags

Runtime switches live in `FeatureFlags` (`Sources/Maxi80/`), fed by the optional `features`
(`[String: Bool]`) object on the `/station` response and applied in `loadStation()`. To add a flag:
add a `Flag` case whose raw value is the backend's `lower_snake_case` name, **and** a matching entry
in `defaults` (`FeatureFlagsTests` fails if you forget). Rules that must hold:

- **Defaults are ship-safe and fail-open.** No network, no `features` object, or an unreadable
  payload all leave the compiled-in defaults in charge — a flag must never be the reason a shipped
  feature disappears. An already-shipped feature therefore defaults *on* (the flag is a kill switch);
  an unreleased one defaults *off*.
- **Gate the entry point, not every function the feature touches.** Find the control that *starts*
  the feature and gate that one place; with no way in, the downstream coordinator methods need no
  guards of their own (`sleep_timer` gates only `isSleepTimerAvailable`, which hides the tray button
  that presents the picker). Check first that the entry point really is singular — a feature also
  reachable from CarPlay or the TV UIs needs its coordinator API gated too.
- **Leave a feature already in progress able to finish or be cancelled.** The flag stops new
  entries; it shouldn't strand state that's already running. A sleep timer armed before the switch
  arrives keeps its countdown pill, because that pill is how the user calls off a stop that's already
  scheduled — hiding it would be worse than leaving the feature on.
- **Inject, don't reach for the singleton, in the coordinator/view model.** Both take
  `featureFlags: FeatureFlags = .shared`, so production gets the process-wide store and tests inject
  a fresh one instead of mutating global state.
- `Station` has a hand-written `init(from:)` purely so a malformed `features` value degrades that one
  field rather than failing the whole station decode, and decodes flags **key by key** so one bad
  value can't discard a kill switch sent in the same payload. Keep every other field strict.
- **Flags land at station-load time only**, so a change reaches iOS/macOS/tvOS on the next cold launch
  but Android within minutes (its `loadStation()` re-runs on every foreground). Don't rely on a flag
  taking effect promptly on Apple platforms.
