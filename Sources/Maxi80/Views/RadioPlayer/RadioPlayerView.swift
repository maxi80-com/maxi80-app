import Maxi80Model
import Maxi80Services
import SwiftUI

/// Root view of the Maxi80 radio player.
///
/// The hero is a Cover Flow carousel of the session's song history: the live track sits at
/// the right edge; swiping right browses older covers in 3D. The background is a gradient
/// derived from the current artwork's dominant color, falling back to a colorScheme-appropriate
/// solid when no artwork color is available. Layout adapts between portrait and landscape.
///
/// The view is split across files by section, all extending this one struct:
/// `RadioPlayerView+Background` (the wash), `+Layout` (orientation layouts and hero sizing),
/// and `+Chrome` (song label, status slot, volume, footer, error banner). Members reached from
/// another of those files are `internal` rather than `private` for that reason alone.
public struct RadioPlayerView: View {

  @Bindable var viewModel: RadioPlayerViewModel
  @Environment(\.colorScheme) var colorScheme
  @Environment(\.scenePhase) var scenePhase
  // Re-opening the sleep-timer picker from the countdown pill (to extend/change the duration).
  // Internal, not private: Skip's bridge requires @State properties to be non-private.
  @State var showSleepTimerSheet = false

  // Android background wash (see `dynamicBackground`): two persistent ping-pong layers.
  // The flash-proofing rule, distilled from repeated on-device measurement: a layer's COLOR
  // may only be written while that layer's opacity is exactly 0 (Compose can render new
  // gradient content a frame before an opacity change that should hide it — so any color
  // write on a visible layer can flash), and visible opacities may only ever be ANIMATED,
  // never jumped. At rest one layer is front (fade 1) and one is back (fade 0); a color
  // change writes the back layer (invisible → safe), then one crossfade animates front→0,
  // back→1 — direct old→new dissolve, no dip through the brand background. Unused on Apple
  // platforms, which keep the native `.animation` gradient interpolation (never flashed).
  // Internal per the Skip bridge rule for `@State`.
  @State var washAColor: Color?
  @State var washBColor: Color?
  @State var washAFade: Double = 0
  @State var washBFade: Double = 0
  /// Android text-contrast fade: 0 = light (white) text, 1 = dark text. Animated inside the
  /// wash driver's `withAnimation` so the glyph color dissolves in lockstep with the
  /// background wash it must contrast against (see `contrastFadingText`).
  @State var textDarkFade: Double = 0

  /// The contrast fade handed to the utility tray so its icons dissolve in the same
  /// transaction as the song label. Apple platforms pass 0 (unused there — the tray keeps
  /// semantic `.secondary`).
  var playbackControlsContrastFade: Double {
    #if os(Android)
      textDarkFade
    #else
      0
    #endif
  }

  /// In-flight deferred crossfade (see the `onChange(of: dominantColorKey)` driver) plus the
  /// driver's non-rendering bookkeeping: which layer is front, and when the running crossfade
  /// ends (a new color must not be written to a layer still animating toward 0 — its RENDERED
  /// opacity is nonzero even though its @State target is 0). A reference box, not observable
  /// state — none of it affects rendering, and a new change must cancel/supersede a pending
  /// one without invalidating the view.
  @State var washDriver = WashDriver()

  /// Plain (non-observable) holder for the wash driver's task + bookkeeping.
  final class WashDriver {
    var task: Task<Void, Never>?
    var frontIsA = false
    var settleUntil = Date.distantPast
  }

  public init(viewModel: RadioPlayerViewModel) {
    self.viewModel = viewModel
  }

