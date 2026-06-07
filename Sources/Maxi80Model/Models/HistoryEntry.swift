import Foundation

public struct HistoryEntry: Sendable, Identifiable, Codable {
    public let id: String
    public let artist: String
    public let title: String
    public let artwork: String?
    public let timestamp: Double

    public var songMetadata: SongMetadata {
        SongMetadata(artist: artist, title: title)
    }

    public init(
        id: String,
        artist: String,
        title: String,
        artwork: String?,
        timestamp: Double
    ) {
        self.id = id
        self.artist = artist
        self.title = title
        self.artwork = artwork
        self.timestamp = timestamp
    }
}
