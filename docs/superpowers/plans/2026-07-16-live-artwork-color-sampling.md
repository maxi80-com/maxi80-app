# Live Artwork Color Sampling (iOS + Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sample a dominant background color from the current song's artwork on-device on **both** iOS and Android, so the live now-playing background lights up the instant metadata changes — before the backend palette arrives via `/history`.

**Architecture:** Extract the platform-specific "image bytes → dominant color" step out of `ArtworkService` (native/Fuse module, can't call Android APIs) into a new **bridged, transpiled** `ImageColorSampler` type in `Maxi80Services`. It exposes one bridge-safe method — `dominantColorHex(from: Data) -> String?` — with platform bodies: Apple platforms use the existing `CGContext` 40×40 average; Android uses `BitmapFactory` + `Bitmap.getPixels` with the same averaging math. `ArtworkService` calls it and maps the hex to its existing color types. History-browsing colors are **unchanged** — they still come from the backend palette via `ArtworkColors.displayBackground`.

**Tech Stack:** Swift 6, Skip framework (transpiled/Lite + bridging for `Maxi80Services`; native/Fuse for `Maxi80`), Swift Testing, `android.graphics.*` (Android), CoreGraphics/UIKit/AppKit (Apple).

## Global Constraints

- Swift 6 with strict concurrency; structured concurrency over GCD; value types by default. (from CLAUDE.md / global prefs)
- **Do not use static functions as helpers — make all helpers instance members of the struct.** (global prefs)
- Platforms: iOS 17+, macOS 14+.
- Use `Logger` (OSLog), never `print()` — `print()` is invisible in Logcat.
- Per-module Skip mode is fixed: `Maxi80` = native (Fuse), `Maxi80Model` = native + bridging, `Maxi80Services` = transpiled (Lite) + bridging. Do not change any `skip.yml` mode.
- Bridged service types follow the repo idiom: `/* SKIP @bridge */` immediately above `#if !SKIP_BRIDGE`, platform bodies split into `Platform/{iOS,macOS,Android}/…` files dispatched by `#if SKIP` (Android) / `#if os(iOS) || os(tvOS)` / `#if os(macOS)`.
- Hex colors are uppercase `"#RRGGBB"`.
- Add dependencies only by editing `Package.swift` by hand (not needed in this plan — no new deps).
- In the transpiled module, avoid `String(format:)` for hex — build the string manually so it transpiles to Kotlin reliably.
- After any dependency/module/bridging-shaped change, a bogus "cannot find X" / stale-artifact error means: `rm -rf .build` then rebuild. `swift test` and `skip android build` leave `.build` in mutually incompatible states — run `rm -rf .build` when switching between them.

---

### Task 1: `ImageColorSampler` type + Apple sampling

Creates the bridged sampler struct with a transpile-safe hex formatter, plus the Apple-platform averaging body (moved verbatim from `ArtworkService`). This is the first task because the struct will not compile for the macOS `swift build`/`swift test` destination until an `averagedComponents(from:)` body exists for Apple platforms.

**Files:**
- Create: `Sources/Maxi80Services/ImageColorSampler.swift`
- Create: `Sources/Maxi80Services/Platform/Apple/ImageColorSampler+Apple.swift`
- Test: `Tests/Maxi80Tests/ImageColorSamplerTests.swift`

> Note on file placement: the repo splits platform bodies into `Platform/iOS` and `Platform/macOS`. Here the iOS and macOS averaging differs only in the decode call (`UIImage` vs `NSImage`) and shares the entire `CGContext` averaging loop, so both live in one `Platform/Apple/` file gated by `#if canImport(UIKit)` / `#elseif canImport(AppKit)` — mirroring exactly how the original `ArtworkService` was structured. This is a deliberate, DRY deviation from the per-OS-folder convention.

> Note on test placement: tests go in `Tests/Maxi80Tests` (not `Tests/Maxi80ServicesTests`). `Maxi80Tests` already does `@testable import Maxi80Services` (see `HistoryMergeTests.swift`), and the `Maxi80ServicesTests` target currently has a **pre-existing, unrelated** Robolectric/Gradle harness failure (`Unresolved reference 'swiftSourceFolder'`) that would obscure this task's results.

**Interfaces:**
- Produces:
  - `public struct ImageColorSampler` with `public init()`.
  - `public func dominantColorHex(from data: Data) -> String?` — returns uppercase `"#RRGGBB"` or `nil` if the bytes can't be decoded on this platform.
  - `func hexString(red: Double, green: Double, blue: Double) -> String` (internal) — pure, transpile-safe hex formatter for 0…1 components.
  - `func hexComponent(_ value: Double) -> String` (internal) — one clamped, zero-padded, uppercase hex byte.
  - `func averagedComponents(from data: Data) -> (red: Double, green: Double, blue: Double)?` (internal) — platform-provided; Apple body added here, Android body added in Task 2.

- [ ] **Step 1: Write the failing tests**

Create `Tests/Maxi80Tests/ImageColorSamplerTests.swift`:

```swift
import Testing
import Foundation
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ImageColorSamplerTests`
Expected: FAIL to compile — `cannot find 'ImageColorSampler' in scope`.

- [ ] **Step 3: Create the sampler struct + hex formatter**

Create `Sources/Maxi80Services/ImageColorSampler.swift`:

```swift
import Foundation

/// Extracts a single dominant (average) color from encoded artwork image bytes, as an uppercase
/// "#RRGGBB" hex string. Lives in the transpiled `Maxi80Services` module so BOTH platforms can
/// sample on-device: the live now-playing path needs a background color immediately on a metadata
/// change, before the backend palette arrives via `/history`. History-browsing colors are handled
/// separately by the backend palette (`ArtworkColors.displayBackground`) and do not use this type.
///
/// Bridged back to the native Fuse module (`ArtworkService`), which maps the hex to its own color
/// types. Returns a hex `String` (a bridge-safe primitive) rather than a model color type, to avoid
/// a cross-module type dependency across the JNI boundary.
/* SKIP @bridge */
#if !SKIP_BRIDGE
public struct ImageColorSampler {

    public init() {}

    /// Decode `data` and return its average color as "#RRGGBB", or `nil` if the bytes can't be
    /// decoded into an image on this platform.
    public func dominantColorHex(from data: Data) -> String? {
        guard let rgb = averagedComponents(from: data) else { return nil }
        return hexString(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Format 0…1 RGB components as an uppercase "#RRGGBB" string. Built manually (no
    /// `String(format:)`) so it transpiles to Kotlin unchanged.
    func hexString(red: Double, green: Double, blue: Double) -> String {
        "#" + hexComponent(red) + hexComponent(green) + hexComponent(blue)
    }

    /// One clamped, zero-padded, uppercase hex byte for a 0…1 component.
    func hexComponent(_ value: Double) -> String {
        let scaled = (value * 255).rounded()
        let clamped = Int(max(0.0, min(255.0, scaled)))
        let hex = String(clamped, radix: 16).uppercased()
        return hex.count == 1 ? "0" + hex : hex
    }
}
#endif
```

- [ ] **Step 4: Create the Apple sampling body**

Create `Sources/Maxi80Services/Platform/Apple/ImageColorSampler+Apple.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ImageColorSamplerTests`
Expected: PASS — 5 tests (3 hex + 2 decode) on macOS. Output pristine (no warnings).

> If `samplesSolidRed` fails by a rounding of ±1 (e.g. `#FE0000`) due to color-space conversion, change that assertion to parse the hex and assert `red >= 0xF0 && green <= 0x0F && blue <= 0x0F`. Do not loosen the pure-`hexString` assertions.

- [ ] **Step 6: Commit**

```bash
git add Sources/Maxi80Services/ImageColorSampler.swift Sources/Maxi80Services/Platform/Apple/ImageColorSampler+Apple.swift Tests/Maxi80Tests/ImageColorSamplerTests.swift
git commit -m "feat: add ImageColorSampler with Apple on-device sampling"
```

---

### Task 2: Android sampling body

Adds the Android `averagedComponents(from:)` using `android.graphics.*`. Verified by `skip android build` (compile + transpile), not by a unit assertion — Robolectric cannot decode real PNG bytes into pixels reliably, so the actual Android pixel path is confirmed on an emulator (noted below), while the shared `hexString` math is already covered on every platform by Task 1's tests.

**Files:**
- Create: `Sources/Maxi80Services/Platform/Android/ImageColorSampler+Android.swift`

**Interfaces:**
- Consumes: `ImageColorSampler` (Task 1).
- Produces: `func averagedComponents(from data: Data) -> (red: Double, green: Double, blue: Double)?` for the Android (`#if SKIP`) platform — same signature as the Apple body, so `dominantColorHex(from:)` resolves on Android.

- [ ] **Step 1: Create the Android sampling body**

Create `Sources/Maxi80Services/Platform/Android/ImageColorSampler+Android.swift`:

```swift
import Foundation

#if !SKIP_BRIDGE

#if SKIP
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color

// MARK: - Android sampling
//
// Decode the bytes, downscale to 40×40, read the pixels, average — mirroring the Apple path so
// the live background color matches across platforms for the same artwork.

extension ImageColorSampler {

    func averagedComponents(from data: Data) -> (red: Double, green: Double, blue: Double)? {
        // `data.platformValue` is the underlying kotlin.ByteArray (SkipFoundation).
        let bytes = data.platformValue
        guard let bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) else { return nil }

        let size = 40
        let scaled = Bitmap.createScaledBitmap(bitmap, size, size, false)

        let pixelCount = size * size
        let pixels = IntArray(pixelCount)
        scaled.getPixels(pixels, 0, size, 0, 0, size, size)

        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0

        for i in 0..<pixelCount {
            let pixel = pixels[i]
            totalR += Double(Color.red(pixel))
            totalG += Double(Color.green(pixel))
            totalB += Double(Color.blue(pixel))
        }

        return (
            red: totalR / Double(pixelCount) / 255.0,
            green: totalG / Double(pixelCount) / 255.0,
            blue: totalB / Double(pixelCount) / 255.0
        )
    }
}
#endif // SKIP

#endif // !SKIP_BRIDGE
```

- [ ] **Step 2: Verify it transpiles and compiles for Android**

Run: `skip android build`
Expected: `Build complete!` with no errors. This confirms the `android.graphics.*` calls, `data.platformValue` → `kotlin.ByteArray`, `IntArray`, and the `Color.red/green/blue` accessors all transpile.

> If `swift test` was run since Task 1, run `rm -rf .build` first — `swift test` and `skip android build` leave `.build` in incompatible states.

- [ ] **Step 3: Commit**

```bash
git add Sources/Maxi80Services/Platform/Android/ImageColorSampler+Android.swift
git commit -m "feat: add Android on-device artwork color sampling"
```

---

### Task 3: Wire `ArtworkService` to the sampler

Replaces `ArtworkService`'s Apple-only color extraction with a call to `ImageColorSampler`, so the sampled color flows into `ArtworkResult.rgb` on **every** platform (including Android, which previously returned no color). Deletes the now-moved `extractDominantColor`/`averageColor`.

**Files:**
- Modify: `Sources/Maxi80/ArtworkService.swift` (rewrite `makeResult(from:url:)`, lines 81-100; delete `extractDominantColor` + `averageColor`, lines 106-161)
- Test: `Tests/Maxi80Tests/ImageColorSamplerTests.swift` (existing) + full suite

**Interfaces:**
- Consumes: `ImageColorSampler().dominantColorHex(from: Data) -> String?` (Task 1/2), `Maxi80Model.RGBColor.parse(hex:) -> RGBColor?` (existing).
- Produces: no signature change — `makeResult` still returns `ArtworkResult`; `ArtworkResult.rgb` is now populated on Android too.

- [ ] **Step 1: Rewrite `makeResult(from:url:)`**

In `Sources/Maxi80/ArtworkService.swift`, replace the whole `makeResult(from:url:)` method (currently lines 81-100) with:

```swift
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
```

- [ ] **Step 2: Delete the moved color-extraction code**

In `Sources/Maxi80/ArtworkService.swift`, delete these now-unused members (the logic moved to `ImageColorSampler+Apple.swift`):
- The `// MARK: - Color Extraction (Apple platforms only)` section with both `extractDominantColor(from:)` overloads (the `#if canImport(UIKit)` and `#elseif canImport(AppKit)` block).
- The entire `#if canImport(CoreGraphics) … averageColor(from:) … #endif` block.

Keep `makeDefaultResult()`, `color(_:)`, `resolveArtworkURL`, `fetchArtwork`, and the top-of-file `import` block unchanged. (`import Maxi80Services` and `import Maxi80Model` are already present.)

> Scope note: `Self.color` and `Self.defaultColor` are pre-existing `static` members of `ArtworkService`. The global "no static helpers" preference applies to *new* helpers you write (the new `ImageColorSampler` helpers are instance methods, per Task 1). Do **not** refactor the existing statics here — that's unrelated churn and out of scope.

- [ ] **Step 3: Verify the whole macOS suite passes**

Run: `swift test`
Expected: All suites pass (the 68 pre-existing tests + the 5 `ImageColorSampler` tests). The only allowed failure is the **pre-existing** `Maxi80ServicesTests.XCSkipTests testSkipModule` Robolectric/Gradle-harness error (`Unresolved reference 'swiftSourceFolder'`) — confirm it is byte-for-byte the same failure as before this plan (it is unrelated to these changes). All `Maxi80Tests`, `Maxi80ModelTests` suites must be green.

- [ ] **Step 4: Verify Android still builds**

Run: `rm -rf .build && skip android build`
Expected: `Build complete!` — confirms `ArtworkService` (Fuse) calling the bridged `ImageColorSampler` (transpiled) links on Android.

- [ ] **Step 5: Commit**

```bash
git add Sources/Maxi80/ArtworkService.swift
git commit -m "refactor: sample live artwork color via ImageColorSampler on both platforms"
```

---

## Manual verification (post-implementation)

The Android pixel path can't be asserted under Robolectric, so confirm it once on an emulator:

- [ ] Launch on the Android emulator (`skip android emulator launch` then `skip app launch`, or run from Android Studio).
- [ ] Play the stream; when a song with cover art starts, confirm the now-playing background tints to a color drawn from the artwork (not the branded default `#262640`-ish fallback).
- [ ] Scroll into history, then back to the live slot — confirm history covers still tint from the backend palette and the live slot from the sampled color.

## Notes / non-goals

- **On-main-thread sampling:** `ArtworkService` is `@MainActor` and sampling runs synchronously, exactly as it did on iOS before this change. Moving sampling off the main actor is a separate optimization, out of scope here.
- **Algorithm parity, not palette parity:** Android uses the same flat 40×40 average as Apple — deliberately, so the live color matches across platforms. This is the *live* fallback; the richer, Apple-Music-derived palette still comes from the backend for history. A future option is `androidx.palette` for a vibrant swatch, which would need a Gradle dep in `Maxi80Services/Skip/skip.yml` and would diverge from the iOS average — not done here.
- **Android already downloads the bytes:** `fetchArtwork` already calls `URLSession.shared.data(from:)` unconditionally, so this adds no new network fetch — it just stops discarding the bytes on Android.
```
