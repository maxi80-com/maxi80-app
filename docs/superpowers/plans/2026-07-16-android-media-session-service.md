# Android Single-Player MediaSessionService (+ Android Auto) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two disconnected Android `ExoPlayer` instances with **one long-lived player hosted by a media3 `MediaSessionService`**, so the media notification, lock screen, Bluetooth — and later Android Auto — all control the player that actually produces audio. Then add Android Auto on top of that correct base.

**Architecture:** The canonical media3 topology for a long-lived streaming app: one `ExoPlayer` created once and kept for the service lifetime; a `MediaSession` built on it once; a foreground `MediaSessionService` that owns both and manages the notification + foreground promotion. `AudioStreamPlayer` (transpiled `Maxi80Services`) stops creating/releasing its own player and instead drives the shared player via `setMediaItem`/`prepare`/`play`/`stop`. `AndroidNowPlayingController`'s throwaway session-player is deleted. iOS/macOS audio code is **not touched**. Android Auto (Phase 2) upgrades the session to a `MediaLibrarySession` with a one-item browse tree.

**Tech Stack:** Swift 6 + Skip (transpiled `Maxi80Services`, `#if SKIP` → Kotlin), `androidx.media3` (exoplayer/session/ui), Android foreground service, Android Auto (`MediaLibraryService` + DHU).

## Global Constraints

- **Do NOT touch iOS/macOS audio code.** All changes are Android-only, inside `#if SKIP` blocks in `Sources/Maxi80Services/Platform/Android/`, or in `Android/app/src/main/…`. The `AudioStreamPlayer`/`NowPlayingController` shared Swift API (the `public func`s and callbacks) must keep the exact same signatures so the native `RadioPlayerCoordinator` and the iOS/macOS platform files compile unchanged. (from user instruction + CLAUDE.md module rules)
- `Maxi80Services` Skip mode is transpiled (Lite) + bridging — do not change `skip.yml` mode. media3 Gradle deps live in that module's `skip.yml` `build.contents`.
- Android platform bodies use `#if SKIP` and import `android.*`/`androidx.media3.*` directly (see existing `ExoPlayerStreamPlayer.swift` / `AndroidNowPlayingController.swift` for the idiom: `import Foundation` → `#if !SKIP_BRIDGE` → `#if SKIP` + imports → `#endif // SKIP` → `#endif // !SKIP_BRIDGE`).
- Use `Logger` (OSLog via `import SkipFuse`), never `print()`.
- Preserve existing behavior: audio-focus handling, the becoming-noisy (headphone-unplug) pause, interruption callbacks, and ICY metadata via `onMediaMetadataChanged` must all still work after consolidation.
- `ANDROID_PACKAGE_NAME = maxi80.module` (from `Skip.env`) — the transpiled Kotlin package. Any manifest `android:name` for a transpiled class resolves under this package.
- Verification for transpiled changes is a THREE-level gate, because each catches different failures:
  1. `swift build` — proves the iOS/macOS `#else`/`#elseif` branches still compile (the "don't break iOS" guard).
  2. `rm -rf .build && skip android build` — proves the native Swift-for-Android path + transpile succeed.
  3. `gradle -p Android :app:compileDebugKotlin` (system gradle at `/opt/homebrew/bin/gradle`, `JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home`) — the ONLY step that compiles the generated Kotlin app code; catches Kotlin-only transpile errors (`String(_:radix:)`-class bugs, unresolved `androidx.*`). `skip android build` does NOT catch these.
  `swift test` and `skip android build` leave `.build` mutually incompatible — `rm -rf .build` when switching.
- media3 `MediaSession`/`MediaLibraryService` require ALL media3 artifacts pinned to the **same** version.
- Skip regenerates `Android/gradlew`; it may be absent. Use the system `gradle` binary (`/opt/homebrew/bin/gradle`) for Gradle-level verification, not `./gradlew`.

---

### Task 1: SPIKE — does a media3 service subclass transpile via `#if SKIP`? (GATE)

