# Android TV parity — reproduce this session's tvOS TV UX on Android TV

**Audience:** a second agent working in parallel on the Android TV path.
**Scope:** Bring the Android TV (`#if os(Android)`) rendering of `TVRadioPlayerView` / `TVHistoryRow`
to parity with the tvOS work done this session. **Do NOT touch the tvOS (`#if os(tvOS)`) branches** —
they are done and being device-tested by another agent. **Do NOT touch phone / CarPlay / macOS / common
code**, with ONE exception already handled (see “Shared fix” below) — you should not need to re-do it.

**Nothing is committed.** The other agent holds uncommitted changes in the same two files
(`Sources/Maxi80/TV/TVRadioPlayerView.swift`, `Sources/Maxi80/TV/TVHistoryRow.swift`). Coordinate: your
edits are confined to the `#if os(Android)` / `#elseif os(Android)` branches and Android-only helpers.
If you can, work on a branch/worktree and diff carefully so you never modify a tvOS or shared line.

---

## CRITICAL: Android is NOT tvOS. Read this before writing any code.

`Maxi80` is a **Skip Fuse (native)** module. On Android it compiles to `libMaxi80.so` via
`swift build --swift-sdk …-android`. In that compile: **`SKIP` is NOT defined; `os(Android)` IS.**
So every Android-behavior branch MUST use `#if os(Android)`, never `#if SKIP` (a `#if SKIP` branch is
DEAD CODE in this module on device). This has burned us repeatedly — see the project memory
`coverflow-rotation-pin-findings`.

**SkipUI API gaps that break the tvOS approach (verified against `.build/checkouts/skip-ui` this session):**

| tvOS API used | Android (SkipUI) status | Consequence |
|---|---|---|
| `.focusSection()` | **Does not exist in SkipUI** | Won't compile / no focus routing. Must solve focus differently. |
| `.defaultScrollAnchor(.trailing)` | **Does not exist in SkipUI** | No declarative initial scroll position. |
| `.defaultFocus($binding, value)` | **No-op stub** | Cannot set initial focus this way. |
| `.focused($binding)` | **Works** — calls Compose `requestFocus()` when the binding matches | This is how you set initial focus on Android (already done for the play button). |
| `@FocusState` | **Works** — but a property on a bridged View must be `internal`, not `private` | See play-button precedent. |
| `.transition`, `AnyTransition.asymmetric`, `.opacity`, `.offset(x:y:)`, `.combined(with:)` | **Work** | Transitions are usable on Android. |
| `AnyTransition.scale(_:)` (no anchor) | **Works** | Use `.scale(0.6)` positional. |
| `AnyTransition.scale(_:anchor:)` | **`@available(*, unavailable)`** | Do NOT pass an `anchor:`. The tvOS code’s `.scale(scale:)` calls must become `.scale(0.6)` (positional, no label, no anchor) on Android. |
| `matchedGeometryEffect` | **`@available(*, unavailable)`** + `Namespace` is a `fatalError()` stub | No matched-geometry flight. (We chose the transition approach anyway.) |
| `.buttonStyle(.card)` / custom tvOS `ButtonStyle` with `@Environment(\.isFocused)` | `.card` is tvOS-only; `isFocused` env behavior on Android/Compose is unverified | Prefer the existing Android pattern: `.buttonStyle(.plain)` + `.focused($binding)` + `.scaleEffect(focused ? … )`, which is already proven for the play button. |

**Build & verify (BOTH paths are mandatory — one is not enough):**
```
swift build                               # macOS/native compile of the shared Swift
skip android build                        # rebuilds libMaxi80.so (NOT the APK)
(cd Android && gradle :app:assembleDebug --offline)   # builds the APK; run from Android/, there is NO ./gradlew, use system gradle
adb -s emulator-5554 install -r .build/Android/app/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell monkey -p com.stormacq.android.maxi80 -c android.intent.category.LAUNCHER 1
```
- `skip android build` alone does NOT repackage the APK; you must run the gradle assemble step too.
- Confirm your change is actually in the shipped `.so` before trusting a device test:
  `unzip -p .build/Android/app/outputs/apk/debug/app-debug.apk lib/arm64-v8a/libMaxi80.so | strings | grep <a-marker-string-from-your-code>`
- Test on the **Android TV** AVD (`sdk_google_atv64`, UI mode television). It is `emulator-5554` in this
  session but re-check `adb devices` and target it explicitly — the env auto-launches phone/Car AVDs too.
