# "Played at" air-time line in the phone/tablet player

**Issue:** [maxi80-app#63](https://github.com/maxi80-com/maxi80-app/issues/63) — show the air time of a browsed history entry on iPhone / iPad / macOS / Android phone, mirroring the TV UIs.

## Goal

When the user swipes the Cover Flow carousel into history, show a small, discreet line (e.g. "Played at 14:30" / "Diffusé à 14:30") between the title/artist and the back-to-live pill. It appears only while browsing history and disappears on the live slot. Its color tracks the rest of the song text.

## Scope

`RadioPlayerView` only — the shared phone/tablet/desktop player. The TV views (`TVRadioPlayerView`) already have this line; this brings the phone UI to parity. No view-model, coordinator, or model changes.

## Design

A third `Text` appended inside the existing `songLabel()` `VStack` in `Sources/Maxi80/RadioPlayerView.swift` (after the artist line):

```swift
if let date = viewModel.focusedEntryDate {
  Text(
    String(
      format: Bundle.module.localizedString(forKey: "Played at %@", value: nil, table: nil),
      date.formatted(date: .omitted, time: .shortened)
    )
  )
  .font(.system(size: airTimeFontSize, weight: .regular))
  .foregroundStyle(subtitleColor.opacity(0.6))
  .lineLimit(1)
}
```

### Reuse (no new logic)

- **`viewModel.focusedEntryDate`** already exists: the browsed entry's captured `Date`, or `nil` on the live slot (or if the backend timestamp doesn't parse). The `if let` therefore gives us the "only while browsing, hidden on live" behavior for free.
- **`"Played at %@"`** catalog key already exists in `Localizable.xcstrings` with the French translation `"Diffusé à %@"`.
- **SkipFoundation-safe formatting**: `Bundle.module.localizedString(forKey:…)` + `date.formatted(date:.omitted, time:.shortened)` — the exact forms the TV view uses and that transpile on Android (the `.hour().minute()` builder and `String(localized:)` do not). `.shortened` respects the user's locale (24h vs AM/PM) and timezone.

### Color tracking

The line uses `subtitleColor.opacity(0.6)` — the same discreet color already used by the artist line and the version footer. `subtitleColor` resolves to `.secondary` on Apple (tracks the forced color scheme) and an explicit `isBackgroundDark`-driven white/black on Android. Because the line sits inside the same `songLabel()` VStack as the title/artist, it recolors in lockstep with them when the artwork wash changes — satisfying "changes colors as the rest of the text."

### Font size

New `airTimeFontSize` computed property, one step below the subtitle: **13pt on iPhone / Android phone, 16pt on iPad / macOS** (`usesExpandedLayout`). Same relative treatment as the TV view's air-time line.

### Layout

Both orientations are **artist-first**: line 1 is the artist in the big primary style (`titleFontSize`/`titleColor`/bold), line 2 is the song name in the smaller secondary style (`subtitleFontSize`/`subtitleColor`). The per-line font sizes/weights are the pre-existing ones — only the content was swapped between the two lines. Selected by a `songLabel(inlineHistoryTime:)` flag; the arrangements differ only in where the air time goes, because the orientations have opposite vertical budgets. In **both** the time is dim `subtitleColor.opacity(0.6)`:

- **Portrait** (`inlineHistoryTime: false`) — artist → song → discreet "Played at 14:30" **third line**. No height reservation: the `phonePortraitSubviewsHeight` budget is untouched; the line only adds ~24pt while browsing. The live-slot layout (common case) is unchanged and the hero stays as large as possible.

- **Landscape** (`inlineHistoryTime: true`) — the info column is short (it shares its height with the controls), so a third line shrank the lines via `minimumScaleFactor`. Instead the bare parenthesized locale time (`(14:02)`, no "Played at" prefix) is **inlined after the song name on line 2**, baseline-aligned — no third line, so the lines keep their full size. Applies to both phone and iPad landscape.

Neither orientation reorders on the live slot (where no time shows) — the artist-first order is fixed, not history-dependent.

## Testing

Pure presentational addition over an already-tested view-model property (`focusedEntryDate`), so no new unit tests. Verification is visual:

- **iPhone sim**: browse into history → "Played at HH:MM" appears under the artist in the locale's clock format; return to live → line gone; layout doesn't clip.
- **Android emulator**: same, and the line's color flips with the wash contrast alongside the title/artist.

## Files touched

- `Sources/Maxi80/RadioPlayerView.swift` — the line + `airTimeFontSize`.
- `Sources/Maxi80/Resources/Localizable.xcstrings` — widened the existing key's comment (no string change).
