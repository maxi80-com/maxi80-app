# Swift 6 / Concurrency Audit & Remediation Plan

**Date:** 2026-07-13
**Scope:** Full audit of Swift concurrency & modern-Swift-6 patterns across the Maxi80 Skip project.
**Status:** Findings only — NO code changes have been applied. This document is the work list.

> Read this whole file before touching code. Several findings interact (P1↔P3, P4↔P9).
> This is a **Skip** project: `Maxi80` + `Maxi80Model` are **native (Fuse)** modules,
> `Maxi80Services` is **transpiled (Lite)** and must compile to Kotlin/Android. Verify every
> change against the Android build, not just `swift build` (which targets the macOS host).

## Build context (verified)

- `Package.swift`: `// swift-tools-version: 6.0`, **no** `swiftLanguageMode` / `StrictConcurrency` /
  `defaultIsolation` overrides → **Swift 6 language mode + complete data-race checking is in force.**
  Every `@unchecked Sendable` / `nonisolated(unsafe)` is *bypassing* that checking, not satisfying it.
- Module modes (from each `Sources/<M>/Skip/skip.yml`):
  - `Maxi80` — native (Fuse). Full modern Swift applies; no excuse for legacy patterns.
  - `Maxi80Model` — native (Fuse) + `bridging.enabled: true`.
  - `Maxi80Services` — transpiled (Lite) + `bridging: true`. GCD/callback patterns here are often
    *forced by Skip* (Kotlin transpile reliability), not free choices — see P7/P8.
- Verify-before-advising Skip caveat: a `/* SKIP @bridge */` class being marked `@MainActor`
  across the JNI boundary is **unverified** — see P2 for the check to run first.

---

## P1 — CRITICAL (correctness): UI never updates after launch

> ✅ **DONE & verified 2026-07** (fixed together with P3 — see below). All 42 tests pass; app builds
> and launches on both platforms.

**Files:** `Sources/Maxi80/RadioPlayerViewModel.swift`, `Sources/Maxi80/RadioPlayerCoordinator.swift`

**Symptom:** After the app launches, the song title/artist, artwork, play/pause state, history
carousel, and error banner **freeze at their initial values**. The app is functionally broken.

**Root cause:** `RadioPlayerViewModel.syncFromCoordinator()` is called **exactly once**, from the
ViewModel `init` (`RadioPlayerViewModel.swift:68`). Confirmed by grep: the only two occurrences of
`syncFromCoordinator` are the definition (`:99`) and that single init call (`:68`).

The View (`RadioPlayerView`) holds `@Bindable var viewModel` and observes the **ViewModel's** own
`@Observable` stored properties (`isPlaying`, `currentSong`, `history`, `errorMessage`, …). Those are
one-time **copies** of coordinator state. When the coordinator mutates its own state in
`handleMetadataChanged` / `fetchHistory` / `handleError` (`RadioPlayerCoordinator.swift:150-196, 233-247`),
the ViewModel's mirror properties are never refreshed → SwiftUI sees no change.

**Fix:** Do NOT just sprinkle more `syncFromCoordinator()` calls — fix it structurally via P3
(the two are the same fix). The correct outcome: the View's observed state tracks the coordinator's
canonical state automatically through the Observation framework.

**Verification:** Launch app (iOS sim + Android emulator per CLAUDE.md `skip app launch`), start
playback, confirm the metadata/artwork/history change as tracks change and that the error banner
appears on a forced error.

---

## P3 — HIGH (modern pattern): two stacked `@Observable` layers defeat Observation

> ✅ **DONE & verified 2026-07 — Option A.** ViewModel's coordinator-derived properties (`isPlaying`,
> `isLoading`, `currentSong`, `currentArtwork`, `dominantColor`, `history`, `station`, `errorMessage`,
> `canShare`) are now computed passthroughs to the `@Observable` coordinator; `syncFromCoordinator()`
> and `updateCanShare()` deleted. Kept `volume` + `selectedHistoryIndex` as stored UI-local state
> (View binds them via `$viewModel.…`). `PreviewHelpers.swift` and 3 test files now configure the
> coordinator instead of setting VM props.

