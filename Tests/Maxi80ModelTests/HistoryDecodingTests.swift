import Testing
import Foundation
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
        let entry = HistoryEntry(artist: "Depeche Mode", title: "Enjoy the Silence", timestamp: "2025-01-15T14:30:00Z")
        let same = HistoryEntry(artist: "Depeche Mode", title: "Enjoy the Silence", timestamp: "2025-01-15T14:30:00Z")
        let different = HistoryEntry(artist: "Depeche Mode", title: "Personal Jesus", timestamp: "2025-01-15T14:30:00Z")

        #expect(entry.id == same.id)
        #expect(entry.id != different.id)
    }

    @Test("Empty entries array decodes to an empty history")
    func decodesEmptyEntries() throws {
        let data = Data("{\"entries\":[]}".utf8)
        let response = try JSONDecoder().decode(HistoryResponse.self, from: data)
        #expect(response.entries.isEmpty)
    }
}
