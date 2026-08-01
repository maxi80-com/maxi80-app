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

  @Test("isVisible window spans anchor±radius (plus drag slack) and excludes far indices")
  func visibleWindow() {
    let radius = CGFloat(geometry.windowRadius)
    #expect(geometry.isVisible(relative: 0))
    #expect(geometry.isVisible(relative: radius))
    #expect(geometry.isVisible(relative: -radius))
    // One slot of slack avoids pop-in while a drag carries a cover across the edge.
    #expect(geometry.isVisible(relative: radius + 1))
    #expect(!geometry.isVisible(relative: radius + 1.5))
    #expect(!geometry.isVisible(relative: -(radius + 2)))
  }
}
