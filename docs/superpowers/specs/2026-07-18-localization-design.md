# Localization: English + French for Maxi80

**Date:** 2026-07-18
**Status:** Approved, implementing

## Goal

Prepare the Maxi80 cross-platform (iOS / macOS / tvOS / Android via Skip) radio player
for localization. Support **English (all regions)** and **French (all regions —
fr-FR, fr-CA, fr-BE share the same translation)**. **No user-facing string may be
hardcoded.**

## Mechanism (verified against Skip docs + showcase sample)

- Skip processes `Localizable.xcstrings` at build time and **generates the Android
  localizations itself**. We never edit `res/values/strings.xml`
  (`https://skip.dev/docs/components/localization/`).
- A language-level `fr` entry in the catalog automatically serves `fr-FR`, `fr-CA`,
  and `fr-BE`. The `en` source language serves all English regions. So a single
  `en`→`fr` catalog satisfies the full requirement — no per-region files, no
  `knownRegions` changes.
- **Module bundle gotcha (the linchpin):** localized string keys resolve against the
  **main** bundle by default. Our UI and catalog live in the `Maxi80` SwiftPM
  **module**, so every localized reference MUST pass `bundle: .module`
  (`Text("Play", bundle: .module)`, `String(localized:, bundle: .module)`).
- Plurals: Skip's String Catalog plural support requires an ICU-MessageFormat
  workaround (see showcase `LocalizationPlayground.swift`). **None of our strings are
  pluralized**, so this is out of scope.

## Current state

- `Sources/Maxi80/Resources/Localizable.xcstrings` already exists with ~11 translated
  `fr` entries (AirPlay output, Back to live, Copy, Pause, Play, Retry, Share, Share
  current track, Song history…, Support Maxi 80, Volume).
- **Latent bug:** existing views reference these keys with bare literals *without*
  `bundle: .module` — so on both platforms the lookups hit the main bundle and the
  existing French translations are effectively **not applied**. Fixing this is part of
  the work.
- `Package.swift` already declares `defaultLocalization: "en"` and
  `.process("Resources")`. No manifest change expected.

## Components

### 1. String catalog — single source of truth
`Sources/Maxi80/Resources/Localizable.xcstrings`. Extend existing entries with every
newly-found UI string; each entry gets a `comment` and a `fr` translation.

### 2. View-layer strings (`Maxi80`, `Maxi80/TV`)
Add `bundle: .module` to every `Text` / `Button` / `Label` / `.accessibilityLabel`
literal.

| File | Lines | Strings |
|------|-------|---------|
| `RadioPlayerView.swift` | 149, 258, 261, 289 | Song history…, Back to live (×2), Retry |
| `PlaybackControlsView.swift` | 56, 80, 92 | Share current track, Pause/Play, Support Maxi 80 |
| `VolumeSliderView.swift` | 14, 22 | Volume, AirPlay output |
| `ShareSheet.swift` | 27, 31 | Share, Copy |
| `TV/TVRadioPlayerView.swift` | 297, 348, 373, 404 | Pause/Play, Back to live (×2), Retry |

### 3. Non-View strings in the `Maxi80` module — `String(localized:, bundle: .module)`
- `RadioPlayerViewModel.shareCurrentTrack()` (line 269): share text becomes
  `"I'm listening to %@ by %@ on Maxi 80. Listen at %@"` — **platform suffix dropped**
  (decision). Brand name and URL injected from constants (component 5).
- `ReconnectionManager.swift` (line 74): `"Connection lost. All reconnection attempts
  failed."`

### 4. Service-module error strings (`Maxi80Services`)
Two `"Playback failed"` fallbacks live in the **transpiled** `Maxi80Services` module
(`AVPlayerStreamPlayer.swift:107`, `AVPlayerStreamPlayer+macOS.swift:72`). To keep the
transpiled module free of UI text (avoid a second catalog there), **localize at the
display boundary**: the native layer substitutes a localized fallback when an incoming
error message is empty. Cleanest exact seam (coordinator vs. view) chosen during
implementation; services module keeps emitting a plain sentinel/empty and the native
side localizes.

### 5. Brand constants — non-localized Swift
Move `"Maxi 80"`, the website URL (`https://www.maxi80.com`), and the French tagline
`"La radio de toute une génération"` into non-localized Swift constants. Decisions:
- Tagline is a **brand slogan — kept verbatim in French for both languages**.
- Brand name and URL are **constants, not catalog entries** (identical in every
  language, satisfies "no hardcoded literals").
- De-duplicate the two rival hardcoded `Station` fallbacks in `StationProvider.swift`
  (16, 19, 20) and `RadioPlayerCoordinator.swift` (192, 214, 217, 413) against these
  constants.

### 6. Config
No change expected (`defaultLocalization: "en"` + processed Resources already present).
Verify only.

## Out of scope
- Preview-only strings (`PreviewHelpers.swift`) — not shipped.
- CarPlay — no hardcoded literals; all text is Now Playing metadata (already covered).
- Plural variants — no pluralized strings exist.

## Verification
1. `swift build` against macOS destination (triggers Skip transpile).
2. Run iOS/macOS with French locale → confirm French renders (proves the
   `bundle: .module` fix).
3. Android emulator with French locale → confirm French renders.
4. Confirm English (default) still renders correctly.
