# Plan: Android — STOP audio on Bluetooth/headset disconnect to match Apple HIG (#30)

> **Supersedes PR #33.** The reporter changed their mind. PR #33's plan (remove
> `setHandleAudioBecomingNoisy(true)` so Android keeps playing on the phone speaker) is the
> **opposite** of the now-desired behavior and should be closed by a maintainer. This plan keeps
> disconnect-pauses behavior and makes it a *true stop* on Android so it matches iOS.

## Triage

**Decision: bug** (Android platform-specific).

**Justification from the issue.** #30 is labeled `bug` + `Android`. Its Bluetooth sub-symptom:
*"pause by quitting the bluetooth streaming (in a car for example): the stream pause (not
stopped). Play again will resume where it was paused [NOT OK]."* The reporter's updated
direction: on Apple, BT disconnect **stops** audio (Apple HIG); make Android behave the same.

**Confirmation of the Apple HIG point (requested).** ✅ Confirmed in code. iOS registers for
`AVAudioSession.routeChangeNotification` and, in
`AVPlayerStreamPlayer.handleRouteChange(reason:)`
(`Sources/Maxi80Services/Platform/iOS/AVPlayerStreamPlayer.swift`, `case .oldDeviceUnavailable`),
pauses playback — the code comment reads *"Headphones/Bluetooth disconnected — pause playback per
Apple guidelines."* This matches Apple's documented behavior for
`AVAudioSession.RouteChangeReason.oldDeviceUnavailable`: pause; do **not** auto-reroute to the
built-in speaker. So the *intent* (stop on disconnect) is already correct on both platforms — the
Android defect is that the stop is a **soft pause that retains the buffer**, not a true stop.

**Justification from the code.** On Android, disconnect already pauses (via
`setHandleAudioBecomingNoisy(true)`), but the interruption path drives only
`playbackState = .paused` without releasing the stream, so the next play resumes a **stale
buffer** instead of reconnecting to the live edge. That is the "resume where it was paused"
symptom the reporter flagged as NOT OK.

## Root cause (named at file/function level)

1. **`SharedAudioPlayer.shared(context:)`** —
   `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift`.
   The shared `ExoPlayer` is built with `.setHandleAudioBecomingNoisy(true)`. On BT/wired
   disconnect media3 receives `ACTION_AUDIO_BECOMING_NOISY` and sets `playWhenReady = false`
   (pause). **This is desired and stays** — it is what makes disconnect stop audio, matching iOS.

2. **`MetadataPlayerListener.onPlayWhenReadyChanged(playWhenReady:reason:)`** —
   `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` (~L64–71).
   On `reason == PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY` it fires
   `onInterruption?(true)` (same branch as `AUDIO_FOCUS_LOSS`). This currently routes the
   disconnect into the *interruption* path rather than the *stop* path.

3. **`RadioPlayerCoordinator.handleInterruption(began:)`** —
   `Sources/Maxi80/RadioPlayerCoordinator.swift` (~L595).
   `began == true` sets `playbackState = .paused` and `publishPlaybackState(isPlaying: false)`
   **but never calls `player.stop()`**. Contrast with the user-initiated
   **`RadioPlayerCoordinator.pause()`** (~L170), which calls `reconnectionManager.cancel()` then
   `player.stop()` → Android `ExoPlayerStreamPlayer.androidStop()` (~L184) →
   `MediaControllerHolder.stop()` = `stop() + clearMediaItems()`, releasing the buffer, dropping
   ExoPlayer to `STATE_IDLE`, removing the foreground notification, and abandoning audio focus.

**Confirmed flow (defect):** BT disconnect → `ACTION_AUDIO_BECOMING_NOISY` → media3
`playWhenReady=false` → `onPlayWhenReadyChanged` (reason = AUDIO_BECOMING_NOISY) →
`onInterruption?(true)` → `handleInterruption(began: true)` → `.paused` with **buffer retained** →
next play resumes stale position instead of live edge.

## Approach

Desired behavior: **on Bluetooth/wired disconnect, truly STOP the live stream on Android** (same
semantics as the pause button and as iOS), so the next play reconnects to the live edge. The
distinction that matters is *permanent output loss (becoming noisy)* vs *transient audio-focus
loss (phone call)*: the former should **stop**; the latter must remain a resumable interruption.

