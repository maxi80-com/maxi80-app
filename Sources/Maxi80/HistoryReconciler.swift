import Foundation
import Maxi80Model
import SkipFuse

/// Handles fetching, merging, and artwork-resolution of the play history list.
///
/// Extracted from `RadioPlayerCoordinator` (issue #68 item 1d) — encapsulates the reconciliation
/// logic so it can be tested independently and keeps the coordinator focused on orchestration.
@MainActor
final class HistoryReconciler {

  private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "HistoryReconciler")

  /// Fetch history from the API and reconcile it into the live `history` array.
  ///
  /// - Parameters:
  ///   - apiClient: The API client to fetch history JSON from.
  ///   - artworkService: Service to resolve artwork URLs.
  ///   - history: The current in-memory history array (inout — mutated in place).
  /// - Returns: The updated history array, or `nil` if fetch/decode failed.
  func fetchAndReconcile(
    apiClient: any APIClientProtocol,
    artworkService: ArtworkService,
    history: inout [HistoryEntry]
  ) async {
    logger.info("fetchHistory: GET /history")
    guard let json = try? await apiClient.fetchHistory(),
      let entries = decodeJSON(json, as: HistoryResponse.self)?.entries
    else {
      logger.notice("fetchHistory: no data or decode failed")
      return
    }

    // First load (empty history): resolve artwork for every entry and seed the list.
    if history.isEmpty {
      let resolved = await resolveArtwork(for: entries, artworkService: artworkService)
      // Re-check AFTER the await: `handleMetadataChanged` may have live-appended a song while we
      // were suspended resolving artwork. If the list is no longer empty, reconcile incrementally.
      if history.isEmpty {
        history = resolved
      } else {
        mergeResolvedEntries(resolved, into: &history)
      }
      logger.info("fetchHistory: seeded \(history.count) entries")
      return
    }

    // Reconcile the backend list into the in-memory one, matching by SONG identity
    // (artist+title), NOT by `id`.
    let existingSongs = Set(history.map(\.songIdentity))
    let songsMissingArtwork = Set(history.filter { $0.artworkURL == nil }.map(\.songIdentity))

    let toResolve = entries.filter {
      !existingSongs.contains($0.songIdentity) || songsMissingArtwork.contains($0.songIdentity)
    }
    guard !toResolve.isEmpty else {
      logger.info("fetchHistory: nothing new or missing artwork to merge")
      return
    }

    let resolved = await resolveArtwork(for: toResolve, artworkService: artworkService)
    mergeResolvedEntries(resolved, into: &history)
  }

  /// Merges backend-resolved entries into the live `history`: heals in-place any existing entry
  /// missing artwork/artist from its backend copy, then appends genuinely-new songs.
  func mergeResolvedEntries(_ resolved: [HistoryEntry], into history: inout [HistoryEntry]) {
    var backendBySong: [SongMetadata: HistoryEntry] = [:]
    for entry in resolved {
      backendBySong[entry.songIdentity] = entry
    }

    // 1. Heal existing entries against the backend copy, in place.
    var healed = 0
    history = history.map { entry in
      guard entry.artworkURL == nil || entry.artist.isEmpty,
        let backend = backendBySong[entry.songIdentity]
      else { return entry }
      let merged = entry.mergedWith(backend)
      if merged != entry { healed += 1 }
      return merged
    }

    // 2. Append genuinely-new songs, deduped against the LIVE array.
    let existingSongsNow = Set(history.map(\.songIdentity))
    let newEntries = resolved.filter { !existingSongsNow.contains($0.songIdentity) }
    if !newEntries.isEmpty {
      history = (history + newEntries).sorted { $0.timestamp < $1.timestamp }
    }
    logger.info(
      "fetchHistory: healed \(healed), added \(newEntries.count); history now has \(history.count)"
    )
  }

  /// Resolves each entry's artwork S3 key into a lightweight presigned URL, concurrently.
  func resolveArtwork(
    for entries: [HistoryEntry],
    artworkService: ArtworkService
  ) async -> [HistoryEntry] {
    await withTaskGroup(of: (Int, String?).self) { group in
      for (index, entry) in entries.enumerated() {
        group.addTask {
          let url = await artworkService.resolveArtworkURL(artist: entry.artist, title: entry.title)
          return (index, url)
        }
      }
      var urlByIndex = [Int: String?]()
      for await (index, url) in group {
        urlByIndex[index] = url
      }
      return entries.enumerated().map { index, entry -> HistoryEntry in
        var copy = entry
        copy.artworkURL = urlByIndex[index] ?? nil
        return copy
      }
    }
  }
}