  public var body: some View {
    NavigationStack {
      // Detect orientation from the actual container size rather than size class: on iPad the
      // horizontal size class is `.regular` in both orientations, so a size-class test never
      // reports portrait. Width-vs-height also tracks iPad split-view / Slide Over pane sizes.
      GeometryReader { geo in
        let isPortrait = geo.size.height > geo.size.width
        Group {
          if isPortrait {
            portraitView(containerWidth: geo.size.width, containerHeight: geo.size.height)
          } else {
            landscapeView(containerWidth: geo.size.width)
          }
        }
        // GeometryReader top-left-aligns its child; expand so the layout fills the pane as before.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { dynamicBackground(isPortrait: isPortrait).ignoresSafeArea() }
        // The branded default background is always dark, so force dark text/controls when
        // it's showing (no artwork color). With artwork, respect the device scheme.
        .environment(\.colorScheme, viewModel.dominantColor == nil ? .dark : colorScheme)
        // Returning to the foreground still needs a playback reconcile (a stale .loading spinner
        // clears, issue #9). The carousel needs nothing: CoverFlowStrip re-derives the centered
        // cover from CarouselModel.selectedID, which survives any view/activity recreation.
        .onChange(of: scenePhase) { _, newPhase in
          if newPhase == .active { SharedPlayer.handleForeground() }
        }
        // Background crossfade driver. Lives HERE, not inside `.background {}`: on
        // SkipUI/Android, onAppear/onChange attached to background content never fire (the
        // wash silently stayed on the brand layer — measured on the A07), while this level
        // provably works (see scenePhase above). Rolls the double buffer and animates the
        // fade; `dynamicBackground` below is purely presentational.
        // Android wash driver: ping-pong crossfade (see the `washAColor` block for the
        // flash-proofing rules). All writes happen inside the task, in a quiet frame — this
        // onChange fires inside the display-sync recomposition storm, which stalls rendering
        // ~300ms on the A07 and would swallow a fade started here. Rapid changes queue
        // behind the running crossfade's settle window rather than tearing it: a layer that
        // is still animating toward 0 has nonzero RENDERED opacity even though its @State
        // target is 0, so writing a color to it early would flash. A newer change cancels
        // and supersedes a pending one. Apple platforms need none of this: their native
        // `.animation` in `dynamicBackground` interpolates the gradient directly.
        #if os(Android)
          .onAppear {
            washBColor = viewModel.dominantColor
            washBFade = washBColor == nil ? 0 : 1
            washDriver.frontIsA = false
            textDarkFade = viewModel.isBackgroundDark ? 0 : 1
          }
          .onChange(of: dominantColorKey) { _, _ in
            let newColor = viewModel.dominantColor
            washDriver.task?.cancel()
            washDriver.task = Task { @MainActor in
              // Only wait if a crossfade is still settling: a layer animating toward 0 has
              // nonzero RENDERED opacity, and rewriting its color while visible can flash.
              // Otherwise start immediately — the song label swaps its text+color in this
              // same update, and any dead time here shows final-contrast text on the OLD
              // wash (reported as "text appears in the wrong color, then fades").
              let remaining = washDriver.settleUntil.timeIntervalSinceNow
              if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
              }
              guard !Task.isCancelled else { return }
              // One plain commit: color to the INVISIBLE back layer + retarget the fades.
              // The layers' implicit `.animation(_, value:)` (see `dynamicBackground`)
              // tweens the opacities Compose-side, starting when the next frame renders —
              // immune to the recomposition-storm wall-clock loss that `withAnimation`
              // suffered here (the reason this driver used to defer 120ms). The back layer
              // fades up FROM 0, so its fresh color first renders invisible: no flash.
              // A nil color is the generic/live slot: fade the incoming layer to 0 so BOTH
              // the wash and the neutral base clear, revealing the brand gradient (matching
              // iOS, which shows brandBackground() when dominantColor is nil). Fading up an
              // empty-color layer would leave the neutral base covering the brand → a blank
              // white/black background.
              let show: Double = newColor == nil ? 0 : 1
              let toA = !washDriver.frontIsA
              if toA {
                washAColor = newColor
              } else {
                washBColor = newColor
              }
              washAFade = toA ? show : 0
              washBFade = toA ? 0 : show
              // Snaps in this commit; the tray/play-button carry their own matching tween.
              textDarkFade = viewModel.isBackgroundDark ? 0 : 1
              washDriver.frontIsA = toA
              // Rendered opacity needs the full tween plus stall slack to truly reach 0.
              washDriver.settleUntil = Date().addingTimeInterval(0.8)
            }
          }
        #endif
        .overlay(alignment: .bottom) { versionFooter }
      }
    }
    .overlay(alignment: .top) {
      if let errorMessage = viewModel.errorMessage {
        errorBanner(message: errorMessage)
      }
    }
  }
}

// MARK: - Previews

#if ENABLE_PREVIEWS
  #Preview("Playing — Portrait") {
    RadioPlayerView(viewModel: PreviewMocks.makeViewModel(isPlaying: true))
      .tint(.orange)
  }

  #Preview("Idle — Station Info") {
    RadioPlayerView(viewModel: PreviewMocks.makeViewModel(hasMetadata: false, hasHistory: false))
      .tint(.orange)
  }

  #Preview("Error State") {
    RadioPlayerView(viewModel: PreviewMocks.makeViewModel(hasError: true))
      .tint(.orange)
  }

  // iPad landscape: exercises the enlarged hero + capped info/controls column. The device trait
  // makes `PlatformEnvironment.isPad` resolve true so the iPad layout branch renders.
  #Preview("iPad Landscape", traits: .landscapeLeft) {
    RadioPlayerView(viewModel: PreviewMocks.makeViewModel(isPlaying: true))
      .tint(.orange)
  }
#endif
