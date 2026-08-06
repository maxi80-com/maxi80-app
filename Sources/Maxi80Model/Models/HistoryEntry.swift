import Foundation

/// Where a played song's cover comes from. Stored non-optionally on `HistoryEntry`, so an entry always
/// says what to show and no reader needs a fallback of its own. Three cases, not two: a song *given* a
/// generic cover has to stay distinguishable from one whose artwork simply hasn't been looked up yet,
/// or a later fetch would re-roll the cover already on screen instead of filling in the real one.
///
/// Named `CoverSource`, not `Cover`, because the carousel already has a `Cover` view model.
public enum CoverSource: Sendable, Equatable {
  /// A resolvable artwork URL — the song's own cover, from the backend.
  case artwork(String)
  /// Asset name of one of the bundled generic covers, given to a song that has no artwork of its own
  /// (issue #70). A *name* rather than an image because this module has no SwiftUI, and never decoded
  /// from the backend, which knows nothing about our bundled covers.
  case generic(String)
  /// Artwork not resolved yet. Backend entries decode into this and leave it within the same fetch,
  /// as `resolveArtwork(for:)` settles every entry on `.artwork` or `.generic`.
  case pending

  /// The artwork URL when there is one. `nil` for a generic or unresolved cover — the one question
  /// callers ask that a generic cover cannot answer, so it stays explicit rather than folded into the
  /// asset name.
  public var artworkURL: String? {
    guard case .artwork(let url) = self else { return nil }
    return url
  }

  /// Whether the song's own artwork is still worth looking up: true for `.pending`, and also for
  /// `.generic`, because a generic cover is what we show *until* the backend collector produces the
  /// real one. Drives which history entries a `/history` refresh re-resolves.
  public var wantsArtwork: Bool {
    artworkURL == nil
  }

  /// The better of two covers for the same play. Real artwork beats a generic cover beats an
  /// unresolved one, and `self` wins ties — so healing a live entry against its backend copy fills in
  /// artwork that has since appeared, but never re-rolls a generic cover already on screen.
  public func mergedWith(_ other: CoverSource) -> CoverSource {
    switch (self, other) {
    case (.artwork, _): return self
    case (_, .artwork): return other
    case (.generic, _): return self
    case (_, .generic): return other
    case (.pending, .pending): return .pending
    }
  }
}

/// A single played song. Decoded from the backend `/history` response, which returns
/// `{"entries": [{artist, title, artwork, timestamp}]}` where `artwork` is an S3 key
/// (not a loadable URL) and `timestamp` is an ISO-8601 string. The backend has no `id`,
/// so a stable one is derived from timestamp + artist + title.
public struct HistoryEntry: Sendable, Identifiable, Decodable, Equatable {
  public let artist: String
  public let title: String
  /// S3 key of the artwork from the backend (e.g. "collected/Artist/Title/artwork.jpg").
  /// Not directly loadable — resolve to a presigned URL via the `/artwork` endpoint.
  public let artworkKey: String?
  /// Opaque timestamp string from the backend (ISO-8601), or a synthesized value for
  /// live entries. Used only to derive a stable id and preserve ordering.
  public let timestamp: String
  /// What to show for this song: its own artwork (a resolvable URL — set directly for live entries,
  /// or after resolving `artworkKey` via the `/artwork` endpoint), or a bundled generic cover. Set
  /// once, wherever the entry is created, and from then on read as-is: downstream code shows the
  /// cover without caring which kind it is.
  public var cover: CoverSource
  /// Apple Music's full artwork color palette, from which the display background is derived.
  /// Supplied by the backend if available (decoded from the `"colors"` object), otherwise
  /// synthesized client-side from the sampled artwork color for live entries.
  public var colors: ArtworkColors?

  /// This entry's artwork URL, or `nil` if it's showing a generic cover / isn't resolved yet.
  public var artworkURL: String? { cover.artworkURL }

  /// The color to paint behind this entry's cover, derived from the palette. `nil` when the
  /// entry has no palette (coverless / not-yet-enriched), so the UI paints its branded default.
  public var backgroundColor: RGBColor? { colors?.displayBackground }

  /// Stable identity derived from the backend fields (the API provides no id).
  public var id: String { "\(timestamp)|\(artist)|\(title)" }

  public var songMetadata: SongMetadata {
    SongMetadata(artist: artist, title: title)
  }

  /// Normalized song identity for history dedup — collapses the station-name artist to empty so
  /// a backend copy and a live artist-less copy of the same program match. See `SongMetadata.identity`.
  public var songIdentity: SongMetadata {
    songMetadata.identity
  }

  /// Merge another entry known to represent the same play as `self`. Prefers a non-empty artist
  /// (so the backend's `Maxi80` wins over a live artist-less copy) and fills artwork/colors from
  /// whichever entry has them, `self` winning ties. The single home of the "keep `Maxi80`, keep
  /// the artwork" policy; only ever applied to a pair the caller already decided is one play.
  public func mergedWith(_ other: HistoryEntry) -> HistoryEntry {
    HistoryEntry(
      artist: artist.isEmpty ? other.artist : artist,
      title: title,
      artworkKey: artworkKey ?? other.artworkKey,
      timestamp: timestamp,
      cover: cover.mergedWith(other.cover),
      colors: colors ?? other.colors
    )
  }

  private enum CodingKeys: String, CodingKey {
    case artist, title, timestamp, colors
    case artworkKey = "artwork"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    artist = try container.decode(String.self, forKey: .artist)
    title = try container.decode(String.self, forKey: .title)
    artworkKey = try container.decodeIfPresent(String.self, forKey: .artworkKey)
    timestamp = try container.decode(String.self, forKey: .timestamp)
    colors = try container.decodeIfPresent(ArtworkColors.self, forKey: .colors)
    // The backend sends an S3 key, not a loadable URL, and knows nothing about our bundled covers —
    // so a decoded entry has no cover yet. `resolveArtwork(for:)` settles it within the same fetch.
    cover = .pending
  }

  public init(
    artist: String,
    title: String,
    artworkKey: String? = nil,
    timestamp: String,
    cover: CoverSource = .pending,
    colors: ArtworkColors? = nil
  ) {
    self.artist = artist
    self.title = title
    self.artworkKey = artworkKey
    self.timestamp = timestamp
    self.cover = cover
    self.colors = colors
  }
}

/// Wrapper matching the backend `/history` response shape.
public struct HistoryResponse: Decodable, Sendable {
  public let entries: [HistoryEntry]
}
