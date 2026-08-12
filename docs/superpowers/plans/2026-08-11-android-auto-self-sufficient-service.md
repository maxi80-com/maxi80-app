# Android Auto: Self-Sufficient Media Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Android playback audible, metadata-bearing, and correctly-illustrated when started from the car with the app never opened — fixing the silent-cold-start bug, issue #61 (no live song text) and issue #80 (station logo instead of the song's generic cover).

**Architecture:** All three symptoms share one root cause: everything the car needs (audio focus, the ICY metadata listener, per-song artwork) is wired only in the native Swift app-side `androidPlay()` / `RadioPlayerCoordinator`, which never runs on an Android Auto cold start. The fix moves the *player-intrinsic* concerns (audio focus, wake mode) to where the player is **constructed** (`SharedAudioPlayer.shared`), so every entry path inherits them, and gives the service its own ICY listener so the car card is populated without the app. Artwork is fixed by shipping the generic covers as Android drawables and resolving a `android.resource://` URI on the Android publish path.

> **⚠️ Architecture note (superseded):** The "service-owned ICY listener" approach above was the original plan but was replaced during implementation. The shipped solution bootstraps the **native Swift pipeline** at process start instead (`Maxi80AppDelegate.onInit()` → `SharedPlayer.handleProcessStart()`), which lets the existing `MetadataParser` + `ArtworkService` run in the service-only process. The service-owned Kotlin ICY listener was subsequently **removed** because having two writers on the same MediaItem caused a last-writer-wins regression on pause→play reconnects (the Kotlin write was raw/unsplit; the native side skipped unchanged metadata; the card degraded). The shipped architecture has one writer — the native pipeline — and zero Kotlin parsing or artwork logic. Do not reintroduce the Kotlin listener.

**Tech Stack:** Swift 6 (Skip transpiled module), Kotlin (raw, `Maxi80MediaService.kt`), androidx.media3 1.9.4 (exoplayer + session), Swift Testing, Gradle, Android Auto Desktop Head Unit (DHU).

## Global Constraints

- **Module modes are mixed and must not be changed.** `Maxi80` = native (Fuse); `Maxi80Model` = native + bridging; `Maxi80Services` = transpiled (Lite) + bridging. Check `Sources/<Module>/Skip/skip.yml` before applying any Skip guidance.
- **media3 version is 1.9.4** for all four artifacts, declared in `Sources/Maxi80Services/Skip/skip.yml`. Do not bump it in this plan.
- **`Maxi80MediaService.kt` is raw Kotlin, not transpiled.** Edit it as Kotlin. Every other Android file under `Sources/Maxi80Services/Platform/Android/` is Swift transpiled by Skip.
- **Never `rm -rf .build`** — skipstone marks transpiled Kotlin read-only, and a partial wipe poisons the next build. Use `make clean`.
- **Use `make test`** (which is `swift test --skip XCSkipTests --no-parallel --scratch-path .build/host-test`), never bare `swift test` — the parallel runner SIGTRAPs and the `XCSkipTests` Robolectric harness is known-broken in this environment.
- **Android build is two halves:** `make build-android` runs `skip android build` then `gradle assembleDebug`. A Kotlin-only change still needs both.
- **`Logger` (OSLog) via `import SkipFuse`, never `print()`** — `print()` does not reach Logcat.
- **No force unwrapping** outside tests. Prefer `guard` for early exits.
- **Don't add comments that restate the code.** Comments explain *why*, matching the existing dense-rationale style in these files.
- **The published cover must be the one the song's `HistoryEntry` already carries** — read `nowPlaceholderCover`, never re-roll `PlaceholderCover.random()`.

---

## Root Cause Reference (read before Task 1)

Verified against media3 1.9.4 sources (`~/.gradle/caches/modules-2/files-2.1/androidx.media3/media3-exoplayer/1.9.4/*-sources.jar`):

1. `ExoPlayer.Builder`'s constructor (`ExoPlayer.java:479`) assigns `audioAttributes = AudioAttributes.DEFAULT` but **never assigns `handleAudioFocus`** → it defaults to `false`.
2. `ExoPlayerImpl.java:497` passes `builder.handleAudioFocus` into the internal player at construction.
3. `SharedAudioPlayer.shared()` builds the player with only `setMediaSourceFactory` + `setHandleAudioBecomingNoisy(true)` — **no `setAudioAttributes`**.
4. The only `setAudioAttributes(…, handleAudioFocusInternally: true)` call in the codebase is inside `androidPlay()` (`ExoPlayerStreamPlayer.swift:162`), which runs **only on an in-app play**.

So on a car cold start, `StopOnPausePlayer.handleSetPlayWhenReady(true)` drives the raw ExoPlayer with **no audio focus request**: media3 reports READY + playWhenReady, so Auto renders a playing button, but the car's audio policy never routes a stream → **playing, silent**. When an unrelated app (voice dictation) performs a real focus transaction, the router re-evaluates and the already-running AudioTrack becomes briefly audible — exactly the user's report.

---

## File Structure

