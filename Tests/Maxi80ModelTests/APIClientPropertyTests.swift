import Testing
import Foundation
import SwiftCheck
@testable import Maxi80Model

// MARK: - Generators for API Endpoints

/// Represents the three API endpoint types supported by APIClient.
enum APIEndpoint: CustomStringConvertible {
    case station
    case artwork(artist: String, title: String)
    case history

    var description: String {
        switch self {
        case .station: return "/station"
        case .artwork(let artist, let title): return "/artwork?artist=\(artist)&title=\(title)"
        case .history: return "/history"
        }
    }

    /// Construct the full URL string that APIClient would use for this endpoint.
    func urlString(baseURL: String) -> String? {
        switch self {
        case .station:
            return "\(baseURL)/station"
        case .artwork(let artist, let title):
            guard var components = URLComponents(string: "\(baseURL)/artwork") else { return nil }
            components.queryItems = [
                URLQueryItem(name: "artist", value: artist),
                URLQueryItem(name: "title", value: title)
            ]
            return components.url?.absoluteString
        case .history:
            return "\(baseURL)/history"
        }
    }
}

extension APIEndpoint: Arbitrary {
    public static var arbitrary: Gen<APIEndpoint> {
        let stationGen = Gen<APIEndpoint>.pure(.station)
        let historyGen = Gen<APIEndpoint>.pure(.history)
        let artworkGen = Gen<APIEndpoint>.compose { composer in
            let artist = composer.generate(using: String.arbitrary.map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            let title = composer.generate(using: String.arbitrary.map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            return APIEndpoint.artwork(artist: artist, title: title)
        }
        return Gen<APIEndpoint>.one(of: [stationGen, historyGen, artworkGen])
    }
}

// MARK: - Property Tests

/// **Validates: Requirements 9.1**
@Suite("APIClient Property Tests — P8: Authorization Header Inclusion")
struct APIClientPropertyTests {

    /// Property 8: For any non-empty auth token and any API endpoint, the constructed
    /// URLRequest SHALL contain the "Authorization" header with the configured token value.
    @Test("P8: Every request includes Authorization header with configured token value")
    func authTokenAlwaysIncluded() {
        property("Authorization header equals configured token for all endpoints") <- forAll { (endpoint: APIEndpoint, apiKey: String) in
            // Skip empty keys (APIClient requires a non-empty key to be meaningful)
            guard !apiKey.isEmpty else { return true }

            let baseURL = "https://api.example.com"
            let client = APIClient(baseURL: baseURL, authToken: apiKey)

            // Get the URL string for this endpoint
            guard let urlString = endpoint.urlString(baseURL: baseURL) else {
                // If URL construction fails (e.g., invalid characters), skip
                return true
            }

            // Use the internal makeRequest method to construct the URLRequest
            guard let request = client.makeRequest(for: urlString) else {
                // If URL is invalid, skip this case
                return true
            }

            // Assert: Authorization header is present and matches the configured token
            return request.value(forHTTPHeaderField: APIConfiguration.authHeaderName) == apiKey
        }
    }

    /// Additional property: For any valid base URL and auth token, all three endpoint methods
    /// produce requests that include the correct Authorization header.
    @Test("P8: All endpoint types include Authorization header")
    func allEndpointTypesIncludeAuthHeader() {
        property("station, artwork, and history requests all have Authorization header") <- forAll { (apiKey: String) in
            guard !apiKey.isEmpty else { return true }

            let baseURL = "https://api.example.com"
            let client = APIClient(baseURL: baseURL, authToken: apiKey)

            let headerName = APIConfiguration.authHeaderName

            // Check station endpoint
            let stationRequest = client.makeRequest(for: "\(baseURL)/station")
            guard stationRequest?.value(forHTTPHeaderField: headerName) == apiKey else {
                return false
            }

            // Check history endpoint
            let historyRequest = client.makeRequest(for: "\(baseURL)/history")
            guard historyRequest?.value(forHTTPHeaderField: headerName) == apiKey else {
                return false
            }

            // Check artwork endpoint with some query params
            if var components = URLComponents(string: "\(baseURL)/artwork") {
                components.queryItems = [
                    URLQueryItem(name: "artist", value: "Test"),
                    URLQueryItem(name: "title", value: "Song")
                ]
                if let artworkURL = components.url?.absoluteString {
                    let artworkRequest = client.makeRequest(for: artworkURL)
                    guard artworkRequest?.value(forHTTPHeaderField: headerName) == apiKey else {
                        return false
                    }
                }
            }

            return true
        }
    }
}
