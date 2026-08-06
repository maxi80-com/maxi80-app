import Testing

@testable import Maxi80

/// Tests for the runtime feature-flag store (GitHub issue #72).
///
/// The governing rule is fail-open: a flag system must never be the reason a shipped feature
/// disappears, so every degraded path (no network, no `features` object, unreadable payload) has to
/// land on the compiled-in defaults rather than on `false`.
@Suite("Feature Flags")
struct FeatureFlagsTests {

  @Test("Before any backend update, flags read their compiled-in defaults")
  @MainActor
  func defaultsBeforeUpdate() {
    let flags = FeatureFlags()

    #expect(flags.isEnabled(.sleepTimer) == true)
    #expect(flags.isEnabled(.anniversaryCover) == false)
  }

  @Test("A backend override turns a default-off flag on")
  @MainActor
  func overrideEnablesFlag() {
    let flags = FeatureFlags()

    flags.update(from: ["anniversary_cover": true])

    #expect(flags.isEnabled(.anniversaryCover) == true)
  }

  @Test("A backend override turns a default-on flag off (kill switch)")
  @MainActor
  func overrideDisablesFlag() {
    let flags = FeatureFlags()

    flags.update(from: ["sleep_timer": false])

    #expect(flags.isEnabled(.sleepTimer) == false)
  }

  @Test("Flags the response doesn't mention keep their defaults")
  @MainActor
  func unmentionedFlagsKeepDefaults() {
    let flags = FeatureFlags()

    flags.update(from: ["anniversary_cover": true])

    #expect(flags.isEnabled(.sleepTimer) == true)
  }

  @Test("Unknown flag names in the response are ignored, not fatal")
  @MainActor
  func unknownFlagsAreIgnored() {
    let flags = FeatureFlags()

    flags.update(from: ["some_future_flag": true, "sleep_timer": false])

    #expect(flags.isEnabled(.sleepTimer) == false)
    #expect(flags.isEnabled(.anniversaryCover) == false)
  }

  @Test("A nil update (no features in the response) restores the compiled-in defaults")
  @MainActor
  func nilUpdateRestoresDefaults() {
    let flags = FeatureFlags()
    flags.update(from: ["sleep_timer": false, "anniversary_cover": true])

    flags.update(from: nil)

    #expect(flags.isEnabled(.sleepTimer) == true)
    #expect(flags.isEnabled(.anniversaryCover) == false)
  }

  @Test("An empty features object restores the compiled-in defaults")
  @MainActor
  func emptyUpdateRestoresDefaults() {
    let flags = FeatureFlags()
    flags.update(from: ["sleep_timer": false])

    flags.update(from: [:])

    #expect(flags.isEnabled(.sleepTimer) == true)
  }

  @Test("A later update replaces the previous overrides rather than merging into them")
  @MainActor
  func updateReplacesPreviousOverrides() {
    let flags = FeatureFlags()
    flags.update(from: ["anniversary_cover": true])

    flags.update(from: ["sleep_timer": false])

    // anniversary_cover went unmentioned by the newer response, so it must fall back to its
    // default rather than keep the stale `true`.
    #expect(flags.isEnabled(.anniversaryCover) == false)
    #expect(flags.isEnabled(.sleepTimer) == false)
  }

  @Test("Every declared flag has a compiled-in default")
  @MainActor
  func everyFlagHasADefault() {
    let flags = FeatureFlags()

    for flag in FeatureFlags.Flag.allCases {
      #expect(flags.defaultValue(for: flag) != nil, "\(flag.rawValue) has no compiled-in default")
    }
  }

  @Test("Flag raw values are the lower_snake_case names the backend sends")
  func rawValuesMatchBackendContract() {
    #expect(FeatureFlags.Flag.anniversaryCover.rawValue == "anniversary_cover")
    #expect(FeatureFlags.Flag.sleepTimer.rawValue == "sleep_timer")
  }
}
