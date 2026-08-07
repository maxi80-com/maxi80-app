import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests the `anniversary_cover` gate on the 25th-anniversary placeholder covers (GitHub issue #71).
///
/// The gate lives in one place, `PlaceholderCover.pool(for:)`. Every generic cover a coverless song is
/// given comes from that pool, and the carousel/Now Playing then read the cover off the song's history
/// entry — so gating the pool gates the feature everywhere and no second flag check exists to fall out
/// of sync.
///
/// The flag switches the whole `PlaceholderCover.anniversary` *set* on or off, not a single cover: on
/// means all of them join the rotation, off means none of them can be drawn. So every assertion below
/// is over the set, never over one image name — adding a fifth celebration cover must not need a test
/// edit.
///
/// The flag defaults *off*: the celebration artwork is unreleased, so a backend that says nothing
/// must leave the original three covers in charge (fail-open means "keep the shipped behaviour",
/// which for an unshipped feature is off).
@Suite("Anniversary Cover Feature Gate")
struct AnniversaryCoverFeatureGateTests {

  /// Draws enough covers that every member of the pool is reached, so "are the anniversary covers
  /// among them" is a fair test. Mirrors what the coordinator does per coverless song.
  ///
  /// The draw count is what makes the randomness a non-issue rather than a flake: with the flag on the
  /// pool is 7 covers, and the rarest single cover is missed from 500 draws with probability
  /// (6/7)^500 ≈ 1e-33 — so requiring *all four* celebration covers to appear is still not a flake.
  /// Checking the pool's *contents* instead would be deterministic but weaker — that is already
  /// `flagAddsAnniversaryToPool`, and it says nothing about `random(for:)` drawing from the
  /// flag-resolved pool, which is the only thing these two tests exist to prove.
  @MainActor
  private func coversForManyDraws(_ flags: FeatureFlags) -> Set<String> {
    Set((0..<500).map { _ in PlaceholderCover.random(for: flags).imageName })
  }

  /// Asset names of the celebration covers — the unit the flag switches, so what assertions compare.
  private var anniversaryNames: Set<String> {
    Set(PlaceholderCover.anniversary.map(\.imageName))
  }

  // MARK: - The pool

  @Test("By default the pool is the original three covers")
  @MainActor
  func poolExcludesAnniversaryByDefault() {
    let pool = PlaceholderCover.pool(for: FeatureFlags())

    #expect(pool == PlaceholderCover.all)
    for cover in PlaceholderCover.anniversary {
      #expect(!pool.contains(cover))
    }
  }

  @Test("The backend flag adds every anniversary cover to the pool")
  @MainActor
  func flagAddsAnniversaryToPool() {
    let flags = FeatureFlags()

    flags.update(from: ["anniversary_cover": true])

    let pool = PlaceholderCover.pool(for: flags)
    // All four celebration covers join, not just one — the flag switches the set.
    for cover in PlaceholderCover.anniversary {
      #expect(pool.contains(cover))
    }
    // Added to the existing covers, not replacing them.
    #expect(pool.count == PlaceholderCover.all.count + PlaceholderCover.anniversary.count)
    for cover in PlaceholderCover.all {
      #expect(pool.contains(cover))
    }
  }

  @Test("Turning the flag back off removes the anniversary covers again")
  @MainActor
  func flagOffRevertsThePool() {
    let flags = FeatureFlags()
    flags.update(from: ["anniversary_cover": true])

    // How the celebration window closes: the backend stops mentioning the flag, so it reverts to
    // its default rather than keeping the stale override.
    flags.update(from: [:])

    #expect(PlaceholderCover.pool(for: flags) == PlaceholderCover.all)
  }

  // MARK: - What a coverless song is given

  @Test("With the flag off, no coverless song is ever given an anniversary cover")
  @MainActor
  func coverlessSongsNeverGetAnniversaryWhenOff() {
    let seen = coversForManyDraws(FeatureFlags())

    #expect(!seen.isEmpty)
    #expect(seen.isDisjoint(with: anniversaryNames))
  }

  @Test("With the flag on, coverless songs can be given any of the anniversary covers")
  @MainActor
  func coverlessSongsGetAnniversaryWhenOn() {
    let flags = FeatureFlags()
    flags.update(from: ["anniversary_cover": true])

    // Every celebration cover must be reachable, not merely one of them: a pool that dropped three
    // of the four would still pass a "contains any" check.
    #expect(coversForManyDraws(flags).isSuperset(of: anniversaryNames))
  }

  @Test("Every drawn cover is one of the bundled covers, flag on or off")
  @MainActor
  func drawsOnlyEverYieldBundledCovers() {
    let flags = FeatureFlags()
    flags.update(from: ["anniversary_cover": true])
    let eligible = Set(PlaceholderCover.pool(for: flags).map(\.imageName))

    #expect(coversForManyDraws(flags).isSubset(of: eligible))
    #expect(coversForManyDraws(FeatureFlags()).isSubset(of: PlaceholderCover.all.map(\.imageName)))
  }
}
