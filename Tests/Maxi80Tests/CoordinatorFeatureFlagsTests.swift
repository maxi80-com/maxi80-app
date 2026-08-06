import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests that `loadStation()` applies the backend's `features` object to the flag store, across all
/// three tiers of the station fallback chain (GitHub issue #72).
///
/// Each test injects its own `FeatureFlags` instance, so none of them mutate the process-wide
/// `FeatureFlags.shared` or depend on execution order.
@Suite("Coordinator Feature Flags")
struct CoordinatorFeatureFlagsTests {

  /// Fake API client serving a controllable `/station` body; everything else is unavailable.
  actor StationMockAPIClient: APIClientProtocol {
    private var stationJSON: String?

    init(stationJSON: String?) {
      self.stationJSON = stationJSON
    }

    func setStationJSON(_ json: String?) {
      stationJSON = json
    }

    func fetchStation() async throws(APIClientError) -> String {
      guard let stationJSON else { throw .noContent }
      return stationJSON
    }

    func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
      throw .noContent
    }

    func fetchHistory() async throws(APIClientError) -> String { throw .noContent }
  }

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

  @MainActor
  private func makeCoordinator(stationJSON: String?, flags: FeatureFlags)
    -> (coordinator: RadioPlayerCoordinator, apiClient: StationMockAPIClient)
  {
    let apiClient = StationMockAPIClient(stationJSON: stationJSON)
    let coordinator = RadioPlayerCoordinator(
      player: AudioStreamPlayer(),
      nowPlaying: NowPlayingController(),
      apiClient: apiClient,
      artworkService: ArtworkService(apiClient: apiClient),
      featureFlags: flags
    )
    return (coordinator, apiClient)
  }

  @Test("Station flags from the API are applied to the flag store")
  @MainActor
  func appliesFlagsFromAPI() async {
    let flags = FeatureFlags()
    let (coordinator, _) = makeCoordinator(
      stationJSON: Self.stationJSON(features: #"{ "anniversary_cover": true }"#), flags: flags)

    await coordinator.loadStation()

    #expect(flags.isEnabled(.anniversaryCover) == true)
  }

  @Test("A station response without a features object leaves the compiled-in defaults in charge")
  @MainActor
  func defaultsWhenResponseOmitsFeatures() async {
    let flags = FeatureFlags()
    let (coordinator, _) = makeCoordinator(stationJSON: Self.stationJSON(), flags: flags)
    // Seed non-default values first, so the assertions below can only pass if `loadStation()`
    // actually applies the (absent) features — a fresh store would satisfy them for free.
    flags.update(from: ["anniversary_cover": true, "sleep_timer": false])

    await coordinator.loadStation()

    #expect(flags.isEnabled(.anniversaryCover) == false)
    #expect(flags.isEnabled(.sleepTimer) == true)
  }

  @Test("A failed station load with no cache leaves the compiled-in defaults in charge")
  @MainActor
  func defaultsWhenStationLoadFails() async {
    let flags = FeatureFlags()
    let (coordinator, _) = makeCoordinator(stationJSON: nil, flags: flags)
    flags.update(from: ["anniversary_cover": true, "sleep_timer": false])

    await coordinator.loadStation()

    #expect(flags.isEnabled(.anniversaryCover) == false)
    #expect(flags.isEnabled(.sleepTimer) == true)
  }

  @Test("A failed station load carries the previously cached flags forward")
  @MainActor
  func cachedFlagsSurviveAFailedReload() async {
    let flags = FeatureFlags()
    let (coordinator, apiClient) = makeCoordinator(
      stationJSON: Self.stationJSON(features: #"{ "anniversary_cover": true }"#), flags: flags)

    await coordinator.loadStation()
    #expect(flags.isEnabled(.anniversaryCover) == true)

    // Backend now unreachable — the coordinator falls back to the cached station, which still
    // carries the flags it was fetched with.
    await apiClient.setStationJSON(nil)
    await coordinator.loadStation()

    #expect(flags.isEnabled(.anniversaryCover) == true)
  }

  @Test("A reload that drops a flag from the response reverts it to its default")
  @MainActor
  func reloadWithoutFlagRevertsToDefault() async {
    let flags = FeatureFlags()
    let (coordinator, apiClient) = makeCoordinator(
      stationJSON: Self.stationJSON(features: #"{ "anniversary_cover": true }"#), flags: flags)

    await coordinator.loadStation()
    #expect(flags.isEnabled(.anniversaryCover) == true)

    // The celebration window closed: the backend stopped sending the flag.
    await apiClient.setStationJSON(Self.stationJSON())
    await coordinator.loadStation()

    #expect(flags.isEnabled(.anniversaryCover) == false)
  }

  @Test("A malformed features payload keeps the station usable and falls back to defaults")
  @MainActor
  func malformedFeaturesKeepStationUsable() async {
    let flags = FeatureFlags()
    let (coordinator, _) = makeCoordinator(
      stationJSON: Self.stationJSON(features: #"{ "anniversary_cover": "yes" }"#), flags: flags)

    await coordinator.loadStation()

    #expect(coordinator.station?.streamUrl == "https://audio1.maxi80.com")
    #expect(flags.isEnabled(.anniversaryCover) == false)
    #expect(flags.isEnabled(.sleepTimer) == true)
  }

  @Test("A backend kill switch disables an on-by-default flag")
  @MainActor
  func killSwitchDisablesShippedFeature() async {
    let flags = FeatureFlags()
    let (coordinator, _) = makeCoordinator(
      stationJSON: Self.stationJSON(features: #"{ "sleep_timer": false }"#), flags: flags)

    await coordinator.loadStation()

    #expect(flags.isEnabled(.sleepTimer) == false)
  }
}
