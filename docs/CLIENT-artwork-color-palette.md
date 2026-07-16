# Client changes for the artwork color palette

**Status:** TODO (client side). The backend is switching from a single derived
`color` hex to Apple Music's **full palette**; the client must consume the
palette and compute its own background color. Backend plan:
`maxi-80-backend-swift/docs/superpowers/plans/2026-07-16-artwork-color-palette.md`.

## Why this change

Today the backend stores one derived hex in `history.json` under `"color"`, and
the client decodes it into `HistoryEntry.dominantColor: RGBColor?` to drive the
now-playing background gradient. That single value came from Apple Music's
`bgColor`, which is a **muted/near-grey background color**, not the artwork's
dominant hue — so warm covers (e.g. Jeanne Mas – "L'enfant") rendered a grey
gradient. See the backend investigation: Apple returned `bgColor 1c2520` (dark
grey-green) while the vivid tones were in the `textColor` fields.

The fix moves color *selection* to the client. The backend now stores Apple's
whole palette faithfully; **the client decides which color to paint.** This is
the correct long-term split (no backfill/redeploy needed when the look changes)
and, importantly, it must work on Android via Skip — so the selection is pure
arithmetic (no image sampling, no `UIKit`/`CoreGraphics`).

## New backend JSON contract

The `/history` response and each entry now carry `"colors"` (an object) instead
of `"color"` (a single hex string). Both `metadata.json` (server-internal) and
each history entry use this shape:

```json
{
  "artist": "Jeanne Mas",
  "title": "L'enfant",
  "artwork": "v2/Jeanne Mas/L'enfant/artwork.jpg",
  "timestamp": "2026-07-16T08:18:26Z",
  "colors": {
    "bg":    "#1C2520",
    "text1": "#E6B996",
    "text2": "#DDB5B1",
    "text3": "#BE9C7E",
    "text4": "#B69894"
  }
}
```

- All five values are `"#RRGGBB"` uppercase.
- `"colors"` is **optional** (absent for coverless / Maxi80-filler / not-yet-enriched
  entries) — decode with `decodeIfPresent`, exactly as `"color"` is today.
- `bg` = Apple's precomputed background color (often muted/dark).
- `text1..4` = Apple's four foreground/text colors — these carry the vivid tones.
- The old `"color"` key is **gone**. There is no released client, so there is no
  need to decode both — drop `"color"` handling entirely (no dual-read).

## Client tasks

All changes are in the shared Swift (works on iOS + Android via Skip). Follow
the project's Skip module rules in `CLAUDE.md` — the model types live in
`Maxi80Model` (transpiled-safe, no UIKit).

### 1. New model type `ArtworkColors` (module `Maxi80Model`)

Create `Sources/Maxi80Model/Models/ArtworkColors.swift`. Mirror the backend
shape; reuse the existing `RGBColor` (which already decodes a `"#RRGGBB"` hex and
is UI-framework-free — see `Sources/Maxi80Model/Models/RGBColor.swift`).

```swift
import Foundation

/// Apple Music's full artwork color palette, as stored by the backend. The client derives the
/// display/background color from these (see `displayBackground`), rather than trusting Apple's
/// muted `bg`. Decoded from the `/history` "colors" object; every value is "#RRGGBB".
public struct ArtworkColors: Sendable, Equatable, Codable {
    public let bg: RGBColor
    public let text1: RGBColor
    public let text2: RGBColor
    public let text3: RGBColor
    public let text4: RGBColor

    public init(bg: RGBColor, text1: RGBColor, text2: RGBColor, text3: RGBColor, text4: RGBColor) {
        self.bg = bg; self.text1 = text1; self.text2 = text2; self.text3 = text3; self.text4 = text4
    }
}
```

`RGBColor` already conforms to `Codable` decoding a hex string, and the keys
(`bg`, `text1`..`text4`) match the JSON, so the synthesized `Codable` works with
no custom `init(from:)`.

### 2. Selection logic: compute the background color from the palette

