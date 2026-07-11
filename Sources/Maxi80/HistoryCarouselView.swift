import SwiftUI
import Maxi80Model
import Maxi80Services

/// A swipeable carousel displaying the song history.
/// The current live song is the rightmost (newest) entry.
/// Swipe left for older entries, swipe right for newer entries.
struct HistoryCarouselView: View {
    @Bindable var viewModel: RadioPlayerViewModel

    var body: some View {
        if viewModel.history.isEmpty {
            // Empty state — show station placeholder
            VStack(spacing: 4) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.4))
                Text("No history yet")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
        } else {
            TabView(selection: $viewModel.selectedHistoryIndex) {
                ForEach(Array(viewModel.history.enumerated()), id: \.element.id) { index, entry in
                    historyCard(for: entry)
                        .tag(index)
                }
            }
            .frame(height: 120)
            #if os(iOS) || os(tvOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
        }
    }

    // MARK: - Subviews

    private func historyCard(for entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            // Small artwork thumbnail
            artworkImage(url: entry.artwork)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Song info
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(entry.artist)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func artworkImage(url: String?) -> some View {
        if let urlString = url, let imageURL = URL(string: urlString) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    defaultCover
                case .empty:
                    defaultCover
                @unknown default:
                    defaultCover
                }
            }
        } else {
            defaultCover
        }
    }

    private var defaultCover: some View {
        Image("NoCover", bundle: .module)
            .resizable()
            .scaledToFill()
    }
}

// MARK: - Preview

#if ENABLE_PREVIEWS
#Preview("History Carousel") {
    HistoryCarouselView(viewModel: PreviewMocks.makeViewModel())
        .padding()
        .background(Color(red: 0.15, green: 0.1, blue: 0.3))
}

#Preview("Empty History") {
    HistoryCarouselView(viewModel: PreviewMocks.makeViewModel(hasHistory: false))
        .padding()
        .background(Color(red: 0.15, green: 0.1, blue: 0.3))
}
#endif