**Files:** `Sources/Maxi80/RadioPlayerViewModel.swift`, `Sources/Maxi80/RadioPlayerCoordinator.swift`,
`Sources/Maxi80/RadioPlayerView.swift`

**Problem:** Current chain is `RadioPlayerCoordinator` (`@MainActor @Observable`, source of truth)
→ ViewModel **copies** fields into its own `@Observable` stored props → View observes the ViewModel.
The manual snapshot (`syncFromCoordinator`) throws away Observation's automatic fine-grained dependency
tracking. This is the design flaw that *causes* P1.

**Two acceptable fixes (pick one; both are "modern"):**

- **Option A (preferred, least code):** Turn the ViewModel's duplicated stored properties into
  **computed** properties that read through to the coordinator. E.g.
  `var currentSong: SongMetadata? { coordinator.currentSong }`,
  `var isPlaying: Bool { if case .playing = coordinator.playbackState { true } else { false } }`, etc.
  Because `coordinator` is `@Observable` and the ViewModel is `@Observable`, reads inside computed
  props register dependencies and the View re-renders on coordinator changes. Delete
  `syncFromCoordinator()` and all stored mirror props. Keep the action methods (`togglePlayback`,
  `setVolume`, `retry`, `shareCurrentTrack`) — they already delegate to the coordinator.
  Keep the artwork mapping (`ArtworkResult` → `Image`/`Color`) as computed too.
- **Option B:** Delete the ViewModel entirely and have `RadioPlayerView` observe the coordinator
  directly (`@Bindable var coordinator`). More invasive (touches the View + previews + `Maxi80App`
  composition root). Only do this if the ViewModel adds no UI-shaping value beyond passthrough.

**Constraints / gotchas:**
- Keep everything `@MainActor` (coordinator and VM already are).
- `RadioPlayerViewModel` is bridged indirectly via the View; ensure computed props remain `public`
  where the View needs them (module boundary: View and VM are both in `Maxi80`, so `internal` is fine
  if the View stops needing `public` — but preview helpers in `PreviewHelpers.swift`/`PreviewMocks`
  construct the VM, check their access needs).
- `PreviewMocks.makeViewModel(...)` (`Sources/Maxi80/PreviewHelpers.swift`) builds a VM for `#Preview`.
  If VM props become computed-through-coordinator, previews must construct a coordinator with mock
  state instead of setting VM props directly. Update `PreviewHelpers.swift` accordingly and keep it
  inside the existing `#if ENABLE_PREVIEWS` gate.

**Verification:** same as P1, plus confirm previews still build in Xcode (macOS destination triggers
skipstone; previews need Xcode toolchain + `ENABLE_PREVIEWS`).

---

## P2 — CRITICAL (data safety): `@unchecked Sendable` masking real mutable shared state

> ✅ **DONE & verified 2026-07 (both platforms).** `AudioStreamPlayer` is now `@MainActor` with
> `@unchecked Sendable` removed; `NowPlayingController` is `final`. All three `DispatchQueue.main.async`
> in `AVPlayerStreamPlayer.swift` replaced with `Task { @MainActor in }` (per user: no DispatchQueue).
> The two NotificationCenter handlers now parse the non-Sendable `Notification` inside the observer
> closure and hop to the main actor with Sendable values only (`handleInterruption(type:optionsRaw:)`,
> `handleRouteChange(reason:)`).
> **KEY FINDING: `@MainActor` on a `/* SKIP @bridge */` class transpiles & runs fine on Android** —
> the earlier bridge concern is resolved. Verified via `skip app launch` → "Launch Skip app succeeded".
> NOTE: this required updating to the latest Skip (skip 1.9.4 / skip-ui 1.58.0 / skip-fuse-ui 1.17.3 /
> skip-model 1.7.5 via `swift package update`) AND a clean rebuild (`rm -rf .build/plugins/outputs`
> and `.../BuildToolPluginIntermediates`) — stale transpile artifacts after a version bump produce
> bogus "X is internal" / "cannot find X in scope" errors in framework code. Clean rebuild fixes them.

