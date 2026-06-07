import SwiftUI

/// Displays album artwork with smooth crossfade transitions when the image changes.
/// Shows a default placeholder when no artwork is available.
///
/// Requirements:
/// - 5.3: Display default Maxi80 cover when no artwork available
/// - 5.4: Continue displaying previous artwork until new artwork is ready
/// - 10.5: Animate transitions between artwork with crossfade
public struct ArtworkView: View {
    public var artwork: Image?

    public init(artwork: Image?) {
        self.artwork = artwork
    }

    public var body: some View {
        ZStack {
            if let artwork {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                defaultCover
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: artwork == nil)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
    }

    /// Default Maxi80 cover shown when no artwork is available.
    private var defaultCover: some View {
        Image("NoCover", bundle: .module)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

#if DEBUG && !SKIP_BRIDGE
#Preview("With Artwork") {
    ArtworkView(artwork: Image(systemName: "music.note"))
        .frame(width: 300, height: 300)
        .padding()
}

#Preview("No Artwork — Default Cover") {
    ArtworkView(artwork: nil)
        .frame(width: 300, height: 300)
        .padding()
}
#endif
