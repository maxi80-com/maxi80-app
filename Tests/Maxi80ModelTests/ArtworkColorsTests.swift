import Testing
import Foundation
@testable import Maxi80Model

/// Locks the client-side background-color selection (`ArtworkColors.displayBackground`), which
/// replaces the backend's single derived `color`. The heuristic: keep Apple's `bg` when it's vivid
/// and bright enough, otherwise fall back to the most saturated bright-enough text color.
@Suite("ArtworkColors — display background selection")
struct ArtworkColorsTests {

    private func colors(bg: String, _ t1: String, _ t2: String, _ t3: String, _ t4: String) -> ArtworkColors {
        ArtworkColors(
            bg: RGBColor.parse(hex: bg)!,
            text1: RGBColor.parse(hex: t1)!,
            text2: RGBColor.parse(hex: t2)!,
            text3: RGBColor.parse(hex: t3)!,
            text4: RGBColor.parse(hex: t4)!
        )
    }

    @Test("Vivid, bright bg is kept")
    func vividBackgroundKept() {
        let palette = colors(bg: "#8A5A2B", "#FFFFFF", "#EEEEEE", "#DDDDDD", "#CCCCCC")
        #expect(palette.displayBackground.hexString == "#8A5A2B")
    }

    @Test("Grey/dark bg falls back to the most saturated bright text color")
    func greyBackgroundFallsBackToVividText() {
        // Real Jeanne Mas – "L'enfant" values: bg is dark grey-green; #E6B996 is the most
        // saturated bright text (sat ≈ 0.348).
        let palette = colors(bg: "#1C2520", "#E6B996", "#DDB5B1", "#BE9C7E", "#B69894")
        #expect(palette.displayBackground.hexString == "#E6B996")
    }

    @Test("Grey bg with only dark text colors keeps bg")
    func greyBackgroundWithDarkTextsKeepsBg() {
        let palette = colors(bg: "#303030", "#101010", "#0A0A0A", "#050505", "#000000")
        #expect(palette.displayBackground.hexString == "#303030")
    }
}
