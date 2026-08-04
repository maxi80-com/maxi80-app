import CoreGraphics
import Testing

@testable import Maxi80

/// Pins the slot/snap/fan math the state-driven renderer draws from (design spec §2/§6).
/// The geometry is a pure value type, so every visual property — including the core
/// drift-immunity invariant — is provable here without instantiating a view.
@Suite("CarouselGeometry")
struct CarouselGeometryTests {
  /// coverSize 240 + spacing −40 → slotWidth 200: round numbers keep expectations exact.
  private let geometry = CarouselGeometry(coverSize: 240)

  @Test("anchor sits at relative 0 with zero drag; neighbors at ±1")
  func anchorCenteredNeighborsAdjacent() {
    #expect(geometry.relativePosition(index: 5, anchorIndex: 5, dragTranslation: 0) == 0)
    #expect(geometry.relativePosition(index: 4, anchorIndex: 5, dragTranslation: 0) == -1)
    #expect(geometry.relativePosition(index: 6, anchorIndex: 5, dragTranslation: 0) == 1)
    #expect(geometry.xOffset(relative: 1) == geometry.slotWidth)
    #expect(geometry.xOffset(relative: 0) == 0)
  }

  @Test("positive (rightward) drag brings an OLDER, lower-index cover toward center")
  func dragSignRevealsOlderCovers() {
    // Half a slot of rightward finger travel: the older neighbor (index 4) moves from
    // relative -1 to -0.5 — approaching center — while the anchor drifts right to +0.5.
    let translation = geometry.slotWidth / 2
    let older = geometry.relativePosition(index: 4, anchorIndex: 5, dragTranslation: translation)
    let anchor = geometry.relativePosition(index: 5, anchorIndex: 5, dragTranslation: translation)
    #expect(older == -0.5)
    #expect(anchor == 0.5)
    #expect(abs(older) < 1)
  }

  @Test("left-insertion drift immunity: relative unchanged when index and anchor shift together")
  func leftInsertionLeavesRelativeUnchanged() {
    // THE core invariant: inserting a cover left of both the cover and the anchor
    // increments both indices, so relative — and therefore every visual property —
    // is untouched. This is what makes history insertions drift-free by construction.
    for (i, a) in [(3, 5), (5, 5), (7, 2), (0, 4)] {
      for drag in [CGFloat(0), 73, -120] {
        let before = geometry.relativePosition(index: i, anchorIndex: a, dragTranslation: drag)
        let after = geometry.relativePosition(
          index: i + 1, anchorIndex: a + 1, dragTranslation: drag)
        #expect(after == before, "relative drifted for index \(i), anchor \(a), drag \(drag)")
      }
    }
  }

  @Test("fan curve symmetry: scale even, rotation odd, flat at center, saturating beyond ±1")
  func fanCurveSymmetryAndClamping() {
    for r in [CGFloat(0.25), 0.5, 1.0] {
      #expect(geometry.scale(relative: r) == geometry.scale(relative: -r))
      #expect(geometry.rotationDegrees(relative: r) == -geometry.rotationDegrees(relative: -r))
    }
    #expect(geometry.rotationDegrees(relative: 0) == 0)
    #expect(geometry.scale(relative: 0) == 1)
    // Beyond one slot the curve holds at its extremes instead of over-shrinking.
    #expect(geometry.scale(relative: 3) == geometry.scale(relative: 1))
    #expect(geometry.scale(relative: 1) == geometry.minScale)
    #expect(geometry.rotationDegrees(relative: -4) == geometry.rotationDegrees(relative: -1))
    #expect(geometry.rotationDegrees(relative: 1) == -geometry.maxRotation)
    #expect(geometry.zIndex(relative: 2) == geometry.zIndex(relative: -2))
    #expect(geometry.zIndex(relative: 0) == 0)
  }

  @Test("snapTarget rounds to nearest slot")
  func snapTargetRoundsToNearest() {
    // 40% of a slot leftward: still nearest to the anchor.
    let stay = geometry.snapTarget(
      anchorIndex: 5, predictedEndTranslation: -geometry.slotWidth * 0.4, coverCount: 10)
    #expect(stay == 5)
    // 60% of a slot leftward: nearest is the newer neighbor.
    let advance = geometry.snapTarget(
      anchorIndex: 5, predictedEndTranslation: -geometry.slotWidth * 0.6, coverCount: 10)
    #expect(advance == 6)
  }

