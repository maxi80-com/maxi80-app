import Foundation

public struct MetadataParser: Sendable {

  public static func parse(_ rawString: String) -> SongMetadata {
    let trimmed = rawString.trimmingCharacters(in: .whitespaces)

    // Separator choice MUST match the backend's parser (maxi-80-backend-swift MetadataParser), or
    // the artist/title — and therefore the `SongMetadata.identity` used to heal the backend's
    // artwork/color onto a live entry — won't agree, leaving the cover blank. Backend rule:
    //   1. Prefer the spaced " - " on its LAST occurrence, so a multi-artist title stays intact
    //      (e.g. "Michael Jackson - Diana Ross - Ease On Down The Road" → artist
    //      "Michael Jackson - Diana Ross", title "Ease On Down The Road").
    //   2. Otherwise fall back to a bare "-" on its FIRST occurrence, for spaceless entries like
    //      "new order-blue monday".
    //   3. No separator → the whole string is the title (artist left empty; `identity`/display
    //      handle the station-name fallback).
    let range: Range<String.Index>
    if let spaced = trimmed.range(of: " - ", options: .backwards) {
      range = spaced
    } else if let bare = trimmed.range(of: "-") {
      range = bare
    } else {
      return SongMetadata(artist: "", title: trimmed)
    }

    let artist = String(trimmed[trimmed.startIndex..<range.lowerBound])
      .trimmingCharacters(in: .whitespaces)
    let title = String(trimmed[range.upperBound...])
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
