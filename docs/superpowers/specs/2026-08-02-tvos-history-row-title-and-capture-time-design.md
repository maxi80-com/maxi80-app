# tvOS History Row Title + Capture Time

**Date:** 2026-08-02
**Scope:** tvOS only (this branch does not touch Android code paths)
**Branch:** `worktree-tvos-carousel-full-artwork`

## Problem

On the Apple TV UI, the horizontal row of covers at the bottom of
`TVRadioPlayerView` is not immediately understandable as *history* — it reads
as "a bunch of covers", not "what played earlier on the station".

## Solution

Two small additions:

### 1. Row title — "C'était quoi ce titre ?"

A small, dim, always-visible label above the history row.

- Lives in `TVHistoryRow`'s `#if os(tvOS)` branch only: a
  `VStack(alignment: .leading)` wraps the existing `ScrollView`; the Android
  and fallback branches are untouched.
- Leading-aligned with the row content (60pt horizontal inset).
- Caption-sized, `.secondary` foreground, plain `Text` (non-focusable — D-pad
  behavior unchanged).
- Localized in `Localizable.xcstrings` (`bundle: .module`):
  - fr-FR / fr-CA: `C'était quoi ce titre ?`
  - en-US: `What was that song?`

### 2. Capture time — under the artist in the hero block

When (and only when) the user is browsing history, a third line appears under
the artist label: "Diffusé à 14:30" / "Played at 2:30 PM".

- `RadioPlayerViewModel` gains one public computed property,
  `focusedEntryDate: Date?`:
  - Parses `focusedHistoryEntry.timestamp` (ISO-8601, backend format
    `2025-01-15T14:30:00Z`) with `ISO8601DateFormatter`.
  - Returns `nil` when on the live slot or when the timestamp is unparsable.
  - Lives in shared code (compiles for Android too) but no Android view
    consumes it — Android UI is behaviorally untouched.
- The tvOS view (`TVRadioPlayerView` labels block) renders it only when
  non-`nil`, formatted with `Date.FormatStyle().hour().minute()` so the locale
  decides 24h vs AM-PM.
- Styling: same or slightly smaller than the artist line, dimmer (~60% opacity
  of the subtitle color) — reads as metadata, not content. Sits in the same
  labels block so it participates in the existing hero crossfade.
- Localized format strings:
  - fr-FR / fr-CA: `Diffusé à %@`
  - en-US: `Played at %@`

## Error handling

- Unparsable timestamp → `focusedEntryDate` is `nil` → line hidden
  (degrades to exactly today's UI).
- Live slot → line hidden.
- No timers, no new state.

## Testing

- View-model test: `focusedEntryDate` returns the parsed date when a history
  cover is selected, and `nil` when the live slot is selected.
- Manual verification on the Apple TV simulator in fr-FR, fr-CA, en-US.

## Out of scope

- Android TV / iPhone / iPad / macOS equivalents (may follow in their own PR).
- Relative time ("il y a 12 min") — rejected: goes stale without a timer.
- Per-thumbnail timestamps — rejected: too busy for a 10-foot UI.
