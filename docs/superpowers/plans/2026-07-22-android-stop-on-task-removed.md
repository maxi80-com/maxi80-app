# Android Stop-on-Task-Removed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Android playback and remove the media notification when the user swipes the app out of recents.

**Architecture:** Override `onTaskRemoved(rootIntent:)` in the Media3 `MediaLibraryService` (`Maxi80MediaService`). On genuine task removal it stops and releases the shared ExoPlayer, then `stopSelf()` — which routes through the existing `onDestroy` to release the session and drop the notification. The pause path and `onDestroy` are untouched.

**Tech Stack:** Kotlin, AndroidX Media3 (`MediaLibraryService`, ExoPlayer), Skip transpiled module `Maxi80Services`.

## Global Constraints

- Platform: **Android only**. No Apple/macOS/tvOS code paths change.
- File is raw Kotlin (`Sources/Maxi80Services/Skip/Maxi80MediaService.kt`), NOT transpiled from Swift — hand-write Kotlin, use `()` call syntax for framework superclass calls.
- Do **not** modify `onDestroy()`, `androidStop()`, or the pause path.
- Do **not** add `android:process` to the manifest (crash-kills-audio must stay).
- `SharedAudioPlayer` lives in the same `maxi80.services` package; `releaseShared()` and `shared(context:)` are already callable.
- Verification is **manual on emulator/device** — the Robolectric/Gradle test harness is known-broken in this project (memory `skip-android-test-harness-broken`); do not gate on `swift test`.
- Trigger the Skip transpiler/Android compile by building against the **macOS** destination (iOS destinations don't run skipstone).

---

### Task 1: Override `onTaskRemoved` to tear down playback on swipe-away

**Files:**
- Modify: `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` (add `Intent` import; add `onTaskRemoved` override next to the existing `onDestroy`, ~line 251)

**Interfaces:**
- Consumes: `SharedAudioPlayer.shared(context: applicationContext): ExoPlayer`, `SharedAudioPlayer.releaseShared()`, `MediaSessionService.stopSelf()`, `ExoPlayer.stop()`, `ExoPlayer.clearMediaItems()`.
- Produces: no new symbols consumed elsewhere — behavior change only.

- [ ] **Step 1: Add the `Intent` import**

At the top of `Maxi80MediaService.kt`, in the import block (alphabetically near the other `android.*` imports, after `android.app.PendingIntent`), add:

```kotlin
import android.content.Intent
```

- [ ] **Step 2: Add the `onTaskRemoved` override**

Insert this method immediately **before** the existing `override fun onDestroy()` (around line 251):

```kotlin
    /**
     * The user swiped the app away (task removed). Fully tear down playback: stop and release the
     * shared ExoPlayer, then stopSelf() — which routes through onDestroy to release the session and
     * drop the media notification.
     *
     * Releasing the shared player here is safe precisely because this fires ONLY on genuine task
     * removal — unlike onDestroy, which media3 also invokes on every pause (see onDestroy below,
     * which deliberately does NOT release the player). This path does not affect pause/resume.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = SharedAudioPlayer.shared(context = applicationContext)
        player.stop()
        player.clearMediaItems()
        SharedAudioPlayer.releaseShared()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }
```

- [ ] **Step 3: Compile the Android target**

Build against macOS to run the Skip transpiler and Kotlin compile:

Run: `swift build`
Expected: builds without errors. (If a stale-artifact error appears after the edit, `swift build` again from clean — see memory `skip-stale-transpile-artifacts`.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Maxi80Services/Skip/Maxi80MediaService.kt
git commit -m "fix(android): stop playback and clear notification on swipe-away

Override onTaskRemoved in Maxi80MediaService to stop/release the shared
ExoPlayer and stopSelf(), so killing the app from recents stops the
foreground service instead of playing on. Does not touch onDestroy or
the pause path.

Closes #12

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Manual on-device verification

**Files:** none (verification only).

- [ ] **Step 1: Build and launch on the Android emulator**

Run: `skip android build` then `skip app launch`
Expected: app launches on the emulator.

- [ ] **Step 2: Start playback and confirm baseline**

Tap play. Expected: audio plays; media notification appears in the drawer/lock screen.

- [ ] **Step 3: Swipe the app away from recents**

Open the recents/task switcher and swipe the Maxi80 card away.
Expected: **audio stops immediately** and the **media notification disappears**.

- [ ] **Step 4: Relaunch and confirm normal cold start**

Launch the app again from the launcher. Tap play.
Expected: normal startup; playback reconnects to the live edge (fresh song, not a stale buffer).

- [ ] **Step 5: Confirm the pause path is unaffected**

Play, then pause from the notification, then resume.
Expected: no double audio, no artifacts — identical to pre-change behavior.

- [ ] **Step 6: Confirm no auto-restart after swipe-away**

After Step 3 (app swiped away, audio stopped), wait ~10s without relaunching.
Expected: the service does not resurrect itself — no audio resumes, no notification reappears. (If it does, the service is being restarted `START_STICKY`-style and we must return `START_NOT_STICKY` from `onStartCommand` or override the restart behavior; note it and re-plan.)

---

## Self-Review

- **Spec coverage:** Root-cause fix (override `onTaskRemoved`) → Task 1. "Stop fully & remove notification" decision → Task 1 Steps 2 + verification Step 3. Crash/no-auto-restart concern → Task 2 Step 6. Scope boundaries (no `onDestroy`/pause/manifest change) → Global Constraints. All spec sections covered.
- **Placeholder scan:** none — Kotlin shown verbatim, commands concrete.
- **Type consistency:** `SharedAudioPlayer.shared(context:)` and `releaseShared()` match the signatures in `SharedAudioPlayer.swift`; `stopSelf()`/`stop()`/`clearMediaItems()` are framework methods used elsewhere in the file.
