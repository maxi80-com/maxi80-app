import Maxi80Services
import SwiftUI

extension RadioPlayerView {

  // MARK: - Song Label

  /// The song-info block for the browsed/live track: artist on the big primary line, song name on
  /// the secondary line, and the browsed entry's air time — placed per `inlineHistoryTime`, since
  /// portrait and landscape have opposite vertical budgets. `SongLabelView` renders all three; this
  /// wrapper supplies the phone's sizes/contrast and the Android tear workaround below.
  ///
  /// `inlineHistoryTime` and `maxLines` are independent, because the layouts need them in different
  /// combinations: the phone's landscape column is short enough to want both the inline air time and
  /// a one-line cap, while the expanded landscape column has the height for a third air-time line but
  /// still wants the cap, since a constant label height is what keeps the column from resizing the
  /// height-linked row it shares with the carousel.
  @ViewBuilder
  func songLabel(
    inlineHistoryTime: Bool = false,
    maxLines: Int = 2,
    contrastOverride: ContrastStyle? = nil
  ) -> some View {
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
      maxLines: maxLines,
      contrast: contrastOverride ?? contrast
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
  func liveIndicator() -> some View {
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
  func volumeControl() -> some View {
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
  var versionFooter: some View {
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

  func errorBanner(message: String) -> some View {
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
