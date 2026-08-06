import Foundation
import Maxi80Model
import SkipFuse

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "ArtworkRetry")

/// Retries the artwork lookup for a song whose cover wasn't available on first fetch (the backend
/// collector hadn't produced it yet), so the cover fills in during the song rather than at the next
/// one.
///
/// Extracted from `RadioPlayerCoordinator` because the whole of it — the backoff schedule, the
/// cancelable task, the staleness checks around each `await` — is about *when to ask again*, and none
/// of it needs the coordinator's state. What it resolves goes back out through `onResolved`; deciding
/// what to do with a cover (current artwork, Now Playing, the history entry) stays with the
/// coordinator, which owns all three.
@MainActor
final class ArtworkRetryManager {

  private let artworkService: ArtworkService

  /// Called on the main actor with artwork that actually resolved (never a default/placeholder
  /// result), together with the song it belongs to. Assigned after construction, because the
  /// coordinator's handler captures `self`.
  var onResolved: ((ArtworkResult, SongMetadata) -> Void)?

  /// Answers "is this still the song playing?" — consulted after every `await`, because cancellation
  /// alone can't close the window between a resumed sleep and the song changing. Assigned after
  /// construction for the same reason as `onResolved`; a `nil` answer stops the retry.
  var isStillCurrent: ((SongMetadata) -> Bool)?

  private var task: Task<Void, Never>?

  init(artworkService: ArtworkService) {
    self.artworkService = artworkService
  }

  /// Delays between attempts when the first lookup found nothing. Grows so we catch up quickly then
  /// back off; the sequence spans ~65s, comfortably covering the collector's cadence.
  nonisolated static let delays: [UInt64] = [5, 10, 20, 30].map { $0 * 1_000_000_000 }

  /// Start retrying for `metadata`, superseding any retry already running. Stops on the first real
  /// result, when the song moves on, or when the schedule is exhausted.
  ///
  /// The `ArtworkService` no longer caches misses, so each attempt actually re-queries the backend.
  func start(for metadata: SongMetadata) {
    task?.cancel()
    task = Task { [weak self] in
      for delay in Self.delays {
        try? await Task.sleep(nanoseconds: delay)
        if Task.isCancelled { return }
        guard let self, self.isStillCurrent?(metadata) == true else { return }

        let artwork = await self.artworkService.fetchArtwork(
          artist: metadata.artist, title: metadata.title)
        if Task.isCancelled || self.isStillCurrent?(metadata) != true { return }
        guard !artwork.isDefault else { continue }

        logger.info("artwork retry succeeded for \(metadata.artist) — \(metadata.title)")
        self.onResolved?(artwork, metadata)
        return
      }
      logger.debug("artwork retry exhausted for \(metadata.artist) — \(metadata.title)")
    }
  }

  /// Abandon any retry in flight — the song has changed, so its cover is no longer wanted.
  func cancel() {
    task?.cancel()
    task = nil
  }
}
