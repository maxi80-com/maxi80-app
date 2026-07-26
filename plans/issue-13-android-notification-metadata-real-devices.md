# Android media notification: no metadata/artwork on real devices (works in Android Auto) — #13, take 2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the phone media notification / lock-screen card show the live song title, artist, and artwork on real devices — matching what already works when Android Auto is connected.

**Architecture:** Stop the app from hand-posting a static foreground notification that clobbers media3's rich card. Let `MediaSessionService`/`MediaLibraryService` own the notification (its `DefaultMediaNotificationProvider` renders live metadata from the player), exactly as it already does on the Android Auto path.

**Tech Stack:** AndroidX Media3 1.x (`media3-session`, `media3-exoplayer`), Skip-transpiled Kotlin (`Maxi80Services`), raw Kotlin (`Maxi80MediaService.kt`).

## Global Constraints

- All Android changes stay under `#if SKIP` (in transpiled `.swift`) or in the raw `.kt` / `.pro` files. **No iOS / macOS / tvOS now-playing paths touched.**
- Keep `Logger` (OSLog) for new diagnostics, not `print()` — it forwards to Logcat. See [[skip-logging]].
- Verification MUST be on a **physical Samsung / One UI device** (the reporter's Galaxy S26 Ultra class). The bug does **not** reproduce on the emulator on *either* debug or release builds (confirmed by the repo owner), so the emulator — regardless of build type — is not evidence. Build type / R8 is ruled out as the cause.
- The single stream URL / station title strings must stay consistent across the three places they currently live (`Maxi80MediaService.buildStreamItem()`, `ExoPlayerStreamPlayer.androidPlay()`, `AndroidNowPlayingController.platformUpdateNowPlaying()`).

---

## Background: what was already tried (and why the bug survived)

Three PRs attacked this issue. Read this before touching code — the point of the plan is **not to pile a fourth fix on top**, but to remove the actual defect and delete the code that was added to compensate for it.

### PR #7 — "show media notification on lock screen and notification drawer" (MERGED)
Genuinely fixed three separate, real problems (issue was originally a 3-in-1 report):
- Added `POST_NOTIFICATIONS` permission (API 33+). **Necessary — keep.**
- Created the notification channel at `IMPORTANCE_DEFAULT` instead of `IMPORTANCE_LOW`. **Necessary — keep.**
- Pinned `DefaultMediaNotificationProvider` to our channel via `setMediaNotificationProvider(...)`. **Necessary — keep** (this is the correct media3 API; it is what renders the rich card).
- **Also added `buildForegroundNotification()` + a manual `startForeground()` posting a hand-built `NotificationCompat` notification.** ← **This is the defect.** See root cause below.

### PR #20 — "plan" (MERGED, plan doc only)
Diagnosed the remaining "Starting playback…" as *empty `MediaItem` metadata on the phone path* and proposed attaching station metadata to the initial `MediaItem` + R8 keep-rules. Reasonable-looking, but it treated a **symptom** (what text the static notification shows) rather than the root cause (that a static notification is being posted at all). Plan doc only — no code.

### PR #22 — "show station metadata instead of 'Starting playback…'" (MERGED)
Implemented PR #20's plan:
1. `ExoPlayerStreamPlayer.androidPlay()` — build the initial `MediaItem` with station `MediaMetadata` (title/artist/artwork). 
2. `Maxi80MediaService.onCreate()`/`buildForegroundNotification()` — removed the `setContentText("Starting playback…")` line.
3. `proguard-rules.pro` — broad `-keep class androidx.media3.** { *; }`.

**Outcome:** changed the *stuck string* from "Starting playback…" to a bare "Maxi 80" with no song and no artwork — because the static notification is still what's on screen. **The bug is not fixed.**

### Verdict on prior code — what is unnecessary / must be removed

| Code | PR | Verdict |
|------|----|---------|
| `POST_NOTIFICATIONS` permission | #7 | **Keep** — required for the card to show at all on API 33+. |
| `IMPORTANCE_DEFAULT` channel (`_v2`) + legacy-channel delete | #7 | **Keep** — required for lock-screen visibility. |
| `setMediaNotificationProvider(DefaultMediaNotificationProvider…setChannelId(CHANNEL_ID))` | #7 | **Keep** — correct media3 API; renders the live card. |
| `buildForegroundNotification()` + manual `startForeground(NOTIFICATION_ID, …)` in `onStartCommand()` | #7 | **REMOVE (root cause).** Conflicts with media3's own notification management and clobbers the rich card on the phone-only path. |
| `NOTIFICATION_ID = 1001` constant (if only used by the manual notification) | #7 | **Remove** once the manual notification is gone, *unless* still passed to the provider builder (see Task 3 — keep it on the provider, drop the manual use). |
| Station `MediaMetadata` on the initial `MediaItem` in `androidPlay()` | #22 | **Keep (now beneficial, was insufficient).** With the static notification gone, this metadata is what the provider renders in the pre-ICY window ("Maxi 80 / Live"), then the ICY writeback upgrades it. It was never the fix on its own, but it is the correct initial state. |
| Broad `-keep class androidx.media3.** { *; }` + `-dontwarn` | #22 | **Keep** — cheap defense-in-depth for the JNI-by-name writeback bridge; harmless if unnecessary. Do **not** cite R8 as the root cause (see below). |
| `MediaMetadata` supply via `platformUpdateNowPlaying → replaceMediaItem` | pre-existing | **Keep** — this is how live song changes reach the card. |

**Bottom line:** the only code that must change to fix the bug is the removal of the manual `startForeground()` / static notification. Everything PR #22 added is either now-useful (initial metadata) or harmless (proguard); it simply wasn't the cause, which is why the bug persisted.

---

## Root cause (file/function level)

The media notification title/artist/artwork come from media3's `DefaultMediaNotificationProvider`, which renders a `MediaStyle` card from the session's player state and **updates automatically as soon as the player has `MediaItem`s — no connected `MediaController` required** (Android media3 docs, *Background playback* / *Control playback*).

`Maxi80MediaService.onStartCommand()` **manually posts its own notification** onto the service's foreground slot:

```kotlin
// Maxi80MediaService.kt onStartCommand()
val notification = buildForegroundNotification()          // static: title "Maxi 80", generic icon, NO live metadata, NO artwork
startForeground(NOTIFICATION_ID, notification, FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
```

`buildForegroundNotification()` builds a `NotificationCompat` card with a fixed `setContentTitle("Maxi 80")` and a generic small icon, and **no live metadata**. It is posted on `NOTIFICATION_ID = 1001` — the **same id** the `DefaultMediaNotificationProvider` is configured to use (`setNotificationId(NOTIFICATION_ID)`). The Android media3 docs explicitly warn that manually calling `startForeground()` with your own notification **conflicts with** media3's built-in notification management. On the phone-only path, the app's static notification wins the id-1001 slot and the rich card never appears.

**Why Android Auto "fixes" it (the user's observed data point):** when Auto connects to the session it attaches as a controller and media3's internal *media notification controller* re-drives the id-1001 notification through `DefaultMediaNotificationProvider` — re-rendering it with live title/artist/artwork. So the same phone notification becomes correct the moment Auto is attached, and reverts otherwise. This is precisely the "different path for Auto vs phone" the reporter suspected.

**Symptom timeline, all one static notification:**
- 5.0.1 / 5.0.2 → `setContentText("Starting playback…")` on the static card.
- 5.0.3 → that line removed (PR #22) → bare "Maxi 80", no song, no art — still the static card.

### Why it works on the emulator but not on real devices

This is the crux the reporter (and I) kept getting stuck on. The mechanism is a **last-writer-wins race on notification id `1001`**:

- The manual static notification is posted on `NOTIFICATION_ID = 1001` (in `onStartCommand()`).
- media3's `DefaultMediaNotificationProvider` is *also* configured with `setNotificationId(NOTIFICATION_ID)` = 1001, and media3 posts/refreshes its rich card on that same id (calling `startForeground(1001, providerNotification)` internally) whenever the player becomes playing or its metadata changes.

So **two independent writers target the same notification slot**, and whichever posts *last* is the card the user sees. There is no code that arbitrates between them — it is pure timing.

**Build type is NOT the discriminator — this is confirmed empirically.** The reporter (repo owner) ran **both the debug and the release (R8-minified) build on the emulator, and both work.** That rules out R8 / minification / the JNI-by-name writeback being stripped: if it were, the release build would fail on the emulator too. So the surviving variable is a single one:

**The discriminator is the runtime environment: stock AOSP emulator vs the physical Samsung device (One UI 8.5).** The reporter is on a Galaxy S26 Ultra / One UI 8.5. Samsung ships a heavily customized notification shade and a bespoke "Media" panel; the emulator uses vanilla AOSP `MediaStyle` rendering. When two notifications contend for one id, the OEM shade is exactly where the difference lives:

- On **stock AOSP (emulator)**, media3's provider re-render *wins/replaces* id 1001, so the live card shows — issue-body dumpsys confirms `android.title = "Didididam ! (dimdam)"` (the real song).
- On **Samsung One UI 8.5 (device)**, the first `startForeground` content (the app's static "Maxi 80" card) gets **latched** into the Media panel and media3's later provider re-renders on the same id are not reflected — so the static card persists.

This is the classic "works on the Pixel emulator, breaks on Samsung" shape, and it fits every observation: it survives build type (ruled out above), and it flips to correct the instant Android Auto attaches (Auto's media-notification-controller forces a fresh render through the provider that One UI *does* honor).

**Honest limit (per systematic debugging — don't pretend to know):** the exact One UI shade behavior is a *runtime* OEM detail, **not provable from static code**, and I have not reproduced it on Samsung hardware here. But I don't need to prove it, because it is only decisive *while there are two writers on id 1001*. **The fix removes one writer** (the manual static notification), so media3 becomes the sole owner of the slot on every OEM — the race, and therefore the emulator/device discrepancy, disappears entirely. That is why Task 3's verification is gated on a **physical Samsung-class device** (not the emulator, which has never reproduced the bug on any build type). The R8 keep-rules from PR #22 stay as harmless belt-and-suspenders, but R8 is explicitly **ruled out** as the cause.

**The catch that PR #7 was working around** (documented in `onCreate()`/`onStartCommand()` comments): media3's `MediaSessionService` normally calls `startForeground()` itself once playback starts, but on API 31+ promoting to foreground from a background *bind* (Android Auto discovery, the launcher scanner) throws `ForegroundServiceStartNotAllowedException` (issue #18). PR #21 solved #18 by gating the manual `startForeground()` on a non-null start intent. The fix below must **preserve that #18 guarantee** while handing the notification back to media3 — see Task 1's investigation of media3's own foreground handling and the fallback.

---

## File structure

- `Sources/Maxi80Services/Skip/Maxi80MediaService.kt` — remove the static-notification path; keep channel + provider + session-activity + `onTaskRemoved`/`START_NOT_STICKY` logic. The one nuanced file.
- `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` — unchanged logic; keep the initial-`MediaItem` metadata. Only touched if the foreground-start responsibility moves (Task 1 outcome).
- `Android/app/proguard-rules.pro` — unchanged (keep-rules stay).
- No new files.

---

## Task 1: Confirm the media3 foreground/notification contract and choose the exact mechanism

**Files:**
- Read only: `Sources/Maxi80Services/Skip/Maxi80MediaService.kt`, media3 `MediaSessionService` reference.

**Interfaces:**
- Produces: a decision recorded in this plan (edit the "DECISION" block below) of **which** of the two mechanisms Task 2 implements. Everything downstream depends on it.

The tension: we must (a) let media3 own the id-1001 notification so it renders live metadata, while (b) keeping the #18 fix (no `startForeground()` on a cold *bind*).

Two viable mechanisms — pick one by testing on a **real device release build**:

- **Mechanism A (preferred): delete the manual notification entirely and let `MediaSessionService` self-foreground.** media3's `MediaSessionService` promotes itself to foreground and posts the provider notification automatically once the player is playing. If starting playback via `startForegroundService()` from `androidPlay()` (already in place) satisfies the 5s ANR window on its own, no manual `startForeground()` is needed at all. The #18 crash was specifically about foregrounding on a *bind with no playback*; media3 only self-foregrounds when the player is actually playing, so a bind alone won't trigger it.
- **Mechanism B (fallback, if A misses the ANR window on some OEM): keep a manual `startForeground()` on the started path only, but post media3's OWN provider notification, not a hand-built one.** Obtain the notification from the provider / session rather than `buildForegroundNotification()`, so the foreground slot is populated with the live card from the first frame.

- [ ] **Step 1: Read the media3 `MediaSessionService` foreground contract**

Confirm from the media3 reference/source: (a) does `MediaSessionService` call `startForeground()` itself when the player transitions to playing, and (b) is the provider notification (id 1001) posted independent of any external controller. (Docs already indicate yes to both; confirm against the pinned media3 version in `skip.yml`.)

- [x] **Step 2: Record the decision**

```
DECISION (Task 1): Mechanism A chosen. It is the only option that fixes the diagnosed root
cause — Mechanism B keeps a second writer on notification id 1001 (the exact One UI latch
problem), so it cannot fix a race whose cause is two writers. A leaves media3 the sole writer.
media3 version: 1.9.4 (skip.yml). MediaSessionService self-foregrounds on play: YES — media3's
MediaNotificationManager calls startForeground() while the player is BUFFERING/READY with
playWhenReady=true. androidPlay() calls prepare()+playWhenReady=true immediately before
startForegroundService(), so buffering (hence media3's startForeground) begins at once, well
inside the ~5s ANR window opened by our custom-intent start. #18 preserved: media3 only
self-foregrounds when the player is playing, so a cold *bind* (no playback) never foregrounds.
RESIDUAL RISK (verify in Task 3 on-device): if some OEM delayed media3's foreground past 5s
we would ANR — not observed; mitigated by media3 foregrounding on the BUFFERING state.
```

- [ ] **Step 3: Commit the plan update**

```bash
git add plans/issue-13-android-notification-metadata-real-devices.md
git commit -m "docs(android): record media3 foreground mechanism decision for #13"
```

---

## Task 2: Remove the static foreground notification (the fix)

**Files:**
- Modify: `Sources/Maxi80Services/Skip/Maxi80MediaService.kt`

**Interfaces:**
- Consumes: Task 1 DECISION.
- Produces: a `Maxi80MediaService` whose notification is owned solely by media3's `DefaultMediaNotificationProvider`; the #18 cold-bind guarantee preserved.

### If Mechanism A (preferred)

- [x] **Step 1: Delete `buildForegroundNotification()`** — done; also removed the now-dead `NotificationCompat` and `MediaStyleNotificationHelper` imports and refreshed the stale `onCreate()` NOTE comment.

- [x] **Step 2: Remove the manual `startForeground()` block from `onStartCommand()`**

Replace the body of `onStartCommand()` so it no longer builds/posts a notification, keeping only the sticky-mode contract:

```kotlin
@OptIn(UnstableApi::class)
override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    super.onStartCommand(intent, flags, startId)
    // Do NOT manually startForeground() here. media3's MediaSessionService promotes the service
    // to the foreground and posts the DefaultMediaNotificationProvider card (live title/artist/
    // artwork) once the shared ExoPlayer is playing — the SAME machinery that already renders the
    // correct card when Android Auto is attached. Hand-posting a static notification on the
    // provider's own NOTIFICATION_ID clobbered that card on the phone-only path (issue #13).
    //
    // The #18 crash (ForegroundServiceStartNotAllowedException on a cold *bind*) does not regress:
    // media3 only self-foregrounds when the player is actually playing, and the sole playback
    // starter (ExoPlayerStreamPlayer.androidPlay → startForegroundService) always accompanies a
    // real play. A cold bind (Auto discovery / launcher scan) never starts playback, so nothing
    // foregrounds. START_NOT_STICKY keeps "swipe away = exit" a true exit (see onTaskRemoved).
    return START_NOT_STICKY
}
```

- [ ] **Step 3: Keep the provider wired to `NOTIFICATION_ID` + `CHANNEL_ID`**

Leave `setMediaNotificationProvider(DefaultMediaNotificationProvider.Builder(this).setNotificationId(NOTIFICATION_ID).setChannelId(CHANNEL_ID).build())` in `onCreate()` untouched. `NOTIFICATION_ID` is now referenced only there — keep the constant.

- [ ] **Step 4: Remove the now-unused `NotificationCompat` / `MediaStyleNotificationHelper` imports if nothing else uses them**

Check for other uses in the file first (`grep` inside the file). Remove only imports with zero remaining references.

### If Mechanism B (fallback)

- [ ] **Step 1 (B): Replace `buildForegroundNotification()`'s body to source the provider's notification** rather than a hand-built one, and keep the gated `startForeground()` in `onStartCommand()` exactly as-is (non-null-intent gate = #18 fix). Do not set a static `setContentTitle`/`setContentText`. Document that this posts media3's live card, not a placeholder.

### Both mechanisms

- [ ] **Step 5: Build the Android app**

```bash
gradle -p Android assembleDebug
```
Expected: BUILD SUCCESSFUL. (Use `swift build` first for the macOS/transpile gate per CLAUDE.md if the `.kt` sits behind transpiled callers.)

- [ ] **Step 6: Commit**

```bash
git add Sources/Maxi80Services/Skip/Maxi80MediaService.kt
git commit -m "fix(android): let media3 own the media notification so live metadata shows on phones (#13)"
```

---

## Task 3: Regression + on-device verification (the gate that the emulator can't provide)

**Files:**
- No source changes. Manual device verification + adb assertions.

**Interfaces:**
- Consumes: Task 2 build artifact.

- [ ] **Step 1: Build and install on a physical Samsung / One UI device**

```bash
gradle -p Android assembleRelease   # (debug is fine too — build type is NOT the discriminator)
```
The **device is what matters, not the build type**: the repo owner confirmed both debug and release builds show the live card correctly on the emulator, so the emulator cannot reproduce the bug on any build and is not a valid gate. Verify on the reporter's device class (Galaxy S26 Ultra / One UI 8.5) or another Samsung/One UI handset.

- [ ] **Step 2: Start playback on the device**

Install, grant the notification permission, press play, then background the app and lock the screen.

- [ ] **Step 3: Assert the live card via adb (no Auto attached)**

```bash
adb shell dumpsys notification --noredact | grep -A25 "maxi80"
```
Expected: `android.title` = the current **song title** (e.g. a real track name, not "Maxi 80"), `android.text` = the **artist**, a non-null `android.largeIcon` / artwork, `channel = maxi80_media_playback_v2`, MediaStyle. Advance a live song and re-check that `android.title` changes (ICY writeback path still works).

- [ ] **Step 4: Confirm #18 did not regress**

Cold-start scenario: with the app force-stopped, open Android Auto head-unit (or the emulator DHU) and confirm the app still lists in the browse tree (no `ForegroundServiceStartNotAllowedException` in `adb logcat`). Also confirm the "Personnaliser le lanceur" launcher scan still lists the app.

- [ ] **Step 5: Confirm #14 did not regress (swipe-away still exits)**

Swipe the app from recents during playback; audio stops and the notification clears (`onTaskRemoved` path).

- [ ] **Step 6: Update the issue with device evidence**

Post the `dumpsys` output (song title present, no Auto) to issue #13 and close it only after a **physical Samsung/One UI device** confirms the live card. If the card is still static on-device with Mechanism A, switch to Mechanism B (Task 2 fallback) and repeat — do **not** add a fourth compensating layer.

---

## Self-review notes

- **Spec coverage:** (1) issue reopened + commented — done outside this plan; (2) PR analysis + unnecessary-code verdict — the "Verdict on prior code" table; (3) Auto-vs-phone path difference — "Root cause" section; (4) fix plan for the phone — Tasks 1–3.
- **Risk:** the only behavioral risk is re-triggering #18 if media3's self-foreground timing misses the ANR window on some OEM — mitigated by Mechanism B fallback and Task 3 Step 4.
- **Do NOT** re-introduce a hand-built `NotificationCompat` with static text; that is the exact regression this removes.
