import SwiftUI

/// State-driven Cover Flow renderer, shared by ALL platforms (design spec §2; Android since
/// 2026-08-01 — every primitive it needs exists in SkipSwiftUI's native Fuse API, with
/// `rotation3DEffect` mapping to a Compose `graphicsLayer`).
///
/// There is no ScrollView: every cover's position is a pure function of
/// `(index, anchorIndex, dragTranslation)` evaluated through `CarouselGeometry`, so the
/// selected cover is centered *by construction*. That makes the drift bug class that killed
/// the ScrollView renderers structurally impossible — an insertion left of the selection
/// shifts `index` and `anchorIndex` equally, and a rotation/resize (or a full Android activity
/// recreation — the view model survives it and re-supplies `selectedID`) simply re-evaluates
/// the math. No pin tokens, no recreation guards, no reconciliation.
struct CoverFlowStrip: View {
  let covers: [Cover]
  /// The id the strip keeps centered. The renderer FOLLOWS this value; it never owns
  /// position. It reports back only settled user gestures via `onSettled`.
  let selectedID: AnyHashable
  var coverSize: CGFloat = 260
  /// Called from exactly two places — drag release and tap-to-focus (plus arrow keys) — so
  /// settle reporting is user-driven by construction (R3): no scroll-phase heuristics exist.
  let onSettled: (AnyHashable) -> Void

  /// Live finger translation. Internal (not private) per the Skip bridge rule for `@State`
  /// on a bridged view type.
  @State var dragTranslation: CGFloat = 0

  /// Recent drag samples, oldest → newest, used to compute release velocity ourselves
  /// rather than trusting the platform's `predictedEndTranslation` (Android carries no
  /// velocity in it — that is the inertia defect this replaces). A short fixed-capacity ring:
  /// each `.onChanged` appends and drops the front past `velocitySampleCapacity`, `.onEnded`
  /// reads the ~`velocityWindow`-second tail, and release clears it.
  ///
  /// Deliberately a reference-type box, NOT observable state: the samples never drive any
  /// rendering (they are only read at release), and appending to a `@State` array here meant
  /// every pointer move invalidated the view and re-shipped the whole array across the
  /// Swift↔Kotlin bridge — measured on the A07 as per-drag-frame overhead and GC pressure.
  /// `@State` holds only the box's identity; its contents mutate invisibly to the renderer.
  /// Internal (not private) per the Skip bridge rule for `@State` on a bridged view type.
  @State var dragSamples = DragSampleRing()

  /// One timestamped finger position for velocity estimation. `Date()` ticks sub-frame on
  /// both platforms (unrelated to the workflow-script `Date.now()` restriction).
  struct DragSample {
    let translation: CGFloat
    let time: Date
  }

  /// Plain (non-observable) storage for the drag-sample ring — see `dragSamples`.
  final class DragSampleRing {
    var samples: [DragSample] = []
  }

  /// Ring-buffer depth: enough to span the velocity window at Compose's sparser `onChanged`
  /// cadence without unbounded growth on a long slow drag.
  private static let velocitySampleCapacity = 12
  /// Trailing window (seconds) over which release velocity is measured. Short enough to
  /// reflect the fingertip's final motion, long enough to survive sparse sample delivery.
  private static let velocityWindow: TimeInterval = 0.1

  /// Vertical breathing room so the cover's drop shadow is never clipped into a hard edge.
  private let verticalMargin: CGFloat = 40

  /// The single spring EVERY settle path shares — drag release, tap, arrow key, and the
  /// external cover-set change modifier below all animate on this exact curve. That shared
  /// curve is load-bearing: a cover's on-screen offset is driven by BOTH `dragTranslation`
  /// (zeroed here) and `anchorIndex` (shifted via `onSettled` → `layoutKey`). If those two
  /// drivers animated on different curves they would fight mid-settle — the "shaggy" glide.
  /// A flick still coasts far because the *target* is farther (velocity projection), not
  /// because the curve differs; a spring sweeping many slots decelerates and carries every
  /// intermediate cover through center, which is the flywheel itself.
  ///
  /// Damping differs by platform. 0.85 overshoots a few percent and swings back — a pleasant
  /// landing bounce at 60fps, but the A07 renders the settle at single-digit fps, so the
  /// overshoot+return collapses into 2–3 frames and reads as a sloppy wobble. Android runs
  /// near-critically damped instead: same glide, lands dead-on with no bump.
  #if os(Android)
    private static let settleSpring: Animation = .spring(response: 0.4, dampingFraction: 0.99)
  #else
    private static let settleSpring: Animation = .spring(response: 0.4, dampingFraction: 0.85)
  #endif

