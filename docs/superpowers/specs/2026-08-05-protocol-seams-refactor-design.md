# Protocol Seams for Platform Services — Design

**Date:** 2026-08-05
**Status:** Approved design, pending implementation plan
**Motivation:** Testability. Prompted by [Our Android app is written in Swift](https://forums.swift.org/t/our-android-app-is-written-in-swift/88778) (Polymarket).

## Context: what the article recommends vs. what Maxi80 already does

The article's architectural moves, audited against this codebase:

| Article recommendation | Maxi80 today |
|---|---|
| Isolate platform-specific code | Already done — `Sources/Maxi80Services/Platform/{iOS,Android,macOS,Apple}/`, dispatched via `#if SKIP` / `os(iOS)` |
| Share a platform-agnostic domain/ViewModel layer | Already done — `RadioPlayerCoordinator` + `RadioPlayerViewModel` are framework-free |
| Dependency injection at a composition root | Already done — `SharedPlayer` builds the graph, constructor-injects |
| Callbacks / AsyncStream instead of Combine across the bridge | Already done — `onMetadataChanged`, `onError`, `onInterruption`, … (the article was *migrating toward* this) |
| CI guardrail: shared code compiles on Android | Already done — `.github/workflows/ci.yml` runs `android-debug` and `android-release` (R8) jobs |
| **Common protocol abstracting platform services** | **Gap** — only `APIClientProtocol` exists; the three bridged services are injected as concrete classes |

**Conclusion: this is a narrow refactor, not a rearchitecture.** Roughly 80% of the article's architecture is already in place. The single genuine gap is the missing protocol seam on the bridged services, and its practical cost is testability.

### Explicitly rejected

- **A DI framework** (the article uses Point-Free `swift-dependencies`). Rejected: contradicts the project's stated preference for init-parameter DI over service locators, adds an unverified-under-Skip dependency, and the existing constructor injection already *is* the pattern the article emulates.
- **Splitting each service into separate `Apple*`/`Android*` classes.** Rejected: fights Skip's one-class transpile model and risks the JNI bridge. The `Platform/` folder split already delivers the isolation the article asks for. The internal `#if SKIP` dispatch stays exactly as-is.
- **A protocol for `ArtworkService`.** Rejected as churn: it already takes `any APIClientProtocol`, so it is fakeable through that existing seam.

## The concrete problem

Nine test files construct a **real `AudioStreamPlayer()`** across eleven sites — `SleepTimerTests`, `AudioFocusInterruptionTests`, `ResumeReconciliationTests`, `VolumeSyncTests`, `CarPlayNowPlayingTests`, `RadioPlayerViewModelTests`, `ViewModelPropertyTests`, `HistoryMergeTests` (2), `ShareTextPropertyTests` (2) — mostly in a per-file `makeCoordinator()` helper. That spins up the macOS AVPlayer path and permits only one direction of interaction: pushing callbacks inward. Tests cannot observe what the coordinator asked the player to *do*.

The eleven duplicated construction sites are themselves a finding: Phase 1 should introduce one shared `makeTestCoordinator(...)` factory in the new `Fakes/` directory rather than editing nine near-identical helpers, so future seam changes touch one place.

Consequently these behaviors are untestable today:

1. **Sleep-timer fade** — only the pure `fadeMultiplier(step:)` arithmetic is covered. That the coordinator actually drives a descending attenuation ramp terminating at `0.0` and *then* stops is not.
2. **Reconnection** — `setupReconnection()`'s `onReconnect` replays the stream URL and reads `player.isPlaying` after `reconnectConfirmationDelay` to confirm recovery. Untested against a player.
3. **True-stop semantics** — that user pause, headset disconnect, and sleep-timer fire all reach a real `stop()`. This is the `#49` / `StopOnPausePlayer` invariant that has regressed before.
4. **Cold-start external adoption** — `reconcileWithPlayer()` when `syncWithExternalPlayback()` returns `true` while `isPlaying` is stale-`false` (the Android Auto cold-connect path from PR #62). Unfakeable.

## Design

### Where protocols live

All three protocols are declared in the **native `Maxi80` module**, with the bridged classes conforming retroactively.

Rationale: the protocol never crosses the JNI boundary, so it carries **zero bridging risk**. Skip does support bridged protocols, but with restrictions (no static or constructor requirements), and bridge changes are historically where this project's builds break. The coordinator is native and is the only consumer, so the protocol belongs with its consumer. This also mirrors the existing, working precedent — `NowPlayingPublishing` at `Sources/Maxi80/NowPlayingSession.swift:9`.

### 1. `AudioPlaying`

```swift
// Sources/Maxi80/Services/AudioPlaying.swift
@MainActor
protocol AudioPlaying: AnyObject {
  var isPlaying: Bool { get }
  var volume: Double { get }
  var attenuation: Double { get }

  var onMetadataChanged: ((String) -> Void)? { get set }
  var onError: ((String) -> Void)? { get set }
  var onInterruption: ((Bool) -> Void)? { get set }
  var onDisconnectStop: (() -> Void)? { get set }
  var onPlaybackStateChanged: ((Bool) -> Void)? { get set }
  var onVolumeChanged: ((Double) -> Void)? { get set }

  func play(url: String)
  func stop()
  func updateVolume(_ newVolume: Double)
  func setPlaybackAttenuation(_ multiplier: Double)
  func currentVolume() -> Double
  func startObservingVolume()
  func syncWithExternalPlayback() -> Bool
}

extension AudioStreamPlayer: AudioPlaying {}
```

`AudioStreamPlayer`'s existing signatures already match exactly, so the conformance is empty. `stopObservingVolume()` is omitted — the coordinator never calls it (the observer intentionally lives for the process lifetime).

`RadioPlayerCoordinator.player` becomes `any AudioPlaying`.

### 2. `Sharing`

```swift
// Sources/Maxi80/Services/Sharing.swift
@MainActor
protocol Sharing: AnyObject {
  func share(text: String, imageData: Data?)
}

extension ShareService: Sharing {}
```

`RadioPlayerCoordinator.shareService` becomes `any Sharing`. Note the current default argument `shareService: ShareService = ShareService()` must become a non-defaulted parameter or keep a concrete default; the plan will make it explicit at the `SharedPlayer` composition root and drop the default, so no call site silently constructs a real share service.

### 3. Now Playing unification

This is the one phase that deletes production branching rather than only adding a seam.

Today `publishNowPlaying` and `publishPlaybackState` each carry an `#if !SKIP` block that prefers the modern iOS-27 `NowPlayingPublishing` publisher and otherwise falls through to the bridged `NowPlayingController`. Two sinks, two code paths, one of them compiled out per platform.

**Unified protocol** — un-gate it from `#if !SKIP` (its body is pure Swift and Android-safe) and widen `update` to carry semantic fields rather than a pre-formatted string:

```swift
@MainActor
protocol NowPlayingPublishing: AnyObject {
  func activate()
  func update(
    stationName: String, artist: String, title: String,
    artworkURL: String?, isPlaying: Bool)
  func updatePlaybackState(isPlaying: Bool)
}
```

`deactivate()` is **dropped**: it is dead code — nothing in `Sources/` or `Tests/` calls it. `NowPlayingController.tearDown()` is likewise never called, but it stays in place as an unused bridged method; removing it would touch the JNI bridge for no benefit, so it is out of scope (noted here so the deadness is recorded).

Two conformances:
- `NowPlayingSession` (iOS/macOS/tvOS 27+, `#if canImport(NowPlaying)`) — formats `programName` as `"\(title) — \(artist)"` internally, which is exactly what the coordinator does inline today.
- A new native adapter wrapping the bridged `NowPlayingController` — forwards to `updateNowPlaying(artist:title:artworkURL:isPlaying:)`, ignores `stationName`, and implements `activate()` as a no-op.

A factory resolves one publisher once in `init`, replacing the per-call `#if`:

```swift
private let nowPlayingPublisher: any NowPlayingPublishing
```

`publishNowPlaying` / `publishPlaybackState` then collapse to a single unconditional call each, keeping the existing CarPlay placeholder-artwork substitution (`shouldPublishPlaceholderArtwork`) untouched.

**Behavior must be identical.** The modern path is still preferred where available; the bridged path is still the fallback and remains the only path on Android. The `activate()`-before-update ordering is preserved.

## Risks and verification

**Primary unknown:** whether an empty retroactive conformance on a `/* SKIP @bridge */` class compiles under the Android Fuse build. Everything else is mechanical.

Mitigation: **Phase 0 is a throwaway spike** — add `extension AudioStreamPlayer: AudioPlaying {}` with two members only, run `make build-android`, confirm, revert. If it fails, the fallback is a thin native `AudioPlayerAdapter` final class wrapping the bridged player (marginally more code, identical test benefit). This decision gates the whole refactor, so it happens first.

**Secondary risk:** the Now Playing phase touches lock-screen / CarPlay / Android Auto behavior, which unit tests cannot fully verify. It requires on-device or emulator confirmation that the notification and lock screen still show artist/title/artwork and respond to transport commands.

**Regression net:** no production behavior changes in any phase. The existing test suite plus `make build-android` is the net; each phase must end green on `swift test` and both CI Android jobs.

## Testing approach

TDD: for each new behavior, the failing test comes first, against a fake, before the coordinator is touched. Writing the test first is what proves the seam is actually usable rather than merely present.

**New test doubles** (`Tests/Maxi80Tests/Fakes/`): `FakeAudioPlayer`, `FakeSharing`, `FakeNowPlayingPublisher` — each recording received calls in order, with settable state (`isPlaying`, `syncWithExternalPlayback` return) so tests can stage player conditions.

**New coverage unlocked:**

| Area | Assertion |
|---|---|
| Sleep-timer fade | Attenuation ramp is monotonically descending, final value `0.0`, `stop()` follows the ramp, `attenuation` restored to `1.0` after |
| Sleep-timer cancel | Cancelling mid-fade restores `1.0` and issues no `stop()` |
| Reconnection | `onReconnect` replays the station URL (not the default) when a station is loaded; recovery verdict follows `player.isPlaying` |
| True stop | Pause, `handleDisconnectStop()`, and sleep-fire each produce exactly one `stop()` |
| Cold-start adoption | `reconcileWithPlayer()` promotes to `.playing` when `syncWithExternalPlayback()` is `true` and `isPlaying` is stale-`false`; no promotion when it returns `false` |
| Sharing | `shareCurrentTrack` forwards the exact text and the fetched image bytes; `nil` artwork URL degrades to text-only |
| Now Playing | Coordinator publishes artist/title/artwork through the single publisher seam; placeholder substitution still applies when artwork is absent |

Existing tests are updated only where `makeCoordinator()` swaps a real service for a fake; their assertions stay unchanged, which is what demonstrates behavior preservation.

## Phasing

Each phase is independently shippable and ends green on `swift test` + `make build-android`.

0. **Spike** — verify retroactive conformance on a bridged class compiles for Android. Gates everything.
1. **`AudioPlaying`** — protocol, conformance, `FakeAudioPlayer`, shared `makeTestCoordinator` factory, coordinator field type change, all eleven existing construction sites migrated to the fake. Then the new test areas (fade, cancel, reconnect, true-stop, cold-start), tests first. This is the largest phase; it may split into 1a (seam + migration, suite stays green) and 1b (new coverage).
2. **`Sharing`** — protocol, conformance, `FakeSharing`, drop the defaulted `ShareService()` argument, new sharing tests.
3. **Now Playing unification** — widen and un-gate `NowPlayingPublishing`, add the bridged adapter, resolve one publisher in `init`, delete both `#if !SKIP` branches, add publisher tests. Requires device/emulator verification of lock screen + Android Auto before merge.

## Out of scope

- Any change to the `#if SKIP` platform dispatch inside the service classes.
- Any change to the `Platform/` folder layout.
- Removing the dead `NowPlayingController.tearDown()` bridged method.
- Introducing a DI container or framework.
- `ArtworkService` protocol extraction.
