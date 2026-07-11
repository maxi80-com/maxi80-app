import SwiftUI
import Maxi80Model
import Maxi80Services

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

        let artworkURLString = try? await apiClient.fetchArtworkURL(artist: artist, title: title)

        guard let urlString = artworkURLString,
              let artworkURL = URL(string: urlString) else {
            let defaultResult = makeDefaultResult()
            cache[cacheKey] = defaultResult
            return defaultResult
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: artworkURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let defaultResult = makeDefaultResult()
                cache[cacheKey] = defaultResult
                return defaultResult
            }

            let result = makeResult(from: data)
            cache[cacheKey] = result
            return result
        } catch {
            let defaultResult = makeDefaultResult()
            cache[cacheKey] = defaultResult
            return defaultResult
        }
    }

    // MARK: - Private Helpers

    private func makeDefaultResult() -> ArtworkResult {
        ArtworkResult(image: nil, dominantColor: Self.defaultColor, isDefault: true)
    }

    private func makeResult(from data: Data) -> ArtworkResult {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else {
            return makeDefaultResult()
        }
        let color = extractDominantColor(from: uiImage)
        let swiftUIImage = Image(uiImage: uiImage)
        return ArtworkResult(image: swiftUIImage, dominantColor: color, isDefault: false)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: data) else {
            return makeDefaultResult()
        }
        let color = extractDominantColor(from: nsImage)
        let swiftUIImage = Image(nsImage: nsImage)
        return ArtworkResult(image: swiftUIImage, dominantColor: color, isDefault: false)
        #else
        // Android: no platform image APIs available — return default color with no image
        return ArtworkResult(image: nil, dominantColor: Self.defaultColor, isDefault: false)
        #endif
    }

    // MARK: - Color Extraction (Apple platforms only)

    #if canImport(UIKit)
    private func extractDominantColor(from image: UIImage) -> Color {
        guard let cgImage = image.cgImage else {
            return Self.defaultColor
        }
        return averageColor(from: cgImage)
    }
    #elseif canImport(AppKit)
    private func extractDominantColor(from image: NSImage) -> Color {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Self.defaultColor
        }
        return averageColor(from: cgImage)
    }
    #endif

    #if canImport(CoreGraphics)
    private func averageColor(from cgImage: CGImage) -> Color {
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
            return Self.defaultColor
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

        let avgR = totalR / Double(pixelCount) / 255.0
        let avgG = totalG / Double(pixelCount) / 255.0
        let avgB = totalB / Double(pixelCount) / 255.0

        return Color(red: avgR, green: avgG, blue: avgB)
    }
    #endif
}
