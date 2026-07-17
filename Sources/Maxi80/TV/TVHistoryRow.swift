// Sources/Maxi80/TV/TVHistoryRow.swift
import SwiftUI
import Maxi80Model

/// A focus-navigable horizontal row of PAST covers for the TV UI, ordered oldest → newest
/// (left → right) so the most-recent history sits nearest the now-playing hero above. The live
/// "now" slot is NOT in this row — it's rendered as the hero cover in `TVRadioPlayerView`; the row
/// is history-only. Reuses the same `viewModel.covers` data the phone Cover Flow uses (oldest →
/// newest with the now slot last), dropping that trailing now slot. Ordering by array position —
/// rather than a `scrollTo` — is deliberate: on Android the transpiled ScrollView ignores a
/// programmatic scroll-to-trailing on appear (see the carousel pin findings).
struct TVHistoryRow: View {
    @Bindable var viewModel: RadioPlayerViewModel
    #if os(tvOS)
    // `Cover.id` is `String`, so the FocusState value type is `String?` — assigning it into the
    // view model's `AnyHashable?` selection wraps implicitly.
    @FocusState private var focusedID: String?
    #endif

    init(viewModel: RadioPlayerViewModel) {
        self.viewModel = viewModel
    }

    /// Past covers only, oldest → newest (newest nearest the now-playing hero). The trailing "now"
    /// slot from `viewModel.covers` is dropped — it lives in the hero, not this row.
    private var orderedCovers: [CoverFlowView.Cover] {
        Array(viewModel.covers.dropLast())
    }

    var body: some View {
        #if os(tvOS)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(orderedCovers, id: \.id) { cover in
                        coverThumbnail(cover)
                            .id(cover.id)
                    }
                }
                .padding(.horizontal, 60)
            }
            // Covers are oldest → newest L→R; open showing the newest (nearest "now") at the trailing
            // edge. `.defaultScrollAnchor` sets the initial offset without an `onAppear`/`scrollTo` race.
            .defaultScrollAnchor(.trailing)
            // `.focusSection()` makes the whole row one focus target: a D-pad *up* from ANY cover
            // routes to the control section above (and *down* returns here), instead of tvOS's
            // geometric default where only the covers directly beneath the play button can move up.
            .focusSection()
            // Focusing a history cover selects it (updating the hero + labels). Leaving the row
            // (moving up to the controls) must NOT reset to live — otherwise `isBrowsingHistory`
            // flips false and the "Back to live" pill disappears before it can be reached. The
            // selection persists until the user explicitly taps "Back to live".
            .onChange(of: focusedID) { _, newValue in
                if let newValue {
                    viewModel.selectedCoverID = newValue
                }
            }
            // Re-pin the row to the newest (rightmost) cover, matching the phone's Cover Flow: key
            // on `coverPinToken` (which folds in `returnToLiveNonce`, so tapping "Back to live"
            // re-fires this) and, while not browsing, jump to the newest cover. Non-animated after a
            // short settle — an animated scrollTo sweeps the row through intermediate cells and
            // cancels their AsyncImage loads, leaving older covers stuck on placeholders.
            .task(id: viewModel.coverPinToken) {
                guard !viewModel.isBrowsingHistory, let target = orderedCovers.last?.id else { return }
                try? await Task.sleep(nanoseconds: 60_000_000)
                proxy.scrollTo(target, anchor: .trailing)
            }
        }
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(orderedCovers, id: \.id) { cover in
                    coverThumbnail(cover)
                        .id(cover.id)
                }
            }
            .padding(.horizontal, 60)
        }
        #endif
    }

    @ViewBuilder
    private func coverThumbnail(_ cover: CoverFlowView.Cover) -> some View {
        let image = CoverImage(url: cover.artworkURL, assetName: cover.assetName)
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))

        #if os(tvOS)
        Button { viewModel.selectedCoverID = cover.id } label: { image }
            .buttonStyle(.card)
            .focused($focusedID, equals: cover.id)
        #else
        Button { viewModel.selectedCoverID = cover.id } label: { image }
            .buttonStyle(.plain)
        #endif
    }
}
