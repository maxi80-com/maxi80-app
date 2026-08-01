import SwiftUI

/// A horizontally-swipeable, Cover Flow–style carousel of album artwork.
///
/// The centered cover faces the viewer flat; covers to either side tilt back in 3D,
/// evoking the classic iTunes Cover Flow. Covers are ordered oldest → newest (left →
/// right), so the live song sits at the rightmost edge. Swiping right browses back in
/// time; the tracks never play back — this is a visual history only.
///
/// Selection is tracked by stable item id (not index) so appending a new song on the
/// right never shifts the browsing position.
struct CoverFlowView: View {

  let covers: [Cover]
  /// The focused cover's id. Typed as `AnyHashable?` because that's what
  /// `scrollPosition(id:)` binds to on the Android/transpiled path.
  @Binding var selection: AnyHashable?
  /// Id the carousel should programmatically scroll to. Changing this value (via `pinToken`)
  /// triggers a `scrollTo`. `scrollPosition(id:)` is read-only across platforms, so an
  /// explicit ScrollViewReader is required to actually move the scroll offset.
  let pinTarget: AnyHashable?
  /// Changes to request a (re-)scroll to `pinTarget` — e.g. when history loads to the left
  /// or the now-slot artwork swaps in.
  let pinToken: String

  /// Edge length of the focused (centered) cover.
  var coverSize: CGFloat = 260
  /// Maximum tilt applied to fully off-center covers.
  private let maxRotation: Double = 55
  /// How much off-center covers shrink (1.0 = no shrink).
  private let minScale: CGFloat = 0.72
  /// Spacing between covers.
  private let spacing: CGFloat = -40
  /// Vertical breathing room inside the scroll view so the cover's drop shadow is fully
  /// contained. Without it, the ScrollView clips the soft shadow into a hard "separator"
  /// line at its bottom edge.
  private let verticalMargin: CGFloat = 40

  #if !os(Android)
    /// Signed screen offset of the *target* cover from container center (positive = right of
    /// center), reported by the target cell via `TargetOffsetKey` and read by the re-pin `.task`
    /// after settling. Drives the self-calibrating anchor correction below — always the target,
    /// even when drift is large enough that a neighbour is the visually-centered cover.
    @State private var targetOffset: Double? = nil
    /// Per-width cache of the fractional `scrollTo` anchor-x that lands the target dead-centre.
    /// iOS 26 and 27 (and each orientation) rest the RTL `.viewAligned` scroll at different offsets,
    /// so no constant anchor works everywhere; we measure the right one once per width and reuse it.
    @State private var calibratedAnchorX: [Int: Double] = [:]
  #endif