This is the plan's central unknown (design doc §10). A `MediaSessionService`/`MediaLibraryService` is instantiated reflectively by the Android framework from a manifest class name and has an override-heavy lifecycle — a step beyond the `BroadcastReceiver`/`MediaSession.Callback` subclasses Skip already handles here. **The outcome decides whether the service in later tasks is authored in Swift (`#if SKIP`) or as a raw `.kt` file in `Sources/Maxi80Services/Skip/`.** No production behavior ships in this task — it is a throwaway probe on a branch.

**Files:**
- Create (throwaway, will be reverted): `Sources/Maxi80Services/Platform/Android/SpikeMediaService.swift`
- Modify (throwaway): `Sources/Maxi80Services/Skip/skip.yml` (bump media3 — see Task 2 values), `Android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Produces: a decision recorded in the report — `SERVICE_LANGUAGE = swift | kotlin` — consumed by Tasks 5–6.

- [ ] **Step 1: Write a minimal service subclass in Swift**

Create `Sources/Maxi80Services/Platform/Android/SpikeMediaService.swift`:

```swift
import Foundation
#if !SKIP_BRIDGE
#if SKIP
import android.content.Intent
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import skip.foundation.ProcessInfo

/// THROWAWAY spike: does Skip transpile a manifest-declared, framework-instantiated
/// MediaSessionService subclass? Not wired into production.
class SpikeMediaService: MediaSessionService {
    private var session: MediaSession? = nil

    override func onCreate() {
        super.onCreate()
        let ctx = ProcessInfo.processInfo.androidContext
        let player = ExoPlayer.Builder(ctx).build()
        session = MediaSession.Builder(ctx, player).build()
    }

    override func onGetSession(controllerInfo: MediaSession.ControllerInfo) -> MediaSession? {
        return session
    }

    override func onDestroy() {
        session?.getPlayer().release()
        session?.release()
        session = nil
        super.onDestroy()
    }
}
#endif
#endif
```

- [ ] **Step 2: Bump media3 and declare the service in the manifest**

In `Sources/Maxi80Services/Skip/skip.yml`, change the three media3 lines to `1.9.4`:

```yaml
        - 'implementation("androidx.media3:media3-exoplayer:1.9.4")'
        - 'implementation("androidx.media3:media3-session:1.9.4")'
        - 'implementation("androidx.media3:media3-ui:1.9.4")'
```

In `Android/app/src/main/AndroidManifest.xml`, add inside `<application>` (the class name is the transpiled package `maxi80.module` + class):

```xml
        <service
            android:name="maxi80.services.SpikeMediaService"
            android:exported="true"
            android:foregroundServiceType="mediaPlayback">
            <intent-filter>
                <action android:name="androidx.media3.session.MediaSessionService" />
            </intent-filter>
        </service>
```

> The transpiled package for `Maxi80Services` types is `maxi80.services` (module name lowercased), NOT `maxi80.module` (that's the app module). Confirm the actual package by checking a generated file: `find .build -path '*skipstone*maxi80/services*' -name '*.kt' | head` after a build. If the class isn't found at runtime, this class-name resolution is itself part of what the spike measures.

- [ ] **Step 3: Run the three-level build gate**

Run: `swift build` — Expected: OK (Swift branches unaffected).
Run: `rm -rf .build && skip android build` — Expected: `Build complete!`
Run: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" /opt/homebrew/bin/gradle -p Android :app:compileDebugKotlin --console=plain`
Expected (SUCCESS case): `BUILD SUCCESSFUL`, and the generated `SpikeMediaService.kt` compiles as a `MediaSessionService` subclass.
Expected (FAILURE case): a transpile/compile error on the service class (e.g. `super.onCreate()` unresolved, override signature mismatch, or the class not emitted).

- [ ] **Step 4: Record the decision and revert the spike**

