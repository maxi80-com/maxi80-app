import Testing
@testable import Maxi80
@testable import Maxi80Model

/// Tests for StationProvider fallback chain logic.
/// Validates Requirements 8.1, 8.2, 8.3, 8.4, 8.5, 8.6
@Suite("StationProvider Fallback Chain")
struct StationProviderTests {

    // MARK: - Helpers

    /// A mock APIClient subclass that returns a controllable JSON response.
    final class MockAPIClient: APIClient {
        var stationJSON: String?

        init(stationJSON: String? = nil) {
            self.stationJSON = stationJSON
            super.init(baseURL: "https://test.example.com", authToken: "test-key")
        }

        override func fetchStation(completion: @escaping (String?) -> Void) {
            completion(stationJSON)
        }
    }

    // MARK: - Tests

    @Test("Returns station from API on success and caches it")
    @MainActor
    func fetchStationFromAPI() async {
        let json = """
        {
            "name": "Test Station",
            "streamUrl": "https://stream.test.com",
            "image": "https://img.test.com/logo.png",
            "shortDesc": "A test station",
            "longDesc": "A test station for unit tests",
            "websiteUrl": "https://test.com",
            "donationUrl": "https://test.com/donate",
            "defaultCoverUrl": "https://img.test.com/cover.png"
        }
        """
        let mockClient = MockAPIClient(stationJSON: json)
        let provider = StationProvider(apiClient: mockClient)

        let station = await provider.loadStation()

        #expect(station.name == "Test Station")
        #expect(station.streamUrl == "https://stream.test.com")
        #expect(station.shortDesc == "A test station")
        // After successful fetch, currentStation should be the cached result
        #expect(provider.currentStation.name == "Test Station")
    }

    @Test("Returns cached station when API fails")
    @MainActor
    func fallbackToCachedStation() async {
        let json = """
        {
            "name": "Cached Station",
            "streamUrl": "https://stream.cached.com",
            "image": "",
            "shortDesc": "Cached desc",
            "longDesc": "Cached long desc",
            "websiteUrl": "https://cached.com",
            "donationUrl": "https://cached.com/don",
            "defaultCoverUrl": ""
        }
        """
        let mockClient = MockAPIClient(stationJSON: json)
        let provider = StationProvider(apiClient: mockClient)

        // First call succeeds, populating cache
        _ = await provider.loadStation()
        #expect(provider.currentStation.name == "Cached Station")

        // Now simulate API failure
        mockClient.stationJSON = nil
        let station = await provider.loadStation()

        // Should return cached station
        #expect(station.name == "Cached Station")
        #expect(station.shortDesc == "Cached desc")
    }

    @Test("Returns hardcoded default when API fails and no cache")
    @MainActor
    func fallbackToHardcodedDefault() async {
        let mockClient = MockAPIClient(stationJSON: nil)
        let provider = StationProvider(apiClient: mockClient)

        let station = await provider.loadStation()

        #expect(station.name == "Maxi 80")
        #expect(station.shortDesc == "La radio de toute une génération")
        #expect(station.streamUrl == "https://audio1.maxi80.com")
        #expect(station.websiteUrl == "https://www.maxi80.com")
        #expect(station.donationUrl == "https://www.maxi80.com/don")
    }

    @Test("Returns hardcoded default when API returns malformed JSON")
    @MainActor
    func fallbackOnMalformedJSON() async {
        let mockClient = MockAPIClient(stationJSON: "{ invalid json }")
        let provider = StationProvider(apiClient: mockClient)

        let station = await provider.loadStation()

        #expect(station.name == "Maxi 80")
        #expect(station.shortDesc == "La radio de toute une génération")
    }

    @Test("currentStation returns default when no fetch has occurred")
    @MainActor
    func currentStationDefaultBeforeFetch() {
        let mockClient = MockAPIClient(stationJSON: nil)
        let provider = StationProvider(apiClient: mockClient)

        #expect(provider.currentStation.name == "Maxi 80")
        #expect(provider.currentStation.shortDesc == "La radio de toute une génération")
    }
}
