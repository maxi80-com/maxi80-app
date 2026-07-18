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
- [x] **Google Play service-account key** — `fastlane@maxi80.iam.gserviceaccount.com`,
      stored in `secrets/play_service_account.json`, symlinked to `Android/fastlane/apikey.json`.
      Auth + Play access verified (HTTP 200). Key rotated after setup; live key id `39dafa3c…`.
- [x] **Play Developer API enabled + access granted** — verified end-to-end: signing a JWT
      with the key opens a Play edit for `com.stormacq.android.maxi80` (HTTP 200). `supply` ready.
- [x] **Screenshots** — captured for all four surfaces × 3 locales (see §3).
- [x] **fastlane credentials verified** — Apple ASC key returns latest build number;
      Play key connects (`validate_play_store_json_key` OK). Both lanes parse.
- [x] Apple App Store Connect credentials wired (see §1).
- [x] Descriptions written, localized, TV copy added, within store limits.
- [x] **Play feature graphic (1024×500)** + **Android TV banner (320×180)** — generated
      from the Maxi 80 neon logo, placed per-locale as `images/featureGraphic.png` and
      `images/tvBanner.png` (supply picks them up automatically).
- [ ] **Android upload keystore** — release AAB is currently debug-signed; add
      `Android/keystore.properties` before `publish-android` (see Makefile `doctor`).
- [ ] **Bump build number before upload** — TestFlight already has build 1; run
      `make bump` (or a publish target) so `CURRENT_PROJECT_VERSION` > 1.

---

## 1. Credentials

### Apple — App Store Connect API key  ✅ wired

- [x] `secrets/AuthKey_37TD6VAMSR.p8` symlinked to
      `Darwin/fastlane/AuthKey_37TD6VAMSR.p8` (git-ignored via `*.p8`).
- [x] `Darwin/fastlane/apikey.json` created (git-ignored) — `key_id` + `issuer_id`
      from `secrets/appstore_api_key.json` plus the **inline `key`** (full `.p8` PEM).
      ⚠️ It must be the inline `key` field, NOT `key_filepath`: the Deliverfile's
      spaceship uploaders (`upload_to_app_store`, `get_provisioning_profile`) call
      `Token.from_json_file`, which requires `key_id` + `key` and ignores `key_filepath`
      (only the standalone `app_store_connect_api_key` action understands the filepath form).
      Regenerate from the symlinked `.p8` if it ever needs rebuilding.
- [x] Verified against Apple (read-only): `fastlane run latest_testflight_build_number
      app_identifier:com.stormacq.sebastien.iphone.maxi80 api_key_path:fastlane/apikey.json`
      → authenticates, returns latest build number.

The app already exists (App ID 335551519, bundle
`com.stormacq.sebastien.iphone.maxi80`). The `release` lane calls
`get_provisioning_profile`, so a valid **Distribution certificate** +
**App Store provisioning profile** must exist for the bundle id (fastlane can
fetch/create them with the API key). `secrets/apple_dist_key.p12` is the
distribution cert.

### Google Play — service-account JSON  🟡 key done, 2 steps left

Cloud project: **maxi80** (number 911786404985), org `sebastien-stormacq-org`
(682227160711). Service account: **`fastlane@maxi80.iam.gserviceaccount.com`**.

- [x] Key created & wired — `secrets/play_service_account.json` symlinked to
      `Android/fastlane/apikey.json` (git-ignored). Auth verified: signing a JWT
      with the key and exchanging it at Google's token endpoint returns an access
      token, so the credential itself is valid.
- [x] Org policy `iam.disableServiceAccountKeyCreation` (Secure-by-Default) was
      blocking key creation; deleted via
      `gcloud org-policies delete iam.disableServiceAccountKeyCreation --organization=682227160711`.
- [x] **Play Developer API enabled** — `gcloud services enable androidpublisher.googleapis.com`.
- [x] **Play access granted** — `fastlane@maxi80.iam.gserviceaccount.com` invited in
      Play Console → Users and permissions (service accounts activate without email
      acceptance). Verified: opening a Play edit returns HTTP 200.
      NB: an unused `fastlane-supply@…` entry may also be listed from a mistyped first
      invite — harmless, can be removed.
- [x] **Key rotated** — the original key (id `76078cc8…`, private key pasted in chat
      during setup) was replaced with a fresh one (id `39dafa3c…`) and deleted. Verify
      only the new id remains:
      `gcloud iam service-accounts keys list --iam-account=fastlane@maxi80.iam.gserviceaccount.com`

The app already exists in the Console (`com.stormacq.android.maxi80`), so the
"first AAB must be uploaded manually" rule (which applies to brand-new apps)
does **not** block us — `supply` can upload directly once the two steps above are done.

Both `apikey.json` files and `*.p8` are already `.gitignore`d. **Never commit.**

Re-verify auth + API access anytime (no fastlane needed) — the check signs a JWT
with the key, gets a token, and opens a Play edit for the package; HTTP 200 = good.

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

## 3. Screenshots — ✅ DONE

Captured for all four surfaces × 3 locales (2026-07-18):

| Surface | en-US | fr-FR | fr-CA | Size |
|---------|:-----:|:-----:|:-----:|------|
| iPhone 6.9" | 3 | 3 | 3 | 1320×2868 (shot 3 landscape 2868×1320) |
| Apple TV | 3 | 3 | 3 | 1920×1080 |
| Android phone | 2 | 2 | 2 | 1080×2400 |
| Android TV | 2 | 2 | 2 | 1920×1080 |

Notes: text-free screens (now-playing) are shared across locales; the
"Back to live" / "Retour au direct" screens were shot per-language. `fr-FR`
and `fr-CA` share the same French images. To re-capture or add shots, use the
workflow below.

### Capture workflow (for future updates)

**You drive the app into each state, then run the capture script** — it saves
into the exact folders `deliver`/`supply` read from. Supports iOS, tvOS and
Android (incl. Android TV). Boot only ONE Apple sim at a time (`booted` is
ambiguous otherwise); for Android ensure `adb devices` shows exactly one.

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
