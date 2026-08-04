import Foundation

// CGFloat lives in CoreGraphics on Apple platforms but in Foundation on the Android Swift
// SDK, where CoreGraphics does not exist.
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

/// Pure slot/snap/fan math for the state-driven Cover Flow renderer.
///
/// Every number the renderer draws — offsets, scales, tilts, snap targets, rubber-band
/// resistance, inertial flick reach — is a deterministic, unit-testable function here rather
/// than SwiftUI state. The renderer contributes no geometry of its own; it only evaluates
/// these functions against `(index, anchorIndex, dragTranslation)`, which is what makes
/// insertion and rotation drift structurally impossible (see CarouselGeometryTests for the
/// left-insertion invariance proof). This type stays free of SwiftUI so it transpiles cleanly
/// on Android; the renderer applies a single settle spring to whatever target `snapTarget`
/// returns.
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

  /// Whether the cover at `index` should be instantiated. One slot of slack beyond
  /// `windowRadius` keeps covers alive as a drag carries them across the boundary,
  /// avoiding pop-in at the window edge. Defined on the same rounded-and-clamped-center
  /// rule as `visibleIndexRange` so the two can never disagree.
  public func isVisible(
    index: Int, anchorIndex: Int, dragTranslation: CGFloat, coverCount: Int
  ) -> Bool {
    let center = windowCenter(
      anchorIndex: anchorIndex, dragTranslation: dragTranslation, coverCount: coverCount)
    return abs(index - center) <= windowRadius + 1
  }

  /// The contiguous index range of instantiated covers, solved in closed form so the
  /// renderer stays O(windowRadius) regardless of history length. Clamped to
  /// `0..<coverCount`; empty when the strip has no covers.
  ///
  /// The window is centered on the NEAREST slot to the effective anchor — not the raw
  /// fractional anchor. Rounding makes the alive set invariant across a drag release:
  /// the state pair jumps from `(anchorIndex, translation)` to `(snapTarget, 0)`, and
  /// `snapTarget` IS the rounded effective anchor, so the center (and therefore the whole
  /// set) is unchanged at that instant. Without this, releasing a drag re-centered the
  /// window and instantiated a fresh off-screen cell (AsyncImage + shadow + strip re-diff)
  /// on the first settle frame — measured as a ~160ms UI-thread freeze on the A07, felt as
  /// a mid-move hesitation. With the rounded center, cell churn happens one cover at a
  /// time mid-drag as the center crosses half-slot lines, where finger tracking masks it.
  public func visibleIndexRange(
    anchorIndex: Int, dragTranslation: CGFloat, coverCount: Int
  ) -> Range<Int> {
    guard coverCount > 0 else { return 0..<0 }
    let center = windowCenter(
      anchorIndex: anchorIndex, dragTranslation: dragTranslation, coverCount: coverCount)
    let bound = windowRadius + 1
    let low = max(0, center - bound)
    let high = min(coverCount - 1, center + bound)
    guard low <= high else { return 0..<0 }
    return low..<(high + 1)
  }

  /// Nearest valid slot index to the effective (drag-shifted) anchor — the alive window's
  /// center. Matches `snapTarget` exactly (round then clamp): the clamp matters at the
  /// strip's ends, where a rubber-banded overshoot rounds past the edge but the release
  /// lands on the edge cover — the window must be centered where the strip will LAND.
  private func windowCenter(
    anchorIndex: Int, dragTranslation: CGFloat, coverCount: Int
  ) -> Int {
    let nearest = Int((CGFloat(anchorIndex) - dragTranslation / slotWidth).rounded())
    return min(max(nearest, 0), coverCount - 1)
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

  /// Seconds-equivalent factor turning release velocity (points/sec) into coast distance
  /// (points): a faster flick throws proportionally farther. Deliberately small so a normal
  /// flick advances a slot or two, not a fistful — over-projection was what made single-cover
  /// browsing impossible on the A07. Named tunable; feel-driven, expect an on-device pass.
  public static let decelerationRate: CGFloat = 0.13

  /// Release speed (points/sec) that separates a deliberate positioning drag from a flick.
  /// Below it the velocity term is dropped and the strip lands purely by finger translation
  /// (precise one-cover control, immune to the A07's noisy sparse `onChanged` velocity
  /// samples); at/above it the flick floor and momentum engage. Low enough that a brief light
  /// flick still registers as a flick rather than staying "glued" to the current cover, high
  /// enough that a slow intentional drag never trips it.
  public static let flickVelocityThreshold: CGFloat = 220

  /// Where the strip would come to rest if its release velocity decelerated to zero: the raw
  /// finger translation plus a velocity-scaled throw, but only once speed clears
  /// `flickVelocityThreshold`. Fed to `snapTarget` in place of the platform's
  /// `predictedEndTranslation` — Android's prediction carries no velocity, so a self-computed
  /// projection is what gives every platform the same reach. Below the threshold it returns
  /// exactly `translation` (deliberate drag → land where the finger left off); above it,
  /// monotonic in `velocity`.
  public func projectedTranslation(translation: CGFloat, velocity: CGFloat) -> CGFloat {
    guard abs(velocity) >= Self.flickVelocityThreshold else { return translation }
    return translation + velocity * Self.decelerationRate
  }

  /// The slot the strip settles on when the finger lifts, given the finger `translation` and
  /// self-computed release `velocity`. This is the single entry point the renderer calls; it
  /// composes the three feel rules:
  ///
  /// 1. **Deliberate drag** (speed below `flickVelocityThreshold`): lands purely by
  ///    translation — a slow drag to the edge of a cover moves one slot, and a barely-there
  ///    nudge stays put. This is the "slight resistance to get started": you have to either
  ///    drag far enough or flick hard enough to leave the current cover.
  /// 2. **Flick floor** (speed at/above the threshold): a flick ALWAYS advances at least one
  ///    slot in its direction, even a brief one whose projected translation would otherwise
  ///    round back to the current cover (the "glued" feel). Once you clear the resistance, the
  ///    swipe registers.
  /// 3. **Momentum** (fast flick): `decelerationRate` carries the projection several slots, so
  ///    a hard flick moves many covers. The floor and the momentum share the same threshold,
  ///    so a flick's minimum is one slot and it grows smoothly from there.
  ///
  /// Always a valid, clamped index (a spring to an integer slot keeps the pinned-landing
  /// guarantee); an empty strip pins to 0.
  public func settleTarget(
    anchorIndex: Int, translation: CGFloat, velocity: CGFloat, coverCount: Int
  ) -> Int {
    guard coverCount > 0 else { return 0 }
    let projected = projectedTranslation(translation: translation, velocity: velocity)
    let snapped = snapTarget(
      anchorIndex: anchorIndex, predictedEndTranslation: projected, coverCount: coverCount)
    guard abs(velocity) >= Self.flickVelocityThreshold else { return snapped }
    // Flick floor: a rightward finger flick (positive translation) reveals OLDER, lower-index
    // covers, so it must land at least one index BELOW the anchor; a leftward flick at least
    // one above. `snapTarget` already clamps, so re-clamp the floored index the same way.
    let direction = translation >= 0 ? -1 : 1
    let floored = anchorIndex + direction
    let clampedFloor = min(max(floored, 0), coverCount - 1)
    return direction < 0 ? min(snapped, clampedFloor) : max(snapped, clampedFloor)
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