Write the outcome to the report: `SERVICE_LANGUAGE = swift` if all three levels passed, else `SERVICE_LANGUAGE = kotlin` (service must be a raw `.kt` file in `Sources/Maxi80Services/Skip/`, with the browse/session logic there). Then revert the throwaway files (keep the media3 bump only if Task 2 hasn't run yet — but here, revert everything so Task 2 owns the bump cleanly):

```bash
git checkout Sources/Maxi80Services/Skip/skip.yml Android/app/src/main/AndroidManifest.xml
rm Sources/Maxi80Services/Platform/Android/SpikeMediaService.swift
```

- [ ] **Step 5: Commit the decision record only**

The code is reverted; commit just the report/decision as a doc note.

```bash
git add docs/ && git commit -m "chore: record MediaSessionService transpilation spike outcome" --allow-empty
```

---

### Task 2: Bump media3 to 1.9.4 and validate the existing phone build

Isolate the dependency bump (design doc §8) as its own validated step so any transitive breakage is caught before behavior changes. media3 1.2.1 → 1.9.4 predates many session/Auto fixes.

**Files:**
- Modify: `Sources/Maxi80Services/Skip/skip.yml` (media3 version, 3 lines)

**Interfaces:**
- Consumes: nothing.
- Produces: media3 `1.9.4` on the classpath for all later tasks.

- [ ] **Step 1: Bump the three media3 artifacts**

In `Sources/Maxi80Services/Skip/skip.yml`, set all three to `1.9.4`:

```yaml
        - 'implementation("androidx.media3:media3-exoplayer:1.9.4")'
        - 'implementation("androidx.media3:media3-session:1.9.4")'
        - 'implementation("androidx.media3:media3-ui:1.9.4")'
```

- [ ] **Step 2: Full build gate**

Run: `rm -rf .build && skip android build` — Expected: `Build complete!`
Run: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" /opt/homebrew/bin/gradle -p Android :app:assembleDebug --console=plain`
Expected: `BUILD SUCCESSFUL`. This exercises the full Kotlin compile + resource + dependency resolution, so a transitive-version conflict (Kotlin stdlib, AndroidX core, Guava) surfaces here.
If it fails on a Guava/AndroidX floor, note the conflicting artifact and add an explicit pin in `skip.yml` `build.contents`; diff against `/Users/sst/code/maxi80/skip-tutorial/hello-world` if the Skip build itself breaks.

- [ ] **Step 3: Smoke-test playback on the emulator (behavior unchanged)**

Run: `skip android run` (emulator booted). Manually verify audio still plays and the media notification appears. This is the baseline the consolidation must preserve.

- [ ] **Step 4: Commit**

```bash
git add Sources/Maxi80Services/Skip/skip.yml
git commit -m "chore: bump media3 to 1.9.4"
```

---

### Task 3: Introduce a shared long-lived ExoPlayer holder

Create a single Android-only holder for one `ExoPlayer` that lives for the process/service lifetime, so both playback and the session bind to the same instance (design doc §5, Option C). This task adds the holder and a test of its single-instance contract; wiring `AudioStreamPlayer` to it is Task 4.

**Files:**
- Create: `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift`
- Test: `Tests/Maxi80Tests/SharedAudioPlayerContractTests.swift`

**Interfaces:**
- Produces (Android, `#if SKIP`):
  - `enum SharedAudioPlayer` with `static func shared(context:) -> ExoPlayer` returning the same instance across calls, and `static func releaseShared()`.
  - Because `ExoPlayer` is Android-only, the type is entirely inside `#if SKIP`; there is no cross-platform API. Tasks 4–6 consume it only within `#if SKIP`.

- [ ] **Step 1: Write the failing contract test (transpile-safe, platform-agnostic logic only)**

`ExoPlayer` can't be unit-tested on macOS, so the test verifies the ONE piece of platform-agnostic logic the holder needs: a monotonic "generation" counter proving the holder hands back the same generation until released. Put the counter in a tiny pure helper the holder uses, so it's testable on every platform.

Create `Tests/Maxi80Tests/SharedAudioPlayerContractTests.swift`:

```swift
import Testing
@testable import Maxi80Services

@Suite("SharedAudioPlayer generation contract")
struct SharedAudioPlayerContractTests {
    @Test("Generation is stable until reset, then increments")
    func generationLifecycle() {
        var gen = SharedPlayerGeneration()
        let a = gen.current()
        let b = gen.current()
        #expect(a == b)               // same instance era
        gen.reset()
        let c = gen.current()
        #expect(c != a)               // a new player era after release
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SharedAudioPlayerContractTests`
Expected: FAIL to compile — `cannot find 'SharedPlayerGeneration' in scope`.

- [ ] **Step 3: Implement the holder + the testable generation helper**

Create `Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift`:

```swift
import Foundation

#if !SKIP_BRIDGE

/// Platform-agnostic, unit-testable "which player era are we in" counter. `public` so the
/// test target resolves it across the transpiled module boundary (internal `@testable` access
/// does not resolve on the Android test build). Pure value logic — no Android types.
public struct SharedPlayerGeneration {
    private var value: Int = 0
    public init() {}
    public mutating func reset() { value += 1 }
    public func current() -> Int { value }
}

#if SKIP
import androidx.media3.exoplayer.ExoPlayer

/// Holds the ONE long-lived ExoPlayer for the app's Android audio. Created once, kept for the
/// service/process lifetime, and shared by playback (`AudioStreamPlayer`) and the media session/
/// service — the media3-canonical topology so the car/notification control the audible player.
enum SharedAudioPlayer {
    private static var player: ExoPlayer? = nil

    /// The single ExoPlayer, created on first use against the app context.
    static func shared(context: android.content.Context) -> ExoPlayer {
        if let existing = player { return existing }
        let created = ExoPlayer.Builder(context).build()
        player = created
        return created
    }

    /// Release and drop the shared player (service destroy / full teardown).
    static func releaseShared() {
        player?.release()
        player = nil
    }
}
#endif

#endif
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SharedAudioPlayerContractTests`
Expected: PASS (1 test). Output pristine.

- [ ] **Step 5: Build gate**

Run: `swift build` → OK.
Run: `rm -rf .build && skip android build` → `Build complete!`
Run: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" /opt/homebrew/bin/gradle -p Android :app:compileDebugKotlin --console=plain` → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Maxi80Services/Platform/Android/SharedAudioPlayer.swift Tests/Maxi80Tests/SharedAudioPlayerContractTests.swift
git commit -m "feat: add shared long-lived ExoPlayer holder for Android"
```

---

### Task 4: Rework `ExoPlayerStreamPlayer` to drive the shared player (no create/release-per-play)

Change Android playback from create-on-play / release-on-stop to `setMediaItem`/`prepare`/`play` on the shared player, and `stop` (not release) on stop. This is the behavior-preserving heart of the consolidation (design doc §5 recommendation).

**Files:**
- Modify: `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` (`androidPlay`, `androidStop`, `androidSetVolume`, the `_exoPlayer` storage, the listener/receiver/focus lifecycle)

**Interfaces:**
- Consumes: `SharedAudioPlayer.shared(context:)`, `SharedAudioPlayer.releaseShared()` (Task 3).
- Produces: `AudioStreamPlayer.play(url:)`/`stop()`/`updateVolume(_:)` behave identically from the coordinator's view (same callbacks fire), now backed by the shared player.

- [ ] **Step 1: Rewrite `androidPlay` to use the shared player**

In `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`, replace the body of `androidPlay(url:)` so it obtains the shared player, attaches the metadata listener once, and uses `setMediaItem`/`prepare`/`play` instead of building a new `ExoPlayer`:

```swift
    func androidPlay(url streamUrl: String) {
        let ctx = context
        let exoPlayer = SharedAudioPlayer.shared(context: ctx)
        self._exoPlayer = exoPlayer

        // Attach the metadata listener once per player instance.
        if _metadataListener == nil {
            let listener = MetadataPlayerListener(player: self)
            self._metadataListener = listener
            exoPlayer.addListener(listener)
        }

        let mediaItem = MediaItem.fromUri(streamUrl)
        exoPlayer.setMediaItem(mediaItem)

        if requestAudioFocus() {
            exoPlayer.prepare()
            exoPlayer.play()
            isPlaying = true
            onPlaybackStateChanged?(true)
        }

        registerNoisyReceiver()
    }
```

- [ ] **Step 2: Rewrite `androidStop` to stop (not release) the shared player**

Replace `androidStop()` so it stops playback and unregisters transient resources but does NOT release the shared player (the session/service must keep it):

```swift
    func androidStop() {
        unregisterNoisyReceiver()
        abandonAudioFocus()

        _exoPlayer?.stop()
        _exoPlayer?.clearMediaItems()
        isPlaying = false
        onPlaybackStateChanged?(false)
        // NB: do NOT release the player or remove the metadata listener — the shared player and
        // its listener persist for the media session/service lifetime. Release happens only in
        // SharedAudioPlayer.releaseShared() at full teardown (Task 6's service onDestroy).
    }
```

- [ ] **Step 3: Point `androidSetVolume` at the shared player (unchanged logic, same instance)**

`androidSetVolume` already operates on `_exoPlayer`; leave it, but confirm `_exoPlayer` is the shared instance (set in Step 1). No code change beyond Step 1 needed; verify by reading.

- [ ] **Step 4: Keep the `_exoPlayer` var but stop owning its lifecycle**

Leave `var _exoPlayer: ExoPlayer? = nil` and `var _metadataListener` as-is (they now cache the shared instance/listener). Remove any `_exoPlayer?.release()` / `_exoPlayer = nil` still present in the file outside `androidStop` (there should be none after Steps 1–2 — verify with a grep in Step 5).

- [ ] **Step 5: Build gate + verify no stray release**

Run: `grep -n "release()\|_exoPlayer = nil" Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` — Expected: no `release()` on `_exoPlayer`, no `_exoPlayer = nil`.
Run: `swift build` → OK.
Run: `rm -rf .build && skip android build` → `Build complete!`
Run: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" /opt/homebrew/bin/gradle -p Android :app:compileDebugKotlin --console=plain` → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Emulator smoke test — behavior preserved**

Run: `skip android run`. Verify: play starts audio; pause stops it; play again resumes (proves the reused player works); headphone-unplug (emulator: disconnect BT/again) still pauses; song-change metadata still updates. This is the acceptance test that consolidation didn't regress phone playback.

- [ ] **Step 7: Commit**

```bash
git add Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift
git commit -m "refactor: Android playback drives the shared long-lived ExoPlayer"
```

---

### Task 5: Back the MediaSession with the shared player; delete the throwaway session player

Rebuild `AndroidNowPlayingController`'s session on the shared player and delete `_sessionPlayer` and the discarded-metadata code (design doc §5). After this, the notification/lock-screen controls act on the audible player.

**Files:**
- Modify: `Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift` (`ensureMediaSession`, `platformUpdateNowPlaying`, `platformUpdatePlaybackState`, `platformTearDown`, storage)

**Interfaces:**
- Consumes: `SharedAudioPlayer.shared(context:)` (Task 3); the shared player now backs both playback (Task 4) and this session.
- Produces: a `MediaSession` bound to the audible player; `updateNowPlaying`/`updatePlaybackState` keep the same Swift signatures (iOS unaffected).

- [ ] **Step 1: Build the session on the shared player**

In `AndroidNowPlayingController.swift`, replace `ensureMediaSession()` so it uses the shared player and drops the standalone one:

```swift
    private func ensureMediaSession() {
        guard _mediaSession == nil else { return }
        let ctx = context
        let callback = NowPlayingSessionCallback(controller: self)
        self._sessionCallback = callback
        let player = SharedAudioPlayer.shared(context: ctx)
        let session = MediaSession.Builder(ctx, player)
            .setCallback(callback)
            .build()
        self._mediaSession = session
    }
```

- [ ] **Step 2: Make metadata actually apply to the player (stop discarding it)**

Replace `platformUpdateNowPlaying(...)` so it sets `MediaMetadata` on the shared player's current item instead of building and discarding it:

```swift
    func platformUpdateNowPlaying(artist: String, title: String, artworkURL: String?, isPlaying: Bool) {
        ensureMediaSession()
        let metadata = MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(artist)
        if let urlString = artworkURL, !urlString.isEmpty {
            _ = metadata.setArtworkUri(Uri.parse(urlString))
        }
        // Apply to the shared player's current item so controllers (notification, lock screen,
        // later the car) see live metadata; the session reflects the player's mediaMetadata.
        // Rebuild the current MediaItem with the new metadata (no-op if nothing is loaded yet —
        // ExoPlayerStreamPlayer sets the item on play, and the next metadata update re-applies).
        let player = SharedAudioPlayer.shared(context: context)
        guard let current = player.getCurrentMediaItem() else { return }
        let updated = current.buildUpon()
            .setMediaMetadata(metadata.build())
            .build()
        player.replaceMediaItem(player.getCurrentMediaItemIndex(), updated)
    }
```

> `getCurrentMediaItem()`, `buildUpon()`, `replaceMediaItem(index:mediaItem:)`, and `getCurrentMediaItemIndex()` are all media3 `Player`/`MediaItem` APIs available in 1.9.4. If the Kotlin compile (Step 5) rejects `replaceMediaItem` on a live-stream item, fall back to `setMediaItem(updated)` guarded so it doesn't restart playback (compare URIs first). Verify against the actual compile — do not assume.

- [ ] **Step 3: Reflect playback state via the player, delete the no-op**

`platformUpdatePlaybackState` was a no-op; media3 derives play/pause from the player state now, so keep it a documented no-op OR forward to the shared player if needed:

```swift
    func platformUpdatePlaybackState(isPlaying: Bool) {
        // No-op: the MediaSession reflects the shared player's own play/pause state (set in
        // ExoPlayerStreamPlayer). Retained for API parity with iOS's MPNowPlayingInfoCenter path.
    }
```

- [ ] **Step 4: Delete `_sessionPlayer` and release only the session on teardown**

Replace `platformTearDown()` and remove the `_sessionPlayer` storage:

```swift
    func platformTearDown() {
        _mediaSession?.release()
        _mediaSession = nil
        _sessionCallback = nil
        // The shared player is released by SharedAudioPlayer.releaseShared() (service onDestroy),
        // NOT here — the session no longer owns a player of its own.
    }
```

Delete the line `var _sessionPlayer: ExoPlayer? = nil` and remove the `import androidx.media3.exoplayer.ExoPlayer` if now unused (verify no other reference in this file first).

- [ ] **Step 5: Build gate**

Run: `grep -n "_sessionPlayer\|ExoPlayer.Builder" Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift` — Expected: no matches.
Run: `swift build` → OK.
Run: `rm -rf .build && skip android build` → `Build complete!`
Run: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" /opt/homebrew/bin/gradle -p Android :app:compileDebugKotlin --console=plain` → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Emulator test — notification controls the audible stream**

Run: `skip android run`. Play, then use the **media notification** play/pause: it must control the audible stream (the acceptance test for the consolidation). Metadata in the notification must show the current artist/title.

- [ ] **Step 7: Commit**

```bash
git add Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift
git commit -m "refactor: back MediaSession with the shared player; delete throwaway session player"
```

---

### Task 6: Host the session in a foreground `MediaSessionService`

Move the session into a `MediaSessionService` (or `.kt` per Task 1's `SERVICE_LANGUAGE`) so playback survives Activity destruction (background/lock-screen correctness) — the foundation Android Auto binds to. Language chosen by Task 1.

**Files:**
- Create: `Sources/Maxi80Services/Platform/Android/Maxi80MediaService.swift` **(if `SERVICE_LANGUAGE = swift`)** OR `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` **(if `SERVICE_LANGUAGE = kotlin`)**
- Modify: `Android/app/src/main/AndroidManifest.xml` (service declaration + permissions)

**Interfaces:**
- Consumes: `SharedAudioPlayer` (Task 3), the session built in Task 5.
- Produces: a manifest-declared foreground media service that owns the session and calls `SharedAudioPlayer.releaseShared()` on destroy.

- [ ] **Step 1: Add permissions + service to the manifest**

In `Android/app/src/main/AndroidManifest.xml`, add before `<application>`:

```xml
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
```

And inside `<application>` (class name = transpiled package for `Maxi80Services` — confirm via `find .build -path '*skipstone*services*' -name '*.kt'`; use that package, e.g. `maxi80.services.Maxi80MediaService`):

```xml
        <service
            android:name="maxi80.services.Maxi80MediaService"
            android:exported="true"
            android:foregroundServiceType="mediaPlayback">
            <intent-filter>
                <action android:name="androidx.media3.session.MediaSessionService" />
            </intent-filter>
        </service>
```

- [ ] **Step 2: Implement the service (language per Task 1)**

If `SERVICE_LANGUAGE = swift`, create `Sources/Maxi80Services/Platform/Android/Maxi80MediaService.swift`:

```swift
import Foundation
#if !SKIP_BRIDGE
#if SKIP
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import skip.foundation.ProcessInfo

/// Foreground media service hosting the app's single MediaSession on the shared ExoPlayer, so
/// playback survives the Activity (background/lock-screen) and provides the base the car binds to.
class Maxi80MediaService: MediaSessionService {
    private var session: MediaSession? = nil

    override func onCreate() {
        super.onCreate()
        let ctx = ProcessInfo.processInfo.androidContext
        let player = SharedAudioPlayer.shared(context: ctx)
        session = MediaSession.Builder(ctx, player).build()
    }

    override func onGetSession(controllerInfo: MediaSession.ControllerInfo) -> MediaSession? {
        return session
    }

    override func onDestroy() {
        session?.release()
        session = nil
        SharedAudioPlayer.releaseShared()
        super.onDestroy()
    }
}
#endif
#endif
```

If `SERVICE_LANGUAGE = kotlin`, author the equivalent as `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` (package `maxi80.services`), calling into the transpiled `SharedAudioPlayer` accessor. (Kotlin body mirrors the Swift above.)

> Reconcile with Task 5 (REQUIRED, not optional): the session moves FROM `AndroidNowPlayingController` INTO the service. In this task, delete the `MediaSession.Builder` call and `_mediaSession` storage from `AndroidNowPlayingController.ensureMediaSession()` (make `ensureMediaSession` a no-op or remove it and its callers), so the service is the sole session owner. `NowPlayingController.updateNowPlaying` keeps working because it publishes metadata to the shared PLAYER (Task 5 Step 2), not to a session it owns — the service's session reflects the player automatically. Acceptance: `grep -rn "MediaSession.Builder\|MediaLibrarySession.Builder" Sources/Maxi80Services` returns EXACTLY ONE match (in the service). This is why Task 5 and Task 6 are separate: Task 5 makes the notification correct with the session still in the controller (independently testable), and Task 6 relocates that exact session into the service.

- [ ] **Step 3: Build gate**

Run: `swift build` → OK.
Run: `rm -rf .build && skip android build` → `Build complete!`
Run: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" /opt/homebrew/bin/gradle -p Android :app:assembleDebug --console=plain` → `BUILD SUCCESSFUL` (assemble, so the manifest merge + service class resolution are exercised).

- [ ] **Step 4: Emulator test — background survival**

Run: `skip android run`. Play, then background the app (home button) and lock the screen: audio must keep playing and the media notification must persist and control it. Kill the Activity from recents: audio behavior should match a media app (service keeps playing until notification dismissed/stopped).

- [ ] **Step 5: Commit**

```bash
git add Sources/Maxi80Services Android/app/src/main/AndroidManifest.xml
git commit -m "feat: host MediaSession in a foreground MediaSessionService"
```

---

### Task 7: Upgrade to `MediaLibraryService` + one-item browse tree (Android Auto)

Turn the session/service into a `MediaLibrarySession`/`MediaLibraryService` serving a single playable "Maxi 80 live" item, and add the Android Auto manifest metadata (design doc §6, §7). This is the Android Auto payoff on top of the now-correct base.

**Files:**
- Modify: the service from Task 6 (→ `MediaLibraryService`, add `MediaLibrarySession.Callback` browse methods)
- Create: `Android/app/src/main/res/xml/automotive_app_desc.xml`
- Modify: `Android/app/src/main/AndroidManifest.xml` (Auto meta-data + `MediaBrowserService` intent action)

**Interfaces:**
- Consumes: the service + shared player (Task 6).
- Produces: a browse tree (`root` → one playable stream item) the car renders; selecting it plays via the shared player.

- [ ] **Step 1: Add the Auto app descriptor + manifest metadata**

Create `Android/app/src/main/res/xml/automotive_app_desc.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<automotiveApp>
    <uses name="media" />
</automotiveApp>
```

In `Android/app/src/main/AndroidManifest.xml`, add inside `<application>`:

```xml
        <meta-data
            android:name="com.google.android.gms.car.application"
            android:resource="@xml/automotive_app_desc" />
```

And add the legacy browse action to the service's `<intent-filter>` (alongside the media3 one):

```xml
                <action android:name="android.media.browse.MediaBrowserService" />
```

- [ ] **Step 2: Upgrade the service to `MediaLibraryService` with a one-item tree**

Change the Task 6 service to extend `MediaLibraryService`, build a `MediaLibrarySession` with a `MediaLibrarySession.Callback`, and implement the browse methods. Replace the service body's session type and add:

```swift
    // onGetLibraryRoot -> a browsable root MediaItem (id "root").
    // onGetChildren("root", ...) -> a list with ONE playable MediaItem: the Maxi 80 live stream
    //   (stream URI, title "Maxi 80", station artwork), MediaMetadata.isPlayable = true, isBrowsable = false.
    // onGetItem(id) -> that item.
    // onAddMediaItems(...) -> resolve the selected id to the live-stream MediaItem so the car's
    //   play starts the shared player (reuses the existing play path / onRemoteCommand).
```

> Implement each callback concretely (media3 `MediaLibrarySession.Callback` returns `ListenableFuture<LibraryResult<...>>`; use `Futures.immediateFuture(LibraryResult.ofItem(...))` etc., matching the `Futures` usage already in `NowPlayingSessionCallback`). The stream URL is the station stream (same default `https://audio1.maxi80.com` the coordinator uses) — pass it in from the shared config rather than hardcoding a second copy; if not readily available in the service, expose it via `SharedAudioPlayer` or a small constant in `Maxi80Services` and reference it from both. Do not duplicate the URL literal.

- [ ] **Step 3: Build gate**

Run: `swift build` → OK.
Run: `rm -rf .build && skip android build` → `Build complete!`
Run: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" /opt/homebrew/bin/gradle -p Android :app:assembleDebug --console=plain` → `BUILD SUCCESSFUL`.

- [ ] **Step 4: DHU test (physical phone required)**

Per design doc §9: install DHU, connect a physical phone (API 28+), enable Android Auto Developer mode + **Unknown sources**, start the head-unit server, `adb forward tcp:5277 tcp:5277`, run `./desktop-head-unit`. Verify: Maxi80 appears in the car media list; selecting it plays the live stream with correct artist/title/artwork; the car's play/pause controls the **audible** stream; song changes propagate; disconnecting the DHU leaves phone audio playing.

- [ ] **Step 5: Commit**

```bash
git add Sources/Maxi80Services Android/app/src/main
git commit -m "feat: Android Auto via MediaLibraryService with one-item browse tree"
```

---

## Manual verification (whole feature)

- [ ] Phone (emulator): play/pause/resume; media notification controls the audible stream with correct metadata; background + lock keeps playing; headphone-unplug pauses; song-change metadata updates.
- [ ] iOS unaffected: `swift build` green throughout; CarPlay still works (no shared-API signature changed).
- [ ] Android Auto (DHU + physical phone): appears in car, plays, correct metadata/artwork, car controls audible stream, disconnect keeps phone audio.

## Notes / non-goals

- **iOS/macOS untouched:** every change is Android-only (`#if SKIP`) or under `Android/`. The `AudioStreamPlayer`/`NowPlayingController` public Swift signatures are unchanged, so `RadioPlayerCoordinator` and the iOS/macOS platform files compile without edits.
- **Android Automotive OS (built-in car OS) is out of scope** — Android Auto (phone-projected) only. Same `MediaLibraryService` architecture would extend to AAOS later; the delta is packaging/distribution, not this plumbing.
- **Player consolidation lands before car code:** Tasks 3–6 make the phone architecture correct and are independently valuable (fixes background/lock-screen reliability and the notification-controls-wrong-player latent bug). Task 7 is the only task that requires a physical phone to fully verify.
- **The spike (Task 1) gates the service language.** If `MediaSessionService` won't transpile via `#if SKIP`, Tasks 6–7 author it as a `.kt` file in `Sources/Maxi80Services/Skip/` with the same logic — no other task changes.
