# Plan: Android app not listed in Android Auto launcher (#18)

## Triage: **bug** (Android-only)

Justified by evidence from both the issue and the code:

- **Issue:** The app advertises "Full Android Auto support," in-app playback on
  Android Auto works *once started from the phone*, but Maxi 80 never appears in
  the car-screen launcher/drawer nor in the phone's "Personnaliser le lanceur"
  (Customize launcher) A–Z checkbox list, so it can't be enabled/launched from
  the car.
- **Code:** The manifest and browse tree are correctly declared (see "Ruled
  out" below), yet the service crashes on the cold background bind that Android
  Auto uses for discovery/enumeration. This is a defect, not a missing feature —
  the intended behavior exists but is broken by one lifecycle bug.

## Reproduction

- **Platform:** Android only (Android Auto / phone-projected car screen).
- **Conditions:** targetSdk 36 / minSdk 28 (per `docs/ANDROID-AUTO-design.md`),
  media3 1.9.4 (`Sources/Maxi80Services/Skip/skip.yml`).
- Install on a phone paired with an Android Auto head unit. With the app **not
  currently playing** (cold), open the car launcher or the phone's "Personnaliser
  le lanceur" list → Maxi 80 is absent.
- Start playback on the phone first, then open Android Auto → the now-playing
  card works. This asymmetry is the key diagnostic clue.

## Root cause (file/function level)

`Maxi80MediaService.onCreate()` in
`Sources/Maxi80Services/Skip/Maxi80MediaService.kt` **unconditionally calls
`startForeground(...)`** at service-creation time (lines ~228–246):

```kotlin
// Post a MediaStyle foreground notification immediately ...
val notification = NotificationCompat.Builder(this, CHANNEL_ID) ... .build()
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
    startForeground(NOTIFICATION_ID, notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
} else {
    startForeground(NOTIFICATION_ID, notification)
}
```

The service is only ever *explicitly started* via `startForegroundService()`
from `ExoPlayerStreamPlayer.androidPlay()`
(`Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`, lines
~182–184) — i.e. **only when the user presses play in the phone app**.

When Android Auto (and the system media-app scanner that populates the
"Personnaliser le lanceur" list) **binds** the `MediaLibraryService` **cold**
— while the app is in the background, with no prior `startForegroundService()`
— `onCreate()` still runs and calls `startForeground()`. On **API 31+** (this
app targets API 36) starting a foreground service from the background is
prohibited: the platform throws `ForegroundServiceStartNotAllowedException`,
tearing the service down **before `onGetLibraryRoot` can return a browsable
root**. Android Auto only lists a media app in its launcher/enable list if the
app's browser service returns a valid root on that cold connection; the crash
means it never does, so the app is absent from the list.

This precisely explains **both** symptoms:
- **Absent from launcher / "Personnaliser le lanceur":** cold browse-connect
  crashes in `onCreate()` before returning a root.
- **Works once started from the phone:** `androidPlay()` calls
  `startForegroundService()`, which legitimately allows the subsequent
  `startForeground()`; the session then exists and the car binds successfully.

media3's `MediaLibraryService` / `MediaSessionService` is explicitly designed to
promote *itself* to the foreground **only when playback starts** (via its
notification provider + `MediaSessionService.Listener`/
`MediaNotification.Provider`), not from `onCreate()`. Calling `startForeground()`
in `onCreate()` on a cold browse-connect is the documented anti-pattern here.

### Ruled out (verified, not the cause)

- **`automotive_app_desc.xml`** — contains `<automotiveApp><uses name="media"/>`,
  which is the correct Google-specified form. OK.
- **Service class name** — manifest `maxi80.services.Maxi80MediaService` matches
  the `.kt` file's `package maxi80.services` + `class Maxi80MediaService`. OK.
- **Intent filters** — the service declares `androidx.media3.session.MediaLibraryService`,
  `androidx.media3.session.MediaSessionService`, and
  `android.media.browse.MediaBrowserService`, plus `exported="true"` and
  `foregroundServiceType="mediaPlayback"`. Discovery declaration is correct. OK.
- **Browse tree** — `onGetLibraryRoot`/`onGetChildren`/`onGetItem`/`onAddMediaItems`
  are all correctly implemented and return a browsable root + one playable item.
  OK (and consistent with the reporter's "playback works once launched" note).

## Approach (fix)

Stop foregrounding the service in `onCreate()`. Let media3 manage foreground
promotion when playback actually starts, so a cold browse-connect can complete
and return the library root.

### File to change (implementation, not part of this plan PR)

`Sources/Maxi80Services/Skip/Maxi80MediaService.kt` — `onCreate()`:

1. **Remove the unconditional `startForeground(...)` block** (the notification
   build + the `if (SDK_INT >= Q) startForeground(...) else startForeground(...)`
   at the end of `onCreate()`). Keep the notification-channel creation, the
   `MediaLibrarySession` build, the `setSessionActivity(...)`, and
   `setMediaNotificationProvider(...)` — those are safe on a cold bind and are
   what media3 needs to render the card once playback begins.
2. **Let media3 promote to foreground on play.** With
   `DefaultMediaNotificationProvider` already set and the session backed by the
   shared `ExoPlayer`, media3's `MediaSessionService` promotes itself to the
   foreground automatically when the player transitions to playing. No manual
   `startForeground()` is required. If a belt-and-suspenders foreground call is
   still wanted for the *playing* path, gate it so it only runs when the service
   was started via `startForegroundService()` (i.e. from `androidPlay()`),
   never on a bind-only path — e.g. only call `startForeground()` from
   `onStartCommand()` when `intent != null`, not from `onCreate()`.
3. **Verify the ANR-window comment is still satisfied.** The current code
   foregrounds within the 5s ANR window; after this change the service is only
   *started* (via `startForegroundService`) from `androidPlay()`, so the
   foreground promotion must still happen within 5s **on that path**. Confirm
   media3 1.9.4 promotes on play quickly enough; if not, add the gated
   `startForeground()` in `onStartCommand()` (guarded on non-null intent) so the
   started (playback) path foregrounds but the bound (discovery) path does not.

No application logic, browse tree, or manifest change is required — the fix is
localized to the service's foreground lifecycle.

### Follow-up validation to fold into the same implementation

- Re-confirm the media notification still shows on the lock screen when playback
  starts from the phone (regression guard for the reason `startForeground` was
  added originally — commit `afed199`, issue lineage around lock-screen
  notification). Note: issue #13 ("Starting playback…" stuck as the title) is a
  *separate* metadata bug and is **out of scope** here; do not conflate.

## Acceptance criteria

1. With the app **not playing** (cold), Maxi 80 appears in the phone's
   Android Auto "Personnaliser le lanceur" A–Z checkbox list and can be enabled.
2. After enabling, Maxi 80 appears in the Android Auto **car-screen launcher/
   drawer** and can be launched directly from the car without first opening the
   app on the phone.
3. Launching from the car auto-starts the live stream and the car shows correct
   title/artist/artwork (existing browse/playback behavior unchanged).
4. Starting playback from the **phone** still posts the foreground media
   notification on the lock screen and notification drawer (no regression of the
   behavior `startForeground` originally provided).
5. No `ForegroundServiceStartNotAllowedException` in logcat when Android Auto
   binds the service cold (verify via DHU or a paired head unit, filtering
   `Maxi80MediaService` / `ActivityManager` FGS warnings).
6. Swipe-away teardown (`onTaskRemoved`) and pause/resume behavior are unchanged.

## Verification (per project three-level gate)

Per `docs/superpowers/plans/2026-07-16-android-media-session-service.md`:
1. `swift build` — iOS/macOS branches still compile.
2. `rm -rf .build && skip android build` — transpile + Swift-for-Android path.
3. `gradle -p Android :app:compileDebugKotlin` — compiles the generated Kotlin
   (the `.kt` service is hand-authored, so this must pass).
4. **DHU test pass** (`docs/ANDROID-AUTO-design.md` §9): app appears in the car
   media-app list on a cold/first connect, launches and plays, shows correct
   metadata, and disconnect leaves phone audio playing.

## Risk / notes

- Removing `startForeground()` from `onCreate()` is low-risk because the service
  is only *started* (not merely bound) from the playback path; media3 owns the
  foreground promotion for the playing state.
- If a device/OEM proves slow to promote on play, use the gated
  `onStartCommand()` foreground (non-null intent only) rather than reinstating
  the unconditional `onCreate()` call — that keeps the discovery bind clean.
- The change is Android-only and inside the hand-authored `.kt` service; the
  transpiled Swift API surface is untouched, so iOS/CarPlay/TV are unaffected.
