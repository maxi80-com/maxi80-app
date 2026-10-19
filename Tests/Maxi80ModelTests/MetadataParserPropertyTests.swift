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
  ///
  /// Excluded: bare-"-" splits whose title `format` can't re-emit unambiguously, because the
  /// backend-mandated separator rules then re-split it differently:
  /// - empty artist with a "-" in the title ("--a" → ("", "-a") → "-a" → ("", "a"))
  /// - title starting with "- " or containing " - " ("a-- b" → ("a", "- b") → "a - - b" → ("a -", "b"))
  /// See `idempotentParse_bareDashSplits_resplitOnReparse`.
  @Test("P1b: parse(format(parse(raw))) == parse(raw) — idempotent parse")
  func idempotentParse() {
    property("parse(format(parse(s))) == parse(s)")
      <- forAll { (raw: String) in
        let first = MetadataParser.parse(raw)
        let isFormatUnambiguous = first.artist.isEmpty
          ? !first.title.contains("-")
          : !first.title.hasPrefix("- ") && !first.title.contains(" - ")
        return isFormatUnambiguous
          ==> (MetadataParser.parse(MetadataParser.format(first)) == first)
      }
  }

  @Test("P1b counterexamples: bare-dash splits that format can't re-emit re-split on reparse")
  func idempotentParse_bareDashSplits_resplitOnReparse() {
    let emptyArtist = MetadataParser.parse("--a")
    #expect(emptyArtist == SongMetadata(artist: "", title: "-a"))
    #expect(MetadataParser.parse(MetadataParser.format(emptyArtist)) == SongMetadata(artist: "", title: "a"))

    let dashSpaceTitle = MetadataParser.parse("a-- b")
    #expect(dashSpaceTitle == SongMetadata(artist: "a", title: "- b"))
    #expect(MetadataParser.parse(MetadataParser.format(dashSpaceTitle)) == SongMetadata(artist: "a -", title: "b"))
  }
}
