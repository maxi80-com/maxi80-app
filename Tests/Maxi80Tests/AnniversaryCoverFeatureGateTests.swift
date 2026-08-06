import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests the `anniversary_cover` gate on the 25th-anniversary placeholder cover (GitHub issue #71).
///
/// The gate lives in one place, `RadioPlayerCoordinator.placeholderCoverPool`. Every placeholder pick
/// — the carousel's now slot, its coverless history entries, and the artwork published to system Now
/// Playing — resolves through that pool, so gating the pool gates the feature everywhere and no
/// second flag check exists to fall out of sync.
///
/// The flag defaults *off*: the celebration artwork is unreleased, so a backend that says nothing
/// must leave the original three covers in charge (fail-open means "keep the shipped behaviour",
/// which for an unshipped feature is off).
@Suite("Anniversary Cover Feature Gate")
struct AnniversaryCoverFeatureGateTests {

  @MainActor
  private func makeViewModel(flags: FeatureFlags)
    -> (viewModel: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator)
  {
    let (coordinator, _) = makeTestCoordinator(featureFlags: flags)
    return (RadioPlayerViewModel(coordinator: coordinator, featureFlags: flags), coordinator)
  }

  /// Songs whose picks cover the whole pool, so "is the anniversary cover reachable" is a fair test.
  private var manySongs: [SongMetadata] {
    (0..<200).map { SongMetadata(artist: "A\($0)", title: "T\($0)") }
  }

  // MARK: - The pool

  @Test("By default the pool is the original three covers")
  @MainActor
  func poolExcludesAnniversaryByDefault() {
    let (_, coordinator) = makeViewModel(flags: FeatureFlags())

    #expect(coordinator.placeholderCoverPool == PlaceholderCover.all)
    #expect(!coordinator.placeholderCoverPool.contains(.anniversary))
  }

  @Test("The backend flag adds the anniversary cover to the pool")
  @MainActor
  func flagAddsAnniversaryToPool() {
    let flags = FeatureFlags()
    let (_, coordinator) = makeViewModel(flags: flags)

    flags.update(from: ["anniversary_cover": true])

    #expect(coordinator.placeholderCoverPool.contains(.anniversary))
    // Added to the existing covers, not replacing them — the anniversary cover joins the rotation.
    #expect(coordinator.placeholderCoverPool.count == PlaceholderCover.all.count + 1)
    for cover in PlaceholderCover.all {
      #expect(coordinator.placeholderCoverPool.contains(cover))
    }
  }

  @Test("Turning the flag back off removes the anniversary cover again")
  @MainActor
  func flagOffRevertsThePool() {
    let flags = FeatureFlags()
    let (_, coordinator) = makeViewModel(flags: flags)
    flags.update(from: ["anniversary_cover": true])

    // How the celebration window closes: the backend stops mentioning the flag, so it reverts to
    // its default rather than keeping the stale override.
    flags.update(from: [:])

    #expect(coordinator.placeholderCoverPool == PlaceholderCover.all)
  }

  // MARK: - The carousel

  @Test("With the flag off, no coverless carousel slot ever shows the anniversary cover")
  @MainActor
  func carouselNeverShowsAnniversaryWhenOff() {
    let (viewModel, coordinator) = makeViewModel(flags: FeatureFlags())
    coordinator.history = (0..<120).map {
      HistoryEntry(artist: "Artist \($0)", title: "Title \($0)", timestamp: "\(1000 + $0)")
    }

    let assetNames = Set(viewModel.covers.compactMap(\.assetName))
    #expect(!assetNames.isEmpty)
    #expect(!assetNames.contains(PlaceholderCover.anniversary.imageName))
  }

  @Test("With the flag on, the anniversary cover appears among the carousel placeholders")
  @MainActor
  func carouselShowsAnniversaryWhenOn() {
    let flags = FeatureFlags()
    let (viewModel, coordinator) = makeViewModel(flags: flags)
    flags.update(from: ["anniversary_cover": true])
    coordinator.history = (0..<120).map {
      HistoryEntry(artist: "Artist \($0)", title: "Title \($0)", timestamp: "\(1000 + $0)")
    }

    let assetNames = Set(viewModel.covers.compactMap(\.assetName))
    #expect(assetNames.contains(PlaceholderCover.anniversary.imageName))
  }

  // MARK: - Now Playing

  @Test("With the flag off, the Now Playing placeholder never uses the anniversary cover")
  @MainActor
  func nowPlayingNeverUsesAnniversaryWhenOff() {
    let (_, coordinator) = makeViewModel(flags: FeatureFlags())

    for song in manySongs {
      coordinator.currentSong = song
      #expect(coordinator.nowPlaceholderCover != .anniversary)
    }
  }

  @Test("With the flag on, the Now Playing placeholder can use the anniversary cover")
  @MainActor
  func nowPlayingUsesAnniversaryWhenOn() {
    // Now Playing resolves the pool separately from the carousel (it materializes a file for the
    // system/CarPlay), so it's worth checking the gate reaches this reader too.
    let flags = FeatureFlags()
    let (_, coordinator) = makeViewModel(flags: flags)
    flags.update(from: ["anniversary_cover": true])

    let seen = manySongs.map { song -> PlaceholderCover in
      coordinator.currentSong = song
      return coordinator.nowPlaceholderCover
    }
    #expect(seen.contains(.anniversary))
  }

  // MARK: - Pool size

  @Test("Every cover is reachable for pools of any size, including even ones")
  func picksReachEveryCoverForAnyPoolSize() {
    // Regression: the pick took the remainder of the raw FNV-1a hash, whose low bits barely move, so
    // an even-sized pool reached only part of it. Three covers hid the bug; adding the anniversary
    // cover made a four-pool land on just two images. Sizes past the current pool are covered so the
    // next cover added can't reintroduce it.
    for size in 1...8 {
      let pool = (0..<size).map {
        PlaceholderCover(imageName: "Cover-\($0)", dominantColor: .black)
      }
      let picked = Set(manySongs.map { PlaceholderCover.forSong($0, from: pool).imageName })
      #expect(picked.count == size, "pool of \(size) reached only \(picked.count) covers")
    }
  }
}
