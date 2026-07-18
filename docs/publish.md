# Publish — Maxi 80 5.0.0 (App Store + Play Store)

Living release checklist for the 5.0.0 update across **four** targets:
iOS App Store, Apple TV (tvOS), Google Play (phone), and Android TV.

Both listings already exist — this is an update, not a first submission:

| Store | Bundle / package | Console |
|-------|------------------|---------|
| App Store (iOS + tvOS) | `com.stormacq.sebastien.iphone.maxi80` (App ID 335551519) | https://appstoreconnect.apple.com/apps/335551519/distribution |
| Google Play (phone + TV) | `com.stormacq.android.maxi80` | https://play.google.com/console/u/0/developers/7368591034945929865/app/4972294180968810917/app-dashboard |

Metadata text is written and localized (`en-US`, `fr-FR`, `fr-CA`) for both
stores. This file tracks what's done and what still needs a human.

Version (shared, `Skip.env`):
- `MARKETING_VERSION = 5.0.0`
- `CURRENT_PROJECT_VERSION = 1`  ← bump on every upload

Legend: `[x]` done · `[ ]` todo · `[!]` blocked / needs you

---

## TODO — the short list

- [!] **Real privacy + support URLs** — all locales still hold `REPLACE-ME`
      placeholders. Apple *requires* both; maxi80.com has no such pages today.
      → create the pages, then replace the sentinels (see §2).
- [!] **Google Play service-account key** — no `apikey.json` in `secrets/` or
      `Android/fastlane/`. Needed before `supply` can upload (see §1).
- [ ] **Screenshots** — none captured yet, all four targets need them (see §3).
- [x] Apple App Store Connect credentials wired (see §1).
- [x] Descriptions written, localized, TV copy added, within store limits.

---

## 1. Credentials

### Apple — App Store Connect API key  ✅ wired

- [x] `secrets/AuthKey_37TD6VAMSR.p8` symlinked to
      `Darwin/fastlane/AuthKey_37TD6VAMSR.p8` (git-ignored via `*.p8`).
- [x] `Darwin/fastlane/apikey.json` created (git-ignored) — combines the
      `key_id` + `issuer_id` from `secrets/appstore_api_key.json` with
      `key_filepath: fastlane/AuthKey_37TD6VAMSR.p8`. Key material stays in
      `secrets/` only; nothing secret is committed.

The app already exists (App ID 335551519, bundle
`com.stormacq.sebastien.iphone.maxi80`). The `release` lane calls
`get_provisioning_profile`, so a valid **Distribution certificate** +
**App Store provisioning profile** must exist for the bundle id (fastlane can
fetch/create them with the API key). `secrets/apple_dist_key.p12` is the
distribution cert.

### Google Play — service-account JSON  ❌ missing

- [!] Create `Android/fastlane/apikey.json` (git-ignored):
  1. Play Console → **Setup → API access** → link a Google Cloud project.
  2. Create a **service account**, grant it **Admin (or Release)** on this app.
  3. Download its JSON key → save as `Android/fastlane/apikey.json`.

The app already exists in the Console (`com.stormacq.android.maxi80`), so the
"first AAB must be uploaded manually" rule (which applies to brand-new apps)
does **not** block us — `supply` can upload directly once the key is in place.

Both `apikey.json` files and `*.p8` are already `.gitignore`d. **Never commit.**

---

## 2. URLs — ACTION REQUIRED  🚧

Every locale holds placeholder URLs. Replace before publishing:

- `privacy_url.txt`  → privacy policy URL (**Apple requires this**)
- `support_url.txt`  → support page URL (**Apple requires this**)
- `marketing_url.txt` / `software_url.txt` → marketing page (optional)

Apple files: `Darwin/fastlane/metadata/<locale>/`. Play takes the privacy URL in
the Console UI (Store presence → App content), not from a metadata file.

> Note: maxi80.com currently has **no** privacy-policy or support/contact page.
> A homepage will not pass Apple review as a privacy policy — a dedicated page
> is needed. Decision (2026-07-18): leave placeholders in place and track here.

Check none slipped through:

```bash
grep -rl "REPLACE-ME" Darwin/fastlane Android/fastlane
```

---

## 3. Screenshots — ACTION REQUIRED  🚧

None captured yet; both stores reject a submission without them. Workflow:
**you drive the app into each state, then run the capture script** — it saves
into the exact folders `deliver`/`supply` read from. The script supports iOS,
tvOS and Android (incl. Android TV):

```bash
# Apple — boot ONE simulator, open Maxi 80, set the state, then:
./fastlane/capture_screenshots.sh ios  en-US 1 now-playing        # iPhone
./fastlane/capture_screenshots.sh tvos en-US 1 now-playing        # Apple TV

# Android — start ONE emulator, open Maxi 80, then:
./fastlane/capture_screenshots.sh droid en-US 1 now-playing phone # phone
./fastlane/capture_screenshots.sh droid en-US 1 now-playing tv    # Android TV
```

Suggested shot list (repeat per locale by switching device/app language):

1. Now playing — cover + artist/title, playing
2. Cover Flow history — carousel of past covers
3. High-resolution artwork close-up
4. CarPlay (iOS) / Android Auto (Android) now-playing
5. Lock-screen / notification controls (phone)

TV shot list (Apple TV + Android TV): now playing on the big screen, and the
history/Cover Flow view.

### Required sizes & sets

| Target       | Requirement |
|--------------|-------------|
| iPhone       | 6.9" set (1320×2868 / 2868×1320) required; 6.5" (1242×2688 / 1284×2778) also accepted. Capture from iPhone 16 Pro Max. |
| iPad         | 13" iPad (2064×2752) — only if shipping the iPad build. |
| Apple TV     | 1920×1080 or 3840×2160. Capture from an Apple TV 4K simulator. |
| Play phone   | min 2, 1080px on the short edge is safe. |
| Play tablet  | `sevenInch` / `tenInch` — optional. |
| Android TV   | `tvScreenshots` — 1920×1080 landscape. Console also needs a **TV banner** (320×180) added in the UI. |
| Play feature graphic | 1024×500 — required by the Console; a designed asset, add in the UI (not a screenshot). |

Folders (created on first capture):
- Apple:    `Darwin/fastlane/screenshots/<locale>/`  (tvOS shots get a `tv-` prefix)
- Android:  `Android/fastlane/metadata/android/<locale>/images/{phone,sevenInch,tenInch,tv}Screenshots/`

---

## 4. Ship

```bash
# iOS + tvOS
cd Darwin && fastlane release     # assemble + upload_to_app_store (submits for review)

# Android (phone + TV)
cd Android && fastlane release    # bundleRelease + upload_to_play_store
```

- iOS `Deliverfile`: `submit_for_review(true)` + `automatic_release(true)`.
- Android `release` uploads the AAB to the default track — set `track:
  'production'` in `Android/fastlane/Fastfile` for a staged rollout.

---

## Feature-claim note

Listings advertise **CarPlay** (iOS), **Android Auto** (Android), and now
**native Apple TV / Android TV** apps. All are shipped in this codebase. Do not
submit a listing claiming a feature the uploaded binary doesn't contain (e.g.
Android Auto must be in the AAB) or the store may reject it.
