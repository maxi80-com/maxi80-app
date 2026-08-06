import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests the `anniversary_cover` gate on the 25th-anniversary placeholder cover (GitHub issue #71).
///
/// The gate lives in one place, `PlaceholderCover.pool(for:)`. Every generic cover a coverless song is
/// given comes from that pool, and the carousel/Now Playing then read the cover off the song's history
/// entry — so gating the pool gates the feature everywhere and no second flag check exists to fall out
/// of sync.
///
/// The flag defaults *off*: the celebration artwork is unreleased, so a backend that says nothing
/// must leave the original three covers in charge (fail-open means "keep the shipped behaviour",
/// which for an unshipped feature is off).
@Suite("Anniversary Cover Feature Gate")
struct AnniversaryCoverFeatureGateTests {

  /// Draws enough covers that every member of the pool is reached, so "is the anniversary cover
  /// among them" is a fair test. Mirrors what the coordinator does per coverless song.
  ///
  /// The draw count is what makes the randomness a non-issue rather than a flake: with the flag on,
  /// P(the anniversary cover is never drawn in 200 tries over a 4-cover pool) = (3/4)^200 ≈ 1e-25.
  /// Checking the pool's *contents* instead would be deterministic but weaker — that is already
  /// `flagAddsAnniversaryToPool`, and it says nothing about `random(for:)` drawing from the
  /// flag-resolved pool, which is the only thing these two tests exist to prove.
  @MainActor
  private func coversForManyDraws(_ flags: FeatureFlags) -> Set<String> {
    Set((0..<200).map { _ in PlaceholderCover.random(for: flags).imageName })
  }

  // MARK: - The pool

  @Test("By default the pool is the original three covers")
  @MainActor
  func poolExcludesAnniversaryByDefault() {
    let pool = PlaceholderCover.pool(for: FeatureFlags())

    #expect(pool == PlaceholderCover.all)
    #expect(!pool.contains(.anniversary))
  }

  @Test("The backend flag adds the anniversary cover to the pool")
  @MainActor
  func flagAddsAnniversaryToPool() {
    let flags = FeatureFlags()

    flags.update(from: ["anniversary_cover": true])

    let pool = PlaceholderCover.pool(for: flags)
    #expect(pool.contains(.anniversary))
    // Added to the existing covers, not replacing them — the anniversary cover joins the rotation.
    #expect(pool.count == PlaceholderCover.all.count + 1)
    for cover in PlaceholderCover.all {
      #expect(pool.contains(cover))
    }
  }

  @Test("Turning the flag back off removes the anniversary cover again")
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

  @Test("With the flag off, no coverless song is ever given the anniversary cover")
  @MainActor
  func coverlessSongsNeverGetAnniversaryWhenOff() {
    let seen = coversForManyDraws(FeatureFlags())

    #expect(!seen.isEmpty)
    #expect(!seen.contains(PlaceholderCover.anniversary.imageName))
  }

  @Test("With the flag on, coverless songs can be given the anniversary cover")
  @MainActor
  func coverlessSongsGetAnniversaryWhenOn() {
    let flags = FeatureFlags()
    flags.update(from: ["anniversary_cover": true])

    #expect(coversForManyDraws(flags).contains(PlaceholderCover.anniversary.imageName))
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