**File:** `Sources/Maxi80Services/AudioStreamPlayer.swift:13`
(`public final class AudioStreamPlayer: @unchecked Sendable`)

**Problem:** The class has mutable `var isPlaying`, `var volume`, and five mutable callback vars
(`onMetadataChanged`, `onError`, `onInterruption`, `onPlaybackStateChanged`, `onVolumeChanged`).
These are mutated from: iOS KVO handlers & `NotificationCenter` observers & the
`MetadataOutputDelegate` (`AVPlayerStreamPlayer.swift`), and on Android the ExoPlayer
`Player.Listener` / focus / noisy-receiver callbacks (`ExoPlayerStreamPlayer.swift`).
`@unchecked Sendable` is an **unaudited blanket suppression** of Swift 6 race checking and violates
the user's global rule ("no `@unchecked Sendable`").

**Reality:** every write already lands on the main thread — iOS uses `DispatchQueue.main.async` and
`queue: .main`; Media3 delivers `Player.Listener` callbacks on the app main looper. So the honest
isolation model is **main-actor**, not "unchecked."

**Preferred fix:** make `AudioStreamPlayer` `@MainActor` and delete `@unchecked Sendable`.
Do the same review for `NowPlayingController` (`NowPlayingController.swift:5` — currently a plain
`public class`, not even `final`; make it `final`, and `@MainActor` if it holds main-thread state).