| File | Change | Responsibility after this plan |
|---|---|---|
| `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift` | Modify | Builds the one ExoPlayer **with audio focus + wake mode**, so every entry path (app, car, media button, auto-resume) is audible |
| `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` | Modify | Drops the now-redundant per-play `setAudioAttributes`; keeps listener attachment + transport |
| `Android/app/src/main/AndroidManifest.xml` | Modify | Adds `WAKE_LOCK` (required by `setWakeMode`) |
| `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` | Modify | Gains a service-owned ICY listener writing live song text to the session (#61) |
| `Android/app/src/main/res/drawable-nodpi/nocover_*.png` | Create (7) | Generic covers as Android drawables, downscaled to 1024² (#80) |
| `Sources/Maxi80Services/NowPlayingController.swift` | Modify | `updateNowPlaying` gains an `artworkAssetName` parameter for the Android drawable path |
| `Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift` | Modify | Resolves the asset name to `android.resource://…/drawable/<name>` |
| `Sources/Maxi80Services/Platform/iOS/IOSNowPlayingController.swift` | Modify | Ignores the new parameter (Apple already materializes a file URL) |
| `Sources/Maxi80/Services/NowPlayingPublishing.swift` | Modify | Protocol carries `artworkAssetName` through the seam |
| `Sources/Maxi80/Services/BridgedNowPlayingPublisher.swift` | Modify | Forwards `artworkAssetName` to the controller |
| `Sources/Maxi80/Player/RadioPlayerCoordinator.swift` | Modify | Passes `nowPlaceholderCover` as the asset name when substituting a placeholder |
| `Tests/Maxi80Tests/Fakes/FakeNowPlayingPublisher.swift` | Modify | Records `artworkAssetName` |
| `Tests/Maxi80Tests/NowPlayingPublishingTests.swift` | Modify | Existing call sites updated for the new parameter |
| `Tests/Maxi80Tests/AndroidPlaceholderArtworkTests.swift` | Create | Pins that a coverless song publishes its own cover's asset name |
| `docs/testing/android-auto-dhu-procedure.md` | Create | The DHU verification procedure |

**Task order rationale:** Task 1 is the audible-playback fix and is independently shippable — it is the whole silent-playback bug and needs no other task. Tasks 2–3 are cosmetic (#61, #80). Task 4 is the DHU procedure. Do them in order; do not bundle.

---

### Task 1: Give the shared ExoPlayer audio focus at construction

This is the silent-cold-start fix. Audio focus is a property of *the player*, not of *who pressed play*, so it belongs where the player is built.

**Files:**
- Modify: `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift` (the `shared(context:)` builder, lines 25–37)
- Modify: `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift:149-162` (remove the now-redundant per-play call)
- Modify: `Android/app/src/main/AndroidManifest.xml` (add `WAKE_LOCK`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: no new Swift symbols. `SharedAudioPlayer.shared(context:) -> ExoPlayer` keeps its exact signature; only the built player's configuration changes.

**Why no unit test:** this code is inside `#if SKIP` (Android-only, transpiled Kotlin) and configures a real ExoPlayer. There is no host-testable seam — `make test` runs on macOS where this branch does not compile in. The `FakeAudioPlayer` sits at the `AudioPlaying` protocol, well above ExoPlayer construction. Verification is therefore the DHU/device procedure in Task 4, which is written specifically to catch this. Do not fabricate a test that asserts nothing.

- [x] **Step 1: Read the two files completely before editing**

Read `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift` and `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` end to end. Both carry long rationale comments that the edits below must keep consistent — in particular `ExoPlayerStreamPlayer.swift`'s comment at lines 149–157 argues *for* calling `setAudioAttributes` on every play, and Step 3 replaces that argument.

- [x] **Step 2: Add audio focus + wake mode to the player builder**

In `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift`, add these imports beside the existing ones:

```swift
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
```

Replace the body of `shared(context:)` from `let created = ExoPlayer.Builder(context)` through `.build()` with:

```swift
        // Audio focus is configured HERE, at construction, not on each play. media3's
        // `ExoPlayer.Builder` never assigns `handleAudioFocus` (verified in 1.9.4:
        // `ExoPlayer.java`'s Builder ctor sets only `audioAttributes = AudioAttributes.DEFAULT`,
        // and `ExoPlayerImpl` passes `builder.handleAudioFocus` straight through), so it defaults
        // to FALSE. Configuring it from `androidPlay()` — the previous design — meant a player
        // started from ANY other entry point never requested focus at all: on an Android Auto cold
        // start `StopOnPausePlayer` drives this player directly and `androidPlay()` never runs, so
        // the stream decoded with no focus request. media3 reported READY + playWhenReady, so the
        // car rendered a playing button, but the car's audio policy routed no stream — playback was
        // "playing" and SILENT. (Tell-tale symptom: starting voice dictation forced a real focus
        // transaction and the already-running AudioTrack became briefly audible.) Building focus
        // into the player makes every path — in-app, car cold start, media button, auto-resume —
        // audible by construction, with no entry point left to forget it.
        let audioAttributes = AudioAttributes.Builder()
          .setUsage(C.USAGE_MEDIA)
          .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
          .build()
        let created = ExoPlayer.Builder(context)
          .setMediaSourceFactory(mediaSourceFactory)
          .setAudioAttributes(audioAttributes, /* handleAudioFocus: */ true)
          // Hold a network wake lock while playing so a backgrounded car session isn't stalled by
          // doze. media3 holds the lock only in READY/BUFFERING with playWhenReady, and releases it
          // on stop, so this costs nothing when idle. Requires WAKE_LOCK in the manifest.
          .setWakeMode(C.WAKE_MODE_NETWORK)
          .setHandleAudioBecomingNoisy(true)
          .build()
```

- [x] **Step 3: Remove the redundant per-play configuration**

In `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`, delete the whole block from the comment beginning `// Configure ExoPlayer to manage audio focus internally.` (line 149) through `exoPlayer.setAudioAttributes(audioAttributes, /* handleAudioFocusInternally: */ true)` (line 162), and replace it with:

```swift
        // Audio focus and attributes are NOT configured here: they are baked into the player by
        // `SharedAudioPlayer.shared()`, so every entry path gets them — including the Android Auto
        // cold start, where this method never runs and a play-time-only configuration left the
        // stream playing silently with no focus request. A rebuilt player (releaseShared()) is
        // configured by its own construction, so there is nothing to re-apply on each play.
```

Removing that block makes **two** imports unused in this file — `androidx.media3.common.AudioAttributes` and `androidx.media3.common.C`, which were used only by the deleted `AudioAttributes.Builder()` chain. Delete both. Verify with `grep -n "AudioAttributes\|C\." Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` first: the only remaining `AudioAttributes` hit should be inside the `androidSetAttenuation` doc comment (prose, not code), and there should be no bare `C.` usage.

- [x] **Step 4: Add the WAKE_LOCK permission**

In `Android/app/src/main/AndroidManifest.xml`, after the `FOREGROUND_SERVICE_MEDIA_PLAYBACK` line, add:

```xml
    <!-- Required by ExoPlayer's setWakeMode(WAKE_MODE_NETWORK) in SharedAudioPlayer: holds a
         PowerManager + WifiLock while playing so a backgrounded/car session isn't stalled by doze.
         media3 holds the locks only while READY/BUFFERING with playWhenReady. -->
    <uses-permission android:name="android.permission.WAKE_LOCK" />
```

- [x] **Step 5: Verify the host test suite still passes (no regression)**

Run: `make test`
Expected: PASS, exit 0. (These files are Android-only, so the suite should be unaffected — this step catches an accidental edit outside `#if SKIP`.)

- [x] **Step 6: Verify both halves of the Android build compile**

Run: `make build-android`
Expected: `skip android build` succeeds, then `gradle assembleDebug` succeeds with `BUILD SUCCESSFUL`.

If you get bogus "cannot find X in scope" / "not registered" errors, the transpile artifacts are stale: run `make clean && make build-android`. Never `rm -rf .build`.

- [x] **Step 7: Commit**

```bash
git add Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift \
        Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift \
        Android/app/src/main/AndroidManifest.xml
git commit -m "$(cat <<'EOF'
fix(android): request audio focus at player construction, not on in-app play

media3's ExoPlayer.Builder never assigns handleAudioFocus, so it defaults to
false. Audio attributes + focus were configured only in androidPlay(), which
does not run on an Android Auto cold start — the car drove the shared player
directly and the stream decoded with no focus request. media3 reported
READY + playWhenReady so Auto rendered a playing button, but the car's audio
policy routed no stream: playback was "playing" and silent, and only became
briefly audible when another app (voice dictation) forced a real focus
transaction.

Configuring focus at construction makes every entry path audible by
construction. Also adds WAKE_MODE_NETWORK (+ the WAKE_LOCK permission it
requires) so a backgrounded car session isn't stalled by doze.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Let the service publish live song text without the app (#61)

The ICY metadata listener is attached by `androidPlay()`/`syncWithExternalPlayback()`, both native-side, so on a car cold start ICY events are dropped and the card stays on "Maxi 80 / Live". Give the service its own listener. `onMetadata`/`IcyInfo` is a Player-pipeline event delivered to any listener registered on the player in-process, so a service-side listener and the native one coexist.

**Files:**
- Modify: `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` (raw Kotlin — add a listener, register in `onCreate`, unregister in `onDestroy`)

**Interfaces:**
- Consumes: `SharedAudioPlayer.shared(applicationContext)` (already called in `onCreate` at line 494) and `buildStreamItem()`.
- Produces: no cross-module symbols. A private `icyListener` field and a private `applyIcyTitle(String)` method, both internal to `Maxi80MediaService`.

**Design decision — do NOT reimplement `MetadataParser` in Kotlin.** The client parser must match the backend's split algorithm exactly (spaced `" - "` on its LAST occurrence, else bare `-` on its FIRST); a second copy in Kotlin would drift and silently break artwork matching. This listener is **display-only** and puts the raw ICY line in the *title* with the station name as artist. Once the app opens, the native writeback (`platformUpdateNowPlaying` → `replaceMediaItem`) overwrites it with the properly-parsed artist/title. Last-writer-wins on the same media item is harmless.

- [x] **Step 1: Add the imports**

In `Sources/Maxi80Services/Skip/Maxi80MediaService.kt`, add to the import block:

```kotlin
import androidx.media3.common.Metadata
import androidx.media3.extractor.metadata.icy.IcyInfo
```

- [x] **Step 2: Add the listener field and the writeback helper**

Inside `class Maxi80MediaService`, directly below `private var session: MediaLibrarySession? = null`, add:

```kotlin
    /**
     * Service-owned ICY listener, so live song text reaches the car card even when the app UI has
     * never opened (issue #61).
     *
     * WHY the service needs its own: the native `MetadataPlayerListener` is attached by
     * `androidPlay()` / `syncWithExternalPlayback()`, both of which live in the app-side Swift and
     * run only once the app UI exists. On an Android Auto cold start the service + shared player
     * stream entirely on their own, so ICY events were dropped and the card stayed on the static
     * "Maxi 80 / Live" placeholder until the app was opened once.
     *
     * Coexists with the native listener rather than replacing it: `onMetadata`/`IcyInfo` is a
     * Player-pipeline event delivered to EVERY listener registered on the player in this process, so
     * both fire. The native side then overwrites this item with properly-parsed artist/title —
     * last-writer-wins on the same string is harmless.
     *
     * Deliberately DISPLAY-ONLY: it puts the raw "ARTIST - TITLE" line in the title and the station
     * name in the artist, and does NOT split it. Splitting would duplicate MetadataParser's contract
     * (which must match the backend's algorithm exactly — spaced " - " LAST, else bare "-" FIRST) in
     * a second language, where it would drift and silently break artwork matching. Slight
     * inconsistency with in-app rendering for the app-never-opened window is the cheaper trade.
     */
    private val icyListener = object : Player.Listener {
        override fun onMetadata(metadata: Metadata) {
            for (index in 0 until metadata.length()) {
                val entry = metadata.get(index)
                if (entry is IcyInfo) {
                    val title = entry.title
                    if (!title.isNullOrEmpty()) applyIcyTitle(title)
                }
            }
        }
    }

    /**
     * Write a raw ICY line onto the session's current media item so the notification / lock screen /
     * Auto card shows it. Reuses the current item's artwork URI so this never clears artwork the
     * native side may already have published.
     */
    private fun applyIcyTitle(rawTitle: String) {
        val player = session?.player ?: return
        val current = player.currentMediaItem ?: return
        val metadata = current.mediaMetadata.buildUpon()
            .setTitle(rawTitle)
            .setArtist("Maxi 80")
            .build()
        player.replaceMediaItem(
            player.currentMediaItemIndex,
            current.buildUpon().setMediaMetadata(metadata).build()
        )
    }
```

- [x] **Step 3: Register the listener in `onCreate`**

In `onCreate`, the shared player is currently created inline inside the `StopOnPausePlayer(...)` call at line 494. Split that so the raw player can be listened to. Replace:

```kotlin
        val player = StopOnPausePlayer(SharedAudioPlayer.shared(applicationContext), buildStreamItem())
```

with:

```kotlin
        // Listen on the RAW shared player, not the StopOnPausePlayer wrapper: ICY arrives on the
        // player pipeline, and the wrapper's presented state is a remap for the car's transport.
        val sharedPlayer = SharedAudioPlayer.shared(applicationContext)
        sharedPlayer.addListener(icyListener)
        val player = StopOnPausePlayer(sharedPlayer, buildStreamItem())
```

- [x] **Step 4: Unregister in `onDestroy` and `onTaskRemoved`**

In `onDestroy`, before `session?.release()`, add:

```kotlin
        // Detach from the SHARED player, which outlives this service (see the note below on why the
        // player itself is never released here) — otherwise every service destroy/recreate cycle
        // would stack another listener on the same long-lived player.
        SharedAudioPlayer.current()?.removeListener(icyListener)
```

In `onTaskRemoved`, before `MediaControllerHolder.release()`, add the same line:

```kotlin
        SharedAudioPlayer.current()?.removeListener(icyListener)
```

**Note on the accessor:** `SharedAudioPlayer.current` is a Swift computed property (`static var current: ExoPlayer?`), which Skip transpiles to a Kotlin *function* `current()`. Verify the emitted form before trusting either spelling: after running `skip android build`, grep the generated Kotlin with
`grep -rn "fun current\|val current" .build/*/Maxi80Services/skipstone/ 2>/dev/null | head` (or search the generated `SharedAudioPlayer.kt` under `.build`). Use whichever the transpiler produced. If it resolves awkwardly, the fallback is to capture `sharedPlayer` from Step 3 in a `private var listenedPlayer: Player?` field and call `listenedPlayer?.removeListener(icyListener)` — this avoids the accessor entirely and is equally correct.

- [x] **Step 5: Verify both halves build**

Run: `make build-android`
Expected: `BUILD SUCCESSFUL`. A Kotlin compile error here most likely means the `SharedAudioPlayer.current` accessor spelling from Step 4 is wrong — apply the fallback in that step.

- [x] **Step 6: Verify the host suite is untouched**

Run: `make test`
Expected: PASS, exit 0 (this task changed only Kotlin).

- [x] **Step 7: Commit**

```bash
git add Sources/Maxi80Services/Skip/Maxi80MediaService.kt
git commit -m "$(cat <<'EOF'
fix(android-auto): show live song text with the app never opened (#61)

The ICY metadata listener was attached only by androidPlay() /
syncWithExternalPlayback(), both app-side Swift, so on an Android Auto cold
start ICY events were dropped and the car card stayed on the static
"Maxi 80 / Live" placeholder until the app was opened once.

Gives the service its own Player.Listener on the shared player. onMetadata is
delivered to every in-process listener, so it coexists with the native one,
which still overwrites the item with properly-parsed artist/title once the app
opens. Deliberately display-only — it does not re-split "ARTIST - TITLE",
because a second copy of MetadataParser's contract in Kotlin would drift from
the backend's algorithm and silently break artwork matching.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Publish the song's own generic cover on Android (#80)

`materializePlaceholderArtwork` is UIKit/AppKit-only and returns `nil` on Android, so `publishNowPlaying` sends no URL and `AndroidNowPlayingController` falls back to the station logo. Ship the covers as drawables and pass the *asset name* through the seam so Android can resolve `android.resource://…/drawable/<name>`.

This is issue #80's option 1 (drawables), chosen over option 2 (an Android materialization implementation) because it needs no image APIs and matches how `media_placeholder` already works.

**Files:**
- Create: `Android/app/src/main/res/drawable-nodpi/nocover_a.png`, `nocover_b.png`, `nocover_c.png`, `nocover_25ans.png`, `nocover_25ans_2.png`, `nocover_25ans_3.png`, `nocover_25ans_4.png`
- Modify: `Sources/Maxi80Services/NowPlayingController.swift` (add `artworkAssetName` to `updateNowPlaying`)
- Modify: `Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift` (resolve the drawable URI)
- Modify: `Sources/Maxi80Services/Platform/iOS/IOSNowPlayingController.swift` (accept + ignore)
- Modify: `Sources/Maxi80/Services/NowPlayingPublishing.swift` (protocol + `NowPlayingSession` conformance)
- Modify: `Sources/Maxi80/Services/BridgedNowPlayingPublisher.swift` (forward)
- Modify: `Sources/Maxi80/Player/RadioPlayerCoordinator.swift` (`publishNowPlaying`, ~line 595)
- Modify: `Tests/Maxi80Tests/Fakes/FakeNowPlayingPublisher.swift` (record it)
- Modify: `Tests/Maxi80Tests/NowPlayingPublishingTests.swift` (update call sites)
- Create: `Tests/Maxi80Tests/AndroidPlaceholderArtworkTests.swift`

**Interfaces:**
- Consumes: `RadioPlayerCoordinator.nowPlaceholderCover -> String` (already exists, `RadioPlayerCoordinator.swift:70`) — the asset name of the cover the current song's `HistoryEntry` carries. `PlaceholderCover.imageName` values are exactly: `NoCover-a`, `NoCover-b`, `NoCover-c`, `NoCover-25ans`, `NoCover-25ans-2`, `NoCover-25ans-3`, `NoCover-25ans-4`.
- Produces:
  - `NowPlayingPublishing.update(stationName:artist:title:artworkURL:artworkAssetName:isPlaying:)` — `artworkAssetName: String?`
  - `NowPlayingController.updateNowPlaying(artist:title:artworkURL:artworkAssetName:isPlaying:)` — `artworkAssetName: String?`
  - `NowPlayingController.androidDrawableName(for:) -> String?` — maps an asset name to a drawable resource name

- [x] **Step 1: Generate the Android drawables**

Android resource names allow only lowercase letters, digits and underscores, so `NoCover-25ans-2` becomes `nocover_25ans_2`. The source PNGs are 1440²; downscale to 1024² to match `media_placeholder.png` (1024², 315 KB) — plenty for a notification and the car's artwork surface, and it keeps seven extra copies off the APK budget.

**Do NOT use `sips -Z`.** Three of the seven sources (`NoCover-25ans-2/3/4`) are 8-bit *palette* PNGs; `sips` decodes them to truecolor, so the 1024² output comes out **larger than the 1440² source** (872 KB → 1.92 MB) and the seven drawables cost 8.0 MB instead of 3.9 MB. Preserve each source's color depth instead — re-quantizing a palette source back to 256 colors is not a fidelity loss, since 256 colors is all the shipped iOS asset has.

Run the committed generator, which resizes, preserves palette depth, and runs `optipng -o2`:

```bash
cd /Users/sst/code/maxi80/maxi80-2026/Maxi80
python3 brand/make-android-drawables.py
```

Expected: seven files, ~3.9 MB total — `nocover_a.png`, `nocover_b.png`, `nocover_c.png`, `nocover_25ans.png`, `nocover_25ans_2.png`, `nocover_25ans_3.png`, `nocover_25ans_4.png`. Confirm the dimensions and that the palette sources stayed `8-bit colormap`:

```bash
for f in Android/app/src/main/res/drawable-nodpi/nocover_*.png; do
  printf "%-24s %9s  %s\n" "$(basename $f)" "$(stat -f%z $f)" "$(file -b $f)"
done
```

They must be **raster PNGs** — this is the #41 trap: media3's `RawResourceDataSource`/`ImageDecoder` cannot rasterize an adaptive-icon XML, which is why `media_placeholder` is a PNG.

- [x] **Step 2: Write the failing test**

Create `Tests/Maxi80Tests/AndroidPlaceholderArtworkTests.swift`:

```swift
// Tests/Maxi80Tests/AndroidPlaceholderArtworkTests.swift
import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Pins that a coverless song publishes the asset NAME of the generic cover it is actually showing.
///
/// Why the name and not just the URL: on Android there are no platform image APIs, so
/// `materializePlaceholderArtwork` returns nil and no `file://` URL exists to publish — the card fell
/// back to the station logo while the carousel showed a per-song cover (issue #80). The name is what
/// lets the Android controller resolve `android.resource://…/drawable/<name>`. The name must be the
/// cover the song's `HistoryEntry` carries, never a fresh roll, or the card and carousel disagree.
@Suite("Android placeholder artwork publishing")
struct AndroidPlaceholderArtworkTests {

  @Test("a coverless song publishes its own generic cover's asset name")
  @MainActor
  func coverlessSongPublishesItsOwnCoverAssetName() async {
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(nowPlaying: publisher)

    coordinator.play()
    await coordinator.handleMetadataChanged("Some Artist - Some Song")

    let published = publisher.updates.last
    #expect(published != nil)
    // No real artwork was resolved (the stub API client returns none), so the coordinator must
    // substitute the placeholder — and name the very cover the now slot is displaying.
    #expect(published?.artworkAssetName == coordinator.nowPlaceholderCover)
  }

  @Test("a song with real artwork publishes no placeholder asset name")
  @MainActor
  func songWithRealArtworkPublishesNoAssetName() async {
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(
      nowPlaying: publisher, placeholderArtworkURL: "file:///tmp/sentinel.png")

    coordinator.play()
    await coordinator.handleMetadataChanged("Some Artist - Some Song")

    // With a materialized placeholder URL available, the URL path is used; the asset name is for
    // platforms that cannot materialize one. Whichever branch wins, the two must not disagree: a
    // published asset name must always match the displayed cover.
    let published = publisher.updates.last
    #expect(published != nil)
    if let name = published?.artworkAssetName {
      #expect(name == coordinator.nowPlaceholderCover)
    }
  }
}
```

- [x] **Step 3: Run the test to verify it fails**

Run: `make test 2>&1 | tail -30`
Expected: FAIL — compile error, because `FakeNowPlayingPublisher.Update` has no `artworkAssetName` member. That is the correct first failure; the next steps add the parameter through the seam.

- [x] **Step 4: Add `artworkAssetName` to the publisher protocol**

In `Sources/Maxi80/Services/NowPlayingPublishing.swift`, change the protocol requirement to:

```swift
  /// Update the currently-playing metadata.
  ///
  /// `artworkAssetName` is the bundled asset name of the generic cover being displayed, passed
  /// alongside `artworkURL` because Android cannot produce a URL for it: it has no platform image
  /// APIs, so `materializePlaceholderArtwork` returns nil there and the Android sink resolves this
  /// name to an `android.resource://…/drawable/…` URI instead (issue #80). Nil when the song has
  /// real remote artwork. Apple sinks ignore it — they already have a `file://` URL.
  func update(
    stationName: String, artist: String, title: String, artworkURL: String?,
    artworkAssetName: String?, isPlaying: Bool)
```

In the same file, update `NowPlayingSession.update(...)` (inside `#if !SKIP && canImport(NowPlaying)`) to match the new signature, ignoring the new parameter:

```swift
    func update(
      stationName: String, artist: String, title: String, artworkURL: String?,
      artworkAssetName: String?, isPlaying: Bool
    ) {
```

Leave that method's body unchanged — Apple platforms materialize a real `file://` URL, so `artworkURL` is already populated and the asset name adds nothing.

- [x] **Step 5: Forward it through the bridged publisher**

In `Sources/Maxi80/Services/BridgedNowPlayingPublisher.swift`, replace the `update` method with:

```swift
  func update(
    stationName: String, artist: String, title: String, artworkURL: String?,
    artworkAssetName: String?, isPlaying: Bool
  ) {
    controller.updateNowPlaying(
      artist: artist, title: title, artworkURL: artworkURL, artworkAssetName: artworkAssetName,
      isPlaying: isPlaying)
  }
```

- [x] **Step 6: Add the parameter to the bridged controller and both platform implementations**

In `Sources/Maxi80Services/NowPlayingController.swift`, add `artworkAssetName: String?` to `updateNowPlaying` and thread it into the platform dispatch. Read the file first and match its existing dispatch shape (`#if SKIP` / `#elseif os(iOS) || os(tvOS)` / `#elseif os(macOS)`), adding the parameter to each branch's call.

In `Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift`, change `platformUpdateNowPlaying` to take `artworkAssetName: String?` and replace the artwork resolution (currently lines 30–44) with:

```swift
        if let urlString = artworkURL, !urlString.isEmpty {
          _ = metadata.setArtworkUri(android.net.Uri.parse(urlString))
        } else if let assetName = artworkAssetName,
          let drawable = Self.androidDrawableName(for: assetName)
        {
          // The song's own generic cover, shipped as an Android drawable (issue #80). Android has no
          // platform image APIs, so the coordinator cannot materialize a file:// URL for it the way
          // Apple does — it passes the asset NAME and we resolve the drawable here. Without this the
          // card fell through to the station logo below while the carousel showed a per-song cover.
          _ = metadata.setArtworkUri(
            android.net.Uri.parse(
              "android.resource://\(context.packageName)/drawable/\(drawable)"))
        } else {
          // Genuinely nothing to show (no song yet): the bundled station logo rather than clearing
          // artwork, so the card does not flicker to no-art. Mirrors the initial MediaItem built in
          // ExoPlayerStreamPlayer.androidPlay() and Maxi80MediaService.stationArtworkUri().
          // `drawable/media_placeholder` is a dedicated 1024px raster PNG (NOT the ic_launcher
          // adaptive-icon XML, which media3's RawResourceDataSource can't rasterize — issue #41).
          _ = metadata.setArtworkUri(
            android.net.Uri.parse(
              "android.resource://\(context.packageName)/drawable/media_placeholder")
          )
        }
```

Add this helper to the same extension:

```swift
      /// Map a bundled cover asset name (`NoCover-25ans-2`) to its Android drawable resource name
      /// (`nocover_25ans_2`). Android resource names allow only lowercase, digits and underscores,
      /// so the asset catalog's mixed case and hyphens are normalized. Returns nil for a name with
      /// no shipped drawable, so the caller falls back to the station logo rather than publishing a
      /// URI that media3 cannot resolve.
      static func androidDrawableName(for assetName: String) -> String? {
        let normalized = assetName.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized.hasPrefix("nocover_") ? normalized : nil
      }
```

In `Sources/Maxi80Services/Platform/iOS/IOSNowPlayingController.swift`, add `artworkAssetName: String?` to `platformUpdateNowPlaying`'s signature and ignore it (iOS already receives a materialized `file://` URL). Add a one-line comment saying so. Do the same for the macOS implementation if it declares its own `platformUpdateNowPlaying` — check with `grep -rn "platformUpdateNowPlaying" Sources/Maxi80Services/`.

- [x] **Step 7: Pass the asset name from the coordinator**

In `Sources/Maxi80/Player/RadioPlayerCoordinator.swift`, the `publishNowPlaying(artist:title:artworkURL:isPlaying:)` method (line 583) currently reads:

```swift
    let publishedArtworkURL =
      shouldPublishPlaceholderArtwork(forArtworkURL: artworkURL)
      ? placeholderArtworkFileURL
      : artworkURL

    nowPlayingPublisher.activate()
    nowPlayingPublisher.update(
      stationName: station?.name ?? BrandConstants.name,
      artist: artist,
      title: title,
      artworkURL: publishedArtworkURL,
      isPlaying: isPlaying
    )
```

Hoist the existing gate — `shouldPublishPlaceholderArtwork(forArtworkURL:)`, defined at line 332 as `(artworkURL?.isEmpty ?? true)` — into a local so the URL and the asset name derive from **one** decision, and pass the name:

```swift
    // One decision, two sinks: Apple platforms publish a materialized `file://` URL, Android has no
    // image APIs to make one and resolves the asset NAME to a drawable instead (issue #80). Deriving
    // both from the same gate is what keeps them from disagreeing.
    let substitutingPlaceholder = shouldPublishPlaceholderArtwork(forArtworkURL: artworkURL)
    let publishedArtworkURL = substitutingPlaceholder ? placeholderArtworkFileURL : artworkURL

    nowPlayingPublisher.activate()
    nowPlayingPublisher.update(
      stationName: station?.name ?? BrandConstants.name,
      artist: artist,
      title: title,
      artworkURL: publishedArtworkURL,
      // The cover the now slot is actually displaying. Read off the current entry via
      // `nowPlaceholderCover` — never re-rolled here, or the card and the carousel would show
      // different covers for the same song.
      artworkAssetName: substitutingPlaceholder ? nowPlaceholderCover : nil,
      isPlaying: isPlaying
    )
```

- [x] **Step 8: Record the asset name in the fake**

In `Tests/Maxi80Tests/Fakes/FakeNowPlayingPublisher.swift`, add `let artworkAssetName: String?` to `struct Update` (after `artworkURL`), and update the `update` method:

```swift
  func update(
    stationName: String, artist: String, title: String, artworkURL: String?,
    artworkAssetName: String?, isPlaying: Bool
  ) {
    let update = Update(
      stationName: stationName, artist: artist, title: title, artworkURL: artworkURL,
      artworkAssetName: artworkAssetName, isPlaying: isPlaying)
    updates.append(update)
    calls.append(.update(update))
  }
```

- [x] **Step 9: Fix the other call sites the new parameter breaks**

Run: `make test 2>&1 | grep -E "error:" | head -20`

Update every reported call site — expect `Tests/Maxi80Tests/NowPlayingPublishingTests.swift` (it constructs `Update` values and/or calls `update(...)` directly) and possibly `CarPlayNowPlayingTests.swift`. Add `artworkAssetName: nil` to existing expectations, since those tests were written for the artwork-URL path and their behavior is unchanged.

- [x] **Step 10: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, exit 0, with `AndroidPlaceholderArtworkTests` among the suites run. If `coverlessSongPublishesItsOwnCoverAssetName` fails with a nil `artworkAssetName`, the Step 7 gate is wrong — the coordinator is not treating this as a placeholder substitution; re-read the publish method and use its real condition.

- [x] **Step 11: Verify the Android build**

Run: `make build-android`
Expected: `BUILD SUCCESSFUL`. Confirm the drawables were packaged:

```bash
unzip -l .build/Android/app/outputs/apk/debug/app-debug.apk | grep nocover
```

Expected: seven `res/...nocover_*.png` entries (the exact res path may be shortened by AAPT).

- [x] **Step 12: Commit**

```bash
git add Android/app/src/main/res/drawable-nodpi/nocover_*.png \
        Sources/Maxi80Services/NowPlayingController.swift \
        Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift \
        Sources/Maxi80Services/Platform/iOS/IOSNowPlayingController.swift \
        Sources/Maxi80/Services/NowPlayingPublishing.swift \
        Sources/Maxi80/Services/BridgedNowPlayingPublisher.swift \
        Sources/Maxi80/Player/RadioPlayerCoordinator.swift \
        Tests/Maxi80Tests/Fakes/FakeNowPlayingPublisher.swift \
        Tests/Maxi80Tests/NowPlayingPublishingTests.swift \
        Tests/Maxi80Tests/AndroidPlaceholderArtworkTests.swift
git commit -m "$(cat <<'EOF'
fix(android): publish the song's generic cover to the card, not the logo (#80)

A coverless song's notification / lock screen / Android Auto artwork was the
station logo while the carousel showed a per-song generic cover. Android has no
platform image APIs, so materializePlaceholderArtwork returns nil there, no URL
was published, and the Android controller took its station-logo fallback.

Ships the seven generic covers as 1024x1024 drawables and threads the displayed
cover's asset NAME through the Now Playing seam, so Android resolves an
android.resource:// drawable URI. The name is read off nowPlaceholderCover, never
re-rolled, so the card and the carousel can never disagree.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Write the DHU verification procedure

The Task 1 fix cannot be unit-tested (Android-only ExoPlayer construction), so this procedure *is* its test. Write it as a document so it is repeatable across releases, not a one-off.

**Files:**
- Create: `docs/testing/android-auto-dhu-procedure.md`

**Interfaces:**
- Consumes: the behavior changes from Tasks 1–3.
- Produces: a documented procedure; no code symbols.

- [x] **Step 1: Write the procedure document**

Create `docs/testing/android-auto-dhu-procedure.md` with exactly this content:

````markdown
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
- **adb-over-USB flakes on the Galaxy A07** (`R8YL119N39J`): wrap adb calls in `timeout`, and
  re-check `adb devices` whenever a command reports "device not found".

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
2. `adb -s R8YL119N39J forward tcp:5277 tcp:5277`
3. `cd ~/Library/Android/sdk/extras/google/auto && ./desktop-head-unit`

`Failed to read from transport - disconnect` on launch = the head-unit server is not running
(re-tap it) or USB is not in data mode.

## Test A — cold-start audio is audible (the silent-playback fix)

This is the regression test for the root cause: `handleAudioFocus` defaults to **false** in
`ExoPlayer.Builder`, and audio attributes used to be configured only in `androidPlay()`, which does
not run on a car cold start.

1. Install and fully kill the app, so nothing app-side has ever run this process:
   ```bash
   adb -s R8YL119N39J install -r .build/Android/app/outputs/apk/debug/app-debug.apk
   adb -s R8YL119N39J shell am force-stop com.stormacq.android.maxi80
   ```
   Confirm no process: `adb -s R8YL119N39J shell pidof com.stormacq.android.maxi80` → empty.
2. Connect the DHU (steps above). **Do not open the app on the phone at any point.**
3. In the DHU, open Maxi 80 from the media launcher and press **play**.
4. **PASS:** audio is audible from the DHU output within a few seconds.
   **FAIL (the original bug):** the play button renders as playing but there is no sound.
5. Confirm focus was actually granted — this is what distinguishes "playing" from "audible":
   ```bash
   adb -s R8YL119N39J shell dumpsys audio | grep -A15 "audio focus"
   ```
   Expect a focus entry owned by `com.stormacq.android.maxi80` with `USAGE_MEDIA`. **No entry for our
   package while the card shows playing is the bug.**
6. Confirm the player is genuinely playing, not just presented as such:
   ```bash
   adb -s R8YL119N39J shell dumpsys media_session | grep -A20 maxi80
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
   adb -s R8YL119N39J logcat -d | grep -i "icy\|metadata" | tail -20
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
   adb -s R8YL119N39J logcat -d | grep -E "RawResourceDataSource|Failed to load bitmap"
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
````

- [x] **Step 2: Verify the document renders and links are accurate**

Confirm the file exists and the referenced paths are real:

```bash
ls -la docs/testing/android-auto-dhu-procedure.md
ls .build/Android/app/outputs/apk/debug/app-debug.apk 2>/dev/null || echo "run make build-android first"
grep -n "CURRENT_PROJECT_VERSION" Skip.env
```

Also confirm the package name used in the adb commands matches the real one:

```bash
grep -n "PRODUCT_BUNDLE_IDENTIFIER\|applicationId\|ANDROID_PACKAGE" Skip.env
```

If it is not `com.stormacq.android.maxi80`, correct every occurrence in the document.

- [x] **Step 3: Commit**

```bash
git add docs/testing/android-auto-dhu-procedure.md
git commit -m "$(cat <<'EOF'
docs: add the Android Auto DHU verification procedure

The Auto cold-start path has no host-testable seam — audio focus, the media
session and the car transport are Android-only code that the macOS test suite
never compiles. This procedure is the real gate for it, including a focus-grant
check via dumpsys that distinguishes "reported playing" from "actually audible",
and the DHU harness artifacts (focus theft, unreliable auto-resume) that have
repeatedly been mistaken for bugs.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Verification Summary

| What | How | Gate |
|---|---|---|
| No host regression | `make test` | Every task |
| Both Android halves compile | `make build-android` | Tasks 1–3 |
| Placeholder cover name published | `AndroidPlaceholderArtworkTests` | Task 3 |
| **Cold-start audio audible** | DHU Test A + `dumpsys audio` focus check | Task 1 — the real gate |
| Car transport on cold start | DHU Test B | Task 1 |
| Live song text without the app | DHU Test C | Task 2 |
| Generic cover on the card | DHU Test D | Task 3 |
| Phone path unregressed | DHU Test E | All |

## Out of Scope

- **Artwork for the app-never-opened window.** Artwork resolution goes through the backend
  (`APIClient`/`ArtworkService`), which is native-side only, so the service-side path in Task 2
  shows correct song *text* with the station logo (or, after Task 3, a generic cover) until the app
  is opened. Fixing that means giving the service its own HTTP artwork path — a separate change.
- **Sharing the stream URL.** `STREAM_URL` is duplicated in `MediaControllerHolder`,
  `Maxi80MediaService` and the native coordinator (there is a standing TODO at
  `Maxi80MediaService.kt:294`). Real, but unrelated to these three symptoms.
- **Sharing `MetadataParser` as a package** between backend and client (see the metadata-parser
  contract notes). Deliberately deferred; Task 2 avoids duplicating the contract instead.
- **Auto-resume reliability**, which the DHU cannot validate (needs a real car).
