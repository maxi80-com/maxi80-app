# Collapse station-name duplicates in play history

**Date:** 2026-07-15
**Status:** Approved, pending implementation

## Problem

The same program appears twice in the history carousel — once with the artist
line showing `Maxi80` and once with no artist line (see the two 19:24
screenshots of "Maxi Club avec Dj Lucky").

Song identity is `(artist, title)`. The two entries come from different sources:

- **Backend `/history`** returns the program with `artist = "Maxi80"`.
- **Live stream metadata** is parsed by `MetadataParser`, which splits on
  `" - "`. A DJ program title has no separator, so the artist is left empty
  (`artist = ""`, `title = "Maxi Club avec Dj Lucky"`).

Because `"Maxi80" != ""`, the two dedup sites treat them as distinct songs:

- `RadioPlayerCoordinator.fetchHistory()` merge (keys on `songMetadata`).
- `RadioPlayerViewModel.pastEntries` (drops trailing entries equal to the
  current song).

Result: a duplicate cover in the carousel.

## Decisions

- **Match rule:** treat any artist equal to the station name as "no artist"
  when computing song identity — case- and whitespace-insensitive, so
  `"Maxi80"`, `"Maxi 80"`, and `"maxi80"` all normalize to empty. This is the
  broadest, most robust option and survives the backend switching between the
  spaced and unspaced forms.
- **Canonical display:** keep the `Maxi80` subtitle. The backend copy is the
  richer entry (it carries the artist name and usually artwork + color), so on
  collapse we prefer it for display.

The two decisions act on different fields and do not conflict: the **match key**
normalizes `Maxi80` → empty so the entries collapse; the **stored/displayed
artist** keeps `Maxi80`.

## Design

The fix is **two rules defined once**, consumed at the sites that already exist.
This is the right DRY boundary: the normalization rule and the entry-merge rule
each live in exactly one place; the call sites remain because they answer
genuinely different questions (data reconciliation vs. view layout). A single
`insert()` god-function is explicitly rejected — it would have to distinguish a
live/backend copy of the *same play* from a legitimate **repeat play** (same
song, later timestamp), which today's code correctly preserves.

### 1. Normalized identity — the match rule (defined once)

Add to `SongMetadata` (`Maxi80Model`):

- `var isStationArtist: Bool` — true when `artist`, lowercased with whitespace
  removed, equals `"maxi80"`.
- `var identity: SongMetadata` — returns a copy with `artist = ""` when
  `isStationArtist`, else `self`.

Add to `HistoryEntry`:

- `var songIdentity: SongMetadata` → `songMetadata.identity`.

`SongMetadata`'s `==` / `hash` are **left unchanged** — they drive artwork-retry
and current-song equality elsewhere, and must keep exact semantics. Normalization
is applied explicitly, via `identity` / `songIdentity`, at the sites below.

### 2. Entry-merge — the canonical rule (defined once)

Add to `HistoryEntry`:

- `func mergedWith(_ other: HistoryEntry) -> HistoryEntry` — merge two entries
  known to represent the same play. Prefers a **non-empty artist** (so the
  backend's `Maxi80` wins over the live empty artist), and fills
  `artworkURL` / `dominantColor` from whichever entry has them (`self` wins
  ties). This is the single place the "keep `Maxi80`, keep the artwork" policy
  lives.

### 3. Consume the two rules at the existing sites

- **`RadioPlayerCoordinator.fetchHistory()` merge** — key `existingSongs`,
  `songsMissingArtwork`, the `toResolve` / `newEntries` filters, and
  `resolvedURLBySong` on `songIdentity` instead of `songMetadata`. When a backend
  entry matches an in-memory entry by identity, heal via `mergedWith` (adopts the
  `Maxi80` artist + artwork/color). This is where the live empty-artist entry and
  the backend `Maxi80` entry collapse into one.
- **`RadioPlayerCoordinator.applyRetriedArtwork()`** — update the matched entry
  via the same `mergedWith` primitive instead of hand-mutating fields.
- **`RadioPlayerViewModel.pastEntries`** (view layout) — drop trailing entries
  whose `songIdentity == current.identity`, so the collapsed program isn't shown
  both in the now slot and as a past cover.
- **`RadioPlayerViewModel.displayedArtist`** (now slot) — when
  `currentSong.artist` is empty, fall back to a matching history entry's
  non-empty artist (by identity) before `station?.name`.

**Repeat plays stay safe:** matching remains scoped exactly as today (heal an
existing entry, or append a genuinely new song). Two plays of the same song at
different timestamps keep distinct entries — `mergedWith` is only ever applied to
a matched pair the merge already decided represents one play.

## Testing (Swift Testing)

- `"Maxi80"`, `"Maxi 80"`, `"maxi80"` all normalize to empty artist identity.
- A backend `Maxi80` entry + a live empty-artist entry for the same title
  collapse to a single carousel entry.
- The retained entry keeps `Maxi80` as its artist and its artwork/color.
- Genuine repeat plays (same identity, different timestamps) are preserved.
- Real `artist + title` pairs (both non-empty, artist not the station name) are
  untouched.
