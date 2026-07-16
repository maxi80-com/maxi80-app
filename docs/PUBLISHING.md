# Publishing Maxi 80 (App Store + Play Store)

Release-time guide for the 5.0.0 update. Metadata text is already written and
localized (en-US, fr-FR, fr-CA) under `Darwin/fastlane/` and `Android/fastlane/`.
This covers the three things that still need **you**: credentials, URLs, and
screenshots.

## Version

Set in `Skip.env` (shared by both platforms):

- `MARKETING_VERSION = 5.0.0`
- `CURRENT_PROJECT_VERSION = 1`  ← bump this build number on every upload

## 1. Credentials fastlane needs

### App Store Connect (Apple)

An **App Store Connect API key** (preferred over Apple ID login):

1. App Store Connect → **Users and Access → Integrations → App Store Connect API**.
2. Generate a key with the **App Manager** role.
3. Download the `.p8` (only offered once). Note the **Key ID** and **Issuer ID**.
4. Create `Darwin/fastlane/apikey.json` (git-ignored):

   ```json
   {
     "key_id": "XXXXXXXXXX",
     "issuer_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
     "key": "-----BEGIN PRIVATE KEY-----\nMIG...\n-----END PRIVATE KEY-----",
     "in_house": false
   }
   ```

   The `key` field is the full `.p8` contents with literal `\n` for newlines.

The app already exists (App ID 335551519, bundle `com.stormacq.sebastien.iphone.maxi80`).
Signing: the `release` lane calls `get_provisioning_profile`, so you also need a
valid **Distribution certificate** + **App Store provisioning profile** for the
bundle id (fastlane can fetch/create them with the API key).

### Google Play Console

A **service-account JSON key**:

1. Play Console → **Setup → API access** → link a Google Cloud project.
2. Create a **service account**, then in Play Console grant it **Admin (or
   Release)** permissions for this app.
3. Download the service account's JSON key → save as `Android/fastlane/apikey.json`
   (git-ignored).

> First upload must be manual: Play requires **at least one AAB uploaded through
> the Console UI** for a new app/track before `supply` (`upload_to_play_store`)
> will accept automated uploads. The iOS listing already exists; the Android app
> package is `com.stormacq.android.maxi80` — confirm it's created in the Console.

Both `apikey.json` files and `*.p8` are already in `.gitignore`. **Never commit them.**

## 2. URLs — ACTION REQUIRED

Every locale currently has placeholder URLs. Replace the sentinel values before
publishing (search the tree for `REPLACE-ME`):

- `privacy_url.txt`   → your privacy policy URL (**Apple requires this**)
- `support_url.txt`   → your support page URL (**Apple requires this**)
- `marketing_url.txt` / `software_url.txt` → your marketing page (optional)

Apple files live in `Darwin/fastlane/metadata/<locale>/`. Play Console takes the
privacy policy URL in the Console UI (Store presence → App content), not from a
metadata file.

Quick check that none slipped through:

```bash
grep -rl "REPLACE-ME" Darwin/fastlane Android/fastlane
```

## 3. Screenshots — ACTION REQUIRED

No screenshots exist yet. Both stores reject a submission without them.
Use `fastlane/capture_screenshots.sh` to grab frames from a simulator/emulator
you drive by hand (single-screen radio app; a UITest harness isn't worth it).

Suggested shot list (do it in each locale by switching the device/app language):

1. Now playing — cover + artist/title, playing
2. Cover Flow history — carousel of past covers
3. High-resolution artwork close-up
4. CarPlay (iOS) / Android Auto (Android) now-playing
5. Lock-screen / notification controls

```bash
# iOS — boot a simulator, open Maxi 80, get the state on screen, then:
./fastlane/capture_screenshots.sh ios en-US 1 now-playing
./fastlane/capture_screenshots.sh ios en-US 2 cover-flow

# Android — start an emulator, open Maxi 80, then:
./fastlane/capture_screenshots.sh droid en-US 1 now-playing phone
./fastlane/capture_screenshots.sh droid en-US 2 cover-flow phone
```

### Required sizes

**App Store** (`deliver`) — you need at least the **6.9" iPhone** set
(1320×2868 or 2868×1320); a **6.5"** set (1242×2688 / 1284×2778) is also accepted
for older-device display. If you ship the iPad build, add **13" iPad** (2064×2752).
Capturing from a matching simulator (e.g. iPhone 16 Pro Max) yields correct pixels.

**Play Store** (`supply`) — phone screenshots are required (min 2), 1080px on the
short edge is a safe target. `sevenInchScreenshots` / `tenInchScreenshots` are
optional tablet sets. A **1024×500 feature graphic** is also required by the
Console (add it in the UI, or as `feature_graphic` — not covered by the capture
script since it's a designed asset, not a screenshot).

Folders (already created):

- iOS:     `Darwin/fastlane/screenshots/<locale>/`
- Android: `Android/fastlane/metadata/android/<locale>/images/{phone,sevenInch,tenInch}Screenshots/`

## 4. Ship

```bash
# iOS
cd Darwin && fastlane release        # assemble + upload_to_app_store (submits for review)

# Android
cd Android && fastlane release       # bundleRelease + upload_to_play_store
```

The iOS `Deliverfile` is set to `submit_for_review(true)` and `automatic_release(true)`.
The Android `release` lane uploads the AAB to the default track — set a track
(e.g. `track: 'production'`) in `Android/fastlane/Fastfile` if you want a staged rollout.

## Feature-claim note

The listings advertise **CarPlay** (iOS) and **Android Auto** (Android). CarPlay
is shipped. Android Auto must be functional in the build you upload — do not
submit the Android listing claiming it until the `MediaLibraryService` /
automotive support is in the AAB, or Google may reject the listing.
