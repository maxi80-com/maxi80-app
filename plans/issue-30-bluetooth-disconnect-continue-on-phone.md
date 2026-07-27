# Plan: Android — Bluetooth disconnect should continue audio on the phone (#30)

## Triage

**Decision: bug** (Android platform-specific).

Justification from the issue: Issue #30 is labeled `bug` + `Android`. Its Bluetooth
sub-symptom states: *"pause by quitting the bluetooth streaming (in a car for example):
the stream pause (not stopped). Play again will resume where it was paused [NOT OK].
Expected behaviour is that the audio must be transferred back to the phone. The user
decides to stop or not."*

Justification from the code: the Android ExoPlayer is deliberately configured to pause on
output loss, which is exactly the observed behavior (see root cause). The other two
sub-symptoms in #30 (notification pause not reported back to the app) overlap with #29 and
are out of scope for this plan; this plan covers **only** the Bluetooth-disconnect axis the
user asked about.

## Root cause (named at file/function level)

1. **`SharedAudioPlayer.shared(context:)`** —
   `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift`.
   The single shared `ExoPlayer` is built with `.setHandleAudioBecomingNoisy(true)`.
   media3 then intercepts the system `ACTION_AUDIO_BECOMING_NOISY` broadcast (fired when a
   Bluetooth/wired output disconnects) and sets `playWhenReady = false` — i.e., it **pauses**
   playback. This is the standard Android "don't blast the speaker" behavior, but for a
   single live-radio stream the desired behavior (per #30) is to keep playing on the phone.

2. **`MetadataPlayerListener.onPlayWhenReadyChanged(playWhenReady:reason:)`** —
   `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` (lines ~64–71).
   When `playWhenReady == false` and
   `reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY`, it sets
   `player.isPlaying = false` and calls `player.onInterruption?(true)`.

3. **`RadioPlayerCoordinator.handleInterruption(began:)`** —
   `Sources/Maxi80/RadioPlayerCoordinator.swift` (line ~595).
   `began == true` sets `playbackState = .paused` and publishes `isPlaying: false`.
   Because "becoming noisy" is a permanent (not transient) event, the `began: false` resume
   path (`play()`) never fires, so playback stays paused permanently — matching the report.

**Confirmed flow:** BT disconnect → `ACTION_AUDIO_BECOMING_NOISY` →
`setHandleAudioBecomingNoisy(true)` sets `playWhenReady=false` → `onPlayWhenReadyChanged`
(reason = AUDIO_BECOMING_NOISY) → `onInterruption?(true)` →
`handleInterruption(began: true)` → `.paused`, no resume.

## Approach

The desired behavior for a live stream is: **on Bluetooth/headset disconnect, do NOT pause —
let audio continue on the phone's built-in speaker; the user decides whether to stop.**

The cleanest fix is to stop media3 from auto-pausing on "becoming noisy" for this app and
handle the route change ourselves so we can keep playing on the phone.

### Change 1 — stop media3 auto-pausing on output loss
File: `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift`, in `shared(context:)`.

- Remove `.setHandleAudioBecomingNoisy(true)` from the `ExoPlayer.Builder` chain (or set it
  to `false`). This prevents media3 from setting `playWhenReady = false` when the BT/headset
  disconnects, so the stream keeps playing and audio routes to the phone speaker
  automatically (Android reroutes `USAGE_MEDIA` output to the built-in speaker when the
  external sink goes away and playback is not paused).
- Add a code comment documenting the rationale (live radio, #30) so a future reader does not
  "restore" the flag.

> Note: `setAudioAttributes(..., handleAudioFocusInternally: true)` in
> `AudioStreamPlayer.androidPlay` is unchanged. Genuine **audio-focus** interruptions
> (phone call, another app taking focus) are still handled correctly and independently via
> `onPlaybackSuppressionReasonChanged` (transient focus loss) and
> `onPlayWhenReadyChanged` with `PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS`. Those paths
> are NOT touched — only the "becoming noisy" auto-pause is removed.

### Change 2 — stop treating "becoming noisy" as an interruption in the listener
File: `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`,
`MetadataPlayerListener.onPlayWhenReadyChanged` (lines ~64–71).

- Remove the `PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY` clause from the condition
  so this callback no longer reports `.paused` for the noisy case. Keep the
  `PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS` clause intact (that is a real interruption
  that should still pause and report state).
- Resulting condition: fire `onInterruption?(true)` only when
  `!playWhenReady && reason == PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS`.

With Change 1 in place, media3 will no longer even set `playWhenReady=false` for the noisy
case, so this callback would not fire for it; Change 2 is belt-and-suspenders and documents
intent. Both changes together guarantee the Bluetooth-disconnect path never pauses.

### iOS scope note (do NOT change in this task)
`AVPlayerStreamPlayer.handleRouteChange(reason: .oldDeviceUnavailable)` currently pauses on
disconnect per Apple's HIG. Issue #30 is Android-labeled and the user's request is Android
("audio must continue on the phone"). Leave iOS behavior as-is; if the product later wants
symmetric behavior, that is a separate iOS issue (Apple guidelines differ, and continuing on
the iPhone speaker after a route change is discouraged by the HIG).

## Files to change
- `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift` — remove/disable
  `setHandleAudioBecomingNoisy`.
- `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` — drop the
  `AUDIO_BECOMING_NOISY` branch from `onPlayWhenReadyChanged`.

No changes required in `RadioPlayerCoordinator.swift`, `Maxi80MediaService.kt`, or any model.

## Acceptance criteria
1. **Manual (device):** Play the stream over a Bluetooth speaker/headset. Disconnect
   Bluetooth (power off the speaker / walk out of range / turn off BT). **Expected:** audio
   continues, now on the phone's built-in speaker; the app stays in the "playing" state
   (pause button still shown); no permanent pause.
2. **Manual (wired):** Same as above with wired headphones unplugged — audio continues on the
   phone speaker.
3. **Regression — real interruption still pauses:** Receive a phone call (or start another
   media app that takes audio focus) while playing. **Expected:** playback pauses (transient
   suppression / focus loss) and, on transient focus regain, resumes — unchanged from today.
4. **Regression — user stop still stops:** Pressing pause/stop in-app or in the notification
   still truly stops the live stream (does not resume from a stale buffer) — unchanged.
5. No change to iOS behavior.

## Out of scope (tracked elsewhere)
- Notification pause state not reflected in the app / swipe-to-dismiss lifecycle → issue #29.
- Title-history "resume where paused" concern is resolved by the true-stop semantics already
  present in `androidStop()` (`stop()` + `clearMediaItems()` → reconnect to live edge on next
  play); this plan does not alter that path.
