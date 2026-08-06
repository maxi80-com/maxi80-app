import SwiftUI
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests generic placeholder covers (issue #70).
///
/// A coverless song is given one of the generic covers when its history entry is created, and from
/// then on that cover is simply the song's artwork: the carousel, the history list and system Now
/// Playing all read it off the entry, and nothing re-picks it. So a session shows all the covers,
/// and no cover ever changes under the user.
@Suite("Placeholder cover selection")
struct PlaceholderCoverRotationTests {

  @MainActor
  private func makeViewModel() -> (vm: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator) {
    let (coordinator, _) = makeTestCoordinator()
    return (RadioPlayerViewModel(coordinator: coordinator), coordinator)
  }

  /// A history entry as the coordinator creates one for a coverless song: no artwork, generic cover.
  private func coverlessEntry(_ index: Int, cover: String = PlaceholderCover.all[0].imageName)
    -> HistoryEntry
  {
    HistoryEntry(
      artist: "Artist \(index)", title: "Title \(index)", timestamp: "\(1000 + index)",
      cover: .generic(cover))
  }

  /// The generic cover an entry was given, or `nil` if it is showing real artwork.
  private func genericCover(_ entry: HistoryEntry?) -> String? {
    guard case .generic(let name) = entry?.cover else { return nil }
    return name
  }

  // MARK: - Assignment

  @Test("A coverless song is given a generic cover when it starts")
  @MainActor
  func coverlessSongGetsACover() async {
    let (vm, coordinator) = makeViewModel()

    // The stub backend serves no artwork, so this song resolves coverless.
    await coordinator.handleMetadataChanged("Talk Talk - Such a Shame")

    #expect(PlaceholderCover.all.map(\.imageName).contains(coordinator.nowPlaceholderCover))
    // The now slot shows it, and the song's history entry carries it.
    #expect(vm.covers.last?.assetName == coordinator.nowPlaceholderCover)
    #expect(genericCover(coordinator.history.last) == coordinator.nowPlaceholderCover)
  }

  @Test("Successive coverless songs don't all get the same cover")
  @MainActor
  func coversVaryAcrossSongs() async {
    let (_, coordinator) = makeViewModel()

    var seen: Set<String> = []
    for index in 0..<60 {
      await coordinator.handleMetadataChanged("Artist \(index) - Title \(index)")
      seen.insert(coordinator.nowPlaceholderCover)
    }

    // The bug this issue is about: one cover picked at launch and reused all session. Asserting the
    // WHOLE pool is reached, not merely "more than one cover", is what catches the real regression
    // shape — a pool that silently collapses to a subset of itself. 60 draws over 3 covers leaves
    // P(some cover unseen) = 3·(2/3)^60 ≈ 3e-10, so this is not a practical flake.
    #expect(seen.count == PlaceholderCover.all.count)
  }

  @Test("Backend history entries with no resolvable artwork get a cover too")
  @MainActor
  func backendEntriesGetCovers() async {
    // These never pass through the now slot — on a cold start `/history` seeds past songs directly —
    // so their covers have to come from the fetch path or they'd render blank.
    // 90 entries over 3 covers: P(some cover unseen) = 3·(2/3)^90 ≈ 5e-16. Same whole-pool
    // assertion as above, at a draw count where chance failure is not a consideration.
    let entryCount = 90
    let json = HistoryMergeTests.historyJSON(
      (0..<entryCount).map { ("Artist \($0)", "Title \($0)", "2026-07-15T10:00:\(1000 + $0)Z") })
    let coordinator = makeTestCoordinator(
      apiClient: HistoryMergeTests.HistoryMockAPIClient(historyJSON: json)
    ).coordinator

    await coordinator.fetchHistory()

    #expect(coordinator.history.count == entryCount)
    #expect(coordinator.history.allSatisfy { genericCover($0) != nil })
    #expect(
      Set(coordinator.history.compactMap { genericCover($0) }).count == PlaceholderCover.all.count)
  }

  @Test("Entries whose artwork resolves get no generic cover")
  @MainActor
  func coveredEntriesHaveNoPlaceholder() async {
    let json = HistoryMergeTests.historyJSON([("A", "A Song", "2026-07-15T10:00:00Z")])
    let coordinator = makeTestCoordinator(
      apiClient: HistoryMergeTests.HistoryMockAPIClient(historyJSON: json, servesArtwork: true)
    ).coordinator

    await coordinator.fetchHistory()

    #expect(coordinator.history.first?.artworkURL != nil)
    #expect(genericCover(coordinator.history.first) == nil)
  }

  // MARK: - Stability

  @Test("A coverless song keeps its cover when it slides from the now slot into history")
  @MainActor
  func nowSlotCoverCarriesIntoHistory() async {
    let (vm, coordinator) = makeViewModel()

    await coordinator.handleMetadataChanged("Live - Live Song")
    let nowCover = vm.covers.last?.assetName
    #expect(nowCover != nil)
    let liveEntryID = coordinator.history.last?.id

    // The next song starts: the previous one becomes the newest past cover, same image as before.
    await coordinator.handleMetadataChanged("Next - Next Song")

    let newestPast = vm.covers.dropLast().last
    #expect(newestPast?.id == liveEntryID)
    #expect(newestPast?.assetName == nowCover)
  }

  @Test("A DJ program keeps its cover when history heals the artist to the station name")
  @MainActor
  func stationArtistCoverSurvivesHistoryHealing() {
    // The live entry is artist-less while it is the now slot, then `mergedWith` promotes the
    // backend's `Maxi80` artist once it is a past cover. The cover must survive that merge.
    let liveEntry = HistoryEntry(
      artist: "", title: "Le Grand Mix", timestamp: "3000",
      cover: .generic(PlaceholderCover.all[2].imageName))

    let healed = liveEntry.mergedWith(
      HistoryEntry(artist: "Maxi80", title: "Le Grand Mix", timestamp: "3000"))

    #expect(healed.artist == "Maxi80")
    #expect(healed.cover == liveEntry.cover)
  }

  @Test("The song playing at launch doesn't get a second cover when it heals its seeded entry")
  @MainActor
  func healingTheSeededEntryKeepsItsCover() async {
    let (vm, coordinator) = makeViewModel()
    // What `/history` seeds: the song already playing, with the cover assigned at fetch time.
    let seeded = HistoryEntry(
      artist: "Live", title: "Live Song", timestamp: "3000",
      cover: .generic(PlaceholderCover.all[1].imageName))
    coordinator.history = [coverlessEntry(0), seeded]

    // The first metadata event is for that same song, and heals the entry in place rather than
    // appending. Re-rolling here would swap the cover the user is already looking at.
    await coordinator.handleMetadataChanged("Live - Live Song")

    #expect(coordinator.history.count == 2)
    #expect(coordinator.nowPlaceholderCover == genericCover(seeded))
    #expect(vm.covers.last?.assetName == genericCover(seeded))
  }

  @Test("Covers are stable across renders, so a rendered cover never swaps under the user")
  @MainActor
  func coversAreStableAcrossRenders() {
    let (vm, coordinator) = makeViewModel()
    coordinator.history = (0..<5).map { coverlessEntry($0) }

    let first = vm.covers.map { $0.assetName }
    let second = vm.covers.map { $0.assetName }
    #expect(first == second)
  }

  // MARK: - The now slot

  @Test("The idle now slot shows a cover")
  @MainActor
  func idleNowSlotHasCover() {
    let (vm, coordinator) = makeViewModel()
    coordinator.currentSong = nil

    #expect(vm.covers.last?.id == RadioPlayerViewModel.nowSlotID)
    #expect(vm.covers.last?.assetName != nil)
  }

  @Test("The Now Playing cover matches the carousel's now slot")
  @MainActor
  func nowPlayingCoverMatchesNowSlot() async {
    let (vm, coordinator) = makeViewModel()
    await coordinator.handleMetadataChanged("Live - Live Song")

    #expect(coordinator.nowPlaceholderCover == vm.covers.last?.assetName)
  }
}
