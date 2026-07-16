import Foundation

#if !SKIP_BRIDGE

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(CoreGraphics)
import CoreGraphics

// MARK: - Apple sampling (iOS / tvOS / macOS)
//
// Moved verbatim from ArtworkService: downscale to 40×40 into an RGBA buffer, then average.

extension ImageColorSampler {

    func averagedComponents(from data: Data) -> (red: Double, green: Double, blue: Double)? {
        #if canImport(UIKit)
        guard let cgImage = UIImage(data: data)?.cgImage else { return nil }
        #elseif canImport(AppKit)
        guard let cgImage = NSImage(data: data)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        return nil
        #endif

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

        return (
            red: totalR / Double(pixelCount) / 255.0,
            green: totalG / Double(pixelCount) / 255.0,
            blue: totalB / Double(pixelCount) / 255.0
        )
    }
}
#endif // canImport(CoreGraphics)

#endif // !SKIP_BRIDGE
