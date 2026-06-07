import Foundation

public struct SongMetadata: Sendable, Equatable, Codable {
    public let artist: String
    public let title: String

    public init(artist: String, title: String) {
        self.artist = artist
        self.title = title
    }
}
