// Sources/Maxi80/TV/TVHistoryRow.swift
import SwiftUI
import Maxi80Model

/// A focus-navigable horizontal row of recently-played covers for the TV UI. The rightmost item is
/// the live "now" slot; focus moves left through history via the remote D-pad. Reuses the same
/// `viewModel.covers` data the phone Cover Flow uses, but navigates by focus, not drag.
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(viewModel.covers, id: \.id) { cover in
                        coverThumbnail(cover)
                            .id(cover.id)
                    }
                }
                .padding(.horizontal, 60)
            }
            .onAppear {
                // Open on the live "now" slot at the right edge, not the oldest cover on the left.
                proxy.scrollTo(RadioPlayerViewModel.nowSlotID, anchor: .trailing)
            }
            #if os(tvOS)
            // Focus lands on the live "now" slot (rightmost) when the row is entered.
            .defaultFocus($focusedID, RadioPlayerViewModel.nowSlotID)
            .onChange(of: focusedID) { _, newValue in
                if let newValue {
                    viewModel.selectedCoverID = newValue
                    // Keep the focused cover in view as the D-pad moves left through history.
                    proxy.scrollTo(newValue, anchor: .center)
                } else {
                    viewModel.returnToLive()
                }
            }
            #endif
        }
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
