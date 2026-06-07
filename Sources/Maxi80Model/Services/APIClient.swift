import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// SKIP @nobridge
public class APIClient: @unchecked Sendable {
    private let baseURL: String
    private let authToken: String

    public init(baseURL: String, authToken: String) {
        self.baseURL = baseURL
        self.authToken = authToken
    }

    public convenience init(configuration: APIConfiguration) {
        self.init(baseURL: configuration.baseURL, authToken: configuration.authToken)
    }

    public func fetchStation(completion: @escaping @Sendable (String?) -> Void) {
        let urlString = "\(baseURL)/station"
        performRequest(urlString: urlString, completion: completion)
    }

    public func fetchArtworkURL(artist: String, title: String, completion: @escaping @Sendable (String?) -> Void) {
        guard var components = URLComponents(string: "\(baseURL)/artwork") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "title", value: title)
        ]
        guard let urlString = components.url?.absoluteString else {
            completion(nil)
            return
        }
        performRequest(urlString: urlString, completion: completion)
    }

    public func fetchHistory(completion: @escaping @Sendable (String?) -> Void) {
        let urlString = "\(baseURL)/history"
        performRequest(urlString: urlString, completion: completion)
    }

    // MARK: - Internal (visible to tests via @testable import)

    func makeRequest(for urlString: String) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(authToken, forHTTPHeaderField: APIConfiguration.authHeaderName)
        return request
    }

    // MARK: - Private

    private func performRequest(urlString: String, completion: @escaping @Sendable (String?) -> Void) {
        guard let request = makeRequest(for: urlString) else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[APIClient] Network error: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil)
                return
            }

            switch httpResponse.statusCode {
            case 200:
                guard let data = data, let jsonString = String(data: data, encoding: .utf8) else {
                    completion(nil)
                    return
                }
                completion(jsonString)
            case 204:
                completion(nil)
            case 401, 403:
                print("[APIClient] Authentication failure: HTTP \(httpResponse.statusCode) for \(urlString)")
                completion(nil)
            default:
                print("[APIClient] Unexpected HTTP status \(httpResponse.statusCode) for \(urlString)")
                completion(nil)
            }
        }.resume()
    }
}