- Drive focus/D-pad with `adb shell input keyevent KEYCODE_DPAD_{UP,DOWN,LEFT,RIGHT,CENTER}` and inspect
  focus state with `adb shell uiautomator dump /sdcard/x.xml` then read it (grep `focused="true"`,
  `content-desc`). This is how the play-button focus was verified this session.

---

## What "parity" means — the tvOS changes to mirror

All of the following were implemented for tvOS this session in `TVRadioPlayerView.swift` and
`TVHistoryRow.swift`. Each item below states the tvOS behavior, its current Android state, and what you
must do for Android.

### 1. Layout: hero cover + right-growing history  ✅ likely already parity
- **tvOS/shared:** `body` now renders `heroCover()` above `songLabel()`, then `controlStack()`, then
  `TVHistoryRow`. `heroCover()` shows `heroCoverModel` (the focused/browsed cover, else the live now
  slot). History row shows PAST covers only (`viewModel.covers.dropLast()`), oldest→newest L→R.
- **Android:** `heroCover()` and `heroCoverModel` are **not** tvOS-gated — the `#else` branch of
  `heroCover()` renders the plain image, and `heroSize` already has an `#if os(Android)` value (220).
  `titleFontSize`/`artistFontSize` already have Android values (34/22). `controlStack()`’s `#else`
  branch renders just `playButton()`.
