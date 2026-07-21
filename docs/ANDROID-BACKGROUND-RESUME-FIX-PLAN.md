# Android background→foreground resume: UI breakage — root cause & fix plan

**Date:** 2026-07-21
**Status:** investigation complete (Phase 1–2 of systematic-debugging), fixes NOT yet applied
**Trigger:** After the Android app is sent to background and then reactivated — whether by tapping the
new media notification (added today, commit `afed199`) or by tapping the app icon — the phone UI
exhibits four symptoms. Playback audio itself keeps working (foreground service); only the in-app UI
state is wrong.

## Symptoms (as reported)

1. Cover-flow carousel is positioned on the **first (oldest)** entry instead of the **now/live** slot.
2. "Back to live" button is either not visible or does nothing.
3. Title/artist text is **out of sync** with the artwork shown in the carousel.
4. Play/stop button is inoperant, or shows a perpetual spinning wheel.

## Reproduction

Deterministic, every time, on Android only:
- Start playback. Send app to background (Home, or it's backgrounded while the OS later destroys the
  activity). Reactivate via the notification tap **or** the launcher icon.
- Not reproducible on iOS/macOS (different lifecycle + the `#if SKIP` scroll path differs).

---

## Root cause (verified against current code, not guessed)

There is **one underlying condition with two independent failure axes**. The condition:

> The `RadioPlayerCoordinator` and `RadioPlayerViewModel` are **process-wide singletons**
> (`SharedPlayer.swift:12-35`), so all their state (`playbackState`, `currentSong`, `currentArtwork`,
> `selectedCoverID`) **survives** Android activity/composition recreation. But on return from
> background, Android **destroys and recreates `MainActivity`** — `Main.kt:onCreate` runs a fresh
> `setContent { … }` (`Main.kt:64-70`), rebuilding the entire SwiftUI/Compose tree — while the
> singletons carry stale/unsynced state and **nothing re-syncs them on resume.**

The Skip app delegate resume hooks are empty (`Maxi80App.swift:66-72`), and there is **no
`scenePhase`/foreground observer anywhere in `Sources/`** (verified: grep returns none). The only work
a recreation triggers is `Maxi80RootView.body`'s `.task { await coordinator.loadStation() }`
(`Maxi80App.swift:53-55`), and `loadStation()` never touches `playbackState` (`RadioPlayerCoordinator.swift:218-247`).

### Axis A — carousel position, back-to-live, title/artist desync (symptoms 1, 2, 3)

This is the **same class of bug** as the shipped rotation fix (see
`memory/coverflow-rotation-pin-findings.md`), but triggered by a *different* recreation event that the
existing guard does not cover.

- `selectedCoverID` lives in the singleton view model and survives recreation
  (`RadioPlayerViewModel.swift:37`, init to `nowSlotID` at `:267-271`).
- On recreation, `CoverFlowView` is rebuilt. Its fresh `ScrollView` lays out at the **leftmost
  (oldest) cover**, then reports that position back into `selectedCoverID` via the binding's
  `setSelectionFromCarousel` (`RadioPlayerView.swift:143-157`).
- **The write-drop guard `isReorienting` is armed ONLY by `onChange(of: isPortrait)`**
  (`RadioPlayerView.swift:37` → `beginReorientation()`, `RadioPlayerViewModel.swift:193-213`). A
  **background→foreground recreation never fires an orientation change**, so the guard is *closed* and
  the leftmost-cover write **lands**, clobbering the persisted `selectedCoverID`. → **Symptom 1.**
- Once `selectedCoverID` points at an old cover, `isBrowsingHistory` derives from it
  (`RadioPlayerViewModel.swift:165-176`). If that id still matches a `pastEntries` id, the button
  shows but the carousel is on the wrong cover; if the id **no longer matches** (see the id-churn note
  below), `isBrowsingHistory` flips to `false` and the button **vanishes**. → **Symptom 2.**