Add a computed property to `ArtworkColors` that reproduces the heuristic (this
is the logic that used to be a backend `dominantHex` — now the client's job):

> Prefer `bg` when it is vivid AND bright enough; otherwise fall back to the most
> saturated of `text1..4` that is itself bright enough. Only swap to a text color
> when it is genuinely more saturated than `bg`; never trade down.

Thresholds (HSV, components 0…1), matching the values validated on the backend:
`minSaturation = 0.20`, `minValue = 0.30`.

```swift
extension ArtworkColors {
    /// The color to paint behind the cover. Prefers Apple's `bg`, but when `bg` is grey/dark
    /// falls back to the most saturated bright-enough text color — so the background matches the
    /// artwork instead of Apple's muted background. Pure arithmetic; safe on Android via Skip.
    public var displayBackground: RGBColor {
        let minSaturation = 0.20, minValue = 0.30

        func sv(_ c: RGBColor) -> (s: Double, v: Double) {
            let mx = max(c.red, c.green, c.blue), mn = min(c.red, c.green, c.blue)
            let v = mx
            let s = mx == 0 ? 0 : (mx - mn) / mx
            return (s, v)
        }

        let bgSV = sv(bg)
        if bgSV.s >= minSaturation && bgSV.v >= minValue { return bg }

        let best = [text1, text2, text3, text4]
            .map { ($0, sv($0)) }
            .filter { $0.1.v >= minValue }
            .max { $0.1.s < $1.1.s }

        if let best, best.1.s > bgSV.s { return best.0 }
        return bg
    }
}
```

Note: `RGBColor` stores components already in 0…1, so HSV `value` is just the max
component — no /255 needed (unlike the backend, which worked on 0–255 ints).

Add unit tests (`Tests/Maxi80ModelTests/…`, Swift Testing) covering:
- Vivid `bg` is kept (e.g. `bg #8A5A2B` → returns `bg`).
- Grey/dark `bg` falls back to the most saturated bright text color. Use the real
  Jeanne Mas values: `bg #1C2520`, texts `#E6B996 #DDB5B1 #BE9C7E #B69894` →
  expect `#E6B996` (most saturated bright text, sat ≈ 0.348).
- Grey `bg` with only dark text colors keeps `bg`.

### 3. `HistoryEntry`: decode `colors`, drive the gradient from `displayBackground`

In `Sources/Maxi80Model/Models/HistoryEntry.swift`:

- Replace the stored `dominantColor: RGBColor?` with `colors: ArtworkColors?`
  (or keep a `dominantColor` computed convenience — your call; but the source of
  truth becomes `colors`).
- Change the `CodingKeys`: replace `case dominantColor = "color"` with
  `case colors` and decode via `decodeIfPresent(ArtworkColors.self, forKey: .colors)`.
- Update the memberwise `init` and `mergedWith(_:)` to carry `colors` instead of
  `dominantColor` (merge prefers whichever entry has a palette, `self` winning ties —
  same policy as today).
- Expose the display color for the UI, e.g.:
  ```swift
  public var backgroundColor: RGBColor? { colors?.displayBackground }
  ```

### 4. Live-entry path: build `ArtworkColors` from local sampling (iOS only)

Today `RadioPlayerCoordinator` sets a live entry's `dominantColor` from
`ArtworkResult.rgb` (client-side image sampling on Apple platforms; nil on
Android). Two options — pick per your preference:

- **Simplest:** for live entries, synthesize an `ArtworkColors` whose `bg` is the
  sampled color and whose `text1..4` are the same value (so `displayBackground`
  returns the sampled color). This keeps the live path visually unchanged.
- **Cleaner:** give `HistoryEntry` an alternate source — a direct
  `backgroundColor` override for live entries — and only use `colors` for entries
  decoded from the backend. Avoids faking a palette.

Either way: on Android the live path has no sampled color (no image APIs), so it
relies on the backend palette arriving via `/history` — which now it will.

### 5. Follow-through

- Update `ArtworkResult` / coordinator wiring so nothing still reads a single
  backend `dominantColor` hex. Grep for `dominantColor` and `"color"` decode
  sites: `HistoryEntry.swift`, `RadioPlayerViewModel.swift` (`dominantColor`
  computed prop feeding `RadioPlayerView`'s `LinearGradient`),
  `RadioPlayerCoordinator.swift`.
- `RadioPlayerViewModel.dominantColor` (feeds the gradient in `RadioPlayerView`)
  should resolve to `focusedHistoryEntry?.backgroundColor` (→ `colors?.displayBackground`),
  falling back to the live artwork color as it does today.
- Run `swift test` and `skip android build` — the palette + selection are pure
  value/arithmetic, so they must transpile and pass on Android too.

## Coordination / ordering

- The backend deploys the new schema first (its Task 5), then runs the one-off
  backfill so all existing history entries carry `colors`.
- Until the client ships this change, it will decode `colors` as absent (it looks
  for the old `"color"` key) → no gradient color, same as a coverless entry. Not
  a crash, just a missing color. Ship the client change to light it up.
- No released client exists, so **do not** add backward-compat for the old
  `"color"` key — clean cut to `colors`.