### Change 1 — distinguish "becoming noisy" from focus loss in the Android listener
File: `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`,
`MetadataPlayerListener.onPlayWhenReadyChanged` (~L64–71).

- Split the current combined condition. Keep
  `PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS` on the existing interruption path
  (`onInterruption?(true)` → resumable).
- For `PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY`, instead of firing
  `onInterruption?(true)`, invoke a **stop** callback that maps to the coordinator's true-stop
  path. Concretely, add/route to a new closure (e.g. `onDisconnectStop?()`) that the coordinator
  wires to `stop()` semantics (see Change 2). Keep setting `isPlaying = false` and
  `onPlaybackStateChanged?(false)` so the observable state is correct.

  > `setHandleAudioBecomingNoisy(true)` in `SharedAudioPlayer.shared` is **unchanged** — it is
  > what pauses media3 on disconnect and matches iOS. We only change what the app does *in
  > response*: promote it from a soft pause to a true stop.

### Change 2 — route disconnect to a true stop in the coordinator
File: `Sources/Maxi80/RadioPlayerCoordinator.swift` (callback wiring near L314; interruption
handling ~L595).

- Add wiring for the new disconnect callback from Change 1. On disconnect, perform the same
  work as user `pause()` (~L170): `reconnectionManager.cancel()`, `player.stop()`,
  `playbackState = .paused`, `publishPlaybackState(isPlaying: false)`. Factor a small private
  helper (e.g. `stopForDisconnect()`) so `pause()` and the disconnect path share the true-stop
  logic without duplicating it.
- Do **not** alter `handleInterruption(began:)` behavior for genuine (focus-loss / phone-call)
  interruptions — those must still pause-and-resume via the `.ended` / `shouldResume` path.

This yields: disconnect → `androidStop()` → `stop() + clearMediaItems()` → `STATE_IDLE`, buffer
released → next play reconnects to the live edge. Matches iOS intent and the pause-button
semantics the reporter already confirmed as OK.

### iOS scope note (verify only; likely no change)
`AVPlayerStreamPlayer.handleRouteChange(.oldDeviceUnavailable)` already pauses per Apple HIG.
On iOS the buffer question is moot for a live HLS/stream in the same way, but during
implementation verify that after a disconnect-pause the next `play()` reconnects to the live edge
(coordinator `pause()`/`play()` already call `player.stop()` on user pause). If iOS disconnect is
found to resume a stale position, apply the same true-stop routing in `handleRouteChange`; do not
change iOS otherwise. #30 is Android-scoped.

## Files to change
- `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` — split
  `AUDIO_BECOMING_NOISY` out of the focus-loss interruption branch; route it to a true-stop
  callback.
- `Sources/Maxi80/RadioPlayerCoordinator.swift` — add disconnect→true-stop wiring and a shared
  `stopForDisconnect()`/`pause()` helper.

No change to `SharedAudioPlayer.swift` (keep `setHandleAudioBecomingNoisy(true)`), no change to
`Maxi80MediaService.kt`, no model changes.

## Acceptance criteria
1. **Manual (Bluetooth):** Play over a Bluetooth speaker/headset, then disconnect (power off /
   walk out of range / turn off BT). **Expected:** audio **stops** (does not continue on the phone
   speaker); the app shows the stopped/paused state (play button visible); foreground notification
   is removed as in a normal stop.
2. **Manual (wired):** Unplug wired headphones while playing → audio stops (same as #1).
3. **Live-edge on resume (the #30 NOT-OK symptom):** After a disconnect-stop, press play →
   playback **reconnects to the live edge**, not the position where it stopped.
4. **Regression — real interruption still pauses/resumes:** Incoming phone call (transient focus
   loss) pauses and, on call end with `shouldResume`, resumes — unchanged
   (`onPlaybackSuppressionReasonChanged` transient path and `AUDIO_FOCUS_LOSS` path untouched).
5. **Regression — user stop still stops:** In-app / notification pause still truly stops and
   reconnects to live edge on next play — unchanged.
6. **Parity:** Android disconnect behavior now matches iOS `handleRouteChange`.

## Out of scope (tracked elsewhere)
- Notification pause state not reflected in the app / swipe-to-dismiss lifecycle → issue #29.
- Duplicate history entries → issue #28.

## Maintainer action outside this PR
- **Close PR #33** (branch `plans/issue-30`): its plan (continue on phone speaker) is superseded
  by this one. Not closed here per hard rules — flagged for human action.
