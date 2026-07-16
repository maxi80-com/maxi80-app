import SwiftUI
#if SKIP
import androidx.compose.foundation.layout.size
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.Icons
// Material icon accessors (e.g. `Icons.Filled.PlayArrow`) are extension properties defined in the
// `.filled` package, so they must be imported — they can't be referenced fully-qualified inline.
import androidx.compose.material.icons.filled.__
import androidx.compose.material3.Icon
#endif

/// The subset of extended Material icons this app draws. Kept as a plain Swift enum available on
/// every platform so call sites (which take `android: MaterialSymbol` even inside `#else` branches)
/// compile everywhere; the mapping to concrete `Icons.Filled.*` image vectors happens in the
/// transpiled composer, keyed by `iconKey`. Only Android actually renders from it.
enum MaterialSymbol {
    case play
    case pause
    case share
    case favorite
    case volumeDown
    case volumeUp
    case liveBroadcast

    /// Stable string key passed across the native→Compose bridge and matched in the composer.
    var iconKey: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .share: "share"
        case .favorite: "favorite"
        case .volumeDown: "volumeDown"
        case .volumeUp: "volumeUp"
        case .liveBroadcast: "liveBroadcast"
        }
    }
}

/// Renders a Jetpack Compose Material icon on Android in place of an SF Symbol.
///
/// SkipUI's `Image(systemName:)` only maps a handful of SF Symbol names to Material's *core* icon
/// set; unmapped names (e.g. `pause.circle.fill`, `speaker.fill`) render as a warning triangle. The
/// media/volume glyphs this app needs live in `material-icons-extended`, which SkipUI already puts
/// on the classpath but does not expose through `Image(systemName:)`. This view bridges directly to
/// those icons via `ComposeView`.
///
/// Apple platforms never use this type — call sites keep `Image(systemName:)` under `#else`.
#if os(Android)
struct AndroidIcon: View {
    /// One of the `MaterialSymbol` cases identifying the extended Material icon to draw.
    let symbol: MaterialSymbol
    /// Point/dp size of the square icon.
    var size: CGFloat = 24
    /// Icon tint.
    var tint: Color = .primary

    var body: some View {
        // `symbol` is a native Swift enum; the composer is transpiled Kotlin, so pass its String
        // key across the bridge (native enums aren't bridgeable, but String is).
        ComposeView {
            MaterialIconComposer(iconKey: symbol.iconKey, size: size, tint: tint)
        }
    }
}

#if SKIP
/// Draws the requested extended Material icon as Compose content, tinted and sized. Transpiled to
/// Kotlin; uses fully-qualified `androidx.*` names so no top-level Compose imports are needed.
struct MaterialIconComposer: ContentComposer {
    let iconKey: String
    let size: CGFloat
    let tint: Color

    @Composable func Compose(context: ComposeContext) {
        let vector = switch iconKey {
        // Filled-disc variants (not the bare PlayArrow/Pause glyphs) so the primary control matches
        // iOS's `play.circle.fill`/`pause.circle.fill`: a single-color vector drawn as a filled disc
        // with the glyph knocked out, so the existing orange `tint` paints the disc and the glyph
        // shows through as negative space.
        case "play": Icons.Filled.PlayCircle
        case "pause": Icons.Filled.PauseCircle
        case "share": Icons.Filled.Share
        case "favorite": Icons.Filled.FavoriteBorder
        case "volumeDown": Icons.Filled.VolumeDown
        case "volumeUp": Icons.Filled.VolumeUp
        case "liveBroadcast": Icons.Filled.Sensors
        default: Icons.Filled.Warning
        }
        Icon(
            imageVector: vector,
            contentDescription: nil,
            modifier: context.modifier.size(size.dp),
            tint: tint.asComposeColor()
        )
    }
}
#endif
#endif
