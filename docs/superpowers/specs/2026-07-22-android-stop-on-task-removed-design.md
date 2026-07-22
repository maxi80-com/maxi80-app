# Android: stop playback when the app is swiped away

**Date:** 2026-07-22
**Status:** Implemented (PR #14)
**Platform:** Android only

## Problem

On Android, killing the app (swiping it out of the recents/task switcher) does not
stop the music. Audio keeps playing and the media notification lingers, because
playback is owned by a foreground service, not the app UI.

## Root cause

`Maxi80MediaService` (`Sources/Maxi80Services/Skip/Maxi80MediaService.kt`) is a Media3
`MediaLibraryService` running as a foreground service in the **same process** as the app
(there is no `android:process` attribute on the `<service>` in
`Android/app/src/main/AndroidManifest.xml`).

When the user swipes the app away, Android removes the **task/Activity** but the
foreground service keeps the **process** alive, so the shared `ExoPlayer` keeps
streaming. The service does **not** override `onTaskRemoved`, so it inherits Media3's
default behavior: keep the service running while `playWhenReady` is `true`. That default
is what causes audio to survive task removal.

### Crash path (already fine)

Because the service shares the app's process, an uncaught crash kills the process and
audio stops on its own. The only requirement here is that we do **not** introduce
auto-restart behavior that would resurrect playback after a crash. Media3 leaves the
service in a stoppable state after `stopSelf()`, so no `START_STICKY` resurrection is
expected — to be confirmed on device.

## Decision

Swiping the app away should **stop playback fully and remove the notification**: stop
ExoPlayer, release the shared player, tear down the foreground service, and clear the
lock-screen/notification card. (Chosen over a "keep alive when Android Auto is connected"
variant — that added complexity is not warranted for this app's usage.)

## Design

A single change at the canonical Media3 seam: override `onTaskRemoved(rootIntent:)` in
`Maxi80MediaService.kt`.

```kotlin
override fun onTaskRemoved(rootIntent: Intent?) {
    // The user swiped the app away. Unlike onDestroy (which media3 also calls on every
    // pause), this fires ONLY on genuine task removal, so a full teardown here is safe
    // and does not affect the pause path.
    val player = SharedAudioPlayer.shared(applicationContext)
    player.stop()
    player.clearMediaItems()
    SharedAudioPlayer.releaseShared()
    stopSelf()                  // → onDestroy releases the session and drops the notification
    super.onTaskRemoved(rootIntent)
}
```

### Why this shape

- **`onTaskRemoved`, not `onDestroy`.** The existing `onDestroy` (lines ~251–262)
  deliberately releases *only* the session and never the shared player, because media3
  destroys the service on every pause and releasing the player there would cause
  overlapping-stream artifacts on the next play. `onTaskRemoved` fires only on real task
  removal, so releasing the player there is both safe and exactly the intent. This change
  does **not** touch `onDestroy`, `androidStop`, or the pause path.
- **`SharedAudioPlayer.releaseShared()` is reachable from the service** — same
  `maxi80.services` package; `onCreate` already calls `SharedAudioPlayer.shared(...)`.
- **`stopSelf()` → `onDestroy` → `session.release()`** clears the media notification,
  satisfying "remove notification."
- **No native-side reconciliation needed.** Task removal tears down the process, so the
  native `@Observable` coordinator/view-model singletons die with it.

## Scope boundaries (explicitly NOT doing)

- No `android:process` split — keeps the desirable "crash kills audio" behavior.
- No change to `androidStop()`, the pause path, or `onDestroy()`.
- No new in-app "quit"/"exit" button — swipe-away is the user action.
- No Android Auto special-casing.

## Verification

Android-only Kotlin lifecycle. The project's Robolectric/Gradle test harness is known to
be broken for environmental reasons (see memory `skip-android-test-harness-broken`), so
verification is **manual on emulator/device**:

1. Launch the app, start playback.
2. Confirm audio plays and the media notification is present.
3. Swipe the app out of the recents/task switcher.
4. **Expect:** audio stops immediately and the notification disappears.
5. Relaunch the app from the launcher.
6. **Expect:** normal cold-start; play works and reconnects to the live edge.
7. Confirm the pause path is unaffected: pause from the notification, then resume — no
   double audio, no artifacts.

## References

- `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` — service to modify
- `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift` — `releaseShared()`
- `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` — `androidStop()`,
  service start
- `Android/app/src/main/AndroidManifest.xml` — service declaration (same-process)
