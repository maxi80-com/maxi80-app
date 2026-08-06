import Testing

@testable import Maxi80
@testable import Maxi80Model

/// Tests for `HistoryReconciler`'s pure rules, asserted directly rather than through a coordinator.
///
/// `HistoryMergeTests` already exercises the same behaviour end-to-end via `fetchHistory()`, which is
/// where the interleaving-sensitive part lives. These tests pin down the rules themselves — which
/// backend entries are worth resolving, and what a merge produces — now that they no longer need a
/// live coordinator to reach.
@Suite("History Reconciler Tests")
struct HistoryReconcilerTests {

  private static func entry(
    _ artist: String, _ title: String, _ timestamp: String, cover: CoverSource = .pending
  ) -> HistoryEntry {
    HistoryEntry(artist: artist, title: title, timestamp: timestamp, cover: cover)
  }

  @Test("Songs already showing artwork are not re-resolved")
  func entriesNeedingResolution_skipsSongsWithArtwork() {
    let backend = [Self.entry("A", "One", "2026-07-15T10:00:00Z")]
    let existing = [
      Self.entry("A", "One", "2026-07-15T10:00:00Z", cover: .artwork("https://art/one.jpg"))
    ]

    #expect(
      HistoryReconciler.entriesNeedingResolution(backend: backend, existing: existing).isEmpty)
  }

  @Test("A song still on a generic cover is re-resolved so the real artwork can replace it")
  func entriesNeedingResolution_includesGenericCovers() {
    let backend = [Self.entry("A", "One", "2026-07-15T10:00:00Z")]
    let existing = [Self.entry("A", "One", "2026-07-15T10:00:00Z", cover: .generic("cover1"))]

    let toResolve = HistoryReconciler.entriesNeedingResolution(backend: backend, existing: existing)
    #expect(toResolve.map(\.title) == ["One"])
  }

  @Test("Songs absent from memory are resolved")
  func entriesNeedingResolution_includesNewSongs() {
    let backend = [
      Self.entry("A", "One", "2026-07-15T10:00:00Z", cover: .artwork("https://art/one.jpg")),
      Self.entry("B", "Two", "2026-07-15T10:30:00Z"),
    ]
    let existing = [
      Self.entry("A", "One", "2026-07-15T10:00:00Z", cover: .artwork("https://art/one.jpg"))
    ]

    let toResolve = HistoryReconciler.entriesNeedingResolution(backend: backend, existing: existing)
    #expect(toResolve.map(\.title) == ["Two"])
  }

  @Test("Merging heals a generic cover in place and reports it")
  func merged_healsInPlace() {
    let current = [Self.entry("A", "One", "2026-07-15T10:00:00Z", cover: .generic("cover1"))]
    let resolved = [
      Self.entry("A", "One", "2026-07-15T10:00:00Z", cover: .artwork("https://art/one.jpg"))
    ]

    let result = HistoryReconciler.merged(current, with: resolved)
    #expect(result.healed == 1)
    #expect(result.added == 0)
    #expect(result.entries.count == 1)
    #expect(result.entries[0].cover == .artwork("https://art/one.jpg"))
  }

  @Test("New songs are appended in timestamp order, newest last")
  func merged_appendsInTimestampOrder() {
    let current = [
      Self.entry("Mid", "Mid Song", "2026-07-15T10:30:00Z", cover: .artwork("https://art/mid.jpg"))
    ]
    let resolved = [
      Self.entry("New", "New Song", "2026-07-15T10:45:00Z", cover: .artwork("https://art/new.jpg")),
      Self.entry("Old", "Old Song", "2026-07-15T10:00:00Z", cover: .artwork("https://art/old.jpg")),
    ]

    let result = HistoryReconciler.merged(current, with: resolved)
    #expect(result.added == 2)
    #expect(result.entries.map(\.title) == ["Old Song", "Mid Song", "New Song"])
  }

  @Test("A song already present is not appended a second time")
  func merged_dedupesAgainstCurrentList() {
    let current = [
      Self.entry("A", "One", "2026-07-15T10:00:00Z", cover: .artwork("https://art/one.jpg"))
    ]
    // The backend's own copy of the same song, with a different timestamp → different id.
    let resolved = [
      Self.entry("A", "One", "2026-07-15T09:59:00Z", cover: .artwork("https://art/one.jpg"))
    ]

    let result = HistoryReconciler.merged(current, with: resolved)
    #expect(result.added == 0)
    #expect(result.entries.count == 1)
  }
}