  var body: some View {
    GeometryReader { proxy in
      let geometry = CarouselGeometry(coverSize: coverSize)
      let anchor = anchorIndex
      ZStack {
        ForEach(visibleCovers(geometry: geometry, anchorIndex: anchor)) { item in
          cell(index: item.index, cover: item.cover, geometry: geometry, anchorIndex: anchor)
        }
      }
      // ZStack centers its children; offsets are measured from that center, so centering
      // the (hugging) ZStack in the container is all the width information we need.
      .frame(width: proxy.size.width, height: proxy.size.height)
      // External changes (history load, new song, back-to-live) animate: the key folds the
      // ordered ids and the anchor, and deliberately NOT `dragTranslation` — finger tracking
      // must never be animated. The very first render has no prior state, so nothing animates.
      .animation(Self.settleSpring, value: layoutKey)
      // contentShape / keyboard navigation don't exist in SkipSwiftUI; Android relies on the
      // covers themselves as the hit area (they overlap, so the strip is dense) and has no
      // hardware arrow keys to serve.
      #if !os(Android)
        .contentShape(Rectangle())
      #endif
      // tvOS has no DragGesture (and the TV UI uses TVRadioPlayerView, not this renderer);
      // the guard only keeps the tvOS leg of this multi-platform target compiling.
      #if !os(tvOS)
        .gesture(dragGesture(geometry: geometry, anchorIndex: anchor))
      #endif
      #if !os(Android)
        .focusable()
        // Keep focusability (for the arrow keys below) but suppress the system focus ring —
        // on macOS it draws an ugly blue rectangle around the whole strip. The carousel shows
        // focus through its centered cover, not a border.
        .focusEffectDisabled()
        // Bare arrows only: modified arrows must pass through untouched. The simulator's
        // rotate shortcuts (Cmd+←/→) are ALSO delivered to the app as arrow presses, so
        // matching them here moved the selection one slot on every rotation — observed as
        // "drift"/re-pin on rotation in the simulator (never on device, which has no keyboard).
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
          guard press.modifiers.isEmpty else { return .ignored }
          moveSelection(by: press.key == .leftArrow ? -1 : 1)
          return .handled
        }
      #endif
      // A rotation/resize mid-drag can cancel the gesture without `onEnded` ever firing,
      // stranding a nonzero translation the math would faithfully render as a permanent
      // off-center offset. The old width is meaningless at the new width anyway; drop it.
      .onChange(of: proxy.size.width) { _, _ in
        guard dragTranslation != 0 else { return }
        setDragTranslationUnanimated(0)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: coverSize + verticalMargin * 2)
    // The ZStack positions covers by pure math with no scroll viewport, so without an
    // explicit clip the strip's side covers paint over neighboring layout (the title/controls
    // column in landscape). The old ScrollView clipped for free; this is its replacement.
    // `verticalMargin` keeps the focused cover's drop shadow inside the clip.
    .clipped()
    #if !os(Android)
      // Not in SkipSwiftUI; SkipUI derives its own accessibility grouping.
      .accessibilityElement(children: .contain)
    #endif
  }

  /// Write the finger translation with implicit animations suppressed. `withTransaction` is
  /// unavailable in SkipSwiftUI, but on Android a plain write is already unanimated: the only
  /// implicit animation on the strip is keyed on `layoutKey`, which a drag never changes.
  private func setDragTranslationUnanimated(_ value: CGFloat) {
    #if os(Android)
      dragTranslation = value
    #else
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { dragTranslation = value }
    #endif
  }

  /// Index of the selected cover. A transient miss (selection rolled off mid-tick) anchors
  /// on the now slot — always the last cover — until the model resolves it the same way.
  var anchorIndex: Int {
    covers.firstIndex { AnyHashable($0.id) == selectedID } ?? covers.count - 1
  }

