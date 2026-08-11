# Android Auto verification via the Desktop Head Unit (DHU)

The Android Auto cold-start path has **no host-testable seam** — audio focus, the media session and
the car transport all live in Android-only code that `make test` (macOS) never compiles. This
procedure is the real gate for it. Run it before shipping any change to `SharedAudioPlayer`,
`ExoPlayerStreamPlayer`, `Maxi80MediaService.kt`, `StopOnPausePlayer` or `MediaControllerHolder`.

## Known test-harness artifacts (not bugs)

Read these first — each has previously cost hours of chasing a non-bug:

- **The DHU steals audio focus from the phone.** While connected, `gearheadForcedResponse=true`
  yanks focus and routes audio to `REMOTE_SUBMIX`, so **phone playback has no sound and auto-pauses**.
  Disconnect the DHU to test phone audio.
- **Auto-resume (`onPlaybackResumption`) is unreliable on the DHU.** Real cars fire it on connect;
  the DHU often does not. Never declare the resume path broken from DHU behavior alone — the real
  car is ground truth.
- **Auto-resume needs a recent-session record.** `am force-stop` / `install -r` wipes "last media
  app", after which resume no-ops. To establish one: play ~10 s, then **Stop** (do not force-kill).
- **`install -r` does not restart a live app** — `am force-stop` after installing, or you are
  testing the old process.
- **adb flakes on the Galaxy A07** (`SM-A075F`): wrap adb calls in `timeout`, and re-check
  `adb devices` whenever a command reports "device not found".

## Device serial

Every command below uses `$DEV`. Set it once per shell — do not hardcode the serial: over USB the
A07 enumerates as `R8YL119N39J`, but over wireless debugging it is a completely different string
(`adb-R8YL119N39J-…._adb-tls-connect._tcp`), and a stale hardcoded serial fails as "device not
found" and reads like a broken cable.

```bash
export DEV=$(adb devices | awk 'NR==2{print $1}')
adb -s "$DEV" shell getprop ro.product.model    # expect SM-A075F
```

The DHU port forward requires **USB** data mode; wireless adb is fine for `logcat`/`dumpsys` but
cannot carry the head-unit transport.

## Pre-flight: confirm you are testing the build you think you are

`Skip.env`'s `CURRENT_PROJECT_VERSION` is bumped per release, not per build, so a fixed and an
unfixed debug APK routinely carry the **same versionCode and versionName**. `versionName` therefore
proves nothing. Check for the code itself instead — grep the packaged dex for a symbol the fix
introduced:

```bash
APK=.build/Android/app/outputs/apk/debug/app-debug.apk
T=$(mktemp -d) && (cd "$T" && unzip -qo "$OLDPWD/$APK" 'classes*.dex' &&
  for d in classes*.dex; do
    strings "$d" | grep -q applyIcyTitle && echo "Task 2 (#61 ICY): $d"
    strings "$d" | grep -q androidDrawableName && echo "Task 3 (#80 cover): $d"
  done)
$(ls ~/Library/Android/sdk/build-tools/*/aapt2 | tail -1) dump permissions "$APK" | grep WAKE_LOCK
```

All three must print. `WAKE_LOCK` is the Task 1 marker — `setWakeMode` requires it, so its absence
means the audio-focus change is not in this APK.

This is the known "stale Kotlin half" trap in another guise: `skip app launch` can install a fresh
`.so` alongside stale dex, so verify **after** installing, not just before.

## One-time setup

```bash
sdkmanager "extras;google;auto"   # installs ~/Library/Android/sdk/extras/google/auto/desktop-head-unit
```

`JAVA_HOME` must point at a valid JDK 21 — export it on its **own line**; concatenating with the
next command corrupts the path.

On the phone: Settings → Android Auto → tap **Version** ~10× → Developer settings. Enable
**"Unknown sources"** — without it, sideloaded/debug builds are hidden from the DHU media launcher
even though the service enumerates fine.

## Each session

1. On the phone, tap **"Start head unit server"** (one-shot — do it right before launching).
2. `adb -s "$DEV" forward tcp:5277 tcp:5277`
3. `cd ~/Library/Android/sdk/extras/google/auto && ./desktop-head-unit`

`Failed to read from transport - disconnect` on launch = the head-unit server is not running
(re-tap it) or USB is not in data mode.

## Test A — cold-start audio is audible (the silent-playback fix)

