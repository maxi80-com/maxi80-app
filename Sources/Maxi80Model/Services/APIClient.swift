import Foundation
import SkipFuse

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "APIClient")

public enum APIClientError: Error {
  case invalidURL
  case invalidResponse
  case noContent
  case unauthorized(statusCode: Int)
  case unexpectedStatus(statusCode: Int)
  case undecodableBody
}

/// Abstraction over the radio backend, allowing fakes to be injected in tests.
// SKIP @nobridge
public protocol APIClientProtocol: Sendable {
  func fetchStation() async throws(APIClientError) -> String
  func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String
  func fetchHistory() async throws(APIClientError) -> String
}

// SKIP @nobridge
public final class APIClient: APIClientProtocol {
  private let baseURL: String
  private let authToken: String

  public init(baseURL: String, authToken: String) {
    self.baseURL = baseURL
    self.authToken = authToken
  }

  public convenience init(configuration: APIConfiguration) {
    self.init(baseURL: configuration.baseURL, authToken: configuration.authToken)
  }

  public func fetchStation() async throws(APIClientError) -> String {
    try await performRequest(urlString: "\(baseURL)/station")
  }

  public func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String
  {
    guard var components = URLComponents(string: "\(baseURL)/artwork") else {
      throw .invalidURL
    }
    components.queryItems = [
      URLQueryItem(name: "artist", value: artist),
      URLQueryItem(name: "title", value: title),
    ]
    guard let urlString = components.url?.absoluteString else {
      throw .invalidURL
    }
    return try await performRequest(urlString: urlString)
  }

  public func fetchHistory() async throws(APIClientError) -> String {
    try await performRequest(urlString: "\(baseURL)/history")
  }

  // MARK: - Internal (visible to tests via @testable import)

  func makeRequest(for urlString: String) -> URLRequest? {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.setValue(authToken, forHTTPHeaderField: APIConfiguration.authHeaderName)
    return request
  }

  // MARK: - Private

  private func performRequest(urlString: String) async throws(APIClientError) -> String {
    guard let request = makeRequest(for: urlString) else {
      throw .invalidURL
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      logger.error("Network error: \(error.localizedDescription)")
      throw .invalidResponse
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw .invalidResponse
    }

    switch httpResponse.statusCode {
    case 200:
      guard let jsonString = String(data: data, encoding: .utf8) else {
        throw .undecodableBody
      }
      return jsonString
    case 204:
      throw .noContent
    case 401, 403:
      logger.error("Authentication failure: HTTP \(httpResponse.statusCode) for \(urlString)")
      throw .unauthorized(statusCode: httpResponse.statusCode)
    default:
      logger.error("Unexpected HTTP status \(httpResponse.statusCode) for \(urlString)")
      throw .unexpectedStatus(statusCode: httpResponse.statusCode)
    }
  }
}
