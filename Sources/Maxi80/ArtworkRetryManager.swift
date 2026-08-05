import Foundation
import Maxi80Model
import OSLog

/// Retries the artwork lookup for a song when it wasn't available on first fetch (the backend
/// collector hadn't produced it yet). Backs off then gives up.
///
/// Extracted from `RadioPlayerCoordinator` (issue #68 item 1b).
@MainActor @Observable
final class ArtworkRetryManager {

  /// Delays between retries. Grows so we catch up quickly then back off;
  /// the sequence spans ~65s, comfortably covering the collector's cadence.
  nonisolated static let retryDelays: [UInt64] = [5, 10, 20, 30].map { $0 * 1_000_000_000 }

  @ObservationIgnored
  private var retryTask: Task<Void, Never>?
  @ObservationIgnored
  private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "ArtworkRetryManager")

  /// Cancel any running retry loop (e.g. when the song changes).
  func cancel() {
    retryTask?.cancel()
    retryTask = nil
  }

  /// Begin retrying artwork for `metadata`.
  ///
  /// - Parameters:
  ///   - metadata: The song to look up artwork for.
  ///   - currentSong: Closure returning the current song, for staleness checks.
  ///   - fetchArtwork: Closure that performs the actual artwork fetch.
  ///   - onResolved: Called when artwork is successfully resolved.
  func startRetry(
    for metadata: SongMetadata,
    currentSong: @escaping () -> SongMetadata?,
    fetchArtwork: @escaping (String, String) async -> ArtworkResult,
    onResolved: @escaping (ArtworkResult, SongMetadata) -> Void
  ) {
    retryTask = Task { [weak self] in
      for delay in Self.retryDelays {
        try? await Task.sleep(nanoseconds: delay)
        if Task.isCancelled { return }
        guard self != nil else { return }

        // Bail if the song moved on while we were waiting.
        guard currentSong() == metadata else { return }

        let artwork = await fetchArtwork(metadata.artist, metadata.title)
        if Task.isCancelled || currentSong() != metadata { return }
        guard !artwork.isDefault else { continue }

        self?.logger.info("artwork retry succeeded for \(metadata.artist) — \(metadata.title)")
        onResolved(artwork, metadata)
        return
      }
      self?.logger.debug("artwork retry exhausted for \(metadata.artist) — \(metadata.title)")
    }
  }
}
