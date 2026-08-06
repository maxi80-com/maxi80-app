import Foundation
import Maxi80Model
import Maxi80Services

/// Provides station metadata with a 3-tier fallback chain:
/// 1. Fetch from API (GET /station)
/// 2. Return cached station from previous successful fetch
/// 3. Return hardcoded default station
///
/// Note: this type decodes `Station` but does **not** apply `Station.features` to `FeatureFlags` —
/// `RadioPlayerCoordinator.loadStation()` is the only place flags are applied. It runs the same
/// fallback chain and is what the live app uses; this type is currently exercised only by tests.
@MainActor
public final class StationProvider {
  private let apiClient: any APIClientProtocol
  private var cachedStation: Station?

  /// Hardcoded fallback station used when API fails and no cache is available.
  private let defaultStation = Station(
    name: BrandConstants.name,
    streamUrl: BrandConstants.streamURL,
    image: "",
    shortDesc: BrandConstants.tagline,
    longDesc: BrandConstants.longDescription,
    websiteUrl: BrandConstants.websiteURL,
    donationUrl: BrandConstants.donationURL,
    defaultCoverUrl: ""
  )

  public init(apiClient: any APIClientProtocol) {
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
    let jsonString = try? await apiClient.fetchStation()

    if let jsonString {
      do {
        let station = try jsonString.decodedJSON(as: Station.self)
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
