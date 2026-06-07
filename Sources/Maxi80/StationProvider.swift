import Foundation
import Maxi80Model
import Maxi80Services

/// Provides station metadata with a 3-tier fallback chain:
/// 1. Fetch from API (GET /station)
/// 2. Return cached station from previous successful fetch
/// 3. Return hardcoded default station
@MainActor
public final class StationProvider {
    private let apiClient: APIClient
    private var cachedStation: Station?

    /// Hardcoded fallback station used when API fails and no cache is available.
    private let defaultStation = Station(
        name: "Maxi 80",
        streamUrl: "https://audio1.maxi80.com",
        image: "",
        shortDesc: "La radio de toute une génération",
        longDesc: "Maxi 80, la radio de toute une génération",
        websiteUrl: "https://www.maxi80.com",
        donationUrl: "https://www.maxi80.com/don",
        defaultCoverUrl: ""
    )

    public init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    /// The current station: cached if available, otherwise the hardcoded default.
    public var currentStation: Station {
        cachedStation ?? defaultStation
    }

    /// Fetches station metadata from the API with fallback chain.
    /// - Returns the API result on success (also caches it),
    ///   the previously cached station on failure,
    ///   or the hardcoded default if no cache exists.
    public func loadStation() async -> Station {
        let jsonString: String? = await withCheckedContinuation { continuation in
            apiClient.fetchStation { result in
                continuation.resume(returning: result)
            }
        }

        if let jsonString,
           let data = jsonString.data(using: .utf8) {
            do {
                let station = try JSONDecoder().decode(Station.self, from: data)
                cachedStation = station
                return station
            } catch {
                print("[StationProvider] Failed to decode station JSON: \(error.localizedDescription)")
            }
        }

        // API failed or decode failed — use cache or default
        return currentStation
    }
}
