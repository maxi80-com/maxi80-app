# Android Auto Support — Design Document

Status: Draft for review · Target: Maxi80 Android (Skip transpiled) · Date: 2026-07-16

This is a **design** document (approach, architecture, decisions, risks, testing). It intentionally does not contain implementation steps or code. A task breakdown at the end can later become an implementation plan.

---

## 1. Overview & UX intent

Maxi80 plays a **single live radio station** — there is no catalog, no on-demand tracks, no seeking. Android Auto support should mirror the UX intent already shipped for iOS CarPlay (`Sources/Maxi80/CarPlay/CarPlaySceneDelegate.swift`):

- **No meaningful browse experience.** There is exactly one thing to play. The driver taps the Maxi80 icon in the car and hears the stream.
- **Auto-play on connect.** A radio app is expected to start when launched from the car, the same way CarPlay calls `SharedPlayer.coordinator.play()` on `didConnect`.
- **Disconnecting from the car must not stop audio.** On CarPlay we release only the interface controller and let the phone keep playing. The Android equivalent is that the playback service and its session outlive the car projection session.
- **Now Playing surfaces stay consistent.** Metadata (artist / title), artwork, and play/pause state shown in the car must be identical to what the phone UI and the system media notification show, because they all originate from the same `RadioPlayerCoordinator`.

The important asymmetry to internalise up front: **CarPlay and Android Auto are architecturally different.** CarPlay is an in-process UIKit-style scene where *we* build the templates (`CPNowPlayingTemplate`). Android Auto for a media app is **out-of-process** — the car is a separate client that connects to a background service and **renders its own UI**. We do not draw any car screens. See §3.

---

## 2. How Android Auto differs from CarPlay

| Aspect | iOS CarPlay (existing) | Android Auto (this doc) |
|--------|------------------------|-------------------------|
| Integration model | `CPTemplateApplicationSceneDelegate` scene, in-process | `MediaLibraryService` (media3) bound out-of-process by the car |
| Who draws the UI | We do (`CPNowPlayingTemplate`, list templates) | The **car** draws a standardized, driver-safe media UI. We supply data only. |
| Connect entry point | `templateApplicationScene(_:didConnect:)` | Car's `MediaBrowser` binds the service; playback begins when the car sends a play/prepare command that resolves to `onAddMediaItems` |
| Content model | Templates | A **browse tree** of `MediaItem`s (root → children), plus a `MediaSession` for transport |
| Transport control | `CPNowPlayingTemplate` + Now Playing info | The car controls the `Player` behind the `MediaSession` directly |
| Custom car screens | Allowed (templates) | **Not** for a media app — the car UI is fixed; only Car App Library templated apps draw custom screens, which we do not need |

Reference: *Media apps for cars overview*, https://developer.android.com/training/cars/media — a media app supplies a `MediaBrowserService`/`MediaLibraryService` + `MediaSession`; the car provides its own driver-safe UI.

Consequence: the bulk of the work is **backend plumbing** (a media service, a browse tree, a correctly-backed session), not UI. There is no Android analogue to `CarPlaySceneDelegate` that we render into.

---

## 3. Android Auto media app model (verified)

