import Foundation

// CGFloat lives in CoreGraphics on Apple platforms but in Foundation on the Android Swift
// SDK, where CoreGraphics does not exist.
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

/// Pure slot/snap/fan math for the state-driven Cover Flow renderer.
///
/// Lives outside SwiftUI so every number the renderer draws — offsets, scales, tilts,
/// snap targets, rubber-band resistance — is deterministic and unit-testable. The
/// renderer contributes no geometry of its own; it only evaluates these functions
/// against `(index, anchorIndex, dragTranslation)`, which is what makes insertion and
/// rotation drift structurally impossible (see CarouselGeometryTests for the
/// left-insertion invariance proof).
public struct CarouselGeometry: Sendable, Equatable {
  /// Rendered edge length of a cover cell.
  public var coverSize: CGFloat
  /// Negative spacing makes adjacent covers overlap, matching the legacy renderer's
  /// dense fan look; `slotWidth` is the effective per-index stride.
  public var spacing: CGFloat
  /// Peak Y-axis tilt (degrees) reached at |relative| == 1 and held beyond it.
  public var maxRotation: Double
  /// Scale floor reached at |relative| == 1 and held beyond it.
  public var minScale: CGFloat
  /// Perspective divisor for the renderer's rotation3DEffect (smaller = more dramatic).
  public var perspective: Double
  /// Covers within this many slots of the anchor are instantiated; the rest are
  /// occluded/off-screen so rendering stays O(windowRadius), not O(history).
  public var windowRadius: Int

  public init(
    coverSize: CGFloat,
    spacing: CGFloat = -40,
    maxRotation: Double = 55,
    minScale: CGFloat = 0.72,
    perspective: Double = 0.6,
    windowRadius: Int = 4
  ) {
    self.coverSize = coverSize
    self.spacing = spacing
    self.maxRotation = maxRotation
    self.minScale = minScale
    self.perspective = perspective
    self.windowRadius = windowRadius
  }

  /// Horizontal stride between adjacent slot centers.
  public var slotWidth: CGFloat { coverSize + spacing }

  /// Signed slot distance of `index` from the effective (drag-shifted) anchor.
  /// 0 means dead center. A rightward finger drag (positive translation) carries the
  /// whole strip right — every cover's offset grows by the translation — so the
  /// effective anchor decreases and older (lower-index) covers approach 0:
  /// effectiveAnchor = anchorIndex − translation/slotWidth,
  /// relative = index − effectiveAnchor = (index − anchorIndex) + translation/slotWidth.
  public func relativePosition(
    index: Int, anchorIndex: Int, dragTranslation: CGFloat
  ) -> CGFloat {
    CGFloat(index - anchorIndex) + dragTranslation / slotWidth
  }

  /// X offset from the container center for a cover at `relative`.
  public func xOffset(relative: CGFloat) -> CGFloat {
    relative * slotWidth
  }

  /// Scale falls linearly from 1 at center to `minScale` at |relative| == 1, then
  /// holds — side covers form a uniform wall rather than shrinking to nothing.
  public func scale(relative: CGFloat) -> CGFloat {
    1 - (1 - minScale) * abs(clampedUnit(relative))
  }

  /// Y-axis tilt in degrees. Negative sign so covers left of center (relative < 0)
  /// rotate their right edge toward the viewer and vice versa — the classic fan.
  public func rotationDegrees(relative: CGFloat) -> Double {
    -Double(clampedUnit(relative)) * maxRotation
  }

  /// Center cover wins overlap; depth falls off symmetrically on both sides.
  public func zIndex(relative: CGFloat) -> Double {
    -abs(Double(relative))
  }

  /// Whether a cover at `relative` should be instantiated. One slot of slack beyond
  /// `windowRadius` keeps covers alive as a drag carries them across the boundary,
  /// avoiding pop-in at the window edge.
  public func isVisible(relative: CGFloat) -> Bool {
    abs(relative) <= CGFloat(windowRadius + 1)
  }

  /// Index the strip should spring to when the finger lifts: the nearest slot to the
  /// effective anchor at the *predicted* end translation, so a flick coasts past the
  /// adjacent cover. Clamped to valid indices; an empty strip pins to 0.
  public func snapTarget(
    anchorIndex: Int, predictedEndTranslation: CGFloat, coverCount: Int
  ) -> Int {
    guard coverCount > 0 else { return 0 }
    let effectiveAnchor = CGFloat(anchorIndex) - predictedEndTranslation / slotWidth
    let nearest = Int((effectiveAnchor).rounded())
    return min(max(nearest, 0), coverCount - 1)
  }

  /// Fraction of the overshoot that survives rubber-banding. Linear resistance keeps
  /// the response continuous and monotonic through the boundary (no discontinuity the
  /// instant the drag crosses the edge) while clearly signalling "no more covers".
  private static let rubberBandResistance: CGFloat = 0.4

  /// Applies edge resistance to a raw drag translation. Within bounds the translation
  /// passes through unchanged; the portion that would carry the effective anchor past
  /// index 0 or `coverCount - 1` is scaled by `rubberBandResistance`. Piecewise-linear,
  /// continuous at the boundary, and monotonic in `translation`.
  public func rubberBanded(
    translation: CGFloat, anchorIndex: Int, coverCount: Int
  ) -> CGFloat {
    guard coverCount > 0 else { return translation * Self.rubberBandResistance }
    // Translation that drags the effective anchor exactly to the last index (leftward
    // finger motion, negative translation) or to index 0 (rightward, positive).
    let maxPositive = CGFloat(anchorIndex) * slotWidth
    let maxNegative = -CGFloat(coverCount - 1 - anchorIndex) * slotWidth
    if translation > maxPositive {
      return maxPositive + (translation - maxPositive) * Self.rubberBandResistance
    }
    if translation < maxNegative {
      return maxNegative + (translation - maxNegative) * Self.rubberBandResistance
    }
    return translation
  }

  /// Clamp to [-1, 1]: the fan curve saturates one slot out so every off-center cover
  /// beyond the immediate neighbors shares the same scale and tilt.
  private func clampedUnit(_ relative: CGFloat) -> CGFloat {
    min(max(relative, -1), 1)
  }
}
