import SwiftCheck
import Testing

@testable import Maxi80Model

// MARK: - Arbitrary conformance for SongMetadata

/// Generates arbitrary SongMetadata suitable for round-trip testing.
/// Constraints:
/// - Artist does NOT contain " - " (since format uses " - " as separator, this would break round-trip)
/// - When artist is empty, title must NOT contain " - " (since format returns just the title,
///   which parse would then split on " - " producing a non-empty artist)
/// - Both fields are trimmed of leading/trailing whitespace (since parse trims)
extension SongMetadata: Arbitrary {
  public static var arbitrary: Gen<SongMetadata> {
    Gen<SongMetadata>.compose { composer in
      let artist = composer.generate(
        using: String.arbitrary
          .suchThat { !$0.contains(" - ") }
          .map { $0.trimmingCharacters(in: .whitespaces) }
      )
      let title: String
      if artist.isEmpty {
        // When artist is empty, format returns just the title.
        // If title contains " - ", parse would split it into artist/title — breaking round-trip.
        title = composer.generate(
          using: String.arbitrary
            .suchThat { !$0.contains(" - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        )
      } else {
        title = composer.generate(
          using: String.arbitrary
            .map { $0.trimmingCharacters(in: .whitespaces) }
        )
      }
      return SongMetadata(artist: artist, title: title)
    }
  }
}

// MARK: - Property Tests

/// **Validates: Requirements 4.2, 4.3, 4.6**
@Suite("MetadataParser Property Tests — P1: ICY Metadata Round-Trip")
struct MetadataParserPropertyTests {

  /// Property 1a: For any SongMetadata (with constrained artist), formatting then parsing
  /// produces the original metadata.
  /// parse(format(metadata)) == metadata
  @Test("P1a: parse(format(metadata)) == metadata for round-trip")
  func roundTrip() {
    property("parse(format(metadata)) == metadata")
      <- forAll { (metadata: SongMetadata) in
        let formatted = MetadataParser.format(metadata)
        let parsed = MetadataParser.parse(formatted)
        return parsed == metadata
      }
  }

  /// Property 1b: For any raw ICY string, parsing then formatting then parsing again
  /// produces the same result as the first parse. This is a weaker but universally-valid
  /// idempotency property that holds even for strings containing " - ".
  /// parse(format(parse(raw))) == parse(raw)
  @Test("P1b: parse(format(parse(raw))) == parse(raw) — idempotent parse")
  func idempotentParse() {
    property("parse(format(parse(s))) == parse(s)")
      <- forAll { (raw: String) in
        let first = MetadataParser.parse(raw)
        let roundTripped = MetadataParser.parse(MetadataParser.format(first))
        return roundTripped == first
      }
  }
}