The modern media3 model (verified against https://developer.android.com/media/media3/session/background-playback and https://developer.android.com/guide/topics/media/session/medialibraryservice):

- A **`MediaLibraryService`** (a subclass of `MediaSessionService`) runs as a background/foreground service. The car — and the system media notification, Assistant, Bluetooth, Wear — all connect to it out-of-process via a `MediaController`/`MediaBrowser`.
- The service owns a **`MediaLibrarySession`**, built from a **`Player`** (an `ExoPlayer`). Browsing callbacks live on the session's `MediaLibrarySession.Callback`:
  - `onGetLibraryRoot(...)` → returns the single root `MediaItem`.
  - `onGetChildren(...)` → returns the children of a node.
  - `onGetItem(...)` → returns one item by id.
  - `onAddMediaItems(...)` → invoked when the car selects an item to play; we resolve it to the live-stream `MediaItem` and start playback.
- **The car renders its own UI.** We never draw car screens for a media app.
- **Pagination is not used by Android Auto** — ignore `page`/`pageSize` (Media3 issue #189; also noted on the content-hierarchy guide). Item counts per level are limited for driver-distraction reasons, which is a non-issue for a one-item app.

### The critical constraint: session player == audio player

From the background-playback guide: *the `Player` passed to the session builder must be the actual audio-producing player.* The car sends transport commands (play/pause/stop) to whatever `Player` backs the session, and it reflects **that player's** state and metadata. If the session is backed by a different player than the one producing sound, the car controls and displays the wrong thing. This is the central problem for Maxi80 today — see §5.

---

## 4. Architecture & Skip module placement

Where each new piece lives, following the project's module rules (Android platform code using `android.*`/media3 via `#if SKIP` lives under `Sources/Maxi80Services/Platform/Android/`):

- **`AudioStreamPlayer` (Maxi80Services, transpiled)** — remains the single source of playback truth. Its Android backing `ExoPlayer` (`ExoPlayerStreamPlayer.swift`) becomes the shared player (see §5).
- **`NowPlayingController` (Maxi80Services, transpiled)** — continues to own the `MediaSession`, but the session is rebuilt on the **shared** player and upgraded to a `MediaLibrarySession` (or a new service owns it — see §5 options).
- **Media (Library) service** — a new Android-only type under `Sources/Maxi80Services/Platform/Android/`. Its job: host the `MediaLibrarySession`, serve the browse tree, and hand the car its session via `onGetSession`. **Open question (§9):** whether a `MediaLibraryService` subclass transpiles cleanly from Swift via `#if SKIP`, or must be authored as a raw `.kt` file placed in `Sources/Maxi80Services/Skip/`. Service classes are instantiated by the Android framework (declared in the manifest, constructed reflectively), which is a different lifecycle from the closure-bridged objects Skip already handles; this needs a spike.
- **`RadioPlayerCoordinator` (Maxi80, native)** — unchanged in spirit. It remains the `@MainActor` owner. `SharedPlayer` stays the one composition root. The coordinator continues to receive playback/metadata via the existing callback closures (`onMetadataChanged`, `onPlaybackStateChanged`, `onRemoteCommand`). The car's transport commands arrive through the same `onRemoteCommand` path already wired for the media notification.
- **`AndroidManifest.xml`** — edited to declare the service, the intent filters, and the Auto metadata (§6).
- **`skip.yml`** — media3 version bump (§7).

Data flow (Android): car ⇄ `MediaLibrarySession` (in the media service) ⇄ **shared `ExoPlayer`** ⇄ `AudioStreamPlayer` → callbacks → `RadioPlayerCoordinator` → `RadioPlayerViewModel`/phone UI. Metadata pushed by the coordinator flows the other direction into the session so the car sees artist/title/artwork.

Note the direction rule from CLAUDE.md holds: native `Maxi80` consumes transpiled `Maxi80Services`; all new Android media code stays inside the transpiled `Maxi80Services` module.

---

## 5. The single-player consolidation problem (central risk)

### The problem, precisely

Today there are **two** `ExoPlayer` instances:

1. The real playback player, created in `ExoPlayerStreamPlayer.androidPlay(url:)` (`_exoPlayer`). This is the one that actually produces audio.
2. A **separate "minimal" player** created inside `AndroidNowPlayingController.ensureMediaSession()` (`_sessionPlayer`, line ~99), used purely to construct a `MediaSession` so the media notification exists.

These are never connected. The session player never plays the stream; the metadata code in `platformUpdateNowPlaying` even builds a `MediaMetadata` and throws it away (`_ = metadataBuilder.build()`), and `platformUpdatePlaybackState` is a no-op. This mostly "works" today only because the media notification's usefulness is limited.

For Android Auto this is **fatal**: the car binds the session, sees `_sessionPlayer` (idle, silent, no media item), and would show a stopped/empty player while audio plays out of the other instance. Play/pause from the car would target the wrong player. **The session must be backed by the same `ExoPlayer` that streams the audio.**

### Options

**Option A — Session service owns the one player; `AudioStreamPlayer` delegates to it.**
Create the shared `ExoPlayer` inside the new `MediaLibraryService` (the media3-idiomatic home for it). `AudioStreamPlayer.androidPlay/stop/setVolume` operate on that shared player (obtained via the service, or via a shared holder) instead of creating their own. The session is built on it in the service.
- Pros: matches the canonical media3 topology (service owns player + session, players live and die with the service, foreground-service/notification lifecycle is handled by media3). Cleanest path to correct background behaviour and to "car disconnect doesn't stop audio."
- Cons: biggest refactor. Introduces a service lifecycle that `AudioStreamPlayer` must coordinate with (start/bind the service before playing). The player is no longer created lazily inside `androidPlay`. Requires the Skip-service question (§9) resolved.

**Option B — `AudioStreamPlayer` owns the one player; `NowPlayingController`/service borrow it.**
Keep `_exoPlayer` in `AudioStreamPlayer` as the single instance and hand a reference to `NowPlayingController` (and the media service) so the `MediaSession`/`MediaLibrarySession` is built on it. Delete `_sessionPlayer` entirely.
- Pros: smallest change to the existing playback code; player creation stays where it is; `SharedPlayer` still injects both services and can wire the reference.
- Cons: player lifecycle is tied to `androidPlay/androidStop` (the player is released on stop), but a media3 session/service expects a stable player for the life of the service. Recreating the player on every play/stop means the session must be rebuilt or re-pointed each time — media3 sessions are not designed to swap their `Player`. Risks the car losing its binding on stop. Ordering (session must exist before the car connects, but player is created lazily on first play) is awkward.

**Option C — Long-lived single player, decoupled from play/stop churn.**
A single `ExoPlayer` is created once (at service/session creation), lives for the process/service lifetime, and `play()`/`stop()` become `setMediaItem + prepare + play` / `stop` (or `pause` + `clearMediaItems`) on that same instance rather than build/release. The session is built once on it. Both `AudioStreamPlayer` and the media service reference this one long-lived player.
- Pros: exactly the media3 mental model — one durable player, transport operations mutate it. Session binding is stable across play/stop, so the car never loses the session. Eliminates the "rebuild session on every play" hazard of B. Aligns with "disconnect/stop doesn't tear down the session."
- Cons: changes `AudioStreamPlayer`'s lifecycle semantics (no longer create-on-play/release-on-stop); audio-focus, becoming-noisy receiver, and metadata-listener registration must be rethought as attach-once rather than per-play. Still needs a home for the player (service vs a shared holder).

### Recommendation

**Adopt Option C's long-lived single-player model, hosted by the new media service as in Option A.** Concretely:

- Create **one** `ExoPlayer` at service/session construction and keep it for the service lifetime.
- Build the `MediaLibrarySession` on that player, once.
- Refactor `ExoPlayerStreamPlayer` so `androidPlay/androidStop/androidSetVolume` operate on the shared player (via a shared holder or the service) using `setMediaItem`/`prepare`/`play`/`stop`, and **delete `_sessionPlayer` and the throwaway metadata build** in `AndroidNowPlayingController`.
- Keep audio-focus and the becoming-noisy receiver, but register them against the shared player's lifecycle; note that media3's `MediaSessionService` can manage audio focus and the foreground notification itself, so some of the manual focus code in `ExoPlayerStreamPlayer` may become redundant — evaluate during implementation.
- `NowPlayingController` stops creating its own session and instead publishes metadata into the session's `Player`/`MediaMetadata` on the shared player (so the actual `MediaMetadata` is finally used, not discarded).

This is the media3-canonical topology and the only one that makes the car show and control the real audio while satisfying the "disconnect doesn't stop playback" intent. It is also the largest change and the main reason this is a design doc rather than a quick patch — the consolidation should be validated on the phone (media notification correctly controls audio) **before** any car wiring is added.

---

## 6. Manifest & resource changes

Verified against https://developer.android.com/training/cars/media and https://developer.android.com/media/media3/session/background-playback. All edits go in the tracked `Android/app/src/main/AndroidManifest.xml`.

**Permissions** (foreground media playback is required on modern Android; minSdk 28 / targetSdk 36):
- `android.permission.FOREGROUND_SERVICE`
- `android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK`
- (`android.permission.INTERNET` already present.)

**Service declaration** (inside `<application>`):
- The media service with `android:exported="true"` and `android:foregroundServiceType="mediaPlayback"`.
- Intent filters:
  - `androidx.media3.session.MediaLibraryService` — how media3 controllers/the car discover the library service.
  - `android.media.browse.MediaBrowserService` — legacy `MediaBrowserServiceCompat` action, required for Android Auto/AAOS compatibility.

**Android Auto declaration** (inside `<application>`):
- `<meta-data android:name="com.google.android.gms.car.application" android:resource="@xml/automotive_app_desc" />`.
- New resource `Android/app/src/main/res/xml/automotive_app_desc.xml` containing `<automotive-app>` with `<uses-feature name="media" />` (declares this app as a media app to Android Auto).

**Android Auto vs Android Automotive OS (AAOS) — recommended scope:**
- **Recommend supporting Android Auto (phone-projected) only** for the first iteration. That requires only the service + intent filters + `automotive_app_desc.xml` above and reuses the phone's whole runtime.
- **Do not** add `<uses-feature android:name="android.hardware.type.automotive" android:required="true" />` — that marks the app as an AAOS-native (built-in car OS) build, which is a separate distribution, has its own review/quality bar, and would need the app to run entirely on the head unit. Out of scope.
- If AAOS is ever wanted, it uses the *same* `MediaLibraryService` architecture; the delta is packaging/distribution and quality review, not the media plumbing built here.

---

## 7. Minimal browse tree

For a single live station the tree is trivial (verified against the MediaLibrarySession callback reference and content-hierarchy guide):

- `onGetLibraryRoot` → one browsable **root** `MediaItem` (e.g. id `"root"`). Set content-style/root hints as appropriate but nothing elaborate.
- `onGetChildren("root")` → a list with **exactly one** playable `MediaItem`: "Maxi 80" live stream, with the stream URI, title, and station artwork. Mark it `FLAG_PLAYABLE` (via the media3 `MediaMetadata` `isPlayable`/`mediaType`), not browsable.
- `onGetItem(id)` → return that one item.
- `onAddMediaItems(...)` → resolve the selected id to the live-stream `MediaItem` and start playback on the shared player. Since there is one item, no queue/index concerns (the Media3 #156 start-index caveat is irrelevant here).
- `onGetSearchResult` → not implemented (no search).

Because there is only one leaf, the driver-distraction item-count limits and pagination are non-issues.

---

## 8. media3 version recommendation

**Current:** `androidx.media3:media3-{exoplayer,session,ui}:1.2.1` (declared in `Sources/Maxi80Services/Skip/skip.yml`), released early 2024.

**Recommendation: bump to a recent 1.9.x or 1.10.x stable.** Verified from the AndroidX stable channel (https://developer.android.com/jetpack/androidx/versions/stable-channel) and the media3 releases page:
- Latest stable line is **1.10.1** (May 2026); **1.8.1** and **1.9.4** are also current stable points on maintained branches.
- **Why bump (not stay on 1.2.1):**
  - 1.2.1 predates a large number of `MediaLibraryService`/`MediaSession` fixes specifically relevant to Android Auto (session subscription synchronization, media-item-transition reporting to controllers, system-UI button placement affecting the Android Auto surface, `MediaSessionService`/`MediaLibraryService` becoming a `LifecycleService`). Several of these directly touch the browse/session paths this feature exercises.
  - Session ⇄ car compatibility and notification/foreground-service handling have materially improved.
- **Suggested target: 1.8.1 or 1.9.4** (well-baked stable), or 1.10.1 if we want the newest. Pin all three media3 artifacts (exoplayer, session, ui) to the **same** version — media3 requires uniform module versions.
- **Caveat:** a jump of ~7 minor versions can shift transitive dependency floors (Kotlin stdlib, AndroidX core, Guava, compileSdk expectations). This should be treated as its own validated step (build + smoke-test the phone app) before the Auto work, and diffed against the reference prototype if the Skip build breaks. Also re-verify the Guava pin (`com.google.common...` used by `NowPlayingSessionCallback`) is compatible.

---

## 9. Testing via Desktop Head Unit (DHU)

Verified against https://developer.android.com/training/cars/testing/dhu.

Setup:
1. **Install the DHU** via Android Studio → SDK Manager → SDK Tools → *Android Auto Desktop Head Unit Emulator*. It installs to `<SDK>/extras/google/auto/`; on macOS `chmod +x ./desktop-head-unit`.
2. **Physical phone required.** Google's DHU docs state a real device (Android 9 / API 28+, which matches our minSdk 28) is required — the emulator is not officially supported for Android Auto media testing. (Community setups exist for all-emulator testing but are unsupported and fiddly; plan on a USB-connected phone.)
3. On the phone: install the Maxi80 debug build, enable **Developer options**, install/update **Android Auto**, then in Android Auto enable **Developer mode** (tap the version 10×) and turn on **Unknown sources** so our sideloaded (non-Play-Store) build is allowed in the car UI. This "Unknown sources" toggle is the setting most likely to be forgotten.
4. Start the **head unit server** from Android Auto's overflow menu; ensure "Add new cars to Android Auto" is enabled.
5. On the workstation: `adb forward tcp:5277 tcp:5277`, then run `./desktop-head-unit`. The DHU window renders the car UI and the phone enters projection mode.

What to verify in the DHU:
- Maxi80 appears in the car's media app list.
- Selecting it starts the live stream (auto-play intent) and the car shows the correct **artist/title/artwork**.
- The car's play/pause controls actually control the **audible** stream (this is the acceptance test for §5's consolidation).
- Disconnecting the DHU leaves phone audio playing.
- Metadata updates (song changes) propagate to the car UI.

---

## 10. Risks & open questions

- **[Open — needs a spike] Does a media3 `MediaLibraryService` subclass transpile from Swift via `#if SKIP`, or must it be a raw `.kt` file in `Sources/Maxi80Services/Skip/`?** Android instantiates services reflectively from the manifest class name and drives an override-heavy lifecycle (`onCreate`, `onGetSession`, `onDestroy`). Skip has handled `BroadcastReceiver`/`MediaSession.Callback` subclasses in Swift already (see existing Android files), which is encouraging, but a manifest-declared `Service` with a framework-managed lifecycle is a step beyond. **Action:** prototype a trivial `MediaLibraryService` in the reference `hello-world` project first; if transpilation or the manifest class-name resolution is unreliable, author the service as `.kt` and keep the browse-tree/session logic there, calling back into transpiled Swift.
- **Player-lifecycle refactor (§5) is the biggest risk.** Moving from create-on-play/release-on-stop to a single long-lived player touches audio focus, the becoming-noisy receiver, and metadata listeners. Regression risk to existing phone playback. Mitigate by landing and validating the consolidation on the phone (media notification correctly controls audio) before any car code.
- **media3 version jump** may cascade into Kotlin/AndroidX/Guava/compileSdk bumps and Skip build breakage. Isolate as its own step; diff against the reference prototype.
- **Foreground service + notification.** media3's service manages the media notification and foreground promotion; we must ensure it doesn't conflict with whatever `AndroidNowPlayingController` currently does, and that `FOREGROUND_SERVICE_MEDIA_PLAYBACK` behaviour is correct on targetSdk 36.
- **Service class name in the manifest** must resolve to the transpiled Kotlin class's fully-qualified name (Android package from `Skip.env`). Getting this wrong yields a silent no-show in the car — the same class-name-resolution concern CarPlay solved with `@objc(...)`.
- **Auto-play semantics.** Android Auto begins playback when the car issues a prepare/play that lands in `onAddMediaItems`; verify our single-item tree makes "tap the app → stream starts" happen without an extra user tap, matching the CarPlay auto-play intent.
- **AAOS scope confirmation.** This doc scopes to Android Auto (phone-projected) only. Confirm no product requirement for a native Automotive OS build.
- **Live stream + `MediaMetadata`.** ICY/stream metadata currently drives `onMediaMetadataChanged`; confirm the same metadata still flows once the player is long-lived and shared, and that it reaches the session so the car sees live song changes.

---

## 11. Rough task breakdown (titles only)

1. Spike: verify `MediaLibraryService` subclass transpiles via `#if SKIP` (else decide on `.kt`) in the reference prototype.
2. Bump media3 to a recent stable (1.8.1 / 1.9.4 / 1.10.1); re-pin Guava; validate the existing phone build.
3. Consolidate to a single long-lived `ExoPlayer` shared by playback and the session; delete the `_sessionPlayer` and the throwaway metadata build; rework audio focus / noisy receiver / metadata listener for the long-lived player.
4. Introduce the `MediaLibrarySession` (upgraded from the current `MediaSession`) backed by the shared player; publish real metadata/artwork into it.
5. Add the `MediaLibraryService` (or `.kt`) hosting the session and serving the minimal browse tree (`onGetLibraryRoot`/`onGetChildren`/`onGetItem`/`onAddMediaItems`).
6. Manifest & resources: permissions, service + intent filters, `com.google.android.gms.car.application` meta-data, `automotive_app_desc.xml`.
7. Wire car transport commands through the existing `onRemoteCommand` path into `RadioPlayerCoordinator`; ensure auto-play-on-select and disconnect-keeps-playing.
8. DHU test pass: appears in car, plays audio, correct metadata/artwork, car controls the audible stream, disconnect behaviour.
9. Docs / memory note; regression check of phone media notification and CarPlay parity of intent.
