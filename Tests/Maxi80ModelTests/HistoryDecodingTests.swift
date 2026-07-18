import Foundation
import Testing

@testable import Maxi80Model

/// Locks the app's decoding to the backend `/history` contract:
/// `{"entries": [{artist, title, artwork (S3 key), timestamp (ISO-8601 string)}]}`.
/// A mismatch here previously left history silently empty.
@Suite("History Decoding — backend contract")
struct HistoryDecodingTests {

  @Test("Decodes the wrapped entries array from the backend")
  func decodesWrappedEntries() throws {
    let json = """
      {
        "entries": [
          {"artist": "A-ha", "title": "Take On Me", "artwork": "collected/A-ha/Take On Me/artwork.jpg", "timestamp": "2025-01-15T14:30:00Z"},
          {"artist": "Tears for Fears", "title": "Shout", "artwork": "collected/Tears for Fears/Shout/artwork.jpg", "timestamp": "2025-01-15T14:33:00Z"}
        ]
      }
      """
    let data = Data(json.utf8)

    let response = try JSONDecoder().decode(HistoryResponse.self, from: data)

    #expect(response.entries.count == 2)
    #expect(response.entries[0].artist == "A-ha")
    #expect(response.entries[0].title == "Take On Me")
    // `artwork` is an S3 key, exposed as artworkKey; no loadable URL yet.
    #expect(response.entries[0].artworkKey == "collected/A-ha/Take On Me/artwork.jpg")
    #expect(response.entries[0].artworkURL == nil)
    #expect(response.entries[0].timestamp == "2025-01-15T14:30:00Z")
  }

  @Test("Derived id is stable and distinguishes entries")
  func derivedIdIsStable() throws {
    let entry = HistoryEntry(
      artist: "Depeche Mode", title: "Enjoy the Silence", timestamp: "2025-01-15T14:30:00Z")
    let same = HistoryEntry(
      artist: "Depeche Mode", title: "Enjoy the Silence", timestamp: "2025-01-15T14:30:00Z")
    let different = HistoryEntry(
      artist: "Depeche Mode", title: "Personal Jesus", timestamp: "2025-01-15T14:30:00Z")

    #expect(entry.id == same.id)
    #expect(entry.id != different.id)
  }

  @Test("Empty entries array decodes to an empty history")
  func decodesEmptyEntries() throws {
    let data = Data("{\"entries\":[]}".utf8)
    let response = try JSONDecoder().decode(HistoryResponse.self, from: data)
    #expect(response.entries.isEmpty)
  }

  @Test("Decodes the artwork colors palette and derives the background color")
  func decodesColorsPalette() throws {
    let json = """
      {
        "entries": [
          {
            "artist": "Jeanne Mas", "title": "L'enfant",
            "artwork": "v2/Jeanne Mas/L'enfant/artwork.jpg",
            "timestamp": "2026-07-16T08:18:26Z",
            "colors": {"bg": "#1C2520", "text1": "#E6B996", "text2": "#DDB5B1", "text3": "#BE9C7E", "text4": "#B69894"}
          }
        ]
      }
      """
    let data = Data(json.utf8)

    let response = try JSONDecoder().decode(HistoryResponse.self, from: data)

    #expect(response.entries[0].colors?.bg == RGBColor.parse(hex: "#1C2520"))
    // Grey bg → background resolves to the most saturated bright text color.
    #expect(response.entries[0].backgroundColor?.hexString == "#E6B996")
  }

  @Test("Absent colors decodes to nil, no background color")
  func absentColorsIsNil() throws {
    let json = """
      {"entries": [{"artist": "A-ha", "title": "Take On Me", "artwork": "k.jpg", "timestamp": "t"}]}
      """
    let response = try JSONDecoder().decode(HistoryResponse.self, from: Data(json.utf8))
    #expect(response.entries[0].colors == nil)
    #expect(response.entries[0].backgroundColor == nil)
  }
}
