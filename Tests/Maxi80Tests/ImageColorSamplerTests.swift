import Foundation
import Testing

@testable import Maxi80Services

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@Suite("ImageColorSampler — dominant color")
struct ImageColorSamplerTests {

  // MARK: - Pure hex formatting (runs on every platform, incl. Android via Robolectric)

  @Test("Formats pure primaries as uppercase #RRGGBB")
  func formatsPrimaries() {
    let sampler = ImageColorSampler()
    #expect(sampler.hexString(red: 1, green: 0, blue: 0) == "#FF0000")
    #expect(sampler.hexString(red: 0, green: 1, blue: 0) == "#00FF00")
    #expect(sampler.hexString(red: 0, green: 0, blue: 1) == "#0000FF")
  }

  @Test("Zero-pads single-digit components")
  func zeroPads() {
    let sampler = ImageColorSampler()
    // 10/255 ≈ 0.039 → rounds to 0x0A; must keep the leading zero.
    #expect(sampler.hexString(red: 10.0 / 255.0, green: 0, blue: 0) == "#0A0000")
  }

  @Test("Clamps out-of-range components")
  func clamps() {
    let sampler = ImageColorSampler()
    #expect(sampler.hexString(red: 2.0, green: -1.0, blue: 0) == "#FF0000")
  }

  // MARK: - Full decode path (Apple platforms only; Robolectric can't decode real PNGs)

  #if canImport(UIKit) || canImport(AppKit)
    @Test("Samples a solid red image to #FF0000")
    func samplesSolidRed() {
      let sampler = ImageColorSampler()
      let data = Self.solidRedPNG()
      #expect(sampler.dominantColorHex(from: data) == "#FF0000")
    }

    @Test("Returns nil for undecodable bytes")
    func nilForGarbage() {
      let sampler = ImageColorSampler()
      #expect(sampler.dominantColorHex(from: Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    @Test("CGImage entry point matches the Data path for the same image")
    func cgImagePathMatchesDataPath() {
      let sampler = ImageColorSampler()
      let data = Self.solidRedPNG()
      #if canImport(UIKit)
        let cgImage = UIImage(data: data)!.cgImage!
      #else
        let cgImage = NSImage(data: data)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
      #endif
      #expect(sampler.dominantColorHex(fromCGImage: cgImage) == "#FF0000")
      #expect(
        sampler.dominantColorHex(fromCGImage: cgImage) == sampler.dominantColorHex(from: data))
    }

    /// Renders an 8×8 solid-red PNG in-memory so the test needs no fixture file.
    static func solidRedPNG() -> Data {
      #if canImport(UIKit)
        let size = CGSize(width: 8, height: 8)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
          UIColor.red.setFill()
          ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!
      #else
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
      #endif
    }
  #endif
}
