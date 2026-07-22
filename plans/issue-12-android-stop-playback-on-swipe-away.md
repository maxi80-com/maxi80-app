# Plan — Issue #12: Android: playback continues after swiping the app away

- **Issue:** [#12](https://github.com/maxi80-com/maxi80-app/issues/12) — "Android: playback continues after swiping the app away"
- **Triage:** `bug` (Android-only; unresolved on `main` at the current HEAD of this run)
- **Platform:** Android only (no Apple-side change)
- **In-flight work:** PR **#14** (`worktree-android-stop-on-task-removed`) is **open, not merged**, and implements exactly the approach below. This plan is derived independently from the code at HEAD and can double as the review checklist for that PR (or a fresh implementation if #14 is abandoned).

---

## 1. Reproduce

- **Platform:** Android phone/tablet (any API level that runs the app; the media notification + `POST_NOTIFICATIONS` behavior is most visible on API 33+).
- **Steps:**
  1. Launch the app and tap Play — audio streams and the Maxi 80 media notification appears.
  2. Swipe the app out of the recents / task switcher.
  3. **Observed:** audio keeps streaming and the media notification lingers.
  4. **Expected:** audio stops and the notification disappears.
- **Apple platforms are unaffected:** iOS/tvOS/macOS use `AVPlayer` and do not run a Media3 foreground service, so this reproduction is Android-specific.

## 2. Root cause (verified against code at HEAD)

Playback on Android is owned by a **Media3 foreground service that runs in the same process as the UI**, and nothing tears the shared player down on task removal:

1. `Maxi80MediaService` extends `MediaLibraryService()` (a `MediaSessionService`) and hosts the app's single session on the process-global shared ExoPlayer.
   - `Sources/Maxi80Services/Skip/Maxi80MediaService.kt:30` — `class Maxi80MediaService : MediaLibraryService()`.
   - At HEAD there is **no `onTaskRemoved` override** in this file (only `onCreate`, `onGetSession`, `onDestroy`). It therefore inherits Media3's default `MediaSessionService.onTaskRemoved(Intent)` behavior: **when the player is in an ongoing-playback state (`playWhenReady == true`, non-empty media items, not `STATE_IDLE`/`STATE_ENDED`) the service keeps running so playback continues; otherwise it calls `stopSelf()`.** Because the user is actively playing at swipe time, the default keeps the service — and thus audio — alive. (Media3 `1.9.4`, pinned in `Sources/Maxi80Services/Skip/skip.yml:8`.)

2. The service runs in the **same process** as the Activity — the `<service>` declaration has **no `android:process`** attribute.
   - `Android/app/src/main/AndroidManifest.xml:55-64`.
   - Swipe-away removes the task/Activity, but a running foreground service keeps the **process** alive, so the shared ExoPlayer keeps streaming.

3. The shared player is a **process singleton that is never released except on process death**, and the process survives swipe-away (see #2).
   - It is started/kept alive via `ctx.startForegroundService(...)` on every play: `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift:168-173`.
   - `androidStop()` only `stop()`s + `clearMediaItems()` and explicitly keeps the player and service alive: `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift:176-187`.
   - `Maxi80MediaService.onDestroy()` deliberately releases **only the session, never the player** (to avoid the pause-time double-stream bug from commit `3c39698`): `Sources/Maxi80Services/Skip/Maxi80MediaService.kt:251-262`.
   - `NowPlayingController.platformTearDown()` is a no-op: `Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift:64-66`.
   - `SharedAudioPlayer.releaseShared()` exists but is **never called anywhere in production** — grep shows it only appears in comments and its own definition: `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift:39-43`. (The comment at `AndroidNowPlayingController.swift:62-63` claiming the player is released in the service is **stale/incorrect** — `onDestroy` does not call it.)

**Conclusion:** On swipe-away the task is removed, but (a) the default `onTaskRemoved` keeps the foreground service running because playback is ongoing, (b) the shared process therefore stays alive, and (c) no code path releases the shared ExoPlayer, so audio keeps streaming and the notification lingers. This matches the issue's proposed root cause — **verified**. The crash path is fine (a crash kills the shared process and audio stops with it); the fix must not introduce auto-restart.

## 3. Assessment of the issue's proposed fix — agree in direction, **incomplete** as written

The issue proposes a single change: override `onTaskRemoved(rootIntent:)` to stop + release the shared ExoPlayer and `stopSelf()`, "does not touch the pause path or `onDestroy`." The **seam and intent are correct**, but two refinements are required because of details in this codebase:

1. **Release order (correctness/crash-safety).** The issue's wording ("release the shared ExoPlayer, `stopSelf()` … releases the session … via `onDestroy`") releases the **player before** the session, with the session's `release()` happening later in the async `stopSelf()` → `onDestroy` window. During that window the live session would wrap an already-released ExoPlayer; any controller/system access forwards to a released player and can crash. **Release the session first, then the player.**

2. **The "single change, pause path untouched" framing is insufficient.** `SharedPlayer` builds the coordinator and `AudioStreamPlayer` as **process-wide singletons that survive Android Activity recreation** (`Sources/Maxi80/SharedPlayer.swift:4-45`, issue #9). Android does **not** guarantee the process dies immediately after `stopSelf()`; it can linger as a cached process. If the user relaunches while the process is still alive, the surviving `AudioStreamPlayer` singleton still holds a stale `_metadataListener` and `_exoPlayer` pointing at the **released** player, producing two regressions the naive fix would ship:
   - **Relaunch → play stalls in `.loading`.** `androidPlay` re-attaches the metadata listener only `if _metadataListener == nil` (`ExoPlayerStreamPlayer.swift:148-152`). After `releaseShared()` rebuilds a fresh ExoPlayer, `_metadataListener` is still non-nil, so the listener is never attached to the new player → no ICY metadata → the spinner never clears. (The comment at lines 144-147 already anticipates this hazard.)
   - **`androidStop()` crashes on a released player.** `androidStop` calls `_exoPlayer?.stop()` unconditionally (`ExoPlayerStreamPlayer.swift:183-184`); on a released instance this throws "sending message to a Handler on a dead thread."

   Therefore the fix needs **companion changes** in `ExoPlayerStreamPlayer.swift` and `SharedAudioPlayer.swift` so the surviving singleton reconciles against a torn-down/rebuilt shared player by **identity**.

PR #14 already implements exactly these three changes, which independently corroborates this analysis.

## 4. Changes to make

> Only Android-specific code changes; do **not** touch Apple paths, `onDestroy`, or the pause semantics beyond the identity guard below.

### Change 1 — `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` (raw Kotlin)
- Add `import android.content.Intent`.
- Add an `onTaskRemoved` override that fully tears down playback and the notification, releasing the **session before** the player:

```kotlin
override fun onTaskRemoved(rootIntent: Intent?) {
    // The user swiped the app away (task removed). Unlike onDestroy — which media3 also invokes
    // on every pause — this fires ONLY on genuine task removal, so a full teardown here is safe
    // and does NOT affect the pause/resume path.
    //
    // Order matters: release the SESSION first, then the shared ExoPlayer. The session wraps the
    // player; releasing the player first would leave the live session pointing at a released
    // player during the async stopSelf() -> onDestroy window, where controller/system access
    // would crash. Releasing the session here also makes onDestroy's session?.release() a no-op.
    session?.release()
    session = null
    SharedAudioPlayer.releaseShared()
    stopSelf()                       // -> onDestroy drops the foreground notification
    super.onTaskRemoved(rootIntent)
}
```
- **Do not modify `onDestroy()`** — it must keep releasing only the session so the pause path never tears down the player (double-stream regression, commit `3c39698`).
- `SharedAudioPlayer.releaseShared()` is reachable here: same `maxi80.services` package, and `onCreate()` already calls `SharedAudioPlayer.shared(...)` (`Maxi80MediaService.kt:196`).

### Change 2 — `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift`
- Add a non-creating accessor so callers can identity-check the live player without lazily rebuilding one:

```swift
/// The current shared player WITHOUT creating one — `nil` after `releaseShared()` until the
/// next `shared()` rebuild. Lets callers detect a torn-down/rebuilt player and drop stale
/// references to a released instance (see AudioStreamPlayer.androidPlay/androidStop).
static var current: ExoPlayer? { player }
```

### Change 3 — `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`
- **In `androidPlay(url:)`** — after `let exoPlayer = SharedAudioPlayer.shared(context: ctx)` and **before** `self._exoPlayer = exoPlayer`, drop a stale listener when the shared player was rebuilt (identity mismatch), so the `_metadataListener == nil` guard re-attaches to the fresh player:

```swift
// If the shared player was torn down (releaseShared() from the service's onTaskRemoved) the
// process can survive with our cached _exoPlayer/_metadataListener pointing at the RELEASED
// instance while shared() above just rebuilt a fresh one. Detect by IDENTITY (not nil — current
// is non-nil again after the rebuild): if our cache isn't the live player, our listener was
// attached to the old player, so drop it. Otherwise the `_metadataListener == nil` guard below
// stays false and we never re-attach to the new player, stalling the coordinator in `.loading`.
if _exoPlayer !== exoPlayer {
  _metadataListener = nil
}
```

- **In `androidStop()`** — only `stop()`/`clearMediaItems()` when the cached `_exoPlayer` is still the live shared player (identity match against `SharedAudioPlayer.current`); otherwise drop the stale references and just reconcile local state, avoiding the dead-Looper crash:

```swift
if let cached = _exoPlayer, cached === SharedAudioPlayer.current {
  cached.stop()
  cached.clearMediaItems()
} else {
  _exoPlayer = nil
  _metadataListener = nil
}
isPlaying = false
onPlaybackStateChanged?(false)
```

## 5. Scope boundaries (explicitly NOT doing)
- **No `android:process` split** — keeping the service in the app process preserves the desirable "crash kills audio" behavior.
- **No change to `onDestroy()`, the pause path, or `androidStop()` semantics** beyond the identity guard needed for the released-player edge case.
- **No new in-app "quit"/"exit" button** — swipe-away is the user action being fixed.
- **No Android Auto special-casing** (no "keep alive while a car controller is connected"); the app streams one station and full teardown on swipe-away is the intended behavior.
- **No auto-restart:** the service must not become `START_STICKY`-resurrecting after `stopSelf()`.

## 6. Acceptance criteria

### Manual, on-device / emulator (primary — see testability note)
1. **Baseline:** Play → audio streams and the media notification is present.
2. **Swipe-away stops everything:** Swipe the app from recents → audio stops (within ~1s) **and** the media notification disappears.
3. **Relaunch works:** Relaunch the app and tap Play → audio starts and reconnects to the **live edge**; the loading spinner clears (no permanent `.loading`). *Validates Change 3 `androidPlay`.*
4. **Pause/resume unaffected:** From the notification, pause then resume → single clean audio stream, no double audio. *Validates that `onDestroy`/pause path is untouched.*
5. **Pause-then-swipe is crash-free:** Pause (do not swipe), then swipe the app away, then relaunch and Play → no crash ("dead thread" / released-player) and playback resumes normally. *Validates Change 3 `androidStop` identity guard.*
6. **No resurrection:** After swipe-away, audio does not restart on its own and no lingering notification remains; the service/process do not auto-restart playback.

### Build / automated
- `skip android build` compiles cleanly, including the new `onTaskRemoved` override in the raw `.kt` file.
- `swift build` and `swift test` remain green; `skip test` (Robolectric) still passes — no regressions in existing suites (`AudioFocusInterruptionTests`, `ResumeReconciliationTests`, `VolumeSyncTests`, etc.).

### Testability note
The teardown → rebuild path requires a **real Android `Context` and a live ExoPlayer**, which the host `swift test` suite does not exercise (existing Android tests construct `AudioStreamPlayer()` and drive callbacks, but never call `androidPlay`/`androidStop` against a real player). So criteria 2–6 are verified on device/emulator. If the `skip test` (Robolectric) harness can construct the shared player, optionally add a regression test asserting that after `SharedAudioPlayer.releaseShared()` a subsequent `shared()` returns a **new instance** and that an identity-mismatched cached player is treated as stale — but do not block the fix on host-side coverage that the transpiled runtime cannot support.

## 7. Files to change (summary)
| File | Change |
|------|--------|
| `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` | Add `import android.content.Intent`; add `onTaskRemoved` override (release session → release shared player → `stopSelf()` → super). Do **not** change `onDestroy`. |
| `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift` | Add `static var current: ExoPlayer? { player }` (non-creating accessor). |
| `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` | `androidPlay`: drop stale `_metadataListener` on shared-player identity mismatch. `androidStop`: gate `stop()`/`clearMediaItems()` on identity match with `SharedAudioPlayer.current`, else drop stale refs. |

No changes to Apple platform code, `AndroidManifest.xml`, or `onDestroy()`.
