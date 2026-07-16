import SwiftUI
import SkipFuse
import Maxi80Model
import Maxi80Services

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "ArtworkService")

@MainActor
public final class ArtworkService {
    private let apiClient: any APIClientProtocol
    private var cache: [String: ArtworkResult] = [:]

    private static let defaultColor = Color(red: 0.15, green: 0.15, blue: 0.25)

    public init(apiClient: any APIClientProtocol) {
        self.apiClient = apiClient
    }

    // MARK: - Public API

    public func fetchArtwork(artist: String, title: String) async -> ArtworkResult {
        let cacheKey = "\(artist)|\(title)"

        if let cached = cache[cacheKey] {
            return cached
        }

        // Only real artwork is cached — never the default/miss result. A miss usually means the
        // backend collector hasn't produced the artwork yet, so it may appear on a later retry;
        // caching the miss would pin the generic cover for the whole song. See the retry loop in
        // RadioPlayerCoordinator.
        guard let urlString = await resolveArtworkURL(artist: artist, title: title),
              let artworkURL = URL(string: urlString) else {
            return makeDefaultResult()
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: artworkURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return makeDefaultResult()
            }

            let result = makeResult(from: data, url: urlString)
            if !result.isDefault {
                cache[cacheKey] = result
            }
            return result
        } catch {
            return makeDefaultResult()
        }
    }

    /// Resolves a song's presigned artwork URL from the `/artwork` endpoint.
    /// The endpoint returns `{"url": "..."}` on success, or an empty body when no artwork
    /// exists — both handled here. Returns `nil` when unavailable.
    public func resolveArtworkURL(artist: String, title: String) async -> String? {
        guard let json = try? await apiClient.fetchArtworkURL(artist: artist, title: title),
              let data = json.data(using: .utf8),
              !data.isEmpty,
              let response = try? JSONDecoder().decode(ArtworkURLResponse.self, from: data) else {
            logger.debug("no artwork for \(artist) — \(title)")
            return nil
        }
        return response.url
    }

    // MARK: - Private Helpers

    private func makeDefaultResult() -> ArtworkResult {
        ArtworkResult(image: nil, dominantColor: Self.defaultColor, isDefault: true)
    }

    private func makeResult(from data: Data, url: String) -> ArtworkResult {
        // Sample the dominant color on-device on every platform (iOS/macOS via CoreGraphics,
        // Android via android.graphics). This drives the LIVE now-slot background immediately,
        // before the backend palette arrives via /history. History entries still take their color
        // from the backend palette (ArtworkColors.displayBackground), not from here.
        let rgb = ImageColorSampler().dominantColorHex(from: data).flatMap(Maxi80Model.RGBColor.parse(hex:))
        let color = rgb.map(Self.color) ?? Self.defaultColor

        #if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else {
            return makeDefaultResult()
        }
        return ArtworkResult(image: Image(uiImage: uiImage), dominantColor: color, isDefault: false, url: url, rgb: rgb)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: data) else {
            return makeDefaultResult()
        }
        return ArtworkResult(image: Image(nsImage: nsImage), dominantColor: color, isDefault: false, url: url, rgb: rgb)
        #else
        // Android: no SwiftUI Image is built from data (the carousel loads it lazily via AsyncImage
        // by URL), but the sampled color IS now available and rides along on `rgb`.
        return ArtworkResult(image: nil, dominantColor: color, isDefault: false, url: url, rgb: rgb)
        #endif
    }

    private static func color(_ rgb: Maxi80Model.RGBColor) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

}
