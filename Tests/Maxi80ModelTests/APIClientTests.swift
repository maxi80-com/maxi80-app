import Testing
import Foundation
@testable import Maxi80Model

// MARK: - Mock URL Protocol

/// Mock URL protocol for testing APIClient without network access.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var mockResponses: [String: (Data?, HTTPURLResponse?, Error?)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        if let (data, response, error) = MockURLProtocol.mockResponses.first(where: { url.contains($0.key) })?.value {
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                if let response {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                }
                if let data {
                    client?.urlProtocol(self, didLoad: data)
                }
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - APIClient Unit Tests

@Suite("APIClient Response Handling")
struct APIClientTests {

    private let baseURL = "https://api.test.maxi80.com"
    private let apiKey = "test-api-key-123"

    private func makeClient() -> APIClient {
        APIClient(baseURL: baseURL, authToken: apiKey)
    }

    private func registerMock() {
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    private func unregisterMock() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.mockResponses = [:]
    }

    // MARK: - fetchStation

    @Test("fetchStation returns valid JSON string on HTTP 200")
    func fetchStationValidJSON() async {
        registerMock()
        defer { unregisterMock() }

        let stationJSON = """
        {"name":"Maxi 80","streamUrl":"https://audio1.maxi80.com","shortDesc":"La radio"}
        """
        let data = stationJSON.data(using: .utf8)
        let response = HTTPURLResponse(
            url: URL(string: "\(baseURL)/station")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        MockURLProtocol.mockResponses["station"] = (data, response, nil)

        let client = makeClient()
        let result: String? = await withCheckedContinuation { continuation in
            client.fetchStation { json in
                continuation.resume(returning: json)
            }
        }

        #expect(result == stationJSON)
    }

    @Test("fetchStation returns nil on HTTP 401 (authentication failure)")
    func fetchStationUnauthorized() async {
        registerMock()
        defer { unregisterMock() }

        let response = HTTPURLResponse(
            url: URL(string: "\(baseURL)/station")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )
        MockURLProtocol.mockResponses["station"] = (nil, response, nil)

        let client = makeClient()
        let result: String? = await withCheckedContinuation { continuation in
            client.fetchStation { json in
                continuation.resume(returning: json)
            }
        }

        #expect(result == nil)
    }

    @Test("fetchStation returns nil on HTTP 403 (forbidden)")
    func fetchStationForbidden() async {
        registerMock()
        defer { unregisterMock() }

        let response = HTTPURLResponse(
            url: URL(string: "\(baseURL)/station")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )
        MockURLProtocol.mockResponses["station"] = (nil, response, nil)

        let client = makeClient()
        let result: String? = await withCheckedContinuation { continuation in
            client.fetchStation { json in
                continuation.resume(returning: json)
            }
        }

        #expect(result == nil)
    }

    @Test("fetchStation returns nil on malformed/invalid response data")
    func fetchStationMalformedResponse() async {
        registerMock()
        defer { unregisterMock() }

        // Return 200 but with nil data (simulates empty body that can't be decoded as UTF-8 string)
        let response = HTTPURLResponse(
            url: URL(string: "\(baseURL)/station")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        MockURLProtocol.mockResponses["station"] = (nil, response, nil)

        let client = makeClient()
        let result: String? = await withCheckedContinuation { continuation in
            client.fetchStation { json in
                continuation.resume(returning: json)
            }
        }

        #expect(result == nil)
    }

    @Test("fetchStation returns nil on network timeout/error")
    func fetchStationNetworkError() async {
        registerMock()
        defer { unregisterMock() }

        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        MockURLProtocol.mockResponses["station"] = (nil, nil, timeoutError)

        let client = makeClient()
        let result: String? = await withCheckedContinuation { continuation in
            client.fetchStation { json in
                continuation.resume(returning: json)
            }
        }

        #expect(result == nil)
    }

    // MARK: - fetchArtworkURL

    @Test("fetchArtworkURL returns nil on HTTP 204 (no content)")
    func fetchArtworkNoContent() async {
        registerMock()
        defer { unregisterMock() }

        let response = HTTPURLResponse(
            url: URL(string: "\(baseURL)/artwork?artist=Test&title=Song")!,
            statusCode: 204,
            httpVersion: nil,
            headerFields: nil
        )
        MockURLProtocol.mockResponses["artwork"] = (nil, response, nil)

        let client = makeClient()
        let result: String? = await withCheckedContinuation { continuation in
            client.fetchArtworkURL(artist: "Test", title: "Song") { json in
                continuation.resume(returning: json)
            }
        }

        #expect(result == nil)
    }
}
