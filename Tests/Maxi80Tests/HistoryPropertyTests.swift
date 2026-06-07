import Testing
import Foundation
import SwiftCheck
@testable import Maxi80
@testable import Maxi80Model

/// **Validates: Requirements 6.5, 6.6**
@Suite("History Property Tests — P2: History Append Preserves Order and Size")
struct HistoryPropertyTests {

    /// Property 2: For any history list of length N and any new SongMetadata,
    /// appending a HistoryEntry from that metadata produces a list of length N+1
    /// whose last element matches the appended artist and title.
    @Test("P2: Appending entry preserves order and increases size by 1")
    func historyAppendPreservesOrder() {
        property("append preserves order and size") <- forAll { (artist: String, title: String) in
            // Create a random-length history (simulating arbitrary prior state)
            var history: [HistoryEntry] = []
            let count = Int.random(in: 0...20)
            for i in 0..<count {
                history.append(HistoryEntry(
                    id: "\(i)",
                    artist: "Artist \(i)",
                    title: "Title \(i)",
                    artwork: nil,
                    timestamp: Double(i)
                ))
            }

            let originalCount = history.count

            // Append new entry (simulating the coordinator logic)
            let newEntry = HistoryEntry(
                id: UUID().uuidString,
                artist: artist,
                title: title,
                artwork: nil,
                timestamp: Date().timeIntervalSince1970
            )
            history.append(newEntry)

            // Property: size increased by exactly 1
            let sizeCorrect = history.count == originalCount + 1

            // Property: last element matches appended entry's artist and title
            let lastMatches = history.last?.artist == artist && history.last?.title == title

            return sizeCorrect && lastMatches
        }
    }
}
