# Apple Developer Support request — macOS TestFlight blocked by legacy App-ID prefix

**Status:** Posted.
**Case ID:** 102945986741

**Where to submit:** Apple Developer → Contact Us → *App ID & Provisioning
Profiles* (Feedback Assistant if they route you there).

**Goal:** get the macOS build TestFlight-eligible by migrating App ID 335551519's
immutable legacy seed prefix (`JPLCX562X7`) to the Team ID (`56U756R2L2`).

**Context / evidence** lives in `docs/publish.md` (Notes → macOS) and was proven
with real `xcrun altool --validate-app -t macos` trials:
- Profile embedded + app-id `JPLCX562X7.…` → **90286** (main app) + **91130** cascade
  (incl. SkipFuse/SwiftJNI frameworks that *have* executables).
- Profile embedded + app-id `56U756R2L2.…` → **90288** (signature ≠ profile).
- No profile → validates clean for the App Store; only cost is the **90889 / ITMS-90889**
  warning (non-blocking; not TestFlight-eligible).

Expectation: a seed-prefix migration on an existing App ID is discretionary and
uncommon (keychain/iCloud data keyed to `JPLCX562X7.*` would move with it). This
app uses no keychain/app-group entitlements (only app-sandbox + network.client),
so there is no such data to migrate — noted in the message below. If Apple
declines, their likely answer is "use a new Bundle ID" (= new app record, loses
ratings/reviews).

---

## Draft message

**Subject:** Request to migrate legacy App ID seed prefix to Team ID — macOS TestFlight blocked (App ID 335551519)

**Team ID:** 56U756R2L2
**App:** Maxi 80 — Apple ID 335551519
**Bundle ID:** com.stormacq.sebastien.iphone.maxi80

Hello,

I'm requesting that the **App ID Prefix (seed ID)** for my Bundle ID `com.stormacq.sebastien.iphone.maxi80` be migrated from its legacy value to my Team ID, so that the app can be distributed via **macOS TestFlight**.

**Background**

This App ID was originally registered in the early App Store era and carries a legacy seed prefix that predates the Team ID:

- App ID seed prefix (from the App Store Connect API `/v1/bundleIds`): **`JPLCX562X7`**
- My Team ID: **`56U756R2L2`**
- The `application-identifier` entitlement in every provisioning profile Apple issues for this Bundle ID is therefore `JPLCX562X7.com.stormacq.sebastien.iphone.maxi80`.

**The problem**

iOS and tvOS distribution work correctly — the App Store and TestFlight accept the legacy prefix, and I ship iOS/tvOS builds regularly.

However, the app also has a **macOS** version (same App Store record, macOS platform tab), and macOS validation enforces a stricter rule than iOS/tvOS: it requires the signature's `application-identifier` to begin with the **Team ID**. When I embed the macOS App Store provisioning profile (required for TestFlight eligibility) and sign the app, `xcrun altool --validate-app -t macos` fails with:

- **90286** — *"Invalid code signing entitlements … the `JPLCX562X7.com.stormacq.sebastien.iphone.maxi80` value for `com.apple.application-identifier` isn't supported. This value should be a string that starts with your Team ID, followed by a dot, followed by the bundle ID."*
- **91130** — *"Invalid Provisioning Profile … Invalid `com.apple.application-identifier` entitlement value"* (cascaded across the app and all nested frameworks).

If I instead sign with a Team-ID-prefixed value (`56U756R2L2.…`) to satisfy 90286, validation then fails with **90288** because the signature no longer matches the profile's app identifier. There is no signing configuration that satisfies both rules, because the profile's app-identifier prefix is derived from the immutable legacy seed ID.

Shipping the macOS build **without** an embedded profile validates cleanly and uploads to the App Store, but the build is not TestFlight-eligible and produces the **ITMS-90889** warning ("Main bundles are expected to have provisioning profiles in order to be eligible for TestFlight") — which is what prompted this request.

**What I'm asking**

Please **migrate/reset the App ID seed prefix for App ID 335551519 (`com.stormacq.sebastien.iphone.maxi80`) to my Team ID `56U756R2L2`**, so that newly issued macOS App Store provisioning profiles carry a `56U756R2L2`-prefixed `application-identifier` and the macOS build becomes TestFlight-eligible.

For reference, this app uses no keychain-sharing, app-group, or iCloud entitlements — its only entitlements are `com.apple.security.app-sandbox` and `com.apple.security.network.client` — so there is no keychain or container data keyed to the legacy prefix that a migration would disrupt.

I would like to keep the existing App Store record (Apple ID 335551519) with its iOS, tvOS, and macOS platforms intact, rather than create a new Bundle ID, so that ratings, reviews, and the existing listing are preserved.

If a seed-prefix migration isn't possible, could you please advise the supported path to enable macOS TestFlight for this app while retaining the existing App Store record?

Thank you,
Sébastien Stormacq (Team ID 56U756R2L2)