  /// Identity for the external-change animation. `Hashable` struct rather than a joined
  /// string so id contents can never collide with the separator.
  private struct LayoutKey: Hashable {
    let ids: [String]
    let anchorIndex: Int
  }

  private var layoutKey: LayoutKey {
    LayoutKey(ids: covers.map(\.id), anchorIndex: anchorIndex)
  }

  /// One instantiated cell: its array index (for geometry) plus the cover. Identity is the
  /// cover id, so cell identity is stable across left-insertions even as indices shift.
  struct VisibleCover: Identifiable {
    let index: Int
    let cover: Cover
    var id: String { cover.id }
  }

  /// Virtualization by math: the geometry solves the visible window as a contiguous
  /// index range in closed form, so a 100-entry history evaluates only the handful of
  /// cells around the anchor — never the full array — keeping the render O(windowRadius).
  func visibleCovers(geometry: CarouselGeometry, anchorIndex: Int) -> [VisibleCover] {
    let range = geometry.visibleIndexRange(
      anchorIndex: anchorIndex, dragTranslation: dragTranslation, coverCount: covers.count)
    return range.map { index in VisibleCover(index: index, cover: covers[index]) }
  }

  // MARK: - Cells

  @ViewBuilder
  private func cell(index: Int, cover: Cover, geometry: CarouselGeometry, anchorIndex: Int)
    -> some View
  {
    let relative = geometry.relativePosition(
      index: index, anchorIndex: anchorIndex, dragTranslation: dragTranslation)

    coverContent(cover)
      .frame(width: coverSize, height: coverSize)
      .clipShape(.rect(cornerRadius: 12))
      // Shadow cost differs wildly by platform. The blur is re-rendered EVERY animation frame
      // (scale/rotation invalidate it), and on the A07's low-end Mali GPU the 18px blur across
      // ~9 covers measured ~115ms/frame during the settle glide — single-digit fps, felt as
      // mid-animation freezes. Android gets a tight, cheap shadow; Apple keeps the deep one.
      #if os(Android)
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 4)
      #else
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 12)
      #endif
      .scaleEffect(geometry.scale(relative: relative))
      .rotation3DEffect(
        .degrees(geometry.rotationDegrees(relative: relative)),
        axis: (x: 0, y: 1, z: 0),
        anchor: .center,
        perspective: geometry.perspective
      )
      .offset(x: geometry.xOffset(relative: relative))
      .zIndex(geometry.zIndex(relative: relative))
      // Tap-to-focus: animates the tapped cover to center and reports it settled. On macOS
      // this (plus click-drag and arrow keys) replaces two-finger scrolling on the strip.
      .onTapGesture {
        guard index != anchorIndex else { return }
        withAnimation(Self.settleSpring) { onSettled(AnyHashable(cover.id)) }
      }
  }

  /// The cell's artwork. On iOS the now slot keeps the constant id `__now__` while its
  /// artwork swaps A→B in place, so keying the inner image on its content makes that swap a
  /// remove+insert and crossfades it. Safe here because nothing binds scroll position to
  /// inner ids anymore — the historical "no inner `.id()` in the cell subtree" landmine is
  /// gone with the ScrollView. Apple-only styling; Android's Coil-backed AsyncImage swaps
  /// in place without the transition plumbing.
  @ViewBuilder
  private func coverContent(_ cover: Cover) -> some View {
    let image = CoverImage(url: cover.artworkURL, assetName: cover.assetName)
    #if os(iOS)
      image
        .id(cover.artworkURL ?? cover.assetName ?? cover.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.4), value: cover.artworkURL)
    #else
      image
    #endif
  }

  // MARK: - Interaction

  #if !os(tvOS)
    /// Whole-strip drag. Finger tracking writes through a transaction with animations disabled
    /// so it is 1:1, never animated, while each move is timestamped into `dragSamples` for
    /// release-velocity estimation.
    ///
    /// `minimumDistance` differs by platform. On Android a nonzero distance makes SkipUI take
    /// the `awaitPointerSlopOrCancellation` branch of Compose's drag detector — `onChanged`
    /// stays silent until the finger crosses the system touch-slop (~8–16dp), so the strip
    /// visibly refuses to move at the very start of a swipe ("glued"). `0` takes the
    /// track-from-touch-down branch instead, giving immediate 1:1 response. The trade is that a
    /// 0-distance drag consumes the initial touch, which can suppress tap-to-focus on a side
    /// cover; browsing on Android is by swipe/flick. Apple platforms keep `10` so cell taps and
    /// arrow keys pass through as before.
    ///
    /// On release, `settleTarget` picks the landing slot and ONE `withAnimation(settleSpring)`
    /// block zeroes the translation and (if it differs) reports the settle — a single spring
    /// from wherever the finger left the strip, so there is no recoil.
    private func dragGesture(geometry: CarouselGeometry, anchorIndex: Int) -> some Gesture {
      #if os(Android)
        let minimumDragDistance: CGFloat = 0
      #else
        let minimumDragDistance: CGFloat = 10
      #endif
      return DragGesture(minimumDistance: minimumDragDistance)
        .onChanged { value in
          let translation = geometry.rubberBanded(
            translation: value.translation.width,
            anchorIndex: anchorIndex,
            coverCount: covers.count)
          appendDragSample(translation: translation)
          setDragTranslationUnanimated(translation)
        }
        .onEnded { value in
          // The SAME rubber-banded coordinate space as the samples and the on-screen strip:
          // within bounds `rubberBanded` is the identity, so this only matters at the ends,
          // where mixing raw with banded values would inflate the velocity estimate and
          // settle the strip somewhere the user never saw.
          let translation = geometry.rubberBanded(
            translation: value.translation.width,
            anchorIndex: anchorIndex,
            coverCount: covers.count)
          let velocity = releaseVelocity(latest: translation)
          dragSamples.samples.removeAll()
          let target = geometry.settleTarget(
            anchorIndex: anchorIndex,
            translation: translation,
            velocity: velocity,
            coverCount: covers.count)
          // ONE spring for every settle — see `settleSpring`. A far target (from a fast flick's
          // velocity projection) makes this exact spring sweep across many covers and decelerate
          // into place, which is the flywheel; a slow drag projects ~0 extra and lands one slot
          // away. Never a second curve, so the translation glide and the anchor shift stay in
          // lockstep (no "shaggy" fight between the two position drivers).
          withAnimation(Self.settleSpring) {
            dragTranslation = 0
            if target != anchorIndex, covers.indices.contains(target) {
              onSettled(AnyHashable(covers[target].id))
            }
          }
        }
    }

    /// Append a timestamped drag sample, dropping the oldest once the ring is full so the
    /// buffer stays bounded on a long slow drag. Mutates the ring box in place — no observable
    /// state changes, so finger moves never invalidate the view for sampling (see `dragSamples`).
    private func appendDragSample(translation: CGFloat) {
      dragSamples.samples.append(DragSample(translation: translation, time: Date()))
      if dragSamples.samples.count > Self.velocitySampleCapacity {
        dragSamples.samples.removeFirst(dragSamples.samples.count - Self.velocitySampleCapacity)
      }
    }

    /// Release velocity in points/sec over the most recent `velocityWindow`, computed as
    /// Δtranslation / Δt between the oldest in-window sample and now. `latest` is the final
    /// `onEnded` translation, timestamped now so the estimate reflects the fingertip's last
    /// motion even when Compose delivered no `onChanged` for it. Falls back to `0` when there
    /// are too few samples or Δt ≈ 0 (a hold-then-lift, which should not coast).
    private func releaseVelocity(latest: CGFloat) -> CGFloat {
      let now = Date()
      let recent = dragSamples.samples.filter {
        now.timeIntervalSince($0.time) <= Self.velocityWindow
      }
      guard let oldest = recent.first else { return 0 }
      let dt = now.timeIntervalSince(oldest.time)
      guard dt > 0.0001 else { return 0 }
      return (latest - oldest.translation) / CGFloat(dt)
    }
  #endif

  /// Arrow-key navigation (macOS, iPad hardware keyboards): move the selection one slot,
  /// clamped to the strip. No-op at the ends.
  private func moveSelection(by delta: Int) {
    let target = anchorIndex + delta
    guard covers.indices.contains(target) else { return }
    withAnimation(Self.settleSpring) { onSettled(AnyHashable(covers[target].id)) }
  }
}
