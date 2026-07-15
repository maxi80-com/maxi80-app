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

    struct Cover: Identifiable, Equatable {
        let id: String
        /// Remote artwork URL (played songs). `nil` for the startup placeholder.
        var artworkURL: String? = nil
        /// Bundled asset name (startup placeholder). `nil` for played songs.
        var assetName: String? = nil
    }

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

    var body: some View {
        GeometryReader { outer in
            let center = outer.frame(in: .global).midX

            ScrollViewReader { proxy in
              ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(covers) { cover in
                        coverCell(cover, containerCenter: center)
                            .id(cover.id)
                    }
                }
                .scrollTargetLayout()
                // Symmetric padding so the first and last covers can center; vertical margin
                // keeps the shadow away from the (clipping) scroll edges.
                .padding(.horizontal, (outer.size.width - coverSize) / 2)
                .padding(.vertical, verticalMargin)
              }
              // Snap each cover to center after a scroll. Works with macOS two-finger/trackpad
              // horizontal scrolling too (it settles the scroll, it doesn't block the gesture).
              .scrollTargetBehavior(.viewAligned)
              // scrollPosition(id:) only *reports* the focused cover; ScrollViewReader does the
              // actual scrolling. Pin on first appearance and whenever pinToken changes.
              .task(id: pinToken) {
                  guard let target = pinTarget else { return }
                  // Let layout settle after content changes, then jump (NOT animate) to center
                  // the target. anchor: .center avoids landing off-center + tilting. A
                  // *non-animated* jump is deliberate: an animated scrollTo sweeps the
                  // LazyHStack across every intermediate cover, kicking off then cancelling
                  // their AsyncImage loads, which then never restart → older covers stuck on the
                  // placeholder. Jumping lands directly without instantiating the cells between.
                  try? await Task.sleep(nanoseconds: 60_000_000)
                  proxy.scrollTo(target, anchor: .center)
              }
              // Reports which cover the user swiped to. On iOS 26/macOS, scrollPosition(id:) writes
              // the centered id back into `selection` and drives the title. On iOS 27 that
              // write-back regressed (verified: proxy-scrolling the viewport never updated the
              // binding), so on Apple platforms we instead derive the centered id ourselves from
              // each cell's distance-to-center (see CenteredCoverKey) and skip scrollPosition's
              // read-back entirely. Android's scrollPosition(id:) still works and its
              // scrollPosition(id:anchor:) fatalErrors on a non-nil anchor, so it keeps this path.
              #if SKIP
              .scrollPosition(id: $selection)
              #else
              .onPreferenceChange(CenteredCoverKey.self) { centered in
                  guard let id = centered?.id else { return }
                  if AnyHashable(id) != selection {
                      selection = AnyHashable(id)
                  }
              }
              #endif
            }
        }
        .frame(height: coverSize + verticalMargin * 2)
    }

    @ViewBuilder
    private func coverCell(_ cover: Cover, containerCenter: CGFloat) -> some View {
        GeometryReader { geo in
            // Signed distance of this cover's center from the container center,
            // normalized to [-1, 1] over roughly one cover width.
            let cellCenter = geo.frame(in: .global).midX
            let offset = Double(cellCenter - containerCenter)
            let normalized = max(-1, min(1, offset / Double(coverSize)))

            let rotation = -normalized * maxRotation
            let scale = 1 - (1 - minScale) * CGFloat(abs(normalized))

            CoverImage(url: cover.artworkURL, assetName: cover.assetName)
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
        }
        .frame(width: coverSize, height: coverSize)
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
        guard let current = value else { value = next; return }
        if next.distance < current.distance { value = next }
    }
}
#endif

/// A single cover image: a remote artwork URL for played songs, or a bundled asset for the
/// startup placeholder. Falls back to the default generic cover if neither loads.
struct CoverImage: View {
    var url: String? = nil
    var assetName: String? = nil

    var body: some View {
        if let url, let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    placeholder.overlay { ProgressView().tint(.white) }
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(assetName ?? "NoCover-a", bundle: .module)
            .resizable()
            .scaledToFill()
    }
}