  @Test("snapTarget honors a flick's predicted end: large prediction moves multiple slots")
  func snapTargetHonorsFlick() {
    let target = geometry.snapTarget(
      anchorIndex: 5, predictedEndTranslation: geometry.slotWidth * 2.6, coverCount: 10)
    #expect(target == 2)
    #expect(abs(target - 5) >= 1)
  }

  @Test("snapTarget clamps to 0 and count-1, and guards an empty strip")
  func snapTargetClamps() {
    let low = geometry.snapTarget(
      anchorIndex: 1, predictedEndTranslation: geometry.slotWidth * 10, coverCount: 5)
    #expect(low == 0)
    let high = geometry.snapTarget(
      anchorIndex: 3, predictedEndTranslation: -geometry.slotWidth * 10, coverCount: 5)
    #expect(high == 4)
    #expect(geometry.snapTarget(anchorIndex: 0, predictedEndTranslation: 500, coverCount: 0) == 0)
  }

  @Test("projectedTranslation is non-decreasing in velocity (flat inside the dead-zone)")
  func projectionMonotonicInVelocity() {
    let translation = geometry.slotWidth * 0.3
    var previous = -CGFloat.greatestFiniteMagnitude
    for v in stride(from: -4000.0, through: 4000.0, by: 200.0) {
      let projected = geometry.projectedTranslation(translation: translation, velocity: CGFloat(v))
      // Non-decreasing overall: the velocity term only ever adds reach in the flick's
      // direction, and inside the sub-threshold dead-zone every sample collapses to the raw
      // translation (equal, not greater), so the guard is ≥ rather than >.
      #expect(projected >= previous)
      previous = projected
    }
  }

  @Test("sub-threshold speed is a deliberate drag: velocity term dropped, lands by translation")
  func projectionDeadZoneIgnoresSlowVelocity() {
    let t = geometry.slotWidth * 0.4
    // Just under the flick threshold, in both directions: projection is exactly the raw
    // translation, so a slow deliberate drag can never be nudged an extra slot by velocity.
    let justUnder = CarouselGeometry.flickVelocityThreshold - 1
    #expect(geometry.projectedTranslation(translation: t, velocity: justUnder) == t)
    #expect(geometry.projectedTranslation(translation: t, velocity: -justUnder) == t)
    // At/over the threshold the velocity term engages and carries the projection past t.
    let atThreshold = CarouselGeometry.flickVelocityThreshold
    #expect(geometry.projectedTranslation(translation: t, velocity: atThreshold) > t)
  }

  @Test("zero velocity ⇒ projection is the raw translation and snapTarget is unchanged")
  func projectionZeroVelocityMatchesRawTranslation() {
    // Regression guard: with no momentum the inertia path must land exactly where the
    // pre-inertia code did — snapTarget on the raw finger translation.
    for t in [CGFloat(0), 73, -120, geometry.slotWidth * 0.6, -geometry.slotWidth * 1.4] {
      #expect(geometry.projectedTranslation(translation: t, velocity: 0) == t)
      let inertial = geometry.snapTarget(
        anchorIndex: 5,
        predictedEndTranslation: geometry.projectedTranslation(translation: t, velocity: 0),
        coverCount: 10)
      let raw = geometry.snapTarget(anchorIndex: 5, predictedEndTranslation: t, coverCount: 10)
      #expect(inertial == raw)
    }
  }

  @Test("high velocity ⇒ far coast target, still clamped to valid indices")
  func projectionHighVelocityStaysClamped() {
    // A hard leftward (negative) flick from mid-strip: momentum carries many slots, but the
    // target can never exceed the last valid index.
    let projected = geometry.projectedTranslation(
      translation: -geometry.slotWidth * 0.5, velocity: -12_000)
    let target = geometry.snapTarget(anchorIndex: 5, predictedEndTranslation: projected, coverCount: 10)
    #expect(target > 6)  // coasted well past the immediate neighbor
    #expect(target == 9)  // clamped to count − 1
    // A hard rightward flick clamps at 0 likewise.
    let projectedRight = geometry.projectedTranslation(
      translation: geometry.slotWidth * 0.5, velocity: 12_000)
    let targetRight = geometry.snapTarget(
      anchorIndex: 5, predictedEndTranslation: projectedRight, coverCount: 10)
    #expect(targetRight == 0)
  }

