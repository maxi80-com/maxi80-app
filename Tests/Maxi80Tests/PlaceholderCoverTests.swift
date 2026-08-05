import Testing

@testable import Maxi80

@Suite("Placeholder cover rotation")
struct PlaceholderCoverTests {

  @Test("Provider cycles through every cover before repeating")
  @MainActor
  func providerCycles() {
    let provider = PlaceholderCoverProvider()
    let count = PlaceholderCover.all.count
    let firstRound = (0..<count).map { _ in provider.next() }

    #expect(Set(firstRound.map(\.imageName)).count == count)
    #expect(provider.next() == firstRound[0])
  }

  @Test("Per-entry covers are stable and in range")
  func forEntryIsStable() {
    for hash in [Int.min, -1, 0, 1, 7, Int.max] {
      let cover = PlaceholderCover.forEntry(hashValue: hash)
      #expect(PlaceholderCover.all.contains(cover))
      #expect(cover == PlaceholderCover.forEntry(hashValue: hash))
    }
  }
}
