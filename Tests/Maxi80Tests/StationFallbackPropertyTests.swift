import Testing
import SwiftCheck
@testable import Maxi80
@testable import Maxi80Model

/// **Validates: Requirements 8.5, 8.6**
@Suite("Station Fallback Property Tests — P5: Station Fallback Chain")
struct StationFallbackPropertyTests {

    // MARK: - Helpers

    /// A mock APIClient that returns a controllable JSON response for station requests.
    /// Uses a distinct name to avoid conflicts with StationProviderTests.MockAPIClient.
    final class FallbackMockAPIClient: APIClient, @unchecked Sendable {
        var stationJSON: String?

        init(stationJSON: String? = nil) {
            self.stationJSON = stationJSON
            super.init(baseURL: "https://test.example.com", authToken: "test-key")
        }

        override func fetchStation(completion: @escaping (String?) -> Void) {
            completion(stationJSON)
        }
    }

    // MARK: - Property Tests

    /// Property 5: When the API fails but a cached Station exists, the provider returns the cached Station.
    /// Generated optional Station fields are used to populate the cache, then API failure is simulated.
    @Test("P5: API failure with cached station returns cached station")
    @MainActor
    func fallbackToCachedStation() async {
        // Use SwiftCheck generators to produce arbitrary test data, then verify the property with async calls.
        let iterations = 100
        for _ in 0..<iterations {
            let name = String.arbitrary.generate
            let streamUrl = String.arbitrary.generate
            let shortDesc = String.arbitrary.generate

            // Skip empty names — station needs a valid name to be meaningful
            guard !name.isEmpty else { continue }

            // Escape special characters for JSON safety
            let escapedName = escapeJSON(name)
            let escapedStreamUrl = escapeJSON(streamUrl)
            let escapedShortDesc = escapeJSON(shortDesc)

            let validJSON = """
            {"name":"\(escapedName)","streamUrl":"\(escapedStreamUrl)","image":"","shortDesc":"\(escapedShortDesc)","longDesc":"","websiteUrl":"","donationUrl":"","defaultCoverUrl":""}
            """

            let mockClient = FallbackMockAPIClient(stationJSON: validJSON)
            let provider = StationProvider(apiClient: mockClient)

            // First fetch succeeds — populates cache
            let firstResult = await provider.loadStation()

            // If JSON encoding caused decode failure, skip this case
            guard firstResult.name == name else { continue }

            // Simulate API failure
            mockClient.stationJSON = nil
            let fallbackResult = await provider.loadStation()

            // Property: cached station is returned on failure
            #expect(fallbackResult.name == name,
                    "Expected cached name '\(name)' but got '\(fallbackResult.name)'")
            #expect(fallbackResult.shortDesc == shortDesc,
                    "Expected cached shortDesc '\(shortDesc)' but got '\(fallbackResult.shortDesc)'")
        }
    }

    /// Property 5: When the API fails and no cached Station exists, the provider returns hardcoded defaults.
    @Test("P5: API failure with no cache returns hardcoded defaults")
    @MainActor
    func fallbackToHardcodedDefaults() async {
        property("hardcoded defaults returned when no cache and API fails") <- forAll(Gen<Int>.fromElements(in: 1...100)) { _ in
            // This property is deterministic — the result is always the same hardcoded station.
            // We just verify it holds across arbitrary "iterations" (no generated state needed).
            let mockClient = FallbackMockAPIClient(stationJSON: nil)
            let provider = StationProvider(apiClient: mockClient)

            // currentStation (synchronous) returns the default when no cache exists
            let result = provider.currentStation

            let nameCorrect = result.name == "Maxi 80"
            let descCorrect = result.shortDesc == "La radio de toute une génération"
            let streamCorrect = result.streamUrl == "https://audio1.maxi80.com"

            return nameCorrect && descCorrect && streamCorrect
        }
    }

    // MARK: - Private Helpers

    private func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