**⚠️ MUST-VERIFY BEFORE APPLYING (Skip-specific, unverified):**
Both classes are `/* SKIP @bridge */`. It is **not confirmed** that a bridged class can be
`@MainActor` across the JNI/bridge boundary and still transpile+compile for Android. Before
committing:
1. Apply `@MainActor`, remove `@unchecked`.
2. Run the **Android** build: `skip android build` (or `skip app launch`). NOT just `swift build`.
3. If the bridge rejects `@MainActor` on a bridged type: fall back to keeping `@unchecked Sendable`
   BUT add a documented safety-invariant comment above the class
   ("INVARIANT: all stored state is confined to the main thread; every callback is dispatched to
   main before mutating. Do not access off-main.") and a follow-up TODO. This is the concurrency
   skill's required treatment for any retained unsafe opt-out.

**Secondary (same file):** the callback vars are `((String) -> Void)?` etc., not `@Sendable`.
On a type invoked from background/platform contexts they should be `@Sendable` closures
(`public var onError: (@Sendable (String) -> Void)?`). Coordinator's `setupCallbacks`
(`RadioPlayerCoordinator.swift:122-146`) already hops to `@MainActor` inside a `Task`, so making the
closures `@Sendable` should be compatible — verify the assignment still typechecks on both platforms.

**Verification:** clean Swift 6 build with zero concurrency warnings on the Fuse side; Android build
green; runtime playback still works on both platforms.

---

## P4 — HIGH: reconnection logic is declared but never wired (dead code + missing feature)

> ✅ **DONE & verified 2026-07 — WIRED IN** (user chose wire-vs-delete → wire). Coordinator now owns a
> `ReconnectionManager`; `setupReconnection()` routes `onStateChanged` → `playbackState` and
> `onReconnect` → re-issue `player.play(url:)`, wait `reconnectConfirmationDelay` (3s), return
> `player.isPlaying`. `handleError` now calls `startReconnection()` instead of going straight to
> `.error`. Successful metadata / fresh `play()` / manual `retryConnection()` reset the cycle; `pause()`
> cancels it. Deleted dead `reconnectAttempts`/`maxReconnectAttempts`. Builds + launches both platforms;
> `ReconnectionPropertyTests` (the manager's own backoff/cancellation test) still passes.
>
> ALSO fixed P5 incidentally here: `play()`'s fire-and-forget history `Task` is now stored in
> `historyTask` and cancel-previous'd (was an unstructured race on `history`).

**Files:** `Sources/Maxi80/RadioPlayerCoordinator.swift`, `Sources/Maxi80/ReconnectionManager.swift`

**Findings:**
- Coordinator declares `reconnectAttempts` (`:36`) and `maxReconnectAttempts = 3` (`:38`), resets
  `reconnectAttempts` in `play()`/`retryConnection()`/`handleMetadataChanged`, but **never
  increments it and never acts on it**. `handleError` (`:193`) only sets `.error` — no retry.
- `ReconnectionManager` (whole file) is **entirely unreferenced** — grep-confirmed no usages outside
  its own definition. It is otherwise well-written structured concurrency (backoff via
  `Task.sleep`, cancellation via stored `Task`, `Task.isCancelled` checks).
- The `PlaybackState.reconnecting(Int)` case exists and the ViewModel handles it, but nothing ever
  emits it.

**Decision required (pick one), then execute:**
- **Wire it:** inject/instantiate `ReconnectionManager` in the coordinator; on `onError` from the
  player, call `startReconnection()`, set `onReconnect` to re-invoke `player.play(url:)` and report
  success, and route `onStateChanged` into `coordinator.playbackState`. Delete the unused
  `reconnectAttempts`/`maxReconnectAttempts` counters (the manager owns that state). This delivers
  the intended auto-reconnect feature.
- **Delete it:** remove `ReconnectionManager.swift`, the `reconnectAttempts`/`maxReconnectAttempts`
  fields, and (optionally) the `.reconnecting` state if truly unused. Cleaner if reconnection is out
  of scope.

`ReconnectionManager` is `@MainActor` and uses only structured concurrency — no concurrency changes
needed to it; this is a wiring/architecture decision.

**Verification:** if wired — simulate a stream drop and confirm 2s/4s/8s backoff, state transitions
to `.reconnecting(n)` then `.playing` or `.error`. If deleted — build stays green.

---

## P5 — MEDIUM: unstructured fire-and-forget `Task` races on `history`

> ✅ **DONE 2026-07** — fixed alongside P4. `play()` now stores the fetch in `historyTask` and
> cancels the previous one before starting a new one.

**File:** `Sources/Maxi80/RadioPlayerCoordinator.swift:72-74` (inside `play()`)

**Problem:** `play()` launches `Task { [weak self] in await self?.fetchHistory() }` with no stored
handle and no cancellation. Repeated `play()` (user toggling, remote commands, interruption-resume
calling `play()` at `:207`) spawn **overlapping** history fetches, each doing a read-modify-write on
`self.history` (`:236-246`) → interleaving/duplication risk. Also violates the "prefer structured
concurrency; justify unstructured Task" guidance.

**Fix:** store the task (`@ObservationIgnored private var historyTask: Task<Void, Never>?`), cancel
the previous one before starting a new one, or guard against concurrent runs. Since the coordinator
is `@MainActor`, the read-modify-write itself is serialized per await-gap, but overlapping fetches
still duplicate work and can reorder results — cancel-previous is the clean pattern.

**Verification:** rapid play/pause/play does not duplicate history entries.

---

## P6 — MEDIUM: `print()` instead of `Logger` + dead code

**Files:** `Sources/Maxi80/StationProvider.swift:49`, `Darwin/Sources/Main.swift:25`

- CLAUDE.md mandates `Logger` (OSLog) over `print()` (print doesn't reach Android Logcat).
- **`StationProvider` is dead code** — grep-confirmed no usages outside its own file. The coordinator
  has its own `loadStation()` with the same fallback chain. **Recommend deleting `StationProvider.swift`
  entirely** (and its tests `Tests/Maxi80Tests/StationProviderTests.swift` +
  `StationFallbackPropertyTests.swift` — OR, if those tests are considered valuable coverage of the
  fallback logic, retarget them at the coordinator's `loadStation`). Deleting removes the `print` too.
- `Darwin/Sources/Main.swift:25` `print("unknown app phase…")` — replace with `Logger`. This is the
  Apple entry point (native), low traffic; still align with the convention. Use
  `import SkipFuse` + `Logger(subsystem:category:)` per Skip's logging doc
  (https://skip.dev/docs/debugging/#logging) — matches how `APIClient.swift` now logs.

**Verification:** build green; if tests deleted/retargeted, `swift test` passes.

---

## P7 — LOW (accept, documented): GCD in the transpiled iOS path

**File:** `Sources/Maxi80Services/Platform/iOS/AVPlayerStreamPlayer.swift:103, 121, 308`
(`DispatchQueue.main.async` inside KVO / metadata-delegate callbacks)

User pref is structured concurrency over GCD, BUT this is iOS-only code inside the **Lite/transpiled**
module. GCD is what Skip transpiles reliably; `MainActor.run` across the bridge is riskier. **Leave as
is.** Minor cleanup available: the `NotificationCenter` observers already register with `queue: .main`
(`:136, :144`), so `handleInterruption`/`handleRouteChange` bodies run on main already — they don't
need any added hop (and currently don't have one — fine). No action required; documented so a future
pass doesn't "fix" it and break Android.

---

## P8 — LOW (no action, verified safe): `nonisolated(unsafe)` associated-object keys

**File:** `Sources/Maxi80Services/Platform/iOS/AVPlayerStreamPlayer.swift:236-242`

These are address-only sentinel bytes for `objc_getAssociatedObject(&key)`; their *value* is never
read or written. This is the idiomatic, genuinely-safe pattern for adding stored properties to an
extension. **No change.** Listed only to record it was reviewed and cleared.

---

## P9 — LOW: verify typed-throws on Android + it currently buys little

**File:** `Sources/Maxi80Model/Services/APIClient.swift` (introduced in the 2026-07 refactor)

- ✅ **VERIFIED 2026-07-13:** the user confirmed the Android build compiles with
  `async throws(APIClientError)` — typed throws transpiles fine. No further action on the build side.
- Every call site currently uses `try?` and discards the typed error
  (`RadioPlayerCoordinator.swift:98,234`; `ArtworkService.swift:31`). So the typed error is presently
  ceremony. Tie-in with P4: if reconnection/error UX is implemented, **consume** the error
  (distinguish `.unauthorized` vs network failure vs `.noContent`) instead of `try?`. Otherwise the
  typed throw is defensible for future-proofing but adds no value today.

**Verification:** Android build green; if error consumed, coordinator surfaces meaningful messages.

---

## Suggested execution order

1. **P1 + P3 together** — one structural fix (Observation done right) repairs the frozen UI. Start here.
2. **P2** — remove `@unchecked Sendable`; verify `@MainActor` survives the Android bridge (fallback plan documented).
3. **P4** — decide wire-vs-delete reconnection; execute.
4. **P5** (task race), **P6** (dead `StationProvider` + `print`→`Logger`).
5. **P9** — Android build verification of typed throws; consume errors if P4 added error UX.
6. P7/P8 — no action (documented as intentionally left).

## Global verification checklist (run after each batch)

- `swift build` (macOS host) — zero warnings, especially concurrency.
- `skip android build` (or `skip app launch`) — the Fuse/Android path; **required** for P2 and P9.
- `swift test` — all suites green (note `APIClientTests` is `.serialized` due to shared `URLProtocol`
  mock state; keep it that way).
- Runtime smoke on iOS sim + Android emulator: playback starts, metadata/artwork/history update live
  (this is the real P1 acceptance test), error banner + retry work.