This is the regression test for the root cause: `handleAudioFocus` defaults to **false** in
`ExoPlayer.Builder`, and audio attributes used to be configured only in `androidPlay()`, which does
not run on a car cold start.

1. Install and fully kill the app, so nothing app-side has ever run this process:
   ```bash
   adb -s "$DEV" install -r .build/Android/app/outputs/apk/debug/app-debug.apk
   adb -s "$DEV" shell am force-stop com.stormacq.android.maxi80
   ```
   Confirm no process: `adb -s "$DEV" shell pidof com.stormacq.android.maxi80` → empty.
2. Connect the DHU (steps above). **Do not open the app on the phone at any point.**
3. In the DHU, open Maxi 80 from the media launcher and press **play**.
4. **PASS:** audio is audible from the DHU output within a few seconds.
   **FAIL (the original bug):** the play button renders as playing but there is no sound.
5. Confirm focus was actually granted — this is what distinguishes "playing" from "audible":
   ```bash
   adb -s "$DEV" shell dumpsys audio | grep -A15 "audio focus"
   ```
   Expect a focus entry owned by `com.stormacq.android.maxi80` with `USAGE_MEDIA`. **No entry for our
   package while the card shows playing is the bug.**
6. Confirm the player is genuinely playing, not just presented as such:
   ```bash
   adb -s "$DEV" shell dumpsys media_session | grep -A20 maxi80
   ```
   Expect state `PLAYING`.
7. **Negative control (proves the test can detect the bug):** the original failure mode became
   briefly audible when another app forced a focus transaction. With the fix in place this is no
   longer needed to get sound — but if Test A ever fails again, trigger voice dictation on the phone
   and watch for audio appearing then stopping shortly after; that signature identifies a
   focus-request regression specifically, rather than a stream/network failure.

## Test B — transport works from the car on a cold start

Continuing from Test A, without opening the app:

1. Press **pause** on the DHU → audio stops, the card flips to a play glyph, and the card is still
   visible (`StopOnPausePlayer` keeps the media item deliberately, issue #49).
2. Press **play** again → audio resumes at the live edge, audible.
3. Repeat twice. **FAIL:** the play button greys out or becomes unresponsive (the
   `STATE_IDLE` → legacy `STATE_NONE` mapping regressing) or audio does not return.

## Test C — live song text without the app (#61)

1. Still without ever opening the app, let playback run through a song change (up to ~4 minutes).
2. **PASS:** the DHU card's title changes from `Live` to the current song line
   (raw `ARTIST - TITLE`, with `Maxi 80` as the artist — the service listener is display-only by
   design and does not split the string).
   **FAIL:** the card stays on `Maxi 80` / `Live` indefinitely.
3. Confirm ICY is reaching the service:
   ```bash
   adb -s "$DEV" logcat -d | grep -i "icy\|metadata" | tail -20
   ```
4. Now open the app on the phone. **PASS:** the card's text switches to properly-split
   artist/title (the native writeback taking over) and does not flicker back.

## Test D — the song's generic cover on the card (#80)

1. With a **coverless** song playing (a DJ program or any track the backend has no artwork for),
   compare the DHU card's artwork with the app carousel's now slot.
2. **PASS:** both show the **same** generic cover.
   **FAIL:** the card shows the Maxi 80 station logo while the carousel shows a generic cover.
3. Confirm media3 could rasterize the drawable — the #41 trap:
   ```bash
   adb -s "$DEV" logcat -d | grep -E "RawResourceDataSource|Failed to load bitmap"
   ```
   Expected: no hits **from our pid**. (`systemui`'s `ImageLoader` loading `ic_launcher` is the
   launcher badge and is unrelated.)
4. With the `anniversary_cover` flag on, confirm an anniversary cover can also appear there.
5. Startup / no song yet → still the station logo, with no blank-artwork flicker.

## Test E — no phone-path regression

Disconnect the DHU first (it holds audio focus — see the artifacts section).

1. Cold-launch the app on the phone, press play → audio audible, notification card posted with
   artwork and a working pause button.
2. Pause from the notification, then replay → audio returns and the card keeps the song's
   title/artwork (does not regress to the `Live` placeholder — issue #43/#49).
3. Swipe the app away → playback stops and the notification disappears (issue #12/#29).

## Reporting

Record, for each of A–E: pass/fail, the device, the build number from `Skip.env`
(`CURRENT_PROJECT_VERSION`), and whether it was the DHU or a real car. A DHU pass on Tests A–B is
necessary but **not sufficient for the auto-resume path** — that one needs a real car.
