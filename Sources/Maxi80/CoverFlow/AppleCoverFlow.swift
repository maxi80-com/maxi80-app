// The Android leg never compiles this type: the legacy CoverFlowView renders there until the
// native Compose renderer lands. Wrapping the whole file keeps SkipUI API-availability and the
// bridge generator entirely out of the picture.
#if !os(Android)

  import SwiftUI

  /// State-driven Cover Flow renderer for Apple platforms (design spec §2).
  ///
  /// There is no ScrollView: every cover's position is a pure function of
  /// `(index, anchorIndex, dragTranslation)` evaluated through `CarouselGeometry`, so the
  /// selected cover is centered *by construction*. That makes the drift bug class that killed
  /// the ScrollView renderers structurally impossible — an insertion left of the selection
  /// shifts `index` and `anchorIndex` equally, and a rotation/resize simply re-evaluates the
  /// math at the new width. No pin tokens, no recreation guards, no reconciliation.
  struct AppleCoverFlow: View {
    let covers: [Cover]
    /// The id the strip keeps centered. The renderer FOLLOWS this value; it never owns
    /// position. It reports back only settled user gestures via `onSettled`.
    let selectedID: AnyHashable
    var coverSize: CGFloat = 260
    /// Called from exactly two places — drag release and tap-to-focus (plus arrow keys) — so
    /// settle reporting is user-driven by construction (R3): no scroll-phase heuristics exist.
    let onSettled: (AnyHashable) -> Void

    /// Live finger translation. Internal (not private) per the Skip bridge rule for `@State`
    /// on view types — kept even though this file is Apple-only, for consistency.
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
        .contentShape(Rectangle())
        // tvOS has no DragGesture (and the TV UI uses TVRadioPlayerView, not this renderer);
        // the guard only keeps the tvOS leg of this multi-platform target compiling.
        #if !os(tvOS)
          .gesture(dragGesture(geometry: geometry, anchorIndex: anchor))
        #endif
        .focusable()
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
      }
      .frame(maxWidth: .infinity)
      .frame(height: coverSize + verticalMargin * 2)
      .accessibilityElement(children: .contain)
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

    /// Virtualization by math: only covers within the geometry's visible window are
    /// instantiated, so a 100-entry history renders a handful of cells, not 100.
    func visibleCovers(geometry: CarouselGeometry, anchorIndex: Int) -> [VisibleCover] {
      covers.enumerated().compactMap { index, cover in
        let relative = geometry.relativePosition(
          index: index, anchorIndex: anchorIndex, dragTranslation: dragTranslation)
        return geometry.isVisible(relative: relative) ? VisibleCover(index: index, cover: cover) : nil
      }
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
    /// gone with the ScrollView.
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
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
              dragTranslation = geometry.rubberBanded(
                translation: value.translation.width,
                anchorIndex: anchorIndex,
                coverCount: covers.count)
            }
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
    /// clamped to the strip. Ignored at the ends so focus can move on.
    private func moveSelection(by delta: Int) -> KeyPress.Result {
      let target = anchorIndex + delta
      guard covers.indices.contains(target) else { return .ignored }
      withAnimation(Self.settleSpring) { onSettled(AnyHashable(covers[target].id)) }
      return .handled
    }
  }

#endif
