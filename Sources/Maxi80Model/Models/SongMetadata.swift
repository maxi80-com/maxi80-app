import Foundation

public struct SongMetadata: Sendable, Equatable, Hashable, Codable {
  public let artist: String
  public let title: String

  public init(artist: String, title: String) {
    self.artist = artist
    self.title = title
  }

  /// True when the artist is the station name (e.g. `Maxi80`, `Maxi 80`), which the backend
  /// attaches to DJ programs that the live stream metadata leaves artist-less. Compared
  /// case- and whitespace-insensitively so both the spaced and unspaced forms match.
  public var isStationArtist: Bool {
    artist.lowercased().filter { !$0.isWhitespace } == "maxi80"
  }

  /// The identity used to decide whether two songs are "the same" in history. Collapses the
  /// station-name artist to empty so a backend `Maxi80` entry and a live artist-less entry for
  /// the same program share one identity. Leaves `==`/`hash` untouched — those keep exact
  /// semantics for artwork retry and current-song equality.
  public var identity: SongMetadata {
    isStationArtist ? SongMetadata(artist: "", title: title) : self
  }
}
