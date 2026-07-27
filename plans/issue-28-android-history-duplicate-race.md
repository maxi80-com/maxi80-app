# Plan — Issue #28: duplicate history entries linked to play/pause on Android

**Issue:** [#28 — Android: duplicate on history](https://github.com/maxi80-com/maxi80-app/issues/28)
**Triage:** `bug` (worth doing).
**Platform:** Primarily Android (the reporter's symptom + label), but the defect is in **shared Swift code** (`RadioPlayerCoordinator`), so the fix applies to all platforms. Android surfaces it more because its `play()`/resume flow re-fires ICY metadata for the currently-playing song (see root cause), giving the race a reliable trigger.

---

## 1. Reproduction

Exact conditions (from the issue + code trace). The reporter has "no steps to reproduce" and the duplicate is timing-dependent, so this is the *derived* repro:

1. Launch the app; let history load (`fetchHistory()` seeds the list, `lastHistoryFetchedAt` set).
2. Play, then **pause**. Leave paused long enough that history goes stale (> `historyStaleness` = 3 min).
3. **Resume** (`play()`). Two things now happen close together on the `@MainActor`:
   - `play()` → `refreshHistoryIfStale()` → `fetchHistory()` starts (history is stale) and **suspends** at its first network `await`.
   - The Android shared ExoPlayer reconnects to the live edge (`MediaControllerHolder.play`) and **re-fires ICY metadata** for the song currently playing → `handleMetadataChanged(...)` runs and, while `fetchHistory()` is suspended, appends the live entry.
4. Advance to the next song so the duplicated song leaves the now-slot.

**Observed:** the song appears **twice** in the history carousel (see the screenshot in the issue).

**Expected:** the song appears exactly once.

Note: the duplicate is *invisible* while the song is the now-slot (the now-slot cover is drawn from `currentSong`, and the trailing history copies matching `current.identity` are trimmed in `RadioPlayerViewModel.pastEntries`). It only surfaces after the next song starts — which is why it looks intermittent and "linked to play/pause activity."

## 2. Root cause (file/function level)

A **MainActor reentrancy (TOCTOU) race** in `RadioPlayerCoordinator.fetchHistory()`.

`RadioPlayerCoordinator` is `@MainActor` (`Sources/Maxi80/RadioPlayerCoordinator.swift:18`). MainActor isolation prevents *data* races but **not interleaving across `await` suspension points**: while one MainActor task is suspended at an `await`, another MainActor task can run to completion and mutate shared state.

`fetchHistory()` (`RadioPlayerCoordinator.swift:630-708`) computes its dedup snapshot **before** it suspends:

- `let existingSongs = Set(history.map(\.songIdentity))` — line **665**
- `let songsMissingArtwork = ...` — line **666**
- then `let resolved = await resolveArtwork(for: toResolve)` — line **677** (suspends on network)
- on resume, new entries are filtered against the **stale** snapshot:
  `let newEntries = resolved.filter { !existingSongs.contains($0.songIdentity) }` — line **701**
  and appended: `history = (history + newEntries).sorted { ... }` — line **703**.

During the suspension at line 677, `handleMetadataChanged(...)` (`RadioPlayerCoordinator.swift:340-408`) can run to completion. It itself suspends on `await artworkService.fetchArtwork(...)` (line **368**) and then appends the live entry — its own dedup guard is **tail-only**: `if history.last?.songIdentity == metadata.identity` (line **397**), added by commit `e5f2664` to fix the launch-seed duplicate. That guard cannot see a race where `fetchHistory()` is mid-flight.

Result: the live-appended song is now in `history`, but it is **not** in `fetchHistory()`'s `existingSongs` snapshot, so the backend copy of the same song passes the `!existingSongs.contains(...)` filter at line 701 and is appended a **second time** → duplicate.

Two related windows in the same function share the defect:
- **Seed path:** `if history.isEmpty { ... await resolveArtwork ...; history = resolved }` (lines **640-645**) re-checks nothing after the await and **unconditionally overwrites** `history`, so a live entry appended during the await is dropped (or, combined with a later fetch, duplicated).
- **`refreshHistory()`** cancels the *previous* task (`historyTask?.cancel()`, line **150**) but does nothing to serialize against `handleMetadataChanged`, which is launched from the `onMetadataChanged` closure as an independent MainActor `Task` (lines **302-306**).

The `mergedWith` site the reporter flagged (`HistoryEntry.swift:45`) is **not** the cause — it is the correct merge policy and is only reached when dedup *does* match. The bug is that dedup **fails to match** because the snapshot it keys off is stale.

**Citations:**
- Stale snapshot taken pre-await: `RadioPlayerCoordinator.swift:665-666`.
- Suspension point that opens the window: `RadioPlayerCoordinator.swift:677` (and seed path `:641`).
- New-entry filter against stale snapshot: `RadioPlayerCoordinator.swift:701`.
- Concurrent live append with tail-only guard: `RadioPlayerCoordinator.swift:368` (await), `:397` (tail-only guard).
- Independent MainActor task wiring: `RadioPlayerCoordinator.swift:302-306`; refresh task: `:149-153`.
- MainActor class: `RadioPlayerCoordinator.swift:18`.

## 3. Approach

Make `fetchHistory()`'s reconciliation **re-read `history` after every suspension** and dedup against the *live* array at the moment of mutation, rather than against a pre-await snapshot. Keep all changes in the shared Swift coordinator; do not touch platform/Kotlin code.

### Files to change

1. **`Sources/Maxi80/RadioPlayerCoordinator.swift`** — `fetchHistory()` only.

   **(a) Recompute the existence set immediately before mutating, not before the await.**
   After `let resolved = await resolveArtwork(for: toResolve)` (line 677) returns, rebuild the sets from the *current* `history` before healing/appending:
   ```swift
   let resolved = await resolveArtwork(for: toResolve)

   // Re-read AFTER the await: handleMetadataChanged may have live-appended a song while we were
   // suspended (both run on @MainActor but interleave across suspension points). Deduping against
   // a pre-await snapshot double-adds the backend copy of a song the live path just appended.
   let existingSongsNow = Set(history.map(\.songIdentity))
   ```
   Then filter new entries against `existingSongsNow` (replacing the use of the stale `existingSongs` at line 701):
   ```swift
   let newEntries = resolved.filter { !existingSongsNow.contains($0.songIdentity) }
   ```
   Leave the heal step (lines 690-697) keyed by `songIdentity` against `backendBySong`; it is idempotent and safe to re-run against the current array. (The `existingSongs`/`songsMissingArtwork` sets at 665-666 may still be used to decide `toResolve`, since resolving an extra entry is harmless — only the *append* decision must use the post-await set.)

   **(b) Guard the seed path against a concurrent live append.**
   Replace the unconditional overwrite (lines 640-645) so it does not clobber entries appended during the await:
   ```swift
   if history.isEmpty {
     let resolved = await resolveArtwork(for: entries)
     if history.isEmpty {
       history = resolved
     } else {
       // A live entry was appended while we resolved artwork — fall through to the incremental
       // reconcile below instead of overwriting it.
       reconcile(resolved: resolved)   // or inline the heal+append using the post-await set
     }
     lastHistoryFetchedAt = Date()
     return
   }
   ```
   The simplest robust form: if `history` is no longer empty after the await, run the same post-await dedup used in (a) instead of assigning `history = resolved`.

   Optional hardening (recommended, low risk): factor the "heal + append using a freshly-read existence set" into a small private `@MainActor` helper so both the seed and incremental paths share one dedup implementation.

No changes to `HistoryEntry.mergedWith`, `SongMetadata.identity`, `handleMetadataChanged`'s tail guard, or any Platform/Kotlin file.

## 4. Acceptance criteria

- A new test in `Tests/Maxi80Tests/HistoryMergeTests.swift` reproduces the race deterministically and passes after the fix: drive `fetchHistory()` and a live `handleMetadataChanged(...)` for the **same** song so the live append lands *while `fetchHistory()` is suspended on artwork resolution*, then assert the song count is exactly 1. A convenient way to force the interleave with the existing `HistoryMockAPIClient`: `await` `handleMetadataChanged` between kicking off `fetchHistory()` and its completion (e.g. start `fetchHistory()` as a task, `await` a live metadata event, then `await` the task), or add a controllable delay hook to the artwork resolution used only in tests.
- Existing `HistoryMergeTests` all still pass — in particular:
  - `firstMetadataDoesNotDuplicateSeededNowPlaying`
  - `repeatOfLaunchSongStillAppends` (A → B → A must still yield two `Song A` entries)
  - `stationArtistProgramCollapses`
  - `missingArtworkIsHealedOnRefresh` / `existingArtworkIsPreserved`
  - `newEntriesMergeInOrder` (timestamp ordering preserved)
- Genuine repeat plays (same song, different timestamps) are still preserved — the fix must dedup only by *presence in the current array at append time*, never collapse distinct plays.
- Manual Android check: play → pause > 3 min → resume → advance one song. The just-played song appears exactly once in the carousel.

## 5. Scope & non-goals

- **In scope:** the shared-Swift dedup race in `fetchHistory()` (append and seed paths).
- **Out of scope:** whether Android should re-fire ICY on resume (that behavior is relied upon elsewhere and is not itself wrong); the notification/title issues (#13), Android Auto launcher (#18), pause-state sync (#29), and BT-disconnect behavior (#30). Those are tracked separately.
- No application behavior changes beyond preventing the duplicate; no UI changes.
