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

**Grep the right half of the APK.** A Skip hybrid APK has two: transpiled modules
(`Maxi80Services`) become Kotlin and land in `classes*.dex`, but native/Fuse modules (`Maxi80`)
compile to machine code in `lib/<abi>/libMaxi80.so` and appear in **neither** the dex nor the
generated Kotlin. Grepping the dex for a `Sources/Maxi80/` symbol finds nothing whether the fix is
present or not — a false negative that reads exactly like a stale build.

```bash
APK=.build/Android/app/outputs/apk/debug/app-debug.apk
T=$(mktemp -d) && (cd "$T" && unzip -qo "$OLDPWD/$APK" 'classes*.dex' 'lib/arm64-v8a/libMaxi80.so' &&
  for d in classes*.dex; do
    strings "$d" | grep -q androidDrawableName && echo "Task 3 (#80 cover, transpiled): $d"
  done
  # Cold-start fix lives in the native module (Maxi80 is Fuse/native → libMaxi80.so, NOT the dex).
  strings lib/arm64-v8a/libMaxi80.so | grep -q handleProcessStart &&
    echo "Cold-start pipeline (#61/#80, native): libMaxi80.so"
  # Absence check: the removed Kotlin ICY writer must NOT be present.
  for d in classes*.dex; do
    strings "$d" | grep -q applyIcyTitle && echo "STALE: applyIcyTitle still in $d (old build)"
  done)
$(ls ~/Library/Android/sdk/build-tools/*/aapt2 | tail -1) dump permissions "$APK" | grep WAKE_LOCK
```

Three lines must print (one per dex for `androidDrawableName`, one for `libMaxi80.so`, one for
`WAKE_LOCK`). Any `STALE` line is a regression — `applyIcyTitle` was removed to prevent the
two-writer race. `WAKE_LOCK` is the audio-focus marker — its absence means the focus change is not
in this APK.

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
4. **Read the card's text after every cycle, not just the transport state.** This is what caught the
   two-writer race: a pause→play reconnect re-delivers ICY for the SAME song, the native side skips
   it as unchanged, and any second writer's text then stands unopposed. Automatable:
   ```bash
   for i in 1 2 3; do
     adb -s "$DEV" shell cmd media_session dispatch pause; sleep 4
     adb -s "$DEV" shell cmd media_session dispatch play;  sleep 8
     adb -s "$DEV" shell dumpsys media_session | grep -oE "description=.*" | head -1
   done
   ```
   **PASS:** every line stays `<TITLE>, <ARTIST>`. **FAIL:** it degrades to
   `<ARTIST> - <TITLE>, Maxi 80` — a second writer has been reintroduced (see the "NO ICY listener"
   note in `Maxi80MediaService.onCreate`). A genuine song change mid-loop is fine; judge the shape.

## Test C — split song text without the app ever being opened (#61)

The claim under test is that the **native** pipeline (`MetadataParser` → `ArtworkService` → Now
Playing publish) runs in a process started for the media service alone. It only does because
`Maxi80AppDelegate.onInit()` calls `SharedPlayer.handleProcessStart()`; before that fix nothing in
such a process ever touched the composition root, and the card was left to the service's
display-only Kotlin listener.

Judge that by the **shape** of the text, which is what tells the two publishers apart:

| Publisher | Title | Artist |
|-----------|-------|--------|
| Kotlin listener (display-only, the pre-fix state) | whole `ARTIST - TITLE` line | `Maxi 80` |
| Native pipeline (expected) | title only | artist only |

1. Still without ever opening the app, let playback run through a song change (up to ~4 minutes).
2. **PASS:** the DHU card shows the title alone with the artist on its own line.
   **FAIL:** the card stays on `Maxi 80` / `Live`, or shows one `ARTIST - TITLE` line with `Maxi 80`
   as the artist (the Kotlin fallback — the native pipeline did not run).
3. Read the card's actual fields rather than trusting the rendering. **Wait for
   `state=PLAYING` first** — a dump taken while `PAUSED`, or after the process died, shows the
   startup placeholder and reads exactly like the bug:
   ```bash
   until adb -s "$DEV" shell dumpsys media_session | grep -q "state=PLAYING"; do sleep 2; done
   adb -s "$DEV" shell dumpsys media_session | grep -E "description=|state=PLAYING"
   ```
   Expect `description=<TITLE>, <ARTIST>` — two separate values, not one line ending in `Maxi 80`.
4. Confirm the native half is what produced them:
   ```bash
   PID=$(adb -s "$DEV" shell pidof com.stormacq.android.maxi80 | tr -d '\r')
   adb -s "$DEV" logcat -d | grep -E " $PID " | grep -E "NowPlaying path|metadata received|artwork resolved"
   ```
   All three must appear. `NowPlaying path:` is logged by `SharedPlayer`'s composition root, so its
   presence alone proves the root was built in a service-only process.
5. Prove no Activity was ever involved, or the test proves nothing:
   ```bash
   adb -s "$DEV" logcat -d | grep -E "Start proc .*maxi80"
   ```
   Expect `for service {…Maxi80MediaService}`. If it says `for next-top-activity` or a
   `MainActivity` line appears, the app was opened — force-stop and start over.
6. Then open the app on the phone. **PASS:** the text stays as it was and does not flicker.

## Test D — the song's cover on the card, app never opened (#80)

Do **not** compare against the app carousel: on a cold start there is no carousel, and opening the
app to get one destroys the very condition being tested. Compare against the two known-wrong
outcomes instead — the station logo, and a blank slot.

Run this while still in the Test A/C process, having never opened the app.

1. With a song the backend **has** artwork for, look at the DHU card and the phone's notification
   shade (`adb -s "$DEV" shell cmd statusbar expand-notifications`, then screenshot with
   `adb -s "$DEV" exec-out screencap -p > /tmp/shade.png`).
   **PASS:** the song's own cover art.
   **FAIL:** the Maxi 80 station logo (`drawable/media_placeholder` — the service's only artwork
   source, which is all a process without the native pipeline can publish), or a blank slot.
2. Screenshot rather than `dumpsys notification` size numbers. `android.largeIcon=Icon(typ=BITMAP
   size=68x68)` is the system's scaled copy: the logo and a real cover both land at 68x68, so the
   size is **not** evidence either way.
3. Confirm the URL the native service resolved, and that it was published:
   ```bash
   PID=$(adb -s "$DEV" shell pidof com.stormacq.android.maxi80 | tr -d '\r')
   adb -s "$DEV" logcat -d | grep -E " $PID " | grep "artwork resolved"
   ```
   Expect `url=https://s3…artwork.maxi80.com/…`. `hasImage=false` is **correct** on Android: image
   decoding is Apple-only (`canImport(UIKit)`), so Android publishes the URL and media3 fetches it.
   `MediaDataLoader: Invalid album art uri` from **systemui's** pid is the legacy system panel
   choking on the long presigned URL and does not affect our card — only hits from `$PID` matter.
4. With a **coverless** song (a DJ program, or any track the backend has no artwork for):
   **PASS:** one of the generic covers. **FAIL:** the station logo. Confirm media3 could rasterize
   the drawable — the #41 trap:
   ```bash
   adb -s "$DEV" logcat -d | grep -E "RawResourceDataSource|Failed to load bitmap"
   ```
   Expected: no hits from our pid. (`systemui`'s `ImageLoader` loading `ic_launcher` is the launcher
   badge and is unrelated.)
5. With the `anniversary_cover` flag on, confirm an anniversary cover can also appear there.
6. Startup / no song yet → still the station logo, with no blank-artwork flicker.

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
