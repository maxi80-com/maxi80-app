import Foundation

/// Apple Music's full artwork color palette, as stored by the backend. The client derives the
/// display/background color from these (see `displayBackground`), rather than trusting Apple's
/// muted `bg`. Decoded from the `/history` "colors" object; every value is "#RRGGBB".
public struct ArtworkColors: Sendable, Equatable, Codable {
  public let bg: RGBColor
  public let text1: RGBColor
  public let text2: RGBColor
  public let text3: RGBColor
  public let text4: RGBColor

  public init(bg: RGBColor, text1: RGBColor, text2: RGBColor, text3: RGBColor, text4: RGBColor) {
    self.bg = bg
    self.text1 = text1
    self.text2 = text2
    self.text3 = text3
    self.text4 = text4
  }

  /// A flat palette where every slot holds the same color, so `displayBackground` returns it
  /// unchanged. Used for live entries whose color is sampled locally from the artwork (Apple
  /// platforms only) — there's no real palette to store, just the one dominant color.
  public init(uniform color: RGBColor) {
    self.init(bg: color, text1: color, text2: color, text3: color, text4: color)
  }
}

extension ArtworkColors {
  /// The color to paint behind the cover. Prefers Apple's `bg`, but when `bg` is grey/dark
  /// falls back to the most saturated bright-enough text color — so the background matches the
  /// artwork instead of Apple's muted background. Pure arithmetic; safe on Android via Skip.
  public var displayBackground: RGBColor {
    let minSaturation = 0.20
    let minValue = 0.30

    func sv(_ c: RGBColor) -> (s: Double, v: Double) {
      let mx = max(c.red, c.green, c.blue)
      let mn = min(c.red, c.green, c.blue)
      let v = mx
      let s = mx == 0 ? 0 : (mx - mn) / mx
      return (s, v)
    }

    let bgSV = sv(bg)
    if bgSV.s >= minSaturation && bgSV.v >= minValue { return bg }

    let best = [text1, text2, text3, text4]
      .map { ($0, sv($0)) }
      .filter { $0.1.v >= minValue }
      .max { $0.1.s < $1.1.s }

    if let best, best.1.s > bgSV.s { return best.0 }
    return bg
  }
}