  @Test("a moderate one-slot flick lands one slot away, not several (single-cover control)")
  func moderateFlickAdvancesOneSlot() {
    // A deliberate one-cover flick: dragged ~0.6 slot with a modest over-threshold speed.
    // The tamed decelerationRate must keep this to a single-slot advance — the regression was
    // that a normal flick jumped three or more, making one-at-a-time browsing impossible.
    let translation = -geometry.slotWidth * 0.6
    let velocity: CGFloat = -600  // clears the flick threshold but is not a hard fling
    let projected = geometry.projectedTranslation(translation: translation, velocity: velocity)
    let target = geometry.snapTarget(anchorIndex: 5, predictedEndTranslation: projected, coverCount: 20)
    #expect(target == 6)
  }

  @Test("settleTarget: a brief flick still advances one slot instead of staying glued")
  func settleTargetFlickFloorUnglues() {
    // A quick light flick whose finger barely moved: raw projection would round back to the
    // anchor ("glued"), but a flick must always leave the current cover by at least one slot.
    let tinyTranslation = -geometry.slotWidth * 0.1
    let flickSpeed = CarouselGeometry.flickVelocityThreshold  // just a flick, low momentum
    let leftward = geometry.settleTarget(
      anchorIndex: 5, translation: tinyTranslation, velocity: -flickSpeed, coverCount: 20)
    #expect(leftward == 6)  // leftward finger flick → one NEWER (higher) index
    let rightward = geometry.settleTarget(
      anchorIndex: 5, translation: geometry.slotWidth * 0.1, velocity: flickSpeed, coverCount: 20)
    #expect(rightward == 4)  // rightward finger flick → one OLDER (lower) index
  }

  @Test("settleTarget: a deliberate sub-threshold drag lands by translation, no floor")
  func settleTargetDeliberateDragNoFloor() {
    // Slow drag not quite reaching the next slot, below the flick threshold: it stays on the
    // current cover — the floor must NOT force a move for a deliberate positioning drag.
    let target = geometry.settleTarget(
      anchorIndex: 5, translation: -geometry.slotWidth * 0.3,
      velocity: CarouselGeometry.flickVelocityThreshold - 1, coverCount: 20)
    #expect(target == 5)
    // A slow drag that DOES carry past the slot midpoint lands one over, by translation alone.
    let moved = geometry.settleTarget(
      anchorIndex: 5, translation: -geometry.slotWidth * 0.7, velocity: 0, coverCount: 20)
    #expect(moved == 6)
  }

  @Test("settleTarget: a fast flick clears the floor and coasts several slots")
  func settleTargetFastFlickCoastsPastFloor() {
    // A hard flick moves well past the one-slot floor via momentum; the floor is a minimum,
    // never a cap.
    let target = geometry.settleTarget(
      anchorIndex: 5, translation: -geometry.slotWidth * 0.4, velocity: -6000, coverCount: 40)
    #expect(target > 6)
  }

  @Test("a hard flick from the last cover lands on a valid pinned slot")
  func hardFlickFromLastCoverLandsPinned() {
    let count = 10
    let last = count - 1
    // Rightward flick from the newest cover: momentum wants to overshoot toward negative
    // indices, but the landing must be a real index and, being an integer, is pinned.
    let projected = geometry.projectedTranslation(
      translation: geometry.slotWidth * 0.5, velocity: 20_000)
    let target = geometry.snapTarget(
      anchorIndex: last, predictedEndTranslation: projected, coverCount: count)
    #expect(target >= 0)
    #expect(target <= last)
    #expect(target == 0)  // clamped to the far end
    // Leftward flick from the last cover can go nowhere — already at the end.
    let projectedPastEnd = geometry.projectedTranslation(
      translation: -geometry.slotWidth * 0.5, velocity: -20_000)
    let stuck = geometry.snapTarget(
      anchorIndex: last, predictedEndTranslation: projectedPastEnd, coverCount: count)
    #expect(stuck == last)
  }

  @Test("rubberBanded is identity within bounds")
  func rubberBandIdentityWithinBounds() {
    // Anchor 2 of 6 covers: up to 2 slots rightward and 3 slots leftward are in bounds.
    for t in [CGFloat(0), 150, -250, geometry.slotWidth * 2, -geometry.slotWidth * 3] {
      #expect(geometry.rubberBanded(translation: t, anchorIndex: 2, coverCount: 6) == t)
    }
  }

  @Test("rubberBanded reduces overshoot magnitude beyond both ends")
  func rubberBandReducesOvershoot() {
    let maxRight = geometry.slotWidth * 2  // anchor 2 → index 0
    let overRight = geometry.rubberBanded(
      translation: maxRight + 100, anchorIndex: 2, coverCount: 6)
    #expect(overRight > maxRight)
    #expect(overRight < maxRight + 100)

    let maxLeft = -geometry.slotWidth * 3  // anchor 2 → index 5
    let overLeft = geometry.rubberBanded(translation: maxLeft - 100, anchorIndex: 2, coverCount: 6)
    #expect(overLeft < maxLeft)
    #expect(overLeft > maxLeft - 100)
  }

