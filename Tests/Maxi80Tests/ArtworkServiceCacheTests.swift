import Testing

@testable import Maxi80
@testable import Maxi80Model

/// Tests that ArtworkService does not cache "no artwork" results, so the background retry can
/// catch up once the backend collector produces the artwork.
@Suite("ArtworkService Cache Tests")
struct ArtworkServiceCacheTests {

  /// Fake API client that records how many times artwork was requested and can be told whether
  /// artwork currently exists.
  actor CountingAPIClient: APIClientProtocol {
    private(set) var artworkCallCount = 0

    func fetchStation() async throws(APIClientError) -> String { throw .noContent }
    func fetchHistory() async throws(APIClientError) -> String { throw .noContent }

    func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
      artworkCallCount += 1
      // Always a miss — models the window before the backend has produced artwork.
      throw .noContent
    }

    func callCount() -> Int { artworkCallCount }
  }

  @Test("A missing-artwork result is NOT cached, so a later fetch re-queries the backend")
  @MainActor
  func missIsNotCached() async {
    let api = CountingAPIClient()
    let service = ArtworkService(apiClient: api)

    let first = await service.fetchArtwork(artist: "New", title: "Song")
    #expect(first.isDefault)

    // A second fetch for the same song must hit the API again (no cached miss short-circuit) —
    // this is what lets the retry loop pick up artwork once it appears.
    let second = await service.fetchArtwork(artist: "New", title: "Song")
    #expect(second.isDefault)

    let count = await api.callCount()
    #expect(count == 2, "Expected the miss to re-query, got \(count) API calls")
  }
}
