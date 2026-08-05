// Tests/Maxi80Tests/Fakes/StubAPIClient.swift
@testable import Maxi80Model

/// A backend that always returns no content. Coordinator tests that don't exercise the network
/// use this so `loadStation()` / `fetchHistory()` are inert.
actor StubAPIClient: APIClientProtocol {
  func fetchStation() async throws(APIClientError) -> String { throw .noContent }
  func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
    throw .noContent
  }
  func fetchHistory() async throws(APIClientError) -> String { throw .noContent }
}
