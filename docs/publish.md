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
- **macOS is UNSUPPORTED by Skip** (Skip targets iOS + Android only). The Mac App
  Store build is hand-rolled and may break on Skip upgrades. What makes it work:
  - **App Sandbox** entitlement (`Entitlements-macOS.plist`) + a **"3rd Party Mac
    Developer Installer"** cert in the Keychain (create via Xcode → Settings →
    Accounts → Manage Certificates → +) — both one-time, already done.
  - `package-macos` archives, then re-signs the app **inside-out** because gym's
    export signs the nested frameworks (SkipFuse, SwiftJNI, SkipAndroidBridge, …)
    with an *Apple Development* cert (→ App Store errors 90284/91130). It re-signs
    every `*.framework` and Skip SPM `*.bundle` with the **Distribution** cert
    (clean, no entitlements), seals the main app with sandbox entitlements, and
    `productbuild`s the `.pkg`. Result: **`altool --validate-app` passes with 0
    errors.**
  - **No macOS TestFlight — caused by a legacy App-ID prefix, NOT by Skip.**
    TestFlight needs an embedded provisioning profile. macOS App Store validation
    hard-requires the signature's `application-identifier` to (a) match the
    profile's and (b) start with the **Team ID** (`56U756R2L2`) — error **90286**
    says so verbatim. But this app's App ID `com.stormacq.sebastien.iphone.maxi80`
    (Apple ID 335551519, registered ~2009) has an immutable legacy **seed prefix
    `JPLCX562X7`** (≠ Team ID; confirmed via the App Store Connect API). Every
    profile Apple issues for this bundle ID therefore carries `JPLCX562X7.…`, so:
    embed it and seal with `JPLCX562X7.…` → 90286 + a cascade of **91130** across
    every nested component (including the SkipFuse/SwiftJNI frameworks that *have*
    executables — which is why the old "executableless bundles" explanation was
    wrong); seal with `56U756R2L2.…` instead → **90288** (signature ≠ profile).
    iOS/tvOS accept the legacy prefix, which is why iOS TestFlight works. The seed
    prefix on an existing App ID cannot be changed — only an Apple Developer
    Support migration, or a new Team-ID-prefixed bundle ID (= new app record),
    would unblock macOS TestFlight; neither is worth it just for beta. Shipping
    *without* the profile validates cleanly for the App Store; the only cost is the
    non-blocking `90889` "missing provisioning profile" warning (the ITMS-90889
    email Apple sends). `publish-macos` therefore uploads the pkg straight to
    **App Store Connect**; review it in the Console (or via `make promote-ios`).
    There is no `publish-macos-open`.
- **Secrets** (`secrets/`, `*/apikey.json`, `*.p8`, `keystore.properties`,
  `*.mobileprovision`, `*.provisionprofile`) are git-ignored — never commit them.
- Build-number scheme `yyyyMMddNN`: must exceed the last published Play
  versionCode `2021122500` and stay under Android's ceiling 2,100,000,000.
