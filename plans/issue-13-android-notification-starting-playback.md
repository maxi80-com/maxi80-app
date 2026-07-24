# Plan: Android media notification stuck on "Starting playback…" (#13)

## Triage: **bug**

Justified by evidence from **both** the issue and the code:

- **Issue evidence.** The two follow-up comments overturn the original "shipping gap, no
  code change" hypothesis. On genuine **5.0.1** the reporter confirms the notification is now
  in the correct drawer zone and the tap-to-open works (issues #2/#3 fixed) — **but the
  "Starting playback…" text still shows**. On **5.0.2**, multiple real-device users still see
  "Starting playback…" on both the lock screen and the notification drawer (screenshots
  attached). The symptom is user-visible on a shipped build.
- **Code evidence.** Git log confirms both fix commits `afed199` and `87da9bf` are contained
  in the `v5.0.2-2026072300` tag (HEAD `39a94d8`), so the fixes *are* shipped — yet the
  symptom persists. The "release/shipping gap" explanation in the original issue body is
  therefore disproven; this is a real defect in the notification-metadata pipeline.

## Root cause (named at file/function level)

The media notification title comes from `player.getMediaMetadata()`, which
`DefaultMediaNotificationProvider` reads to render the rich media card. The current code sets
that metadata through **two** places, and there is a concrete, code-provable defect in the
phone playback path:

1. **The stream is loaded with EMPTY metadata.**
   `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`, function
   `androidPlay(url:)` (lines ~172–173):

   ```swift
   let mediaItem = MediaItem.fromUri(streamUrl)   // <-- no MediaMetadata
   exoPlayer.setMediaItem(mediaItem)
   ```

   At the moment playback starts, the current `MediaItem` has **no title/artist**, so
   `getMediaMetadata()` is empty and the provider has nothing to render.

2. **A hardcoded placeholder is posted and the design *relies on* it being overwritten.**
   `Sources/Maxi80Services/Skip/Maxi80MediaService.kt`, `onCreate()` (line 234):

   ```kotlin
   .setContentText("Starting playback…")
   ```

   The comment on lines 228–231 states the intent: `DefaultMediaNotificationProvider`
   "replaces this with the full rich card once playback metadata arrives." The only thing that
   later supplies that metadata on the phone path is the writeback in
   `Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift`,
   `platformUpdateNowPlaying(...)` (lines 36–40):

   ```swift
   guard let current = player.getCurrentMediaItem() else { return }
   let updated = current.buildUpon().setMediaMetadata(metadata.build()).build()
   player.replaceMediaItem(player.getCurrentMediaItemIndex(), updated)
   ```

**The asymmetry that proves the defect:** the Android Auto path builds its item via
`Maxi80MediaService.buildStreamItem()` **with** metadata attached at construction
(`.setTitle("Maxi 80").setArtist("Live")`, lines 82–88), whereas the phone path
(`androidPlay`) attaches **none**. So the phone notification is guaranteed to render the
placeholder for a window that lasts *at least* until the first ICY event is parsed and the
`replaceMediaItem` writeback runs — and **indefinitely** if that writeback does not take
effect on the running binary.

**Why it works on the emulator but not on real phones (mechanism — not fully provable from
static code, flagged honestly):** the only known discriminator is that real-device builds are
R8-minified (`Android/app/build.gradle.kts` lines 84–85: `isMinifyEnabled = true`,
`isShrinkResources = true`) while the emulator debug build is not. `proguard-rules.pro` keeps
`maxi80.services.**` but has **no keep-rules for the Media3 `Player`/`MediaItem`/`MediaMetadata`
surface** used by the writeback. A minified-build failure of the `replaceMediaItem` writeback
(strip/rename/inlining interacting with the Skip JNI-by-name bridge) would leave the empty
initial metadata in place forever — matching the reported symptom exactly. This mechanism
cannot be *proven* from static code without a release-build on-device log, so the plan makes
the fix robust regardless of which mechanism is at fault, and adds an explicit
release-build verification step to close the question.

## Fix approach (concrete)

The core idea: **never present empty/placeholder metadata to the notification.** Give the
initial phone `MediaItem` real station metadata at load time, and remove the hardcoded
placeholder text so the worst case is the station name, never "Starting playback…".

### Change 1 — attach metadata at load time (primary fix)
File: `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`, `androidPlay(url:)`

Replace the bare `MediaItem.fromUri(streamUrl)` with a `MediaItem.Builder()` that sets a
`MediaMetadata` carrying the station name (and station artwork URI) up front — mirroring
`Maxi80MediaService.buildStreamItem()`. Example:

```swift
let mediaItem = MediaItem.Builder()
  .setUri(streamUrl)
  .setMediaMetadata(
    MediaMetadata.Builder()
      .setTitle("Maxi 80")
      .setArtist("Live")
      // optional: .setArtworkUri(station launcher-icon URI, as in buildStreamItem)
      .build()
  )
  .build()
exoPlayer.setMediaItem(mediaItem)
```

This guarantees `getMediaMetadata()` is non-empty from the first frame, so
`DefaultMediaNotificationProvider` renders "Maxi 80 / Live" immediately and the ICY writeback
then upgrades it to the live song. The existing `replaceMediaItem` writeback in
`platformUpdateNowPlaying` is unchanged and continues to supply live titles.

> Note: keep the station title/URL in sync with `Maxi80MediaService.STREAM_URL` and
> `buildStreamItem()`. The existing TODO in `Maxi80MediaService.kt` (lines 47–52) about a
> single authoritative station-config source applies here too; a shared constant is preferable
> to a third copy of the string.

### Change 2 — drop the misleading placeholder text (defensive)
File: `Sources/Maxi80Services/Skip/Maxi80MediaService.kt`, `onCreate()` (line ~232–239)

The immediate `startForeground` notification must still be posted within the 5-second ANR
window, but its `setContentText("Starting playback…")` should be removed (or replaced with the
station name / no text). With Change 1 in place, the Media3 provider immediately re-posts over
`NOTIFICATION_ID` with real metadata; even in the failure window the card shows the station,
not a stuck "Starting playback…" string.

### Change 3 — R8 keep-rules for the Media3 writeback surface (defensive, closes the mechanism)
File: `Android/app/proguard-rules.pro`

Add keep-rules so the minified release build cannot strip/rename the metadata pipeline the
writeback depends on:

```
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
```

(If a narrower rule is preferred, at minimum keep `androidx.media3.common.MediaItem`,
`androidx.media3.common.MediaMetadata`, `androidx.media3.session.DefaultMediaNotificationProvider`,
and the `Player` methods `getCurrentMediaItem`, `getCurrentMediaItemIndex`, `replaceMediaItem`,
`getMediaMetadata`.) This is the explicit safeguard against the R8 mechanism hypothesis and
must be validated by the release-build verification step below.

## Acceptance criteria

1. **Release build, real device (or `assembleRelease` + minified APK on emulator):** on first
   play, the media notification and lock-screen card show **"Maxi 80 / Live"** (or the station
   name) — **never** "Starting playback…".
2. After the first ICY metadata event, the card updates to the **live song title/artist**
   (e.g. matches the in-app now-playing) and continues to update on each song change.
3. Behavior is verified specifically on a **minified release build** (not just debug), since
   that is the shipped configuration and the only build where the bug reproduces. Capture the
   posted notification's `android.title`/`android.text` to confirm.
4. Android Auto browse/playback (via `buildStreamItem()`) is unchanged and still shows correct
   metadata.
5. Issues #2 (tap opens app via `setSessionActivity`) and #3 (channel `..._v2` at
   `IMPORTANCE_DEFAULT`) remain fixed — no regression.
6. No change to iOS/macOS/tvOS now-playing code paths.

## Files to change
- `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` (primary — attach metadata at load)
- `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` (drop placeholder text)
- `Android/app/proguard-rules.pro` (defensive keep-rules; validate on release build)

## Out of scope / follow-up
- Consolidating the duplicated station URL/title into one authoritative source (existing TODO
  in `Maxi80MediaService.kt`).
- If, after Change 1, a minified release build **still** shows placeholder text with the keep-
  rules in place, capture a release-build logcat of the `replaceMediaItem` path and re-open to
  investigate a Media3 notification-refresh ordering issue (controller-connection timing) as the
  residual mechanism.