  var body: some View {
    GeometryReader { outer in
      let center = outer.frame(in: .global).midX

      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: spacing) {
            ForEach(orderedCovers) { cover in
              coverCell(cover, containerCenter: center, resolvedTarget: pinTarget ?? selection)
                .id(cover.id)
            }
          }
          .scrollTargetLayout()
          // Symmetric padding so the first and last covers can center; vertical margin
          // keeps the shadow away from the (clipping) scroll edges.
          .padding(.horizontal, (outer.size.width - coverSize) / 2)
          .padding(.vertical, verticalMargin)
        }
        // Apple only: lay the carousel out right-to-left so the content-leading element is the
        // now slot (rightmost on screen). This is issue #25's real fix. History loads/grows on the
        // LEFT; iOS's ScrollView holds its *leading* edge across content-size changes, so pinning
        // the now slot to the leading edge means the newly-prepended older covers extend off the
        // trailing (left) side and the now slot never moves — the flash (oldest cover centered for
        // one frame under the default left anchor) can't happen. `orderedCovers` reverses the array
        // to match, so oldest still appears far-left and now far-right on screen. Tilt and centered-
        // selection read `.global` (screen) coordinates, which RTL doesn't remap, so their symmetric
        // math is unaffected. Android keeps LTR + its own `scrollPosition(id:)`/`.center` pin.
        #if !os(Android)
          .environment(\.layoutDirection, .rightToLeft)
        #endif
        // Snap each cover to center after a scroll. Works with macOS two-finger/trackpad
        // horizontal scrolling too (it settles the scroll, it doesn't block the gesture).
        .scrollTargetBehavior(.viewAligned)
        // scrollPosition(id:) only reports the focused cover; ScrollViewReader does the scrolling.
        // Re-pin on first appearance, whenever pinToken changes, and whenever the container width
        // changes: a rotation recreates this view (portrait and landscape host it in different
        // slots) and its fresh ScrollView lays out at the leftmost cover, so the pin must re-center
        // on the browsed/live cover. The parent preserves `selection` across the recreation, so
        // `pinTarget ?? selection` is the correct target.
        .task(id: repinToken(width: outer.size.width)) {
          let target = pinTarget ?? selection
          // Let layout settle before pinning. The pin is a jump, not an animated sweep: an animated
          // scrollTo drags the LazyHStack across every intermediate cover, starting then cancelling
          // their AsyncImage loads so those covers stick on the placeholder. Jumping lands directly
          // without instantiating the cells between.
          try? await Task.sleep(nanoseconds: 60_000_000)
          guard let target else { return }
          #if os(Android)
            proxy.scrollTo(target, anchor: .center)
          #else
            // Apple centres via a self-calibrating anchor — the RTL layout rests at an OS/width-
            // dependent offset no fixed anchor can null out. See `centerTargetByCalibration`.
            await centerTargetByCalibration(
              target, proxy: proxy, width: Int(outer.size.width))
          #endif
        }
        // Reports which cover the user swiped to. Apple derives the centered id from each cell's
        // distance-to-center (CenteredCoverKey) because scrollPosition(id:) doesn't report proxy
        // scrolls on iOS 27. Android's scrollPosition(id:) works and its anchor variant traps on a
        // non-nil anchor, so it keeps that path.
        #if SKIP
          .scrollPosition(id: $selection)
        #else
          .onPreferenceChange(CenteredCoverKey.self) { centered in
            guard let id = centered?.id else { return }
            if AnyHashable(id) != selection {
              // The parent drops this write during a rotation, so the recreated carousel's transient
              // leftmost-cover centering can't lose the browsed cover.
              selection = AnyHashable(id)
            }
          }
        #endif
        // Guarded `!os(Android)` to match `TargetOffsetKey`/`targetOffset` (Apple-only). The block
        // above is `!SKIP`, which also compiles on the Android *native-bridge* build (SKIP off,
        // os(Android) on) where those symbols don't exist — so this observer must be guarded
        // separately or that build fails to find them.
        #if !os(Android)
          .onPreferenceChange(TargetOffsetKey.self) { offset in
            // Latest signed offset of the *target* cover — the input to the anchor calibration.
            targetOffset = offset
          }
        #endif
      }
    }
    .frame(height: coverSize + verticalMargin * 2)
  }

  /// The cover order handed to the `ForEach`. Apple lays the ScrollView out right-to-left (see the
  /// `.environment(\.layoutDirection, .rightToLeft)` above) so the now slot sits at the content-
  /// leading edge; reversing here (now → oldest) makes that RTL layout render oldest far-left and
  /// now far-right on screen — the same visual order as before. Android keeps LTR and the original
  /// oldest → now order.
  private var orderedCovers: [Cover] {
    #if os(Android)
      covers
    #else
      covers.reversed()
    #endif
  }

  /// Identity for the re-pin `.task`. Folds in the rounded container width so a rotation re-fires
  /// the pin, since relayout at the new width resets the scroll to the leftmost cover.
  private func repinToken(width: CGFloat) -> String {
    "\(pinToken)|\(Int(width))"
  }

  #if !os(Android)
    /// How long to wait for a `scrollTo` to settle before reading the target's resting offset.
    private static let settleNanos: UInt64 = 350_000_000
    /// Below this many points of residual offset the target is "centered enough"; stop correcting.
    private static let centeredTolerancePt: Double = 2

    /// Scroll so the re-pin `target` lands dead-centre, self-calibrating the `scrollTo` anchor.
    ///
    /// Why calibrate: under the RTL layout (issue #25 flash fix) the `.viewAligned` scroll rests at
    /// an offset that iOS 26 and iOS 27 — and each orientation — resolve differently, so no constant
    /// `scrollTo` anchor lands the target centred (measured: `.leading` drifts +40 on 27 and ±87–90
    /// on 26; `.trailing` is perfect on 26 but drifts −47/−102 on 27). Rather than hard-code per-OS
    /// numbers, we measure the target's own signed offset at two nearby anchors, solve the line for
    /// the anchor that yields zero offset, cache it per width, and reuse it. Robust across OS
    /// versions with no `#available` gate. All probes stay near centre, so no cover flashes past.
    @MainActor
    private func centerTargetByCalibration(
      _ target: AnyHashable, proxy: ScrollViewProxy, width: Int
    ) async {
      // Fast path: reuse a previously-solved anchor for this width — a single jump, no probing.
      if let x = calibratedAnchorX[width] {
        proxy.scrollTo(target, anchor: UnitPoint(x: x, y: 0.5))
        return
      }

      // Probe two anchors and read the target's resting offset at each.
      let x0 = 0.5
      let x1 = 0.65
      guard let f0 = await offset(after: x0, target: target, proxy: proxy) else {
        proxy.scrollTo(target, anchor: UnitPoint(x: x0, y: 0.5))
        return
      }
      // Already centred at the first probe — nothing to solve.
      if abs(f0) <= Self.centeredTolerancePt {
        calibratedAnchorX[width] = x0
        return
      }
      guard let f1 = await offset(after: x1, target: target, proxy: proxy) else {
        proxy.scrollTo(target, anchor: UnitPoint(x: x0, y: 0.5))
        return
      }

      // offset(x) is linear in the anchor x: solve offset(xSolved) = 0.
      let slope = (f1 - f0) / (x1 - x0)
      guard abs(slope) > 0.0001 else {
        proxy.scrollTo(target, anchor: UnitPoint(x: x0, y: 0.5))
        return
      }
      let xSolved = min(1, max(0, x0 - f0 / slope))
      calibratedAnchorX[width] = xSolved
      proxy.scrollTo(target, anchor: UnitPoint(x: xSolved, y: 0.5))
    }

    /// Jump the target to `anchorX`, wait for it to settle, and return the target cover's signed
    /// screen offset from centre (positive = right of centre), or `nil` if it hasn't reported yet.
    @MainActor
    private func offset(after anchorX: Double, target: AnyHashable, proxy: ScrollViewProxy) async
      -> Double?
    {
      proxy.scrollTo(target, anchor: UnitPoint(x: anchorX, y: 0.5))
      try? await Task.sleep(nanoseconds: Self.settleNanos)
      return targetOffset
    }
  #endif

  @ViewBuilder
  private func coverCell(_ cover: Cover, containerCenter: CGFloat, resolvedTarget: AnyHashable?)
    -> some View
  {
    GeometryReader { geo in
      // Signed distance of this cover's center from the container center,
      // normalized to [-1, 1] over roughly one cover width.
      let cellCenter = geo.frame(in: .global).midX
      let offset = Double(cellCenter - containerCenter)
      let normalized = max(-1, min(1, offset / Double(coverSize)))

      // `normalized` is derived from `.global` (screen) coordinates, which the right-to-left layout
      // does NOT mirror — but `rotation3DEffect` around the Y axis IS layout-direction-aware and
      // SwiftUI flips it under RTL. So on Apple (where the carousel is laid out RTL to pin the now
      // slot, issue #25) we negate the angle to cancel that flip and keep side covers fanning away
      // from center rather than leaning in and overlapping. Android is LTR and keeps the sign.
      #if os(Android)
        let rotation = -normalized * maxRotation
      #else
        let rotation = normalized * maxRotation
      #endif
      let scale = 1 - (1 - minScale) * CGFloat(abs(normalized))

      coverImage(cover)
        .frame(width: coverSize, height: coverSize)
        .clipShape(.rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 12)
        .scaleEffect(scale)
        .rotation3DEffect(
          .degrees(rotation),
          axis: (x: 0, y: 1, z: 0),
          anchor: .center,
          perspective: 0.6
        )
        // Off-center covers sit behind the focused one.
        .zIndex(1 - abs(normalized))
        // Report this cover's distance-to-center so the parent can pick the centered id
        // (Apple only — Android drives `selection` via scrollPosition(id:) instead).
        #if !SKIP
          .preference(
            key: CenteredCoverKey.self,
            value: CenteredCover(id: cover.id, distance: abs(offset))
          )
        #endif
        // The *target* cover reports its own signed offset so the re-pin `.task` can null it out
        // regardless of which cover is momentarily centered (Apple only).
        #if !os(Android)
          .preference(
            key: TargetOffsetKey.self,
            value: (resolvedTarget.map { AnyHashable(cover.id) == $0 } ?? false) ? offset : nil
          )
        #endif
    }
    .frame(width: coverSize, height: coverSize)
  }

  /// The cell's artwork. On iOS the now slot keeps the constant id `__now__` while its artwork
  /// swaps A→B in place, so keying the inner image on its content (url/asset) makes that swap a
  /// remove+insert and crossfades it. Scoped to iOS and to the image only, so the carousel's
  /// scroll/tilt/pin (which key on `cover.id`) are untouched. Other platforms swap instantly.
  @ViewBuilder
  private func coverImage(_ cover: Cover) -> some View {
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
}

#if !SKIP
  /// The cover nearest the container center, used to derive the focused selection on Apple platforms
  /// where iOS 27's `scrollPosition(id:)` no longer writes the centered id back into its binding.
  private struct CenteredCover: Hashable {
    let id: String
    let distance: Double
  }

  private struct CenteredCoverKey: PreferenceKey {
    static let defaultValue: CenteredCover? = nil

    static func reduce(value: inout CenteredCover?, nextValue: () -> CenteredCover?) {
      guard let next = nextValue() else { return }
      guard let current = value else {
        value = next
        return
      }
      if next.distance < current.distance { value = next }
    }
  }
#endif

#if !os(Android)
  /// Signed screen offset of the re-pin target cover from container center (positive = right of
  /// center). Only the target cell emits a non-nil value; used to self-calibrate the re-pin anchor.
  private struct TargetOffsetKey: PreferenceKey {
    static let defaultValue: Double? = nil

    static func reduce(value: inout Double?, nextValue: () -> Double?) {
      if let next = nextValue() { value = next }
    }
  }
#endif