- Title/artist come from `focusedHistoryEntry` (keyed off `selectedCoverID`,
  `RadioPlayerViewModel.swift:233-258`), while the hero/now-slot artwork comes from
  `coordinator.currentArtwork`. When the clobbered `selectedCoverID` resolves to a history entry but
  the artwork still reflects the live song, **text and artwork describe different songs.** → **Symptom 3.**

  *Id-churn amplifier:* `HistoryEntry.id = "\(timestamp)|\(artist)|\(title)"` (`HistoryEntry.swift:29`).
  Resuming playback re-enters `play()` → `refreshHistoryIfStale()` → `fetchHistory()`, which reconciles
  by song *identity* and **re-sorts** (`RadioPlayerCoordinator.swift:600-653`). A browsed entry can get
  a different `id`, so a previously-valid `selectedCoverID` stops matching — flipping `isBrowsingHistory`
  and desyncing focus.

> Note on `#if SKIP` (from `memory/coverflow-rotation-pin-findings.md`): `Maxi80` is Skip **Fuse
> (native)** mode, so on the real Android device `#if SKIP` is **NOT defined** — the `#else`
> `onPreferenceChange`/`CenteredCoverKey` branch (`CoverFlowView.swift:89-97`) is what actually
> compiles and runs. Either branch writes back through the same guarded setter, so the root cause is
> identical; but any Android-behavior change **must** use `#if os(Android)`, never `#if SKIP`, and be
> verified in the `.so` (`strings libMaxi80.so | grep <marker>`).

### Axis B — play/stop button spinner / inoperant (symptom 4)

- The button's look **and** action derive solely from `coordinator.playbackState` via `isLoading` /
  `isPlaying` (`RadioPlayerViewModel.swift:43-55`; action `togglePlayback()` `:284-290`).
- `playbackState` leaves `.loading` and becomes `.playing` in **exactly one place**:
  `handleMetadataChanged` when an ICY metadata event arrives (`RadioPlayerCoordinator.swift:290-297`).
- The player's real playing state (`onPlaybackStateChanged` / `onIsPlayingChanged`, emitted by every
  platform incl. `ExoPlayerStreamPlayer.swift:50-62`) is **declared on `AudioStreamPlayer`
  (`:28`) but NEVER assigned by the coordinator** — `setupCallbacks()` wires `onMetadataChanged`,
  `onError`, `onInterruption`, `onVolumeChanged`, `onRemoteCommand`, but **not**
  `onPlaybackStateChanged` (`RadioPlayerCoordinator.swift:251-284`, verified: no assignment exists in
  `Sources/Maxi80/`). So all real-state signals hit `onPlaybackStateChanged?(...)` → nil → discarded.
- On resume the ExoPlayer is **already playing** in the foreground service; no new `prepare()` happens
  and **no fresh ICY metadata event necessarily arrives** — so the sole `.loading → .playing` promoter
  may never fire. If any resume path (or a stale pre-background state) leaves `playbackState == .loading`,
  the button **spins forever**, and because `togglePlayback()` treats `isLoading` as "active" it calls
  `pause()` on tap — so the control feels **inoperant**. → **Symptom 4.**
- Compounding: notification/lock-screen play-pause is handled by media3's `MediaLibrarySession` on the
  shared ExoPlayer directly (`Maxi80MediaService.kt`), and `AndroidNowPlayingController.handleRemoteCommand`
  has no Android caller — so notification transport controls move the player **without informing
  `coordinator.playbackState`**. The coordinator's state can therefore be arbitrarily stale vs reality
  after any notification interaction.

**Common denominator:** the coordinator's observable state is **never reconciled with ground truth
(the live ExoPlayer + the true now-playing cover) on foreground.** The rotation fix solved this for the
*orientation* recreation only; the *background* recreation is an uncovered instance of the same gap.

---

## Fix plan

Guiding principle (matches the shipped rotation fix and `memory/coverflow-rotation-pin-findings.md`):
**cross-recreation state and reconciliation must live in the persistent view model / coordinator, not
in view-local `@State`; and it must be verified on-device in the real `.so`, on both build paths.**

Two changes, addressing the two axes. Do them one at a time (systematic-debugging Phase 4: one fix,
verify, then the next).

### Fix 1 (Axis B — playback state reconciliation): wire `onPlaybackStateChanged` + reconcile on foreground

