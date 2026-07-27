# Plan — Issue #29 (symptom 2): pause button state not synced with the player on Android

**Issue:** [#29 — Android : swiping notification doesn't terminate the app](https://github.com/maxi80-com/maxi80-app/issues/29)
**Scope of THIS plan:** symptom 2 only. Symptom 1 (notification-swipe should terminate the app) is intentionally **out of scope** here — see "Scope & non-goals".
**Triage:** `bug` (worth doing).
**Platform:** Android (Skip Fuse / native mode; `#if SKIP` is **not** defined on-device — the Kotlin bits that fire the callback live in `ExoPlayerStreamPlayer.swift` behind `#if SKIP`, but the coordinator wiring being fixed is plain Swift shared code).

---

## 1. Reproduction

Exact conditions (from the issue + code trace):

1. Launch the Android app, let history load.
2. Start playback.
3. Open the notification shade.
4. Press **pause** on the media notification.
5. Observe the in-app play/pause control.

**Observed:** the ExoPlayer stream actually pauses (audio stops), but the in-app control still shows the **playing/pause-available** state — "no sync with actual stream paused status" (issue text). The app's `playbackState` stays `.playing`.

**Expected:** when the stream is paused from the notification (media3 → ExoPlayer), the coordinator's `playbackState` transitions to `.paused` and the in-app control reflects it.

This is a **state-sync bug**, independent of symptom 1 (process termination on swipe) and independent of #30 (whether "pause" should be a full "stop"). It reproduces even without swiping the notification away.

## 2. Root cause (file/function level)

The ExoPlayer wrapper already detects and reports pause/play transitions:

- `Sources/Maxi80Services/AudioStreamPlayer.swift:28` declares the callback
  `public var onPlaybackStateChanged: ((Bool) -> Void)?`.
- `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` — the
  `MetadataPlayerListener` fires `player.onPlaybackStateChanged?(...)` from every
  relevant media3 transition:
  - `onIsPlayingChanged(isCurrentlyPlaying:)` → lines 59–62 (this is the one that fires when the notification pauses playback)
  - `onPlaybackStateChanged(playbackState:)` → lines 49–57
  - `onPlayWhenReadyChanged(...)` / `onPlaybackSuppressionReasonChanged(...)` → lines 64–84
  - It also keeps `player.isPlaying` in sync in each of these.

**But the coordinator never subscribes to that callback.**
`RadioPlayerCoordinator.setupCallbacks()` (`Sources/Maxi80/RadioPlayerCoordinator.swift:301-334`) wires `onMetadataChanged`, `onError`, `onInterruption`, and `onVolumeChanged` — **`onPlaybackStateChanged` is never assigned.** So when media3 pauses the ExoPlayer from the notification, the observable `playbackState` is never demoted to `.paused`.

The existing recovery path can't cover this either: `reconcileWithPlayer()` (`RadioPlayerCoordinator.swift:186-196`) is deliberately conservative — it only **promotes** `.loading`/`.reconnecting` → `.playing` when `player.isPlaying` is true, and `guard player.isPlaying else { return }` makes it a no-op when the player is paused. It **never demotes** to `.paused`. So neither the live callback nor the foreground reconcile currently reflects an external pause.

Citations:
- Callback declared, never wired: `AudioStreamPlayer.swift:28` vs `RadioPlayerCoordinator.setupCallbacks()` `RadioPlayerCoordinator.swift:301-334`.
- Callback fired on external pause: `ExoPlayerStreamPlayer.swift:59-62` (`onIsPlayingChanged`).
- Conservative reconcile that can't demote: `RadioPlayerCoordinator.reconcileWithPlayer()` `RadioPlayerCoordinator.swift:186-196`.

## 3. Approach

Wire the missing callback in `setupCallbacks()` and add a handler that reconciles the observable state with the externally-driven player state, **without** fighting the coordinator's own intentional transitions.

### Files to change

1. **`Sources/Maxi80/RadioPlayerCoordinator.swift`**
   - In `setupCallbacks()` (around line 318, next to the existing `onInterruption` wiring), add:
     ```swift
     player.onPlaybackStateChanged = { [weak self] isPlaying in
       Task { @MainActor [weak self] in
         self?.handlePlaybackStateChanged(isPlaying: isPlaying)
       }
     }
     ```
   - Add a new `@MainActor` handler (internal, not private, so tests can drive it — mirroring the convention of `handleMetadataChanged`):
     ```swift
     /// Reconcile the observable `playbackState` with an *external* player transition
     /// (e.g. the media3 notification pause on Android). This is the demotion counterpart to
     /// `reconcileWithPlayer()`, which only promotes.
     func handlePlaybackStateChanged(isPlaying: Bool) {
       if isPlaying {
         // Only clear a pending spinner; do not fabricate playback from idle/paused.
         switch playbackState {
         case .loading, .reconnecting:
           playbackState = .playing
           publishPlaybackState(isPlaying: true)
         default:
           break
         }
       } else {
         // External pause/stop. Demote only from active states; never stomp an
         // in-flight reconnection/error cycle (that path owns its own state) or a
         // terminal .idle.
         switch playbackState {
         case .playing, .loading:
           playbackState = .paused
           publishPlaybackState(isPlaying: false)
         default:
           break
         }
       }
     }
     ```
   - Rationale for the `.default: break` guards:
     - Do **not** demote while `.reconnecting`/`.error`: `ReconnectionManager` drives those states via `setupReconnection()` (`RadioPlayerCoordinator.swift:563-582`) and its `onReconnect` closure briefly stops/replays the stream, which will emit `isPlaying=false` transients; demoting there would clobber the reconnection state machine.
     - Do **not** promote from `.idle`/`.paused` on `isPlaying=true` — matches the existing conservative `reconcileWithPlayer()` contract and the `reconcileDoesNotPromoteIdle` test, so a stray media3 "ready" can't fabricate playback the user didn't ask for.
   - The `onInterruption` path (`handleInterruption`, `RadioPlayerCoordinator.swift:595-604`) already sets `.paused` on audio-focus loss; the new handler is idempotent with it (setting `.paused` when already `.paused` is a no-op via the `.default` branch), so the two won't fight.

No other source files change. **No application logic in `ExoPlayerStreamPlayer.swift` needs to change** — it already fires the callback and maintains `player.isPlaying`.

### Note on relationship to other issues
- **#30** ("pause button is a pause, not a stop") concerns whether the *action* should tear the stream down vs. suspend it. This plan does **not** change pause semantics; it only makes the UI reflect the player's real state. Fixing #29-symptom-2 is a prerequisite for #30 being observable but is orthogonal.
- **Symptom 1** of #29 (terminate on notification swipe) is a service-lifecycle question (`Maxi80MediaService.kt` / `onTaskRemoved`) and is explicitly not addressed here.

## 4. Acceptance criteria

Implementable and verifiable without re-investigating:

1. **Wiring exists:** `RadioPlayerCoordinator.setupCallbacks()` assigns `player.onPlaybackStateChanged`.
2. **External pause syncs state:** given `playbackState == .playing`, invoking the coordinator's `handlePlaybackStateChanged(isPlaying: false)` sets `playbackState == .paused` and publishes `isPlaying: false`.
3. **Does not fabricate playback:** given `playbackState == .idle` (or `.paused`), `handlePlaybackStateChanged(isPlaying: true)` leaves state unchanged (consistent with `reconcileDoesNotPromoteIdle`).
4. **Does not fight reconnection:** given `playbackState == .reconnecting(n)` or `.error(...)`, `handlePlaybackStateChanged(isPlaying:)` (either value) leaves the reconnection/error state unchanged.
5. **Clears a pending spinner:** given `playbackState == .loading`, `handlePlaybackStateChanged(isPlaying: true)` sets `.playing` (parity with `reconcileWithPlayer`).
6. **On-device (manual):** repro steps 1–4 above — after pressing pause in the notification, the in-app control shows the paused state within one media3 transition; pressing play in the notification restores the playing state.
7. **No pause-semantics change:** the stream still pauses (not necessarily fully stops) on notification pause — behavior deferred to #30.

### Suggested tests (extend `Tests/Maxi80Tests/ResumeReconciliationTests.swift`, same harness/`makeCoordinator()`)
- `externalPauseDemotesPlayingToPaused`: `play()` → `handleMetadataChanged("Artist - Song")` (→ `.playing`) → `handlePlaybackStateChanged(isPlaying: false)` → expect `.paused`.
- `externalPlayDoesNotPromoteIdle`: from `.idle`, `handlePlaybackStateChanged(isPlaying: true)` → expect `.idle`.
- `externalStateDoesNotOverrideReconnecting`: force `.reconnecting`/`.error` via the reconnection callback → `handlePlaybackStateChanged(isPlaying: false)` → expect the reconnection/error state preserved.
- `externalPlayClearsLoadingSpinner`: `play()` (→ `.loading`) → `handlePlaybackStateChanged(isPlaying: true)` → expect `.playing`.

## 5. Scope & non-goals
- Only symptom 2 (state sync) is planned here.
- No changes to Android service termination / notification-swipe teardown (symptom 1).
- No change to pause-vs-stop semantics (#30).
- No changes to any Kotlin/`ExoPlayerStreamPlayer.swift` playback logic.
