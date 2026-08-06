import Foundation
import Maxi80Model
import SkipFuse

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "HistoryReconciler")

/// The rules for folding the backend's `/history` list into the in-memory one: which backend entries
/// are worth resolving artwork for, how a resolved entry heals an existing one, and where a genuinely
/// new song lands in the order.
///
/// Extracted from `RadioPlayerCoordinator` as a *pure* type: every rule is a function of the two lists
/// handed in, returning the list that should replace `history`. Nothing here reads or writes the
/// coordinator's state, which is what makes the reconciliation testable in isolation — and it keeps the
/// one thing that genuinely needs the coordinator, the re-read of `history` *after* the artwork await,
/// visible at the call site instead of buried in here (see `RadioPlayerCoordinator.fetchHistory`).
struct HistoryReconciler {

  let artworkService: ArtworkService

  /// The outcome of a merge: the list to install, plus what changed, for the caller to log.
  struct MergeResult {
    let entries: [HistoryEntry]
    let healed: Int
    let added: Int
  }

  /// Backend entries worth resolving artwork for, given the entries already in memory: songs not in
  /// memory at all (played while stopped/paused), plus songs whose in-memory entry is still showing a
  /// generic cover, which the backend copy can now replace. Songs already showing artwork are left
  /// out, so they never reload and never flicker.
  ///
  /// Matching is by SONG identity (artist+title), NOT by `id`: a live-appended entry and the backend's
  /// own copy of the same song get different timestamps → different ids, so id-based matching would
  /// show a duplicate. Identity rather than raw metadata, so a backend `Maxi80` entry and a live
  /// artist-less entry for the same DJ program collapse to one song instead of two covers.
  static func entriesNeedingResolution(
    backend: [HistoryEntry], existing: [HistoryEntry]
  ) -> [HistoryEntry] {
    let existingSongs = Set(existing.map(\.songIdentity))
    let songsMissingArtwork = Set(existing.filter { $0.cover.wantsArtwork }.map(\.songIdentity))
    return backend.filter {
      !existingSongs.contains($0.songIdentity) || songsMissingArtwork.contains($0.songIdentity)
    }
  }

  /// Merges backend-resolved entries into `current`: heals in place any existing entry missing
  /// artwork/artist from its backend copy, then appends songs not already present, ordered by
  /// timestamp so the newest sits nearest the now-slot (the carousel renders oldest→newest,
  /// left→right).
  ///
  /// `current` must be the list as it stands **at merge time** — not a snapshot taken before the
  /// artwork await in `fetchHistory()`. `RadioPlayerCoordinator` is `@MainActor`, which prevents data
  /// races but not interleaving across suspension points: while `fetchHistory()` is suspended
  /// resolving artwork, `handleMetadataChanged(...)` can run to completion and live-append the
  /// currently-playing song. Deduping against a pre-await snapshot would then miss that live entry and
  /// append the backend's copy of the same song a second time → the duplicate reported in issue #28.
  ///
  /// Dedup is by *presence in `current`* (`songIdentity`), so genuine repeat plays (same song,
  /// different timestamps) are preserved — the backend reports each song once, so a repeat already in
  /// memory simply isn't re-appended.
  static func merged(_ current: [HistoryEntry], with resolved: [HistoryEntry]) -> MergeResult {
    // Backend entry per identity, for healing existing entries (carries the `Maxi80` artist, artwork
    // URL, and color the live copy may be missing).
    var backendBySong: [SongMetadata: HistoryEntry] = [:]
    for entry in resolved {
      backendBySong[entry.songIdentity] = entry
    }

    // 1. Heal existing entries against the backend copy, in place (preserves order & repeats).
    //    Merges when the in-memory entry lacks artwork or a real artist; `mergedWith` keeps the
    //    non-empty `Maxi80` artist and fills artwork/color.
    var healed = 0
    var entries = current.map { entry -> HistoryEntry in
      guard entry.cover.wantsArtwork || entry.artist.isEmpty,
        let backend = backendBySong[entry.songIdentity]
      else { return entry }
      let merged = entry.mergedWith(backend)
      if merged != entry { healed += 1 }
      return merged
    }

    // 2. Append genuinely-new songs, then order by timestamp.
    let existingSongsNow = Set(entries.map(\.songIdentity))
    let newEntries = resolved.filter { !existingSongsNow.contains($0.songIdentity) }
    if !newEntries.isEmpty {
      entries = (entries + newEntries).sorted { $0.timestamp < $1.timestamp }
    }
    return MergeResult(entries: entries, healed: healed, added: newEntries.count)
  }

  /// Resolves each entry's artwork S3 key into a lightweight presigned URL, concurrently.
  /// AsyncImage loads the image lazily — we do NOT download it here. The background color is
  /// derived from the backend `colors` palette already decoded on the entry; if absent it stays nil.
  ///
  /// Entries whose artwork doesn't resolve get a generic cover here, the other half of the rule in
  /// `handleMetadataChanged`: an entry is given one when it is created without artwork. Backend
  /// entries never pass through the now slot — on a cold start `/history` seeds ~20 past songs — so
  /// this is where their covers come from, and every coverless entry in `history` carries one.
  @MainActor
  func resolveArtwork(for entries: [HistoryEntry]) async -> [HistoryEntry] {
    let urlByIndex = await withTaskGroup(of: (Int, String?).self) { group in
      for (index, entry) in entries.enumerated() {
        group.addTask { [artworkService] in
          let url = await artworkService.resolveArtworkURL(artist: entry.artist, title: entry.title)
          return (index, url)
        }
      }
      var urlByIndex = [Int: String?]()
      for await (index, url) in group {
        urlByIndex[index] = url
      }
      return urlByIndex
    }

    return entries.enumerated().map { index, entry -> HistoryEntry in
      var copy = entry
      let url = urlByIndex[index] ?? nil
      copy.cover = url.map(CoverSource.artwork) ?? .generic(PlaceholderCover.random().imageName)
      return copy
    }
  }

  /// Fetch `/history` from the backend and decode it. Returns `nil` when there's nothing usable —
  /// which the caller must treat as "leave the current list alone", not as an empty history.
  func fetchBackendEntries(using apiClient: any APIClientProtocol) async -> [HistoryEntry]? {
    logger.info("fetchHistory: GET /history")
    guard let json = try? await apiClient.fetchHistory(),
      let entries = try? json.decodedJSON(as: HistoryResponse.self).entries
    else {
      logger.notice("fetchHistory: no data or decode failed")
      return nil
    }
    return entries
  }
}