The durable fix is to stop treating "metadata arrived" as the only proof of playing.

1. **Wire the dropped callback.** In `RadioPlayerCoordinator.setupCallbacks()`
   (`RadioPlayerCoordinator.swift:251-284`), assign `player.onPlaybackStateChanged`:
   - When it reports `true` (STATE_READY / isPlaying) and current `playbackState` is `.loading` /
     `.reconnecting` → promote to `.playing`.
   - When it reports `false` while we believe we're `.playing` and the user didn't pause → treat per
     existing interruption/reconnection policy (do **not** naively flip to `.paused`; a transient
     buffering blip shouldn't stop the UI). Keep this conservative to avoid regressing reconnection.
   - Hop to `@MainActor` like the other callbacks.
2. **Add a foreground reconcile.** Introduce a single `coordinator.reconcileWithPlayer()` (name TBD)
   that reads the player's real state (`AudioStreamPlayer` already exposes `isPlaying`,
   `AudioStreamPlayer.swift:15`; add a lightweight "current playback state" query if `isPlaying` alone
   is insufficient — e.g. distinguish buffering) and sets `playbackState` to match ground truth, then
   `republishNowPlaying()`. Call it from a **foreground hook** (see Fix 3).

### Fix 2 (Axis A — carousel/selection): guard the selection write-back on recreation, not just rotation

Generalize the existing `isReorienting` write-drop window so it also covers a background→foreground
recreation (which recreates `CoverFlowView` exactly like rotation does).

Options (pick during implementation; prefer the smallest that verifies on-device):

- **2a (preferred, minimal):** Rename/repurpose the guard to a general "carousel is recreating" window
  and **arm it on foreground**, not only on `onChange(of: isPortrait)`. The foreground hook (Fix 3)
  calls `beginReorientation()`-equivalent so the recreated carousel's transient leftmost-cover
  write-back is dropped, preserving the persisted `selectedCoverID`. Keep the 700 ms auto-clear.
- **2b (belt-and-suspenders):** On foreground reconcile, **re-assert** `selectedCoverID` to the correct
  target (the now slot unless a *valid, still-present* history id was being browsed) and bump
  `coverPinToken` so the re-pin `.task` re-centers. This also repairs the id-churn case where the
  browsed id no longer matches after `fetchHistory()` re-sort.
- Do **not** attempt scroll-manipulation inside the view — `memory/coverflow-rotation-pin-findings.md`
  proves every scrollTo/selection-write lever loses to Compose's authoritative reset. The lever that
  works is the persistent-target + `pinToken`-keyed re-pin `.task`, which is already in place.
- Use `#if os(Android)` for any Android-specific behavior (NOT `#if SKIP`).

### Fix 3 (the missing seam): add a real foreground hook

Today the resume hooks are empty and no `scenePhase` observer exists. Add one seam that both fixes hang
off:

- **Preferred:** implement `Maxi80AppDelegate.onResume()` (already bridged and called from
  `MainActivity.onResume` → `AppDelegate.shared.onResume()`, `Main.kt:96-99`) to invoke
  `SharedPlayer.coordinator.reconcileWithPlayer()` and arm the carousel guard. Because `onResume` is a
  bridged `Sendable` with no coordinator reference today, route it through `SharedPlayer` (MainActor).
- **Cross-platform alternative:** add `.onChange(of: scenePhase)` in `Maxi80RootView`/`RadioPlayerView`
  to call the same reconcile on `.active`. Verify Skip supports `scenePhase` on Android (it may not —
  `memory/skip-swiftui-android-api-gaps.md`); if not, use the `onResume` delegate path for Android and
  `scenePhase` for Apple. **Confirm before relying on it.**

---

## Test plan (write failing tests FIRST — systematic-debugging Phase 4.1)

Native Swift tests (run via `make test`, they gate release):

1. **Playback reconcile:** given `playbackState == .loading` and the player reports `isPlaying == true`,
   `reconcileWithPlayer()` sets `.playing`. Given player not playing, stays consistent. (New
   `ResumeReconciliationTests`.)