- **Your task:** verify on the Android TV emulator that the hero shows above the labels and the history
  row is history-only, oldest→newest. This should already be true (shared code). If the hero doesn’t
  render, recall the Fuse gotcha: **`body` must inline `#if os(Android)` branches** — do not hoist a
  branch into a separate computed `var`, it renders empty on Android (see memory
  `coverflow-rotation-pin-findings`, gotcha #1). The current structure is fine; just don’t “refactor” it.

### 2. History row opens on the NEWEST (rightmost) cover
- **tvOS:** `.defaultScrollAnchor(.trailing)` on the ScrollView.
- **Android:** that modifier does not exist in SkipUI. The Android `#else` body branch currently does a
  plain `ScrollView` with NO initial scroll. Per project memory (`tv-support`, and the pin findings),
  the transpiled Android `ScrollView` **ignores `scrollTo(..., anchor: .trailing)` on appear**.
- **Your task — this is the hard one. Options, in order of preference:**
  1. **Reverse the array on Android** so the newest is the FIRST (leftmost) item, which is where the
     Compose row naturally rests. i.e. Android `orderedCovers` = `Array(viewModel.covers.dropLast().reversed())`.
     This is the approach the TV history row *originally* used and it’s the only reliable “open on live”
     lever on Android (documented in memory `tv-support`). **Trade-off:** newest-on-left contradicts the
     tvOS newest-on-right ordering, so parity is “opens on newest,” not “identical L→R order.” Confirm
     with the user if the ordering divergence is acceptable, OR:
  2. Try a Compose-side initial index via a native `ComposeView` `LazyRow` with
     `rememberLazyListState(initialFirstVisibleItemIndex:)` — this is the technique that fixed the phone
     rotation carousel (memory `coverflow-rotation-pin-findings`, “FIX IMPLEMENTED & WORKING”), but it is
     heavy (Android-only reimplementation of the row, Coil for artwork, no callbacks through the composer).
     Only pursue if the user rejects option 1.
  - Keep `orderedCovers` for tvOS EXACTLY as-is (`dropLast()`, no reverse). Only change the Android branch.

### 3. Focus routing: UP from any cover → play button; DOWN → row
- **tvOS:** solved with `.focusSection()` on both the control stack (wrapped full-width in an `HStack`
  with `Spacer`s) and the history ScrollView.
- **Android:** `.focusSection()` **does not exist in SkipUI**. This is the biggest unknown for Android.
- **Your task:** investigate how D-pad focus traversal behaves in SkipUI/Compose on Android TV.
  - First, EMPIRICALLY test the current build: does UP from a focused cover already reach the play
    button on Android (Compose’s default focus search may already do the right thing, unlike tvOS’s
    stricter geometric model)? Use `adb keyevent` + `uiautomator dump` to observe. **Do not assume** —
    measure. It’s entirely possible Android needs no fix here.
  - If it does need help, the SkipUI-available lever is `.focused($binding)` + `@FocusState` (proven for
    the play button). You may be able to steer focus by observing the focused cover and programmatically
    moving focus, but avoid fighting the framework. Report findings to the user before building anything
    elaborate. Do NOT introduce `.focusSection()` (won’t compile).

### 4. "Back to live" button
- **tvOS:** a focusable pill (`backToLiveButton()` + `TVPillButtonStyle`) shown while
  `viewModel.isBrowsingHistory`, inside the `#if os(tvOS)` control stack. Tapping calls
  `viewModel.returnToLive()` and returns focus to play.
- **Android:** the control stack `#else` branch renders only `playButton()` — there is NO back-to-live
  button on Android, and `backToLiveButton()`/`TVPillButtonStyle` are `#if os(tvOS)`-only.
- **Your task:** add an Android back-to-live control **only if the Android UX needs it** (it depends on
  whether the Android history row lets the user browse/select a cover the way tvOS focus does). If you
  add it: gate it `#if os(Android)`, mirror the pill visually, use the proven Android button pattern
  (`.buttonStyle(.plain)` + `.focused` + `.scaleEffect`), and DON’T use `@Environment(\.isFocused)`
  custom `ButtonStyle` until you’ve verified it works on Compose. Wire the tap to `viewModel.returnToLive()`.
  The `Image(systemName: "dot.radiowaves.left.and.right")` used on tvOS is an SF Symbol — on Android use
  `AndroidIcon(symbol: .liveBroadcast, …)` (see `AndroidIcon.swift`; the phone “Back to live” already
  does this — copy that pattern, do not invent).

### 5. Play button: gentle focus affordance, no platter
- **tvOS:** custom `TVGlyphButtonStyle` (scale + soft halo, suppresses the white platter).
- **Android:** ALREADY DONE this session — the `#elseif os(Android)` branch uses `.buttonStyle(.plain)`
  + `.focused($playFocused)` + `.scaleEffect(playFocused ? 1.15 : 1)` + `.task { playFocused = true }`
  for initial focus. **Leave it as-is.** Do NOT try to port `TVGlyphButtonStyle` to Android (it relies
  on `@Environment(\.isFocused)` in a `ButtonStyle`, unverified on Compose).
- **Your task:** just verify on device it still looks/behaves right after your other changes.

### 6. Fonts too large on Android  ✅ already done
- `titleFontSize`/`artistFontSize` already branch to 34/22 on Android. Verify no regression.

### 7. Hero crossfade on song change
- **What was dropped:** the elaborate hero→history *shrink + drift-down* transition was prototyped and
  reverted (didn’t read on device). Do NOT implement that.
- **What SHIPS (tvOS + iOS):** a simple opacity **crossfade** of the hero/now-cover when the cover
  changes — the previous image fades out, the new one fades in. On tvOS it's on the `TVRadioPlayerView`
  hero: a `heroKey(cover)` helper returns the cover's ARTWORK identity (`cover.artworkURL ??
  cover.assetName ?? cover.id`), and the image gets `.id(key)` + `.transition(.opacity)` +
  `.animation(.easeInOut(duration: 0.4), value: key)`, gated `#if os(tvOS)`.
  (iOS applies the same idea to the Cover Flow now-cell, `#if os(iOS)` — not your concern.)
- **KEY ON ARTWORK, NOT TITLE (important):** an earlier version keyed on `displayedTitle|displayedArtist`
  and flashed through the placeholder, because on a song change the TITLE updates immediately
  (`currentSong = B`) while the new artwork only resolves after an `await fetchArtwork` — so a title key
  rebuilt the hero while the cover was still the old/placeholder image. Keying on the artwork URL/asset
  makes the rebuild coincide with the image actually changing. Mirror THIS (artwork key), not the title.
- **Android task:** mirror the tvOS hero crossfade on the Android hero, gated `#if os(Android)`.
  SkipUI supports `.transition(.opacity)` and `.animation(_:value:)` (verified this session). Reuse the
  same `heroKey(cover)` helper — widen its gate to `#if os(tvOS) || os(Android)` so Android can call it
  too, WITHOUT touching the tvOS branch of `heroCover()`. Do NOT use `.scale(scale:)`/`anchor:`
  (unavailable on Android) — a plain `.opacity` transition is all that's needed. Verify on device at a
  real song change (you can’t force one on the emulator deterministically; watch the live stream flip or
  briefly inject a fake metadata event and remove it before finishing). If it’s janky on Compose, report
  it — an instant swap is an acceptable fallback.
- **Placeholder-flash / image cache — Apple-only, and the coordinator seeds it:**
  - On Apple, rebuilding the hero via `.id()` restarts `AsyncImage` and briefly flashes the generic
    cover. This session added an Apple-only decoded-`Image` cache (`CoverImageCache` in
    `CoverFlowView.swift`, gated `#if canImport(UIKit) || canImport(AppKit)`): `CoverImage` renders a
    cached image synchronously, and stores each image on first successful `AsyncImage` load.
  - Additionally, `RadioPlayerCoordinator.cacheArtworkImage(_:)` seeds that cache the moment artwork
    resolves — called right after `currentArtwork = artwork` in BOTH `handleMetadataChanged` and
    `applyRetriedArtwork`. `fetchArtwork` already decoded `ArtworkResult.image` (Apple only), so the new
    song's cover is cached before it becomes the hero → no `AsyncImage` reload, no flash. Guarded
    `#if canImport(UIKit) || canImport(AppKit)`; the `#if os(Android)` path of `ArtworkResult.image` is
    `nil`, so this is inert on Android.
  - **Android does NOT get `CoverImageCache` or the seeding** — `CoverImage`'s Android path uses
    `AsyncImage` backed by Coil, which caches decoded bitmaps itself, and `ArtworkResult` carries no
    decoded `Image` on Android to seed with. **Do not port the Apple cache.** Your only task here is to
    verify on device that (a) browsing history and (b) a live song change do NOT flash the generic cover.
    If either does, it’s a Coil cache-config issue to investigate on the Android `CoverImage`/ExoPlayer
    side — report it; don’t replicate the Apple `Image` cache (there’s no Apple `Image` on Android).

### 8. Readable title/artist on any background (luminance-driven text color)
- **Shared (both platforms):** `RadioPlayerViewModel` gained two read-only helpers — `dominantRGB`
  (the raw `RGBColor` behind `dominantColor`) and `isBackgroundDark` (true when there's no dominant
  color → branded dark gradient, or its Rec.601 luminance `0.299r+0.587g+0.114b < 0.55`). The TV
  `titleColor`/`subtitleColor` now use `viewModel.isBackgroundDark` on BOTH platforms: white text on
  dark backgrounds, dark text on bright ones. This replaced the old Android `colorScheme`-based check.
- **Android:** this is ALREADY DONE and NOT platform-gated — `titleColor`/`subtitleColor` in
  `TVRadioPlayerView` already call `viewModel.isBackgroundDark` unconditionally, and the shared helper
  works on Android (pure arithmetic on `RGBColor`, no UIKit). **Leave it as-is.**
- **Your task:** just verify on the Android TV emulator that titles are readable over both dark and
  bright album-art backgrounds. If a specific background still reads wrong, the single tunable is the
  `0.55` threshold in `RadioPlayerViewModel.isBackgroundDark` (shared — change only with user sign-off).

---

## Shared fix already done this session (DO NOT redo, but be aware)
A history **de-dup bug** (first song after launch appeared twice) was fixed in the shared
`RadioPlayerCoordinator.handleMetadataChanged()` — before appending a live entry it now heals in place
if the newest history entry is the same song by `songIdentity`. This is common code and already fixes
Android too. Regression tests added in `Tests/Maxi80Tests/HistoryMergeTests.swift`. You do not need to
touch this; just know the history now behaves correctly on Android as well.

Also done this session (Apple-only, ignore): the tvOS app icon via `TVAppIcon.brandassets` +
`ASSETCATALOG_COMPILER_APPICON_NAME[sdk=appletv*]` in `Darwin/Maxi80.xcconfig`. Android leanback banner
is a separate concern (`tv_banner.xml`, see memory `tv-support`) and is out of scope here unless asked.

---

## Definition of done
1. `swift build` green, `skip android build` green, `(cd Android && gradle :app:assembleDebug --offline)` green.
2. Marker string from each change confirmed present in the packaged `libMaxi80.so`.
3. On the Android TV emulator, screenshot-verified: hero above labels; history row history-only and
   opening on the newest track; D-pad UP reaches play from any cover (or documented why it already
   worked / why it can’t); play button focus affordance intact; (if added) back-to-live works; (if added)
   the song-change transition plays without jank.
4. You changed ONLY Android branches + Android-only helpers in the two TV files. `git diff` shows no
   edits to any `#if os(tvOS)` block, shared code, or phone/car/macOS files.
5. Report to the user any place where true parity isn’t achievable on Android (esp. history ordering in
   item 2 and focus routing in item 3) with the trade-off you chose.

## Key project memories to read first
- `coverflow-rotation-pin-findings` — `#if SKIP` is dead on device (use `#if os(Android)`); Compose row
  reset/scroll behavior; the `ComposeView`+`LazyRow` technique; Fuse `body`-inlining gotcha.
- `tv-support` — TV architecture (`isTVMode` → `TVRadioPlayerView`), the reverse-order history trick,
  tvOS/Android compile gotchas.
- `android-sf-symbols-and-text-color` — use `AndroidIcon` for glyphs; forced colorScheme doesn’t recolor
  semantic text.
