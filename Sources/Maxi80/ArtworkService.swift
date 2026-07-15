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
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else {
            return makeDefaultResult()
        }
        let rgb = extractDominantColor(from: uiImage)
        let swiftUIImage = Image(uiImage: uiImage)
        return ArtworkResult(image: swiftUIImage, dominantColor: rgb.map(Self.color) ?? Self.defaultColor, isDefault: false, url: url, rgb: rgb)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: data) else {
            return makeDefaultResult()
        }
        let rgb = extractDominantColor(from: nsImage)
        let swiftUIImage = Image(nsImage: nsImage)
        return ArtworkResult(image: swiftUIImage, dominantColor: rgb.map(Self.color) ?? Self.defaultColor, isDefault: false, url: url, rgb: rgb)
        #else
        // Android: no platform image APIs available — carry the URL so AsyncImage can load it.
        return ArtworkResult(image: nil, dominantColor: Self.defaultColor, isDefault: false, url: url)
        #endif
    }

    private static func color(_ rgb: Maxi80Model.RGBColor) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    // MARK: - Color Extraction (Apple platforms only)

    #if canImport(UIKit)
    private func extractDominantColor(from image: UIImage) -> Maxi80Model.RGBColor? {
        guard let cgImage = image.cgImage else { return nil }
        return averageColor(from: cgImage)
    }
    #elseif canImport(AppKit)
    private func extractDominantColor(from image: NSImage) -> Maxi80Model.RGBColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return averageColor(from: cgImage)
    }
    #endif

    #if canImport(CoreGraphics)
    private func averageColor(from cgImage: CGImage) -> Maxi80Model.RGBColor? {
        let size = 40
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * size
        let totalBytes = bytesPerRow * size

        var pixelData = [UInt8](repeating: 0, count: totalBytes)

        guard let context = CGContext(
            data: &pixelData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0
        let pixelCount = size * size

        for i in 0..<pixelCount {
            let offset = i * bytesPerPixel
            totalR += Double(pixelData[offset])
            totalG += Double(pixelData[offset + 1])
            totalB += Double(pixelData[offset + 2])
        }

        return Maxi80Model.RGBColor(
            red: totalR / Double(pixelCount) / 255.0,
            green: totalG / Double(pixelCount) / 255.0,
            blue: totalB / Double(pixelCount) / 255.0
        )
    }
    #endif
}