2. **`onPlaybackStateChanged` wiring:** driving the player's state callback promotes `.loading →
   .playing` (mirrors existing `AudioFocusInterruptionTests` style).
3. **Selection preserved across a simulated recreation:** with the guard armed (foreground window
   open), a `setSelectionFromCarousel(oldestCover)` write is **dropped**, so `selectedCoverID` keeps
   its prior value → `isBrowsingHistory` / `pinTarget` unchanged.
4. **Id-churn:** after a `fetchHistory()` re-sort changes a browsed entry's id, the reconcile re-asserts
   a valid `selectedCoverID` (now slot) rather than leaving a dangling id.

These are logic tests on the singletons — no emulator needed and they reproduce the bug without a
device (the device is for final verification only).

## On-device verification (Phase 4.3 — REQUIRED before claiming fixed)

Per `memory/coverflow-rotation-pin-findings.md` gotchas:
- Build BOTH paths: `skip android build` **and** (from `Android/`) `gradle :app:compileDebugKotlin`.
  If daemons/stale artifacts bite, `make clean && make build-android` (hardened clean drains daemons).
- Install on the **phone** AVD (`Medium_Phone_API_36.1`), package `com.stormacq.android.maxi80`;
  target adb explicitly (env auto-launches TV/Car AVDs).
- Reproduce: play → background → reactivate via **notification** and via **icon**. Confirm all four
  symptoms are gone. Instrument with `Logger` at `.error` level (Android drops `.info`; drop the
  `privacy:` arg) if needed.
- Verify any Android-gated marker is actually in the packaged `.so`
  (`strings …/libMaxi80.so | grep <marker>`), and that `skip app launch` didn't serve a stale APK.

## Risks / watch-outs

- Do **not** naively map every `onPlaybackStateChanged(false)` to `.paused` — it will regress the
  reconnection/interruption state machine (`ReconnectionManager`, `handleInterruption`). Keep Fix 1
  conservative and lean on the existing policy.
- The notification transport controls bypass the coordinator entirely (media3 → ExoPlayer). A full fix
  for *state* correctness may also want to observe the MediaSession, but the foreground reconcile
  (Fix 3) is sufficient for the reported symptoms — reconciling on every foreground catches whatever
  the notification did while backgrounded. Broader MediaSession observation is a possible follow-up,
  not part of this fix.
- Keep changes minimal and in the persistent layer; resist rewriting `CoverFlowView` (the rotation
  saga proved the ComposeView rewrite was an overreach).

## Files in scope

- `Sources/Maxi80/RadioPlayerCoordinator.swift` — `setupCallbacks()`, new `reconcileWithPlayer()`.
- `Sources/Maxi80/RadioPlayerViewModel.swift` — generalize `isReorienting`/`beginReorientation` into a
  recreation guard; possibly re-assert `selectedCoverID`.
- `Sources/Maxi80/RadioPlayerView.swift` — arm the guard on foreground (not only `isPortrait`).
- `Sources/Maxi80/Maxi80App.swift` — implement `Maxi80AppDelegate.onResume()` and/or `scenePhase`.
- `Sources/Maxi80/SharedPlayer.swift` — expose a MainActor entry point for the resume hook if needed.
- `Sources/Maxi80Services/AudioStreamPlayer.swift` — possibly a "current state" query beyond `isPlaying`.
- Tests: new `ResumeReconciliationTests` (+ extend selection tests).

## What was verified during investigation (evidence, not assumption)

- No `scenePhase`/foreground observer exists in `Sources/` (grep: none).
- `onPlaybackStateChanged` is emitted by all platform players but assigned nowhere in `Sources/Maxi80/`.
- `setupCallbacks()` wires 5 callbacks, not `onPlaybackStateChanged`.
- `.loading → .playing` occurs only in `handleMetadataChanged`.
- `isReorienting` is armed only by `onChange(of: isPortrait)`; `setSelectionFromCarousel` drops writes
  only while it's set.
- Coordinator/VM are `static let` singletons; `Maxi80RootView.init` re-resolves them on each recreation;
  `MainActivity.onCreate` runs a fresh `setContent` each time.
</content>
</invoke>
