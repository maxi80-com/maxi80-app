import Foundation

public struct MetadataParser: Sendable {

    public static func parse(_ rawString: String) -> SongMetadata {
        let separator = " - "
        guard let range = rawString.range(of: separator) else {
            return SongMetadata(
                artist: "",
                title: rawString.trimmingCharacters(in: .whitespaces)
            )
        }
        let artist = String(rawString[rawString.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let title = String(rawString[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return SongMetadata(artist: artist, title: title)
    }

    public static func format(_ metadata: SongMetadata) -> String {
        if metadata.artist.isEmpty {
            return metadata.title
        }
        return "\(metadata.artist) - \(metadata.title)"
    }
}
