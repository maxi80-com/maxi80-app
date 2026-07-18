import Foundation

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
  /// A resolvable artwork URL. Set directly for live entries (already resolved), or
  /// populated after resolving `artworkKey` via the `/artwork` endpoint.
  public var artworkURL: String?
  /// Apple Music's full artwork color palette, from which the display background is derived.
  /// Supplied by the backend if available (decoded from the `"colors"` object), otherwise
  /// synthesized client-side from the sampled artwork color for live entries.
  public var colors: ArtworkColors?

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
      artworkURL: artworkURL ?? other.artworkURL,
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
    artworkURL = nil
  }

  public init(
    artist: String,
    title: String,
    artworkKey: String? = nil,
    timestamp: String,
    artworkURL: String? = nil,
    colors: ArtworkColors? = nil
  ) {
    self.artist = artist
    self.title = title
    self.artworkKey = artworkKey
    self.timestamp = timestamp
    self.artworkURL = artworkURL
    self.colors = colors
  }
}

/// Wrapper matching the backend `/history` response shape.
public struct HistoryResponse: Decodable, Sendable {
  public let entries: [HistoryEntry]
}