  @Test("rubberBanded is continuous at the boundary and monotonic in translation")
  func rubberBandContinuousAndMonotonic() {
    let edge = geometry.slotWidth * 2
    let atEdge = geometry.rubberBanded(translation: edge, anchorIndex: 2, coverCount: 6)
    let justPast = geometry.rubberBanded(translation: edge + 0.5, anchorIndex: 2, coverCount: 6)
    #expect(abs(justPast - atEdge) < 1)

    // Sample a wide sweep crossing both boundaries: output must never decrease.
    var previous = -CGFloat.greatestFiniteMagnitude
    for step in stride(from: -1200.0, through: 1200.0, by: 25.0) {
      let value = geometry.rubberBanded(
        translation: CGFloat(step), anchorIndex: 2, coverCount: 6)
      #expect(value > previous)
      previous = value
    }
  }

  @Test("isVisible window spans anchor±radius (plus one slot of slack) and excludes far indices")
  func visibleWindow() {
    let radius = geometry.windowRadius
    let count = 100
    func visible(_ index: Int) -> Bool {
      geometry.isVisible(index: index, anchorIndex: 10, dragTranslation: 0, coverCount: count)
    }
    #expect(visible(10))
    #expect(visible(10 + radius))
    #expect(visible(10 - radius))
    // One slot of slack avoids pop-in while a drag carries a cover across the edge.
    #expect(visible(10 + radius + 1))
    #expect(!visible(10 + radius + 2))
    #expect(!visible(10 - radius - 2))
  }

  @Test("visibleIndexRange returns exactly the indices isVisible would accept, clamped")
  func visibleIndexRangeMatchesIsVisible() {
    // The closed-form range must agree with a brute-force isVisible scan for every
    // (anchor, drag) combination — this is what lets the renderer skip the full array.
    let count = 100
    for anchor in [0, 1, 50, 98, 99] {
      for drag in [CGFloat(0), 73, -73, geometry.slotWidth * 2, -geometry.slotWidth * 2] {
        let expected = (0..<count).filter { index in
          geometry.isVisible(
            index: index, anchorIndex: anchor, dragTranslation: drag, coverCount: count)
        }
        let range = geometry.visibleIndexRange(
          anchorIndex: anchor, dragTranslation: drag, coverCount: count)
        #expect(Array(range) == expected, "mismatch for anchor \(anchor), drag \(drag)")
      }
    }
  }

  @Test("alive window is invariant across a drag release (no cell churn on the settle frame)")
  func visibleIndexRangeStableAcrossRelease() {
    // Releasing a drag jumps the state pair from (anchor, translation) to (snapTarget, 0).
    // The alive set must be IDENTICAL at that instant, otherwise the renderer instantiates a
    // fresh cell (AsyncImage + shadow) on the first settle frame — the measured ~160ms A07
    // freeze felt as a mid-move hesitation.
    let count = 60
    for anchor in [0, 5, 30, 58, 59] {
      for fraction in stride(from: -2.5, through: 2.5, by: 0.25) {
        let drag = geometry.slotWidth * CGFloat(fraction)
        let during = geometry.visibleIndexRange(
          anchorIndex: anchor, dragTranslation: drag, coverCount: count)
        let landed = geometry.snapTarget(
          anchorIndex: anchor, predictedEndTranslation: drag, coverCount: count)
        let after = geometry.visibleIndexRange(
          anchorIndex: landed, dragTranslation: 0, coverCount: count)
        #expect(during == after, "churn for anchor \(anchor), drag fraction \(fraction)")
      }
    }
  }

  @Test("visibleIndexRange evaluates O(windowRadius) indices, not the whole history")
  func visibleIndexRangeIsBounded() {
    let range = geometry.visibleIndexRange(anchorIndex: 5000, dragTranslation: 0, coverCount: 10_000)
    #expect(range.count <= 2 * (geometry.windowRadius + 1) + 1)
  }

  @Test("visibleIndexRange is empty for an empty strip")
  func visibleIndexRangeEmptyStrip() {
    #expect(geometry.visibleIndexRange(anchorIndex: 0, dragTranslation: 0, coverCount: 0).isEmpty)
  }
}
