---
name: capturing-appstore-screenshots
description: Use when regenerating App Store / Play Store screenshots for the Maxi80 app for a release — capturing iOS/iPadOS/tvOS/macOS store shots, replacing licensed album art with the branded placeholder cover, or driving fastlane/capture_screenshots.sh across locales.
---

# Capturing App Store screenshots (Maxi80)

Regenerate the store screenshots for a release without any **licensed album art** —
every cover shows the bundled Maxi'80 placeholder instead. Shots feed `deliver`
(Apple) and `supply` (Play) from `Darwin/fastlane/screenshots/` and
`Android/fastlane/metadata/`.

The capture helper is `fastlane/capture_screenshots.sh`. It grabs the CURRENT frame
of a hand-driven simulator/emulator/window — it does not build, launch, or drive the
app. Invocation:

```bash
./fastlane/capture_screenshots.sh <ios|tvos|mac|droid> <locale> <order> <name> [phone|seven|ten|tv]
#   locale : en-US | fr-FR | fr-CA      order : 1..N (store display order)      name : slug
```
Output dirs it writes to (the exact trees `deliver`/`supply` read):

| Platform arg | Writes to | Capture method (inside the script) |
|---|---|---|
| `ios`  | `Darwin/fastlane/screenshots/ios/<locale>/NN-<name>.png` | `simctl io booted screenshot` |
| `tvos` | `Darwin/fastlane/screenshots/appletv/<locale>/NN-<name>.png` | `simctl io booted screenshot` |
| `mac`  | `Darwin/fastlane/screenshots/mac/<locale>/NN-<name>.png` | `screencapture -R <window rect>` → `mkasset` normalize |
| `droid`| `Android/fastlane/metadata/android/<locale>/images/<kind>/` | `adb exec-out screencap` |

## The core idea

The live radio stream sends real "ARTIST - TITLE" metadata and the app fetches real
album art. To keep licensed artwork out of the store, **patch the build** so every
cover renders a bundled placeholder. See `coverimage-placeholder.patch.md` (bundled)
for the exact two-line edit. Do NOT rely on "shoot between 21h–22h when there's no
cover" — the patch is deterministic and works any time of day.

## Workflow

