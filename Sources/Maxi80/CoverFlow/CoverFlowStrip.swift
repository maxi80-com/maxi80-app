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

  /// Vertical breathing room so the cover's drop shadow is never clipped into a hard edge.
  private let verticalMargin: CGFloat = 40

  /// The single spring every settle path shares, so a drag release, a tap, an arrow key,
  /// and an external cover-set change all land with the same feel.
  private static let settleSpring: Animation = .spring(response: 0.35, dampingFraction: 0.86)

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
      .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 12)
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
    /// Whole-strip drag. `minimumDistance: 10` lets cell taps pass through. Finger tracking
    /// writes through a transaction with animations disabled so it is 1:1, never animated.
    /// On release, ONE `withAnimation` block zeroes the translation and (if the snap target
    /// differs) reports the settle — a single spring from wherever the finger left the
    /// strip, so there is no recoil (R2).
    private func dragGesture(geometry: CarouselGeometry, anchorIndex: Int) -> some Gesture {
      DragGesture(minimumDistance: 10)
        .onChanged { value in
          setDragTranslationUnanimated(
            geometry.rubberBanded(
              translation: value.translation.width,
              anchorIndex: anchorIndex,
              coverCount: covers.count))
        }
        .onEnded { value in
          let target = geometry.snapTarget(
            anchorIndex: anchorIndex,
            predictedEndTranslation: value.predictedEndTranslation.width,
            coverCount: covers.count)
          withAnimation(Self.settleSpring) {
            dragTranslation = 0
            if target != anchorIndex, covers.indices.contains(target) {
              onSettled(AnyHashable(covers[target].id))
            }
          }
        }
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
