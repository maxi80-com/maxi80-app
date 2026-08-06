import Maxi80Model
import Maxi80Services
import SwiftUI

/// Root view of the Maxi80 radio player.
///
/// The hero is a Cover Flow carousel of the session's song history: the live track sits at
/// the right edge; swiping right browses older covers in 3D. The background is a gradient
/// derived from the current artwork's dominant color, falling back to a colorScheme-appropriate
/// solid when no artwork color is available. Layout adapts between portrait and landscape.
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
  private var playbackControlsContrastFade: Double {
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

  // MARK: - Background

  /// Background wash with a fade between artwork colors — per-platform mechanisms because
  /// their animation systems fail in opposite ways:
  ///
  /// - **Apple**: the native implicit `.animation(_, value:)` over the branch interpolates
  ///   gradient colors smoothly (this is the pre-crossfade original — it never flashed).
  /// - **Android**: SkipUI renders that same modifier as a single-frame swap, so Android
  ///   runs two persistent ping-pong wash layers whose colors are only ever written while
  ///   invisible and whose opacities are only ever animated (the flash-proofing rules — see
  ///   the `washAColor` declaration). The crossfade dissolves old→new directly, no dip
  ///   through the brand base. Purely presentational here; the driver lives on the MAIN view
  ///   tree in `body`, because on SkipUI/Android lifecycle modifiers attached to
  ///   `.background {}` content never fire.
  ///
  ///   A scheme-neutral base sits UNDER the washes so a shown wash composites over the same
  ///   light/dark system background iOS uses — NOT over the dark neon-dusk brand, which
  ///   multiplied every color darker than iOS. Its opacity tracks how much wash is showing
  ///   (`max(washAFade, washBFade)`), so it covers the brand exactly while a color is
  ///   present and fades away with the wash to reveal the brand on the live slot. During a
  ///   color→color crossfade one fade rises as the other falls, so the max stays high and
  ///   the neutral base never dips (no mid-fade darkening).
  @ViewBuilder
  private func dynamicBackground(isPortrait: Bool) -> some View {
    #if os(Android)
      ZStack {
        brandBackground()
        (colorScheme == .dark ? Color.black : Color.white)
          .opacity(max(washAFade, washBFade))
          .animation(.easeInOut(duration: 0.5), value: washAFade)
          .animation(.easeInOut(duration: 0.5), value: washBFade)
        if let a = washAColor {
          washGradient(a, isPortrait: isPortrait)
            .opacity(washAFade * washMaxOpacity)
            // Implicit tween per layer: the driver writes fade targets in a plain commit
            // and this animates the rendered opacity Compose-side (same mechanism as the
            // tray/play-button; must match their curve+duration so all dissolve as one).
            .animation(.easeInOut(duration: 0.5), value: washAFade)
        }
        if let b = washBColor {
          washGradient(b, isPortrait: isPortrait)
            .opacity(washBFade * washMaxOpacity)
            .animation(.easeInOut(duration: 0.5), value: washBFade)
        }
      }
    #else
      Group {
        if let color = viewModel.dominantColor {
          washGradient(color, isPortrait: isPortrait)
            .opacity(washMaxOpacity)
        } else {
          brandBackground()
        }
      }
      .animation(.easeInOut(duration: 0.5), value: viewModel.dominantColor)
    #endif
  }

  /// Artwork-driven soft wash of a cover's dominant color. Shape shared with the TV UI.
  private func washGradient(_ color: Color, isPortrait: Bool) -> some View {
    BrandedWash.wash(color, isPortrait: isPortrait)
  }

  /// Peak wash opacity over the brand base (the pre-crossfade constant, unchanged).
  private var washMaxOpacity: Double {
    colorScheme == .dark ? 0.9 : 0.4
  }

  /// Stable identity for the current artwork color, `nil` on the brand background. `Color`
  /// equality is unreliable across the Skip bridge; the raw RGB is not.
  private var dominantColorKey: String? {
    guard let rgb = viewModel.dominantRGB else { return nil }
    return "\(rgb.red)-\(rgb.green)-\(rgb.blue)"
  }

  /// Default on-brand background when no artwork color is available. Shape shared with the TV UI —
  /// see `BrandedWash.brand`.
  @ViewBuilder
  private func brandBackground() -> some View {
    BrandedWash.brand()
  }

  // MARK: - Layout Sizing

  /// Whether to use the roomier "big canvas" treatment (enlarged hero + capped info/controls
  /// column) instead of the phone layout. Shared with `PlaybackControlsView`, which renders the
  /// lower half of the same column and must make the same choice.
  private var usesExpandedLayout: Bool { PlatformEnvironment.usesExpandedLayout }

  /// Width cap for the info/controls column in the expanded landscape layout.
  private let expandedColumnWidth: CGFloat = 420
  private let expandedHSpacing: CGFloat = 24
  private let expandedHPadding: CGFloat = 24

  /// Hero size for the expanded layouts, derived from the width actually available to the carousel
  /// so its left/right neighbor covers always peek through — a fixed size clipped them on narrower
  /// windows (macOS) even though it fit the iPad. Sized as a fraction of the carousel's own cell
  /// width and capped so it never grows absurdly large on very wide displays.
  private func expandedCoverSize(containerWidth: CGFloat, isLandscape: Bool) -> CGFloat {
    let carouselWidth: CGFloat
    if isLandscape {
      // Left cell of the HStack: total minus padding, inter-column spacing, and the capped column.
      carouselWidth = containerWidth - expandedHPadding * 2 - expandedHSpacing - expandedColumnWidth
    } else {
      carouselWidth = containerWidth
    }
    // ~58% of the cell leaves ~21% on each side for the neighbor covers to show.
    let cap: CGFloat = isLandscape ? 560 : 460
    return max(260, min(cap, carouselWidth * 0.58))
  }

  // Phone-portrait column paddings/spacing — named so the same values feed both the layout and the
  // adaptive-hero chrome budget below (rather than being hardcoded in two places).
  private static let phonePortraitVSpacing: CGFloat = 20
  private static let phonePortraitTopPadding: CGFloat = 12
  // Clearance for the pinned bottom footer. Sized for the brand-logo row (~22pt tall) plus a
  // small margin above it, so the volume row never sits under the logo/version stamp.
  private static let phonePortraitBottomPadding: CGFloat = 36

  /// Estimated height of the non-hero *subviews* in phone portrait — song labels + status slot +
  /// two-tier controls + volume row. Kept separate from the paddings/spacing (which are derived
  /// from the named constants above) so only this genuine content estimate is hand-tuned. If those
  /// subviews change materially, update this one number. Verified against iPhone SE → Pro Max.
  /// (This is only the subviews estimate; the derived chrome total adds paddings + gaps below.)
  private static let phonePortraitSubviewsHeight: CGFloat = 332

  /// Total fixed chrome height the adaptive hero must leave room for: the subview estimate plus the
  /// column's own paddings and the 4 inter-element gaps (5 children → 4 spacings).
  private static var phonePortraitChromeHeight: CGFloat {
    phonePortraitSubviewsHeight
      + phonePortraitTopPadding + phonePortraitBottomPadding
      + phonePortraitVSpacing * 4
  }

  /// Phone-portrait hero size, adapted to the container height so the spacer-free column always
  /// fills the screen exactly — the hero takes all the slack left after the fixed chrome (labels,
  /// status slot, two-tier controls, volume row, paddings, and footer clearance). The hero renders
  /// at `coverSize + 80` tall (its internal vertical margins). Capped at 320 so very tall phones
  /// don't inflate it past a sensible hero, floored at 160 so shorter phones still show a usable
  /// carousel rather than clipping.
  ///
  /// ALSO capped by width: tall-aspect Android phones have enough vertical slack to hit the 320
  /// height cap, but 320 on a ~411dp-wide screen fills it edge-to-edge and the previous/next
  /// covers can't peek through. ~62% of the width leaves ~19% per side for the neighbors (same
  /// idea as the 58% used by the landscape/expanded layouts, slightly roomier because portrait
  /// has no second column). On iPhones the height term is already the binding cap, so this
  /// doesn't change the iOS layout.
  private func phonePortraitCoverSize(
    containerWidth: CGFloat, containerHeight: CGFloat
  ) -> CGFloat {
    let heroChrome: CGFloat = 80  // CoverFlowView's verticalMargin * 2
    let available = containerHeight - Self.phonePortraitChromeHeight - heroChrome
    return max(160, min(320, min(available, containerWidth * 0.62)))
  }

  /// Hero size for the compact (phone) landscape layout. The old fixed 260pt default filled the
  /// carousel's whole cell, so the previous/next covers never peeked through. The HStack splits
  /// the width roughly in half between the strip and the info/controls column; size the hero as
  /// ~58% of the strip's share (same fraction as the expanded layouts) so ~21% shows on each side.
  private func compactLandscapeCoverSize(containerWidth: CGFloat) -> CGFloat {
    let carouselWidth = (containerWidth - expandedHSpacing) / 2
    return max(160, min(260, carouselWidth * 0.58))
  }

  // MARK: - Portrait Layout

  @ViewBuilder
  private func portraitView(containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
    if usesExpandedLayout {
      // iPad's tall canvas: anchor the enlarged hero + song info near the top and the controls
      // near the bottom, with flexible air between the two groups so the space reads as
      // intentional breathing room rather than one empty void above everything.
      VStack(spacing: 28) {
        Spacer().frame(height: 32)
        coverFlow(coverSize: expandedCoverSize(containerWidth: containerWidth, isLandscape: false))
        songLabel()
        liveIndicator()
        Spacer()
        PlaybackControlsView(
          viewModel: viewModel, contrastDarkFade: playbackControlsContrastFade)
        Spacer().frame(height: 32)
        // The volume row would otherwise stretch edge-to-edge on iPad's wide portrait canvas;
        // cap it so it sits as a centered cluster with generous side insets.
        volumeControl()
          .frame(maxWidth: 520)
        Spacer().frame(height: 48)
      }
    } else {
      // No flexible spacers: they let the column overflow on shorter phones (collapsing to 0 and
      // pushing the footer off-screen) while leaving a dead gap on taller ones. Instead the hero
      // absorbs all the slack — it's sized to exactly the height left after the fixed chrome, so the
      // column always fills the screen precisely: nothing clips, and the coverflow (the app's key
      // element) is as large as the device allows.
      VStack(spacing: Self.phonePortraitVSpacing) {
        coverFlow(
          coverSize: phonePortraitCoverSize(
            containerWidth: containerWidth, containerHeight: containerHeight))

        songLabel()

        liveIndicator()

        PlaybackControlsView(
          viewModel: viewModel, contrastDarkFade: playbackControlsContrastFade)

        volumeControl()
      }
      .padding(.top, Self.phonePortraitTopPadding)
      .padding(.bottom, Self.phonePortraitBottomPadding)  // clearance for the pinned version footer
    }
  }

  // MARK: - Landscape Layout

  @ViewBuilder
  private func landscapeView(containerWidth: CGFloat) -> some View {
    if usesExpandedLayout {
      // iPad / macOS landscape: let the hero fill the left half and vertically center the info +
      // controls as one block in the right half (title/artist/back-to-live sat too high before).
      HStack(spacing: expandedHSpacing) {
        coverFlow(coverSize: expandedCoverSize(containerWidth: containerWidth, isLandscape: true))
        VStack(spacing: 24) {
          Spacer()
          songLabel(inlineHistoryTime: true)
          liveIndicator()
          Spacer().frame(height: 32)
          PlaybackControlsView(
            viewModel: viewModel, contrastDarkFade: playbackControlsContrastFade)
          Spacer().frame(height: 32)
          volumeControl()
          Spacer()
        }
        // Cap the info/controls column so the hero keeps enough horizontal room for its
        // left/right neighbor covers to stay on screen (they were clipping when the column
        // expanded to fill half the width), while still giving the title/controls real presence.
        .frame(maxWidth: expandedColumnWidth)
      }
      .padding(.horizontal, expandedHPadding)
    } else {
      HStack(spacing: 24) {
        coverFlow(coverSize: compactLandscapeCoverSize(containerWidth: containerWidth))

        VStack(spacing: 16) {
          Spacer()
          songLabel(inlineHistoryTime: true)
          liveIndicator()
          Spacer()
          PlaybackControlsView(
            viewModel: viewModel, contrastDarkFade: playbackControlsContrastFade)
          volumeControl()
          Spacer()
        }
      }
      .padding()
    }
  }

  // MARK: - Cover Flow Hero

  /// The hero carousel. `coverSize` lets each layout size the hero for its canvas — iPad portrait
  /// and (especially) landscape have room for a much larger hero than the phone default. When a
  /// caller doesn't specify, fall back to a per-idiom default: enlarged on iPad, 260 elsewhere.
  @ViewBuilder
  private func coverFlow(coverSize: CGFloat? = nil) -> some View {
    CoverFlowCarousel(
      viewModel: viewModel,
      coverSize: coverSize ?? (PlatformEnvironment.isPad ? 380 : 260)
    )
    .accessibilityLabel(
      Text("Song history. Swipe to browse previously played tracks.", bundle: .module))
  }

  // MARK: - Song Label

  /// The song-info block for the browsed/live track: artist on the big primary line, song name on
  /// the secondary line, and the browsed entry's air time — placed per `inlineHistoryTime`, since
  /// portrait and landscape have opposite vertical budgets. `SongLabelView` renders all three; this
  /// wrapper supplies the phone's sizes/contrast and the Android tear workaround below.
  @ViewBuilder
  private func songLabel(inlineHistoryTime: Bool = false) -> some View {
    // Both platforms render the label's color INSTANTLY (no fade): the title/artist STRING
    // changes in the same view update as the contrast decision, so the new text appears in
    // its final color from its first frame — matching iOS. Fading is reserved for elements
    // that persist across the change (wash, icons, play glyph — see `textDarkFade`).
    //
    // REVERT-OPTION(text-contrast-fade): if instant-correct-color proves unachievable on
    // Android, restore the two-layer fade that shipped briefly on 2026-08-04: a
    // `contrastFadingText(_:size:weight:light:dark:)` helper rendering each line as TWO
    // pixel-aligned Text layers (light tint under, dark over, identical font/lineLimit/
    // minimumScaleFactor) cross-faded by `.opacity(1 - textDarkFade)` / `.opacity(textDarkFade)`
    // — accepting that a new string then appears in the outgoing color and dissolves.
    let label = SongLabelView(
      primary: viewModel.displayedArtist,
      secondary: viewModel.displayedTitle,
      airDate: viewModel.focusedEntryDate,
      primarySize: titleFontSize,
      secondarySize: subtitleFontSize,
      airTimeSize: airTimeFontSize,
      inlineAirTime: inlineHistoryTime,
      contrast: contrast
    )
    .padding(.horizontal, 20)

    #if os(Android)
      // The string and its color are computed together but reach Compose as SEPARATE updates
      // to an existing node, and the bridge can render one a frame before the other (the
      // measured tear class) — briefly showing the new title in the old color. Structural
      // replacement, by contrast, lands in a single frame on SkipUI (measured: it's why
      // `.transition` snaps). Exploit that: key the label on the contrast decision, so a
      // flip REPLACES the whole label — new string and new color born together, no tear.
      label.id(viewModel.isBackgroundDark)
    #else
      label.accessibilityElement(children: .combine)
    #endif
  }

  /// Song title / artist point sizes. SkipUI maps SwiftUI's semantic font styles (`.largeTitle`,
  /// `.title`) to noticeably larger Material text sizes on Android, so the title wrapped to two
  /// lines there while fitting one on iOS. Use explicit sizes per platform: a touch larger on
  /// Apple, smaller on Android, to match visually.
  private var titleFontSize: CGFloat {
    #if os(Android)
      26
    #else
      if usesExpandedLayout {
        38  // iPad and macOS
      } else {
        26  // iPhone
      }
    #endif
  }

  private var subtitleFontSize: CGFloat {
    #if os(Android)
      19
    #else
      if usesExpandedLayout {
        30  // iPad and macOS
      } else {
        19  // iPhone
      }
    #endif
  }

  /// Point size for the discreet "Played at …" air-time line. A step smaller than the artist so it
  /// reads as secondary metadata; larger on the roomy iPad/macOS canvas to match the bigger title.
  private var airTimeFontSize: CGFloat {
    #if os(Android)
      13
    #else
      usesExpandedLayout ? 16 : 13  // iPad and macOS : iPhone
    #endif
  }

  /// The title/subtitle colors for text over the wash. `ContrastStyle.phone` owns the per-platform
  /// rule (semantic on Apple, luminance-derived on Android) that this view and `TVRadioPlayerView`
  /// used to each spell out.
  private var contrast: ContrastStyle {
    .phone(isBackgroundDark: viewModel.isBackgroundDark)
  }

  private var titleColor: Color { contrast.title }
  private var subtitleColor: Color { contrast.subtitle }

  // MARK: - Back to Live

  @ViewBuilder
  private func liveIndicator() -> some View {
    // The reserved status slot. Both states can be active at once — a sleep timer runs while the
    // user scrolls into history — so show them side-by-side on a single row rather than letting one
    // hide the other or stacking them (stacking pushed the volume row off-screen in landscape).
    // When neither is active a clear spacer holds the height.
    if viewModel.isBrowsingHistory || viewModel.isSleepTimerActive {
      HStack(spacing: 8) {
        if viewModel.isBrowsingHistory {
          Button {
            withAnimation(.easeInOut) { viewModel.returnToLive() }
          } label: {
            backToLiveLabel
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 14)
              .padding(.vertical, 7)
              .background(.orange, in: Capsule())
              .foregroundStyle(.white)
          }
          .buttonStyle(.plain)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if viewModel.isSleepTimerActive {
          SleepCountdownPill(viewModel: viewModel, showPicker: $showSleepTimerSheet)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .sheet(isPresented: $showSleepTimerSheet) {
        SleepTimerPickerSheet(viewModel: viewModel, isPresented: $showSleepTimerSheet)
      }
    } else {
      // Reserve consistent vertical space so the layout doesn't jump.
      Color.clear.frame(height: 32)
    }
  }

  /// "Back to live" pill content. The `dot.radiowaves.left.and.right` SF Symbol has no SkipUI
  /// Material mapping, so on Android draw the closest extended icon (broadcast waves) beside the
  /// text; Apple keeps the SF Symbol label.
  @ViewBuilder
  private var backToLiveLabel: some View {
    #if os(Android)
      HStack(spacing: 6) {
        AndroidIcon(symbol: .liveBroadcast, size: 15, tint: .white)
        Text("Back to live", bundle: .module)
      }
    #else
      Label {
        Text("Back to live", bundle: .module)
      } icon: {
        Image(systemName: "dot.radiowaves.left.and.right")
      }
    #endif
  }

  // MARK: - Volume Control

  @ViewBuilder
  private func volumeControl() -> some View {
    #if !SKIP
      VolumeSliderView(viewModel: viewModel)
        .padding(.horizontal)
    #endif
  }

  // MARK: - Version Footer

  /// The bottom-edge chrome pinned across the full width in both orientations (the TV, CarPlay,
  /// and Android Auto UIs are separate entry points and never render this view): the tappable
  /// Maxi 80 brand logo on the leading edge, the discreet build stamp on the trailing edge. The
  /// version string is extracted per-platform by `AppVersion`; the styling is identical on both.
  @ViewBuilder
  private var versionFooter: some View {
    HStack(alignment: .bottom) {
      brandLogo
      Spacer(minLength: 12)
      Text(verbatim: AppVersion.displayString)
        .font(.system(size: 10))
        .foregroundStyle(subtitleColor.opacity(0.6))
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 4)
  }

  /// The Maxi 80 neon logo — a `Link` so a tap opens the station website in the system browser
  /// (the same cross-platform pattern as the donate button; `Link` routes through `openURL`,
  /// which launches the external browser on both iOS and Android). Sized as a small footer mark.
  @ViewBuilder
  private var brandLogo: some View {
    let logo = Image("Maxi80Logo", bundle: .module)
      .resizable()
      .scaledToFit()
      .frame(height: 22)
      .opacity(0.8)
      .accessibilityLabel(Text(verbatim: BrandConstants.name))

    if let url = URL(string: BrandConstants.websiteURL) {
      Link(destination: url) { logo }
    } else {
      logo
    }
  }

  // MARK: - Error Banner

  private func errorBanner(message: String) -> some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)

      Text(verbatim: message)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .lineLimit(2)

      Spacer()

      Button {
        viewModel.retry()
      } label: {
        Text("Retry", bundle: .module)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal)
    .padding(.top, 8)
    .transition(.move(edge: .top).combined(with: .opacity))
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
