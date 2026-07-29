# Sleep Timer — Design & Implementation Plan (#1)

## Context

Radio listeners frequently fall asleep with the app playing, leaving audio running all night (battery, data, sound). Issue [#1](https://github.com/maxi80-com/maxi80-app/issues/1) asks for a **sleep timer**: the user picks a duration, playback automatically stops when it fires, and the running timer is visible in the UI with an easy way to cancel or extend it. Scheduled for after 5.0.0 ships.

The timer must work on **iOS, macOS, and Android** and drive the existing playback layer (`RadioPlayerCoordinator` / `AudioStreamPlayer`) rather than any platform-specific scheduling mechanism, so behavior stays consistent everywhere and survives backgrounding / activity recreation.

> **TV IS OUT OF SCOPE (2026-07-29, per user).** Do **not** add any sleep-timer UI to **TV (tvOS or Android TV)** — leave `TVRadioPlayerView` exactly as it ships today (play/pause only). No sleep button, no picker, no countdown on TV. The coordinator/services timer + fade code is cross-platform and harmless on TV (simply never invoked there); only the UI additions are phone/tablet-only.

### Decisions (confirmed with the user)

| Question | Decision |
|----------|----------|
| Control location | **Inline secondary button** (moon glyph) in `PlaybackControlsView`, next to share/donate |
| Duration options | **Presets only**: 15 / 30 / 45 / 60 / 90 min (no custom picker) |
| Firing behavior | **Fade-out on every platform** — requires new ExoPlayer private-volume plumbing on Android so the fade does *not* touch system volume |
| Running-state UI | **Countdown pill** with cancel + extend, styled like the existing "Back to live" pill |

### Design principles grounded in the codebase

- The codebase uses **structured `Task` + `Task.sleep(nanoseconds:)`** exclusively for scheduling — no `Timer`/`scheduledTimer`/`DispatchQueue.asyncAfter`. The closest existing analog is `RadioPlayerCoordinator.startArtworkRetry(for:)` (`RadioPlayerCoordinator.swift:452`): a stored cancelable `Task`, delay loop, `Task.isCancelled` guards. **Model the timer on it.**
- Process-wide playback state lives in `RadioPlayerCoordinator` (`@MainActor @Observable`) so it survives Android activity recreation. The sleep-timer state belongs there too.
- `RadioPlayerViewModel` surfaces coordinator state to SwiftUI via **computed read-through properties** (there is no manual `syncFromCoordinator()`; Observation propagates automatically — e.g. `isPlaying` at `RadioPlayerViewModel.swift:43-46`).
- Cross-platform glyphs use the SF-Symbol-on-Apple / Material-icon-on-Android dual pattern via `AndroidIcon` + `PlaybackControlsView.secondaryIcon(_:android:tint:)` (`PlaybackControlsView.swift:133`).

---

## A1. Coordinator — timer engine

**File:** `Sources/Maxi80/RadioPlayerCoordinator.swift`

- Add observable state near the other `@Observable` props (lines 37–48):
  - `public private(set) var sleepTimerFiresAt: Date?` — `nil` means inactive. This is the single source of truth for both "is it running" and "how long is left"; storing the fire *date* (not a countdown int) means the remaining time is always computed fresh and survives suspension/resume without drift.
- Add a cancelable task handle alongside `historyTask` (line 61) / `artworkRetryTask` (line 69):
  - `@ObservationIgnored private var sleepTimerTask: Task<Void, Never>?`
- Public methods (modeled on `startArtworkRetry(for:)`, line 452):
  - `func startSleepTimer(minutes: Int)` — cancel any existing `sleepTimerTask`; compute and set `sleepTimerFiresAt`; launch a `Task { [weak self] in … }` that `Task.sleep`s until the fire time (guarding `Task.isCancelled`), then runs the fade helper (A2), then clears state.
  - `func cancelSleepTimer()` — cancel the task, set `sleepTimerFiresAt = nil`, reset playback attenuation to full (A2).
  - `func extendSleepTimer(minutes: Int)` — simplest correct approach: compute current remaining from `sleepTimerFiresAt`, then `cancelSleepTimer()` + `startSleepTimer(minutes: remainingMinutes + minutes)`. (Or restart from a stored total; remaining-based is fine for presets.)
- **On fire:** run the fade helper (A2), then call the **existing** `stopForDisconnect()` (line 179 — `player.stop()`, `playbackState = .paused`, `publishPlaybackState(isPlaying: false)`), then reset attenuation to full and set `sleepTimerFiresAt = nil`.
- **Cancel on manual playback changes:** call `cancelSleepTimer()` from `pause()` (line 170) / `stopForDisconnect()` and on the next `play()` (line 132), so a manual stop/start never leaves a stale timer running or fades a freshly-resumed stream. (Guard against recursion between `cancelSleepTimer()` and `stopForDisconnect()` — the fire path calls `stopForDisconnect()` directly and must not re-enter cancel logic that fights it; clear `sleepTimerTask` before calling stop, or have the fire path bypass the cancel-on-stop hook.)

**Testability:** extract the fire-time / remaining-minutes arithmetic into a small pure function (or accept an injectable clock) so it can be unit-tested without real sleeping, mirroring the existing test targets.

---

## A2. Fade-out plumbing (must NOT touch user or system volume)

The user's volume slider value and — critically on Android — the **system media volume** must be untouched by the fade. Introduce a **transient playback attenuation** multiplier that is separate from user volume: effective output = `userVolume * attenuation`, where `attenuation` is normally `1.0` and only the fade drives it toward `0`.

- **`Sources/Maxi80Services/AudioStreamPlayer.swift`** — add a bridged method `func setPlaybackAttenuation(_ multiplier: Double)` (clamp 0…1). Dispatch via `#if` to platform impls, same shape as `updateVolume(_:)` (line 76). Keep a stored `userVolume` so attenuation and user volume can be composed and reapplied. (This class is `/* SKIP @bridge */` — keep the bridge annotations intact.)
- **iOS/tvOS** — `Sources/Maxi80Services/Platform/iOS/AVPlayerStreamPlayer.swift` (`platformSetVolume` at line 59): set `avPlayer?.volume = userVolume * multiplier`. `AVPlayer.volume` is per-app attenuation relative to system volume — safe, does not touch system volume.
- **macOS** — `Sources/Maxi80Services/Platform/macOS/AVPlayerStreamPlayer+macOS.swift` (`macSetVolume` at line 51): same via `macPlayer?.volume`.
- **Android** — `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`: set ExoPlayer's **private** `player.volume = multiplier` (0…1). **Do NOT route through `androidSetVolume` (line 219)** — that drives `STREAM_MUSIC` system volume and fires the `onVolumeChanged` observer (see comment lines 212–217). ExoPlayer's private `volume` normally stays at `1.0`, so the fade path is the only writer of it and the user's system volume is never touched.
- **Coordinator fade helper:** step `attenuation` from `1.0 → 0` over ~2–3 s (e.g. ~10–15 steps with `Task.sleep`), then call `stopForDisconnect()`, then `setPlaybackAttenuation(1.0)` so the next `play()` starts at full volume. Guard each step with `Task.isCancelled` so an extend/cancel mid-fade aborts cleanly and restores attenuation.

---

## A3. ViewModel — read-through state + actions

**File:** `Sources/Maxi80/RadioPlayerViewModel.swift` (computed-passthrough pattern, e.g. `isPlaying` lines 43–46)

- Computed read-through:
  - `var isSleepTimerActive: Bool { coordinator.sleepTimerFiresAt != nil }`
  - `var sleepTimerFiresAt: Date? { coordinator.sleepTimerFiresAt }` — the pill computes remaining from this.
- Action methods delegating to the coordinator:
  - `func startSleepTimer(minutes: Int)`, `func cancelSleepTimer()`, `func extendSleepTimer(minutes: Int)`.
- **Live countdown without a new timer:** drive the pill's ticking label with SwiftUI's `TimelineView(.periodic(from:by:))` (1 s cadence). The label text is `sleepTimerFiresAt - now` formatted `MM:SS`; the `TimelineView` only needs to trigger re-render, so no Combine/`Timer` and no per-second observable writes. (`VolumeSliderView.swift` / `PlaybackControlsView.swift` already use `PreviewMocks.makeViewModel` for previews — reuse for the pill preview.)

---

## A4. UI — Option A control bar + picker sheet + countdown

> **Layout basis: Option A from `docs/CONTROL-BAR-design.md` (chosen), phone/tablet only.** The control bar becomes **two tiers** — the big centered play hero on top, and a balanced tray of three equal ghost-circle utility buttons (`Share · Sleep · Donate`) below. This fixes the imbalance the fourth button introduced and, crucially, the sleep **active state reuses the reserved status slot** (`liveIndicator()`) for the countdown pill, so activating the timer causes **zero reflow**. Follow `CONTROL-BAR-design.md` for exact structure, the per-idiom size table (keyed on `PlatformEnvironment.isPad`), and spacing constants. **TV is untouched** — the two-tier tray and countdown apply only to the phone/tablet `PlaybackControlsView` / `RadioPlayerView` path.

- **Sleep button** — `Sources/Maxi80/PlaybackControlsView.swift`: the Sleep control is the middle utility button in the new tray (per Option A), rendered with the same ghost-circle treatment as Share/Donate rather than shoehorned into the old `HStack(spacing: 36)`. Apple SF Symbol `moon.zzz` (→ `moon.zzz.fill` when a timer is active); Android via a new `MaterialSymbol` case. Tapping toggles a `@State private var showSleepTimerSheet` — gate any Apple-only sheet state the same way `showShareSheet` is gated (`#if !os(Android)`, lines 15–19) if needed, though a sheet works on all platforms.
- **Picker sheet** — presets only: buttons for 15 / 30 / 45 / 60 / 90 min; selecting one calls `viewModel.startSleepTimer(minutes:)` and dismisses. Present via `.sheet` following the shape of the only existing sheet, `ShareSheet.swift:18`.
- **Countdown (in the status slot)** — when `viewModel.isSleepTimerActive`, render the countdown pill in the reserved `liveIndicator()` status slot (Option A) rather than as an extra element that pushes layout: moon glyph + `MM:SS` (via `TimelineView`) + an `✕` button calling `cancelSleepTimer()`, plus a tap-to-extend affordance (tapping the pill body re-opens the picker, or an explicit "+15" — decide during build; extend routes to `viewModel.extendSleepTimer`). Style it like `backToLiveLabel` (`RadioPlayerView.swift:271-285`). Because it lives in the existing status slot shared by both `portraitView()`/`landscapeView()`, the `if/else` layout structure stays intact (see note below).
- **Android glyph** — `Sources/Maxi80/AndroidIcon.swift`: add a `MaterialSymbol` case `.bedtime` to the enum (lines 17–38) with its `iconKey`, and a mapping in `MaterialIconComposer.Compose` (lines 76–90) to `Icons.Filled.Bedtime`.
- **TV** — **no change.** `Sources/Maxi80/TV/TVRadioPlayerView.swift` stays as-is (play/pause only); no sleep-timer control, picker, or countdown on tvOS / Android TV.

> **Layout-structure caveat:** current `main` uses a plain `Group { if isPortrait { portraitView() } else { landscapeView() } }` in `RadioPlayerView` — there is **no `AnyLayout`** (an earlier memory to the contrary described an unmerged worktree branch). Rotation recreates `CoverFlowView`, compensated by `beginReorientation()` (line 38) + the width-folded re-pin in `CoverFlowView`. This workstream only *adds* a control/pill within the existing branches — keep the `if/else` intact. **This is the only file shared with the iPad-layout plan (#52); coordinate ordering to avoid a merge conflict.**

---

## A5. Localization

**File:** `Sources/Maxi80/Resources/Localizable.xcstrings` — add en + fr keys:
- "Sleep timer" (button/sheet title), the preset labels (or a `"%d min"` format string), "Cancel", "Extend", and accessibility labels ("Set sleep timer", "Sleep timer active, %@ remaining").
- In views use `Text("…", bundle: .module)`; for the formatted `MM:SS` / "%@ remaining" strings use `Bundle.module.localizedString(forKey:value:table:)`, mirroring the share-text format lookup at `RadioPlayerViewModel.swift:370-372`.
- Durations/labels belong in the string catalog, **not** `BrandConstants` (which holds only non-localized brand strings/endpoints).

---

## Files touched (summary)

| File | Change |
|------|--------|
| `Sources/Maxi80/RadioPlayerCoordinator.swift` | timer state + `start/cancel/extend` methods + fade helper |
| `Sources/Maxi80Services/AudioStreamPlayer.swift` | `setPlaybackAttenuation(_:)` bridged method + `userVolume` compose |
| `Sources/Maxi80Services/Platform/iOS/AVPlayerStreamPlayer.swift` | attenuation via `avPlayer.volume` |
| `Sources/Maxi80Services/Platform/macOS/AVPlayerStreamPlayer+macOS.swift` | attenuation via `macPlayer.volume` |
| `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift` | attenuation via ExoPlayer **private** `player.volume` |
| `Sources/Maxi80/RadioPlayerViewModel.swift` | read-through state + delegating actions |
| `Sources/Maxi80/PlaybackControlsView.swift` | moon button + picker sheet + countdown pill |
| `Sources/Maxi80/AndroidIcon.swift` | new `MaterialSymbol` case + composer mapping |
| `Sources/Maxi80/TV/TVRadioPlayerView.swift` | focus-navigable control in `controlStack()` |
| `Sources/Maxi80/Resources/Localizable.xcstrings` | en + fr strings |

---

## Verification

Shared setup: ensure `Sources/Maxi80/Resources/Configuration.plist` exists (`cp Sources/Maxi80/Resources/Configuration.plist.template …` if missing). Trigger the Skip transpiler by building the **macOS** destination.

- `swift build` (macOS) and `skip android build` both compile.
- iOS simulator: start playback, set a 15-min timer (temporarily shorten the fire delay for testing), confirm the pill counts down, playback **fades then stops**; confirm cancel and extend work; confirm starting a timer then manually pausing/playing **cancels** the timer.
- Confirm the user volume slider and (Android) system media volume are **unchanged** after a fade+stop and after the next play (attenuation reset to full). On Android verify with `adb shell dumpsys` that `STREAM_MUSIC` didn't move and the media notification card behaves.
- Verify the timer survives backgrounding (Apple `scenePhase`, Android activity recreation) and doesn't fight Now Playing / CarPlay / remote commands.
- tvOS: the control, picker, and pill cancel/extend are reachable and dismissible with the remote (`skip app launch` on tvOS + Android TV paths).
- `swift test` for the coordinator timer arithmetic (injectable clock / pure fire-time calc), mirroring existing test targets.
