# Release checklist for Maxi 80

## 0. Screenshots (optional, only if the UI changed)

The app shows song metadata in the user's language, but the only locale-sensitive UI element is the "Back to Live" pill. If you avoid capturing that state, one screenshot works for all three locales (en-US, fr-FR, fr-CA). The capture script already handles this: take the shot once in en-US, then copy to the other locale folders.

Capture one locale, then propagate:

```bash
# Capture en-US (boot the right simulator, get the app into the state you want)
make screenshots ARGS="ios   en-US 1 now-playing"
make screenshots ARGS="ios   en-US 1 ipad-now-playing"   # boot iPad Pro 13-inch
make screenshots ARGS="tvos  en-US 1 now-playing"
make screenshots ARGS="mac   en-US 1 now-playing"
make screenshots ARGS="droid en-US 1 now-playing phone"
make screenshots ARGS="droid en-US 1 now-playing tv"

# Copy en-US to fr-FR and fr-CA (all platforms, all screenshot types)
make screenshots-copy-locales
```

`screenshots-copy-locales` copies every en-US PNG into the fr-FR and fr-CA folders for iOS, iPad, tvOS, macOS, and Android (phone, 7-inch, 10-inch, TV). Three locales covered from one capture session.

If you DO show the "Back to Live" pill or other localized text, capture each locale separately instead of using `screenshots-copy-locales`.

Args are `<ios|tvos|mac|droid> <locale> <order> <name> [phone|seven|ten|tv]`.

iPhone and iPad both use the `ios` command. deliver classifies by pixel size, so boot the right simulator and prefix iPad names with `ipad-` to avoid collisions.

Destinations:

- Apple: `Darwin/fastlane/screenshots/{ios,appletv,mac}/<locale>/NN-name.png`
- Android: `Android/fastlane/metadata/android/<locale>/images/{phone,sevenInch,tenInch,tv}Screenshots/`

Tips:
- Boot exactly one simulator at a time (`booted` is ambiguous with multiple).
- Pixel size must match a real accepted device (iPhone 16 Pro Max, iPad Pro 13-inch, Apple TV 4K).
- macOS captures the live Maxi80 window via AppleScript and normalizes to 2560x1600. Needs `/tmp/mkasset` or you get a warning and ASC rejects the size.
- Apple upload uses `sync_screenshots` (checksum diff), so replacing files and re-running won't duplicate.

Commit the screenshots before shipping. The clean-tree gate in `make release` rejects any dirty file other than `Skip.env`.

## 1. Preflight

```bash
make doctor
```

Verifies tools (skip, fastlane, gradle, xcodebuild, java) and credentials (API keys, keystore). Fix anything marked MISS before continuing.

## 2. Ship

If screenshots or listing text changed:
```bash
make clean && make ship-with-metadata
```

If only the binary changed (no listing/screenshot updates):
```bash
make clean && make ship
```

`ship-with-metadata` runs four steps in order:

1. **`release`** - clean-tree check (Skip.env exempt), bump build number, build+sign iOS IPA + tvOS IPA + macOS .pkg + Android AAB, run Swift tests, commit + annotated tag `v5.2.0-N`. Uploads nothing.
2. **`publish-all`** - uploads binaries to private test tracks: iOS/tvOS to TestFlight internal, macOS to App Store Connect, Android to Play internal (draft).
3. **`publish-metadata-all`** - listing text + screenshots for all platforms.
4. **`push-release`** - pushes branch + tag to origin, creates GitHub release.

## 3. Test

Verify the build on TestFlight and Play internal track.

## 4. Promote to production

```bash
make promote-all     # iOS: submits for App Store review + Android: Play production 100%
```

`promote-ios` needs a GM (non-beta) Xcode or Apple rejects the submission.

For a staged Android rollout: `cd Android && fastlane promote_production release_status:inProgress rollout:0.1`.

## Notes

- `Skip.env` is the single source of version truth. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` flow into both platforms.
- Build number scheme is `yyyyMMddNN`. `make bump` rewrites it; if the daily base isn't greater than the current value, it falls back to OLD+1.
- Apple metadata lanes create an editable draft. Nothing is submitted until `promote-ios`.
- `publish-metadata-android` is NOT a draft. The Play listing is app-global, so writing it queues a Play review. Dry-run first: `cd Android && fastlane metadata validate_only:true`.
- Without `Android/app/keystore.properties`, gradle signs the AAB with the debug key and Play rejects the upload.
