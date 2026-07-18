# Publishing Maxi 80

Release automation for **iOS (incl. CarPlay), Apple TV, macOS, and Android
(phone + TV)** — all driven by the `Makefile`. Both store listings already
exist; this covers routine updates.

| Store | Package | Console |
|-------|---------|---------|
| App Store (iOS · tvOS · macOS) | `com.stormacq.sebastien.iphone.maxi80` (App ID 335551519) | https://appstoreconnect.apple.com/apps/335551519 |
| Google Play (phone · TV) | `com.stormacq.android.maxi80` | https://play.google.com/console/u/0/developers/7368591034945929865/app/4972294180968810917 |

**Before anything:**
```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
make doctor          # checks tools, credentials, signing keys — must say "doctor: OK"
```

`make help` lists every target. The three workflows below are all you need.

---

## 1. Update metadata / screenshots (anytime, no binary)

Store text lives in `Darwin/fastlane/metadata/<locale>/*.txt` (Apple) and
`Android/fastlane/metadata/android/<locale>/*` (Play). Edit those, then push:

```bash
make publish-metadata-all     # Apple: iOS + tvOS + macOS listings + App Privacy (draft, no review)
make publish-android          # Play: also pushes listing text + images alongside the AAB *
```
\* Play has no metadata-only command — `supply` bundles listing + images with
the AAB upload. To refresh Play text/images without a new build, do it in the
Play Console, or run a full `make release && make publish-android`.

### Re-capturing screenshots
You drive the app into each state; the script saves into the exact folders
fastlane reads. Boot **one** Apple sim at a time; for Android ensure
`adb devices` shows exactly one.

```bash
./fastlane/capture_screenshots.sh ios   en-US 1 now-playing        # iPhone 6.9"
./fastlane/capture_screenshots.sh tvos  en-US 1 now-playing        # Apple TV
./fastlane/capture_screenshots.sh mac   en-US 1 now-playing        # macOS (window auto-normalized)
./fastlane/capture_screenshots.sh droid en-US 1 now-playing phone  # Android phone
./fastlane/capture_screenshots.sh droid en-US 1 now-playing tv     # Android TV
```
`<platform> <locale> <order> <name> [phone|tv]`. French (`fr-FR`/`fr-CA`) share
the same images — capture once, copy to both. Then re-run the publish command above.

---

## 2. Push a build to test

One command builds+signs every platform at a single new version, tests, commits
and tags; a second uploads to the test tracks. Pick **internal** (private, fast,
no review — for your own testing) or **open** (public beta, triggers store review):

```bash
make release          # bump → build+sign iOS(+CarPlay)+tvOS+Android → test → commit + tag

make publish-all      # INTERNAL: TestFlight internal + Play internal (private, no review)
#   …or…
make publish-all-open # OPEN: TestFlight "Public Beta" + Play open track (public, store-reviewed)

git push && git push origin <tag printed by make release>
```

`make release` aborts on a dirty tree or a build/test failure **before** it
commits, so a failure leaves git clean — fix and rerun. The build number
(`yyyyMMddNN`) is shared across all platforms and baked into each binary.

**Internal vs open (symmetric on both stores):**

| | Apple | Google Play | Review? |
|---|---|---|---|
| **internal** (`publish-all`) | TestFlight internal testers | Play `internal` track (draft) | No — instant |
| **open** (`publish-all-open`) | TestFlight external group **"Public Beta"** | Play `beta` (open) track | Yes — store beta review |

**Then test:**
- **iOS / Apple TV** — App Store Connect → TestFlight → install via the TestFlight app.
- **Android** — Play Console → Testing → install on a device.

> **One-time setup for open (Apple):** the external group **"Public Beta"** must
> exist in App Store Connect → TestFlight (create it once; add testers or a public
> link). Different group? pass `GROUP="…"`:
> `cd Darwin && fastlane upload platform:ios open:true group:"Your Group"`.
>
> **Single-platform** variants exist for both tiers: `publish-ios` / `publish-ios-open`,
> `publish-tvos` / `publish-tvos-open`, `publish-android` / `publish-android-open`.

---

## 3. Promote to production (after testing passes)

Opt-in, per platform — nothing ships to users automatically.

```bash
make promote-all         # = promote-ios + promote-android
# or individually:
make promote-ios         # submit the uploaded iOS build for App Store review
make promote-android     # promote the Play internal build to production (100%)
```

- **promote-ios** publishes App Privacy + metadata and submits for review
  (Deliverfile pre-answers export-compliance + content-rights, so no prompts).
  ⚠️ **Requires a GM (release) Xcode** — a build made with a *beta* Xcode uploads
  to TestFlight fine but Apple rejects it for review. Apple TV promotes the same
  way once its build is up.
- **promote-android** moves the exact internal build to production, full rollout.
  Staged rollout instead:
  `cd Android && fastlane promote_production release_status:inProgress rollout:0.1`

---

## Notes

- **One app per store, not per platform.** Play: phone + Android TV ship from the
  same package/AAB (manifest declares TV). App Store: one record with iOS/tvOS/macOS
  tabs; `deliver` uploads one platform per run (handled by the per-platform lanes).
- **macOS binary is DEFERRED** — ships metadata only. Needs a Mac Installer
  certificate + the App Sandbox entitlement (`com.apple.security.app-sandbox`) +
  testing. `package-macos` / `publish-macos` exist but are intentionally excluded
  from `release` / `publish-all`.
- **Secrets** (`secrets/`, `*/apikey.json`, `*.p8`, `keystore.properties`,
  `*.mobileprovision`) are git-ignored — never commit them.
- Build-number scheme `yyyyMMddNN`: must exceed the last published Play
  versionCode `2021122500` and stay under Android's ceiling 2,100,000,000.
