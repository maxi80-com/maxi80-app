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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(viewModel.covers, id: \.id) { cover in
                    coverThumbnail(cover)
                }
            }
            .padding(.horizontal, 60)
        }
        #if os(tvOS)
        .onChange(of: focusedID) { _, newValue in
            if let newValue { viewModel.selectedCoverID = newValue }
        }
        #endif
    }

    @ViewBuilder
    private func coverThumbnail(_ cover: CoverFlowView.Cover) -> some View {
        let image = Group {
            if let urlString = cover.artworkURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fit)
                    } else if let asset = cover.assetName {
                        Image(asset, bundle: .module).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.black.opacity(0.3)
                    }
                }
            } else if let asset = cover.assetName {
                Image(asset, bundle: .module).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.black.opacity(0.3)
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        #if os(tvOS)
        Button { viewModel.selectedCoverID = cover.id } label: { image }
            .buttonStyle(.card)
            .focused($focusedID, equals: cover.id)
        #else
        image
        #endif
    }
}
