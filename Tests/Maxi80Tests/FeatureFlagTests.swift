import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model

/// Tests for the runtime feature-flag system.
/// Validates that defaults, API overrides, and reset semantics work correctly.
@Suite("FeatureFlags")
@MainActor
struct FeatureFlagTests {

  // MARK: - Defaults

  @Test("sleepTimer defaults to true when no overrides are set")
  func sleepTimerDefaultIsTrue() {
    let flags = FeatureFlags()
    #expect(flags.isEnabled(.sleepTimer) == true)
  }

  @Test("anniversaryCover defaults to false when no overrides are set")
  func anniversaryCoverDefaultIsFalse() {
    let flags = FeatureFlags()
    #expect(flags.isEnabled(.anniversaryCover) == false)
  }

  // MARK: - Overrides

  @Test("API override enables anniversaryCover")
  func overrideEnablesAnniversaryCover() {
    let flags = FeatureFlags()
    flags.update(from: ["anniversary_cover": true])
    #expect(flags.isEnabled(.anniversaryCover) == true)
  }

  @Test("API override disables sleepTimer")
  func overrideDisablesSleepTimer() {
    let flags = FeatureFlags()
    flags.update(from: ["sleep_timer": false])
    #expect(flags.isEnabled(.sleepTimer) == false)
  }

  @Test("API can override multiple flags at once")
  func overrideMultipleFlags() {
    let flags = FeatureFlags()
    flags.update(from: ["anniversary_cover": true, "sleep_timer": false])
    #expect(flags.isEnabled(.anniversaryCover) == true)
    #expect(flags.isEnabled(.sleepTimer) == false)
  }

  // MARK: - Unknown flags

  @Test("Unknown keys in the features dict are silently ignored")
  func unknownKeysIgnored() {
    let flags = FeatureFlags()
    // Should not throw or affect known flags
    flags.update(from: ["some_future_flag": true, "another_unknown": false])
    // Known flags retain their defaults
    #expect(flags.isEnabled(.anniversaryCover) == false)
    #expect(flags.isEnabled(.sleepTimer) == true)
  }

  // MARK: - Reset semantics

  @Test("Empty dict clears overrides and restores defaults")
  func emptyDictResetsToDefaults() {
    let flags = FeatureFlags()
    // Set some overrides
    flags.update(from: ["anniversary_cover": true, "sleep_timer": false])
    #expect(flags.isEnabled(.anniversaryCover) == true)
    #expect(flags.isEnabled(.sleepTimer) == false)

    // Reset with empty dict
    flags.update(from: [:])
    #expect(flags.isEnabled(.anniversaryCover) == false)
    #expect(flags.isEnabled(.sleepTimer) == true)
  }

  @Test("Second update replaces first — no leftover keys from prior call")
  func secondUpdateReplacesFirst() {
    let flags = FeatureFlags()
    flags.update(from: ["anniversary_cover": true])
    flags.update(from: ["sleep_timer": false])
    // anniversary_cover was NOT in the second update, so it reverts to default
    #expect(flags.isEnabled(.anniversaryCover) == false)
    #expect(flags.isEnabled(.sleepTimer) == false)
  }
}

/// Tests that `Station` correctly decodes with and without the `features` field.
@Suite("Station Decoding — features field")
struct StationFeaturesDecodingTests {

  private let baseJSON = """
    {
      "name": "Maxi 80",
      "streamUrl": "https://audio1.maxi80.com",
      "image": "https://img.maxi80.com/logo.png",
      "shortDesc": "La radio de toute une génération",
      "longDesc": "Les hits des années 80",
      "websiteUrl": "https://www.maxi80.com",
      "donationUrl": "https://www.maxi80.com/don",
      "defaultCoverUrl": "https://img.maxi80.com/cover.jpg"
    }
    """

  @Test("Decodes station without features field (backward compat)")
  func decodesWithoutFeaturesField() throws {
    let data = Data(baseJSON.utf8)
    let station = try JSONDecoder().decode(Station.self, from: data)
    #expect(station.features == nil)
    #expect(station.name == "Maxi 80")
  }

  @Test("Decodes station with features field present")
  func decodesWithFeaturesField() throws {
    let json = """
      {
        "name": "Maxi 80",
        "streamUrl": "https://audio1.maxi80.com",
        "image": "",
        "shortDesc": "La radio de toute une génération",
        "longDesc": "",
        "websiteUrl": "https://www.maxi80.com",
        "donationUrl": "https://www.maxi80.com/don",
        "defaultCoverUrl": "",
        "features": {"anniversary_cover": true, "sleep_timer": false}
      }
      """
    let station = try JSONDecoder().decode(Station.self, from: Data(json.utf8))
    #expect(station.features?["anniversary_cover"] == true)
    #expect(station.features?["sleep_timer"] == false)
  }

  @Test("Decodes station with empty features dict")
  func decodesWithEmptyFeaturesDict() throws {
    let json = """
      {
        "name": "Maxi 80",
        "streamUrl": "https://audio1.maxi80.com",
        "image": "",
        "shortDesc": "La radio de toute une génération",
        "longDesc": "",
        "websiteUrl": "https://www.maxi80.com",
        "donationUrl": "https://www.maxi80.com/don",
        "defaultCoverUrl": "",
        "features": {}
      }
      """
    let station = try JSONDecoder().decode(Station.self, from: Data(json.utf8))
    #expect(station.features != nil)
    #expect(station.features?.isEmpty == true)
  }
}
