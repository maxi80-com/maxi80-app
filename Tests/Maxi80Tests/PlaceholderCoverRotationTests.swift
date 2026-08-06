import SwiftUI
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests placeholder-cover selection (issue #70).
///
/// A coverless slot no longer shows one cover picked at launch: each song gets its own arbitrary
/// pick from the pool, so a session shows all the covers. The pick is stable per song, so it
/// doesn't change under a cover that's already on screen.
@Suite("Placeholder cover selection")
struct PlaceholderCoverRotationTests {

  @MainActor
  private func makeViewModel() -> (vm: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator) {
    let (coordinator, _) = makeTestCoordinator()
    return (RadioPlayerViewModel(coordinator: coordinator), coordinator)
  }

  private func coverlessEntry(_ index: Int) -> HistoryEntry {
    HistoryEntry(artist: "Artist \(index)", title: "Title \(index)", timestamp: "\(1000 + index)")
  }

  // MARK: - The pick itself

  @Test("The same song always gets the same cover")
  func pickIsStablePerSong() {
    let song = SongMetadata(artist: "Talk Talk", title: "Such a Shame")
    let first = PlaceholderCover.forSong(song)
    for _ in 0..<10 {
      #expect(PlaceholderCover.forSong(song) == first)
    }
  }

  @Test("Every cover in the pool gets used across many songs")
  func pickSpreadsAcrossThePool() {
    // Sampling far more songs than covers: a pool member never being picked would mean the
    // selection is stuck, which is the bug this issue is about.
    let picked = Set(
      (0..<200).map { PlaceholderCover.forSong(SongMetadata(artist: "A\($0)", title: "T\($0)")).imageName }
    )
    #expect(picked.count == PlaceholderCover.all.count)
  }

  @Test("A song differing only by artist can get a different cover")
  func pickDependsOnTheWholeSong() {
    // Not a guarantee for any single pair (the pool is small, so collisions are expected) —
    // across many pairs the artist must matter, or the pick ignores half the song.
    let differs = (0..<50).contains { index in
      PlaceholderCover.forSong(SongMetadata(artist: "X\(index)", title: "Same Title"))
        != PlaceholderCover.forSong(SongMetadata(artist: "Y\(index)", title: "Same Title"))
    }
    #expect(differs)
  }

  // MARK: - Carousel placeholders

  @Test("Coverless history entries don't all share one cover")
  @MainActor
  func coverlessHistoryEntriesVary() {
    let (vm, coordinator) = makeViewModel()
    coordinator.history = (0..<60).map(coverlessEntry)

    let pastAssetNames = vm.covers.dropLast().compactMap(\.assetName)
    #expect(pastAssetNames.count == 60)
    #expect(Set(pastAssetNames).count == PlaceholderCover.all.count)
  }

  @Test("Placeholders are stable across renders, so a rendered cover never swaps under the user")
  @MainActor
  func placeholdersAreStableAcrossRenders() {
    let (vm, coordinator) = makeViewModel()
    coordinator.history = (0..<5).map(coverlessEntry)

    let first = vm.covers.map { $0.assetName }
    let second = vm.covers.map { $0.assetName }
    #expect(first == second)
  }

  @Test("A coverless song keeps its placeholder when it slides from the now slot into history")
  @MainActor
  func nowSlotPlaceholderCarriesIntoHistory() {
    let (vm, coordinator) = makeViewModel()
    let liveEntry = HistoryEntry(artist: "Live", title: "Live Song", timestamp: "3000")
    // While `Live Song` is current, its history entry is trailing — it lives only in the now slot.
    coordinator.history = [coverlessEntry(0), coverlessEntry(1), liveEntry]
    coordinator.currentSong = SongMetadata(artist: "Live", title: "Live Song")

    let nowPlaceholder = vm.covers.last?.assetName
    #expect(nowPlaceholder != nil)

    // The next song starts: the previous one becomes the newest past cover, same cover as before.
    coordinator.currentSong = SongMetadata(artist: "Next", title: "Next Song")
    coordinator.history.append(HistoryEntry(artist: "Next", title: "Next Song", timestamp: "4000"))

    let newestPast = vm.covers.dropLast().last
    #expect(newestPast?.id == liveEntry.id)
    #expect(newestPast?.assetName == nowPlaceholder)
  }

  @Test("The idle now slot shows a placeholder")
  @MainActor
  func idleNowSlotHasPlaceholder() {
    let (vm, coordinator) = makeViewModel()
    coordinator.currentSong = nil

    #expect(vm.covers.last?.id == RadioPlayerViewModel.nowSlotID)
    #expect(vm.covers.last?.assetName != nil)
  }

  @Test("Entries with resolved artwork carry no placeholder")
  @MainActor
  func coveredEntriesHaveNoPlaceholder() {
    let (vm, coordinator) = makeViewModel()
    coordinator.history = [
      HistoryEntry(
        artist: "A", title: "A Song", timestamp: "1000",
        artworkURL: "https://art.example/a.jpg"),
      coverlessEntry(1),
    ]

    let past = vm.covers.dropLast()
    #expect(past.first?.assetName == nil)
    #expect(past.last?.assetName != nil)
  }

  // MARK: - Now Playing placeholder

  @Test("The Now Playing placeholder cover follows the carousel's now slot")
  @MainActor
  func nowPlayingPlaceholderMatchesNowSlot() {
    let (vm, coordinator) = makeViewModel()
    coordinator.history = [coverlessEntry(0)]
    coordinator.currentSong = SongMetadata(artist: "Live", title: "Live Song")

    #expect(coordinator.nowPlaceholderCover.imageName == vm.covers.last?.assetName)
  }

  @Test("The Now Playing placeholder changes with the song")
  @MainActor
  func nowPlayingPlaceholderFollowsTheSong() {
    let (_, coordinator) = makeViewModel()
    var seen: Set<String> = []
    for index in 0..<60 {
      coordinator.currentSong = SongMetadata(artist: "A\(index)", title: "T\(index)")
      seen.insert(coordinator.nowPlaceholderCover.imageName)
    }

    #expect(seen.count == PlaceholderCover.all.count)
  }
}
