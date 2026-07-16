// Sources/Maxi80/TV/TVHistoryRow.swift
import SwiftUI
import Maxi80Model

/// A focus-navigable horizontal row of recently-played covers for the TV UI. The live "now" slot is
/// the FIRST (leftmost) item and where the row opens/focuses; history extends to the right,
/// newest → oldest. Reuses the same `viewModel.covers` data the phone Cover Flow uses (which orders
/// oldest → newest with the now slot last), reversed for TV so the live cover leads. Reversing —
/// rather than a `scrollTo` to the trailing edge — is deliberate: on Android the transpiled
/// ScrollView ignores a programmatic scroll-to-trailing on appear (see the carousel pin findings),
/// so anchoring by order is the only reliable way to open on the live cover.
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

    /// Covers ordered live-first: the now slot leads, history follows newest → oldest.
    private var orderedCovers: [CoverFlowView.Cover] {
        Array(viewModel.covers.reversed())
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(orderedCovers, id: \.id) { cover in
                    coverThumbnail(cover)
                        .id(cover.id)
                }
            }
            .padding(.horizontal, 60)
        }
        #if os(tvOS)
        // Focus lands on the live "now" slot (now the leading item) when the row is entered.
        .defaultFocus($focusedID, RadioPlayerViewModel.nowSlotID)
        .onChange(of: focusedID) { _, newValue in
            if let newValue {
                viewModel.selectedCoverID = newValue
            } else {
                viewModel.returnToLive()
            }
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
