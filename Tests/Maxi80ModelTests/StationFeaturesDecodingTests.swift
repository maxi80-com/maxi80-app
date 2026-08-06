import Foundation
import Testing

@testable import Maxi80Model

/// Tests for the optional `features` object on the `/station` response (GitHub issue #72).
///
/// The decoder must be lenient about `features` specifically: a malformed flag payload may not take
/// the whole station down with it, because that would cost the app its stream URL and descriptions
/// over a backend typo.
@Suite("Station Features Decoding")
struct StationFeaturesDecodingTests {

  /// Builds a `/station` body with the required fields, plus whatever `features` fragment is given.
  static func stationJSON(features: String? = nil) -> String {
    let featuresField = features.map { ",\n  \"features\": \($0)" } ?? ""
    return """
      {
        "name": "Maxi 80",
        "streamUrl": "https://audio1.maxi80.com",
        "image": "",
        "shortDesc": "desc",
        "longDesc": "long desc",
        "websiteUrl": "https://www.maxi80.com",
        "donationUrl": "https://www.maxi80.com/don",
        "defaultCoverUrl": ""\(featuresField)
      }
      """
  }

  static func decode(_ json: String) throws -> Station {
    try JSONDecoder().decode(Station.self, from: Data(json.utf8))
  }

  @Test("Decodes the features object into a boolean dictionary")
  func decodesFeatures() throws {
    let station = try Self.decode(
      Self.stationJSON(features: #"{ "anniversary_cover": true, "sleep_timer": false }"#))

    #expect(station.features?["anniversary_cover"] == true)
    #expect(station.features?["sleep_timer"] == false)
    #expect(station.name == "Maxi 80")
  }

  @Test("A response with no features key decodes with nil features")
  func decodesWithoutFeatures() throws {
    let station = try Self.decode(Self.stationJSON())

    #expect(station.features == nil)
    #expect(station.streamUrl == "https://audio1.maxi80.com")
  }

  @Test("An explicit null features value decodes to nil")
  func decodesNullFeatures() throws {
    let station = try Self.decode(Self.stationJSON(features: "null"))

    #expect(station.features == nil)
  }

  @Test("An empty features object decodes to an empty dictionary")
  func decodesEmptyFeatures() throws {
    let station = try Self.decode(Self.stationJSON(features: "{}"))

    #expect(station.features?.isEmpty == true)
  }

  @Test("Malformed feature values are dropped without failing the station decode")
  func malformedFeaturesDoNotFailStationDecode() throws {
    let station = try Self.decode(Self.stationJSON(features: #"{ "anniversary_cover": "yes" }"#))

    #expect(station.features?.isEmpty == true)
    // The important part: the rest of the station survived.
    #expect(station.name == "Maxi 80")
    #expect(station.streamUrl == "https://audio1.maxi80.com")
  }

  @Test("One malformed flag value does not discard the other flags in the same payload")
  func malformedFlagDoesNotDiscardItsNeighbours() throws {
    // An all-or-nothing decode would make an emergency kill switch a silent no-op whenever some
    // unrelated flag in the same payload carries a bad value.
    let station = try Self.decode(
      Self.stationJSON(features: #"{ "sleep_timer": false, "new_flag": "yes" }"#))

    #expect(station.features?["sleep_timer"] == false)
    #expect(station.features?["new_flag"] == nil)
    #expect(station.features?.count == 1)
  }

  @Test("A features value of the wrong JSON type degrades to nil features")
  func nonObjectFeaturesDegradesToNil() throws {
    let station = try Self.decode(Self.stationJSON(features: "[1, 2, 3]"))

    #expect(station.features == nil)
    #expect(station.name == "Maxi 80")
  }

  @Test("A station built without features has nil features")
  func initDefaultsFeaturesToNil() {
    let station = Station(
      name: "Maxi 80", streamUrl: "https://audio1.maxi80.com", image: "", shortDesc: "",
      longDesc: "", websiteUrl: "", donationUrl: "", defaultCoverUrl: "")

    #expect(station.features == nil)
  }

  @Test("Encoding round-trips the features dictionary")
  func encodeRoundTripsFeatures() throws {
    let original = Station(
      name: "Maxi 80", streamUrl: "https://audio1.maxi80.com", image: "", shortDesc: "",
      longDesc: "", websiteUrl: "", donationUrl: "", defaultCoverUrl: "",
      features: ["anniversary_cover": true])

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Station.self, from: data)

    #expect(decoded.features?["anniversary_cover"] == true)
  }
}