1. **Isolate at the release tag in a scratch worktree.** Tags look like
   `v5.0.8-2026072901`; confirm it exists first (`git fetch --tags`, `git tag | grep`).
   The screenshot patch must never ship, so work detached:
   ```bash
   git worktree add worktrees/shots-<tag> <tag>   # worktrees/ is gitignored
   ```
   Seed the gitignored `Configuration.plist` (holds the backend URL + token; without a
   valid one the stream won't play, so the "playing" shots need it). Copy from the main
   checkout, or from the template if that's all there is:
   ```bash
   cp Sources/Maxi80/Resources/Configuration.plist worktrees/shots-<tag>/Sources/Maxi80/Resources/ \
     || cp worktrees/shots-<tag>/Sources/Maxi80/Resources/Configuration.plist.template \
           worktrees/shots-<tag>/Sources/Maxi80/Resources/Configuration.plist   # then fill in API_BASE_URL / API_AUTH_TOKEN
   ```
2. **Apply the force-placeholder patch** (`coverimage-placeholder.patch.md`) in the
   worktree. Rebuild and confirm covers show the vinyl art with varied neighbors.
3. **Build per platform** — always pass `SKIP_ACTION=none` (on EVERY destination:
   iOS, tvOS, macOS) so xcodebuild skips the Android/gradle phase, which otherwise
   fails the whole build. Scheme is `"Maxi80 App"`; one native target serves all
   Apple platforms. The bundle id is `com.stormacq.sebastien.iphone.maxi80` (or read
   it: `/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" <app>/Info.plist`).

   | Platform | `-destination` | Built `.app` under `<derivedData>/Build/Products/` |
   |---|---|---|
   | iOS/iPad | `platform=iOS Simulator,id=<UDID>` | `Debug-iphonesimulator/Maxi80.app` |
   | tvOS | `platform=tvOS Simulator,id=<UDID>` | `Debug-appletvsimulator/Maxi80.app` |
   | macOS | `platform=macOS,arch=arm64` | `Debug/Maxi80.app` |
   ```bash
   xcodebuild -project Darwin/Maxi80.xcodeproj -scheme "Maxi80 App" \
     -destination "<destination>" -derivedDataPath /tmp/maxi80-shots-dd \
     SKIP_ACTION=none build
   ```
4. **Launch, set locale, reach the state, capture** (mechanics below). The app
   launches **idle/non-playing** — that IS the "non-playing" shot; the user taps play
   to reach "playing". No pause step is needed.
5. **Capture EN only, then copy to every French locale.** On the live track the
   "Back to live" pill never shows, so all locales are pixel-identical. Shoot `en-US`,
   then copy into BOTH `fr-FR` and `fr-CA` (fr-CA reuses the fr-FR French UI):
   ```bash
   for p in ios appletv mac; do
     cp en-US-tree/$p/en-US/*.png $p/fr-FR/ && cp en-US-tree/$p/en-US/*.png $p/fr-CA/
   done
   ```
   Then verify EVERY French file is byte-identical to its en-US source (`md5`) — a
   single missed file leaves stale album art in the store (this has happened). Only
   populate the locales the release actually targets.
6. **Clean up:** remove stale album-art files being replaced, then
   `git worktree remove --force worktrees/shots-<tag>` (discards the patch) and
   `xcrun simctl delete` any sim you created.

## Shots per platform (current listing shape)

| Platform | Device / size | Shots |
|---|---|---|
| iPhone | 17 Pro Max, **iOS 26** → 1320×2868 | portrait non-playing, portrait playing, landscape playing |
| iPad | Air 13" → 2048×2732 / 2732×2048 | portrait non-playing, portrait playing, landscape playing |
| tvOS | Apple TV 4K **(at 1080p)** → 1920×1080 | non-playing, playing |
| macOS | real app window → normalized 2560×1600 | non-playing, playing |

**Filenames don't route shots — resolution does.** `deliver` classifies each image to
a device class by its pixel size (iPhone 6.9" 1320×2868, iPad 12.9" 2048×2732, etc.),
so the name is purely organizational; the `NN-` prefix only sets display ORDER within
a class (natural sort). Name iPad files with an `ipad-` slug (`01-ipad-now-playing`)
so they don't collide with iPhone shots in the shared `ios/<locale>/` folder and each
class still orders 1→2→3. tvOS and macOS have their own folders (`appletv/`, `mac/`)
so plain `01-now-playing`/`02-playing` names are fine there.

**Create the sims** (pick device types/runtimes present via `xcrun simctl list`):
```bash
# iPhone 17 Pro Max on iOS 26.5 (stable — see mistakes) → 1320×2868
xcrun simctl create "shot-iphone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
# Apple TV 4K "(at 1080p)" gives 1920×1080 directly — do NOT use the 4K/2160p variant
xcrun simctl list devices available | grep -i "apple tv"   # find the "(at 1080p)" UDID
```
iPad Air 13" and the 1080p Apple TV usually already exist — reuse them.

## Capture mechanics

- **One booted sim at a time.** The script uses `xcrun simctl io booted screenshot`;
  `booted` is ambiguous with two sims up. Boot only the one you're shooting.
- **Locale:** launch with args — `xcrun simctl launch <UDID> <bundleID> -AppleLanguages '(en)' -AppleLocale en_US` (or `fr`/`fr_FR`).
- **Clean status bar (iOS/iPadOS):**
  `xcrun simctl status_bar <UDID> override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3`
- **Rotate:** focus the Simulator, then `key code 124` (⌘→, landscape) / `key code 123` (⌘←, portrait) via System Events. Verify with a screenshot's dimensions before saving.
- **macOS:** no simulator — launch the real app window and force English via launch
  args (the `simctl` locale trick is sim-only):
  `open <app> --args -AppleLanguages '(en)' -AppleLocale en_US`. The script
  region-captures the window and calls `/tmp/mkasset` to normalize to 2560×1600
  (contain-fit + black pad), so exact window size doesn't matter. Copy the bundled
  tool first: `cp .claude/skills/capturing-appstore-screenshots/mkasset /tmp/mkasset`.
  Needs Screen Recording permission for your terminal (can't be scripted — grant it in
  System Settings → Privacy if capture fails). Quit with `osascript -e 'tell application "Maxi80" to quit'` when done.
- **Driving play/pause:** synthetic clicks into the scaled Simulator window are
  unreliable — **ask the user to tap the play button** (and to rotate, on tvOS to
  press the remote's center) rather than fighting coordinate math. Capture right after.

## Common mistakes

- **Forgetting `SKIP_ACTION=none`** → build dies in the gradle phase
  (`settings.gradle.kts` / "gradle command failed"). It's iOS screenshots; skip Android.
- **iPhone 17 Pro Max on iOS 27** has been flaky on this machine — create/boot the
  Pro Max sim on **iOS 26.5** for stable capture.
- **Missing `/tmp/mkasset`** → macOS shots save at the wrong size with a warning. Copy
  the bundled tool into `/tmp` first.
- **Leaving the patch in the tree** → it must be discarded with the worktree; never
  commit `forcePlaceholderForScreenshots`. Confirm `git status` on the real branch
  shows only screenshot `.png` changes afterward.
- **Shooting EN and FR separately** → wasted effort; they're identical on the live
  track. Capture once, copy.
- **All neighbor covers identical** → the placeholder isn't varying; see the patch
  file's verify step.
