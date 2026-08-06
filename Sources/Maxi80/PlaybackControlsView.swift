import Maxi80Model
import Maxi80Services
import SwiftUI

/// Playback controls, laid out as Option A (see `docs/CONTROL-BAR-design.md`): a big play/pause
/// hero on its own tier, above a balanced tray of three equal ghost-circle utility buttons —
/// Share · Sleep · Donate. The trio is balanced by construction (three equal circles, evenly
/// spaced), fixing the old "small · BIG · small" imbalance. The sleep countdown lives in the
/// reserved status slot in `RadioPlayerView` (`liveIndicator()`), so activating a timer causes no
/// reflow here; only the moon glyph toggles filled.
///
/// Requirements:
/// - 1.1, 1.2: Play/pause toggle
/// - 15.1, 15.2: Donation link button
/// - 17.1, 17.5: Share button (disabled when no metadata)
/// - 17.2, 17.3, 17.4: Share sheet with text + artwork
struct PlaybackControlsView: View {
  @Bindable var viewModel: RadioPlayerViewModel
  #if !os(Android)
    // Drives the SwiftUI `.shareSheet` (UIActivityViewController) on Apple platforms. Android never
    // uses it — the share button fires the native system chooser directly — so it's gated out there.
    @State var showShareSheet = false
  #endif
  // Presents the sleep-timer preset picker. A `.sheet` works on all platforms (unlike the share
  // sheet), so this state is not platform-gated.
  @State var showSleepTimerSheet = false
  /// 0 = light glyphs, 1 = dark glyphs. RadioPlayerView passes its animated `textDarkFade`
  /// here so the tray dissolves in lockstep with the song label and the background wash —
  /// icons and text flipping at different moments read as a glitch ("Christmas tree").
  /// Only Android renders from it (Apple uses semantic `.secondary`); declared on all
  /// platforms so call sites stay uniform.
  var contrastDarkFade: Double = 0
  #if os(Android)
    /// The two fixed contrast tints the crossfade dissolves between (colors are never
    /// animated directly — SkipUI renders color changes as single-frame snaps; only opacity
    /// is proven to fade cleanly).
    private static let lightControl = Color.white.opacity(0.7)
    private static let darkControl = Color.black.opacity(0.6)
  #endif

  var body: some View {
    VStack(spacing: tierSpacing) {
      playButton
      utilityTray
    }
    // The wash driver's `withAnimation` transaction does not propagate across the bridged
    // view boundary on Android — `contrastDarkFade` arrives as a plain parameter and the
    // contrast opacities would snap while the song label (inside the parent's transaction)
    // tweened. Re-create the tween locally with the explicit `.animation(_, value:)` SkipUI
    // honors (the carousel strip's proven layoutKey mechanism), covering BOTH tiers so the
    // play button's backing disc and the utility tray dissolve together. Curve and duration
    // MUST match the wash driver's crossfade so everything moves as one.
    #if os(Android)
      .animation(.easeInOut(duration: 0.5), value: contrastDarkFade)
    #endif
    #if os(macOS)
      // macOS gives buttons a default bezel/background; .plain keeps them transparent like iOS.
      .buttonStyle(.plain)
    #endif
    #if !os(Android)
      // Apple platforms present the share sheet here. On Android the button calls the native
      // chooser directly, so this modifier (and its backing state) are gated out entirely.
      .shareSheet(
        isPresented: $showShareSheet,
        text: { viewModel.shareMessage },
        imageData: { await viewModel.shareImageData() }
      )
    #endif
    .sheet(isPresented: $showSleepTimerSheet) {
      SleepTimerPickerSheet(viewModel: viewModel, isPresented: $showSleepTimerSheet)
    }
  }

  // MARK: - Sizing / spacing (per idiom)

  /// The roomier treatment used on iPad and macOS (both fill a large window); iPhone/Android phones
  /// keep the compact phone sizes. The same flag `RadioPlayerView` reads, so the two halves of the
  /// column can't disagree.
  private var usesExpandedLayout: Bool { PlatformEnvironment.usesExpandedLayout }

  /// Diameter of the play/pause hero disc.
  private var heroSize: CGFloat { usesExpandedLayout ? 84 : 72 }
  /// Diameter of each ghost-circle utility button (≥44pt touch target on phone).
  private var secondaryFrame: CGFloat { usesExpandedLayout ? 60 : 48 }
  /// Point size of the glyph inside each utility button, normalized so the differing symbol shapes
  /// share one visual center.
  private var secondaryGlyphSize: CGFloat { usesExpandedLayout ? 30 : 24 }
  /// Fixed spacing between the three utility buttons so the trio stays centered.
  private var traySpacing: CGFloat { usesExpandedLayout ? 44 : 28 }
  /// Gap between the hero tier and the utility tray.
  private var tierSpacing: CGFloat { usesExpandedLayout ? 28 : 20 }

  /// Tint for the utility glyphs and their ghost-circle backgrounds on Apple platforms, where
  /// `.secondary` already tracks the forced color scheme. Android doesn't use a single color:
  /// its contrast is an animated crossfade between fixed light/dark layers driven by
  /// `contrastDarkFade` (see `secondaryIcon`/`secondaryControl`) — computing a Color from the
  /// animated state here would snap, because animation interpolates animatable modifier data
  /// (opacity), not body re-evaluation.
  private var secondaryControlColor: Color {
    Color.secondary
  }

  // MARK: - Hero tier

  @ViewBuilder
  private var playButton: some View {
    Button {
      viewModel.togglePlayback()
    } label: {
      Group {
        if viewModel.isLoading {
          ProgressView()
            .tint(.orange)
        } else {
          #if os(Android)
            // SF Symbols don't exist on Android and `pause.*`/`play.circle.*` aren't in
            // SkipUI's core-icon map, so draw the extended Material icons directly. The
            // glyph is knocked out of the orange disc, so a small backing disc BEHIND the
            // icon shows through only the knockout, coloring the central play/pause shape —
            // white while the text/icons are white, black while they are dark, cross-faded
            // by the same `contrastDarkFade` (see the `.animation` on the VStack). The
            // backing circle is well inside the orange disc (the Material glyph occupies the
            // icon's center) so no ring ever shows around the button.
            ZStack {
              // Opaque white/black, not the tray's translucent tints: this disc is knocked out of
              // the orange glyph, so it must fully color the play/pause shape.
              contrastCrossfade(light: .white, dark: .black) { tint in
                Circle()
                  .fill(tint)
                  .frame(width: heroSize * 0.5, height: heroSize * 0.5)
              }
              AndroidIcon(
                symbol: viewModel.isPlaying ? .pause : .play, size: heroSize, tint: .orange)
            }
          #else
            Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
              .font(.system(size: heroSize))
              .foregroundStyle(.orange)
          #endif
        }
      }
      .frame(width: heroSize, height: heroSize)
    }
    .accessibilityLabel(
      viewModel.isPlaying
        ? Text("Pause", bundle: .module)
        : Text("Play", bundle: .module))
  }

  // MARK: - Utility tray tier

  /// Three equal ghost-circle buttons, evenly spaced. Order is Share · Sleep · Donate: Sleep (a
  /// session-mode action) sits centrally between the two "outbound" actions. Sleep drops out
  /// entirely when the `sleep_timer` flag is off — a switched-off feature should be absent, not a
  /// permanently dimmed mystery button — leaving Share · Donate evenly spaced.
  @ViewBuilder
  private var utilityTray: some View {
    HStack(spacing: traySpacing) {
      shareControl
      if viewModel.isSleepTimerAvailable {
        sleepControl
      }
      donateControl
    }
    // Contrast tween lives on the body's VStack (covers this tray AND the play button).
  }

  @ViewBuilder
  private var shareControl: some View {
    Button {
      #if os(Android)
        viewModel.shareCurrentTrackNatively()
      #else
        showShareSheet = true
      #endif
    } label: {
      secondaryControl {
        secondaryIcon(
          "square.and.arrow.up", android: .share,
          dim: viewModel.canShare ? 1.0 : 0.5)
      }
    }
    .disabled(!viewModel.canShare)
    .accessibilityLabel(Text("Share current track", bundle: .module))
  }

  @ViewBuilder
  private var sleepControl: some View {
    // A sleep timer only makes sense while audio is playing ("stop the music after N minutes"), so
    // the control is only enabled during playback. A running timer implies playback, so it stays
    // enabled then too.
    let isEnabled = viewModel.isPlaying || viewModel.isSleepTimerActive
    Button {
      showSleepTimerSheet = true
    } label: {
      secondaryControl {
        // moon.zzz.fill while a timer is running, moon.zzz idle. Android's single Bedtime crescent
        // is already filled, so the idle/active distinction there is carried by the countdown pill.
        secondaryIcon(
          viewModel.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz",
          android: .bedtime,
          fixedTint: viewModel.isSleepTimerActive ? .orange : nil,
          dim: isEnabled || viewModel.isSleepTimerActive ? 1.0 : 0.5)
      }
    }
    .disabled(!isEnabled)
    .accessibilityLabel(
      viewModel.isSleepTimerActive
        ? Text("Sleep timer active", bundle: .module)
        : Text("Set sleep timer", bundle: .module))
  }

  /// Donate: a `Link` when a donation URL exists, else a dimmed placeholder so the tray keeps a
  /// stable three-slot width.
  @ViewBuilder
  private var donateControl: some View {
    if let donationUrl = viewModel.station?.donationUrl,
      !donationUrl.isEmpty,
      let url = URL(string: donationUrl)
    {
      Link(destination: url) {
        secondaryControl {
          secondaryIcon("heart.circle", android: .favorite)
        }
      }
      // Link tints its label with the app accent (orange) by default; force the concrete
      // secondary gray so donate matches the share button. (Android's glyph carries its own
      // explicit two-layer tint, so the Link tint only matters on Apple platforms.)
      .tint(secondaryControlColor)
      .accessibilityLabel(Text("Support Maxi 80", bundle: .module))
    } else {
      secondaryControl {
        secondaryIcon("heart.circle", android: .favorite, dim: 0.5)
      }
      .accessibilityHidden(true)
    }
  }

  #if os(Android)
    /// Render `content` twice — once in the light contrast tint, once in the dark — and cross-fade
    /// the pair by `contrastDarkFade`, so the element dissolves between contrasts in lockstep with
    /// the background wash and the song label.
    ///
    /// Two layers rather than one animated color because SkipUI renders a color change as a
    /// single-frame snap; only opacity is proven to fade cleanly on Compose (see
    /// `SkipUI Android Animation Rules`). The tween itself lives on the body's `VStack`, so
    /// everything here moves on one curve.
    ///
    /// - Parameters:
    ///   - light/dark: the two fixed tints, defaulting to the tray's translucent pair. The play
    ///     button's knockout disc overrides them with opaque white/black.
    ///   - dim: a flat attenuation applied to both layers, carrying the disabled/placeholder
    ///     dimming that call sites used to bake into the tint's own opacity.
    @ViewBuilder
    private func contrastCrossfade<Content: View>(
      light: Color = Self.lightControl,
      dark: Color = Self.darkControl,
      dim: Double = 1,
      @ViewBuilder content: (Color) -> Content
    ) -> some View {
      ZStack {
        content(light).opacity((1 - contrastDarkFade) * dim)
        content(dark).opacity(contrastDarkFade * dim)
      }
    }
  #endif

  // MARK: - Ghost-circle wrapper

  /// Wrap a utility glyph in a subtle circular background so the three read as deliberate peer
  /// buttons rather than bare glyphs, preserving a ≥44pt hit target. On Android the circle is
  /// two fixed-tint layers cross-faded by `contrastDarkFade`, matching the glyphs.
  @ViewBuilder
  private func secondaryControl<Label: View>(@ViewBuilder label: () -> Label) -> some View {
    #if os(Android)
      label()
        .frame(width: secondaryFrame, height: secondaryFrame)
        .background(
          contrastCrossfade { tint in
            Circle().fill(tint.opacity(0.12))
          }
        )
    #else
      label()
        .frame(width: secondaryFrame, height: secondaryFrame)
        .background(Circle().fill(secondaryControlColor.opacity(0.12)))
    #endif
  }

  /// A secondary control glyph normalized to a fixed size and square frame so the tray buttons
  /// align and read as the same size despite their different symbol shapes.
  ///
  /// On Apple platforms this renders the SF Symbol tinted via `.foregroundStyle`. On Android SF
  /// Symbols don't exist (and several of these aren't in SkipUI's core-icon map), so it draws the
  /// matching extended Material icon — as TWO fixed-tint layers (light under, dark over)
  /// cross-faded by `contrastDarkFade`, so the glyph dissolves in lockstep with the song label
  /// and wash. `fixedTint` (the sleep timer's active orange) bypasses the contrast crossfade;
  /// `dim` carries the disabled/placeholder attenuation that call sites previously baked into
  /// the tint's opacity.
  @ViewBuilder
  private func secondaryIcon(
    _ systemName: String, android: MaterialSymbol, fixedTint: Color? = nil, dim: Double = 1
  ) -> some View {
    #if os(Android)
      if let fixedTint {
        AndroidIcon(symbol: android, size: secondaryGlyphSize, tint: fixedTint)
          .frame(width: secondaryGlyphSize, height: secondaryGlyphSize)
      } else {
        contrastCrossfade(dim: dim) { tint in
          AndroidIcon(symbol: android, size: secondaryGlyphSize, tint: tint)
        }
        .frame(width: secondaryGlyphSize, height: secondaryGlyphSize)
      }
    #else
      Image(systemName: systemName)
        .font(.system(size: secondaryGlyphSize))
        .frame(width: secondaryGlyphSize, height: secondaryGlyphSize)
        .foregroundStyle((fixedTint ?? secondaryControlColor).opacity(dim))
    #endif
  }
}

// MARK: - Sleep Countdown Pill

/// The running-timer pill shown in the reserved status slot, styled like the "Back to live" pill:
/// a moon glyph + a live `MM:SS` count + an `✕` to cancel. Tapping the count re-opens the picker to
/// extend/change the duration.
///
/// The 1-second tick comes from `PeriodicClock`, which owns the per-platform mechanism.
struct SleepCountdownPill: View {
  @Bindable var viewModel: RadioPlayerViewModel
  @Binding var showPicker: Bool

  var body: some View {
    PeriodicClock(interval: 1) { now in
      SleepCountdownPillBody(viewModel: viewModel, showPicker: $showPicker, now: now)
    }
  }
}

/// The static pill content for a given `now`, shared by the Apple `TimelineView` and the Android
/// `Task`-ticked wrapper.
struct SleepCountdownPillBody: View {
  @Bindable var viewModel: RadioPlayerViewModel
  @Binding var showPicker: Bool
  let now: Date

  var body: some View {
    let countdown = viewModel.sleepCountdownText(now: now) ?? "0:00"
    HStack(spacing: 8) {
      Button {
        showPicker = true
      } label: {
        HStack(spacing: 6) {
          #if os(Android)
            AndroidIcon(symbol: .bedtime, size: 15, tint: .orange)
          #else
            Image(systemName: "moon.zzz.fill")
          #endif
          countdownLabel(countdown)
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(verbatim: SleepTimerFormatting.remainingLabel(countdown)))

      Button {
        withAnimation(.easeInOut) { viewModel.cancelSleepTimer() }
      } label: {
        #if os(Android)
          Text(verbatim: "✕")
        #else
          Image(systemName: "xmark")
        #endif
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Cancel", bundle: .module))
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    // Deliberately quieter than the solid-orange play/pause hero: a soft tinted capsule with orange
    // text + a hairline border, so the countdown reads as secondary status rather than competing
    // with the primary transport control.
    .background(Color.orange.opacity(0.15), in: Capsule())
    .overlay(Capsule().stroke(Color.orange.opacity(0.4), lineWidth: 1))
    .foregroundStyle(.orange)
  }

  /// The countdown time label. `monospacedDigit()` keeps the pill width steady as digits change,
  /// but isn't in SkipUI's surface, so it's applied only on Apple platforms.
  @ViewBuilder
  private func countdownLabel(_ countdown: String) -> some View {
    #if os(Android)
      Text(verbatim: countdown)
    #else
      Text(verbatim: countdown).monospacedDigit()
    #endif
  }
}

// MARK: - Sleep Timer Picker Sheet

/// Preset-only sleep-timer picker (15 / 30 / 45 / 60 / 90 min) presented as a single row of light
/// duration chips — orange reads as an accent, not five solid slabs. Selecting a chip starts the
/// timer and dismisses. While a timer runs, the sheet also shows the remaining time and offers
/// Extend / Turn off; otherwise a quiet Cancel closes it without changing anything.
struct SleepTimerPickerSheet: View {
  @Bindable var viewModel: RadioPlayerViewModel
  @Binding var isPresented: Bool

  var body: some View {
    VStack(spacing: 24) {
      Capsule()
        .fill(Color.secondary.opacity(0.4))
        .frame(width: 36, height: 5)
        .padding(.top, 10)

      VStack(spacing: 6) {
        Text("Sleep timer", bundle: .module)
          .font(.headline)

        if viewModel.isSleepTimerActive {
          // Surface the running countdown so the sheet doubles as the management screen.
          SleepTimerSheetRemaining(viewModel: viewModel)
        } else {
          Text("Stop playback after", bundle: .module)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 6) {
        ForEach(RadioPlayerViewModel.sleepTimerPresets, id: \.self) { minutes in
          Button {
            viewModel.startSleepTimer(minutes: minutes)
            isPresented = false
          } label: {
            DurationChipLabel(minutes: minutes)
          }
          .buttonStyle(.plain)
        }
      }
      Text("minutes", bundle: .module)
        .font(.caption)
        .foregroundStyle(.secondary)

      // While a timer is running, offer a quick extend (folds +15 min onto the remaining time) and
      // a way to turn it off entirely, in addition to picking a fresh preset above.
      if viewModel.isSleepTimerActive {
        HStack(spacing: 12) {
          Button {
            viewModel.extendSleepTimer(minutes: 15)
            isPresented = false
          } label: {
            Text("Extend", bundle: .module)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.orange)
              .padding(.vertical, 10)
              .padding(.horizontal, 20)
              .overlay(Capsule().stroke(.orange, lineWidth: 1))
          }
          .buttonStyle(.plain)

          Button {
            viewModel.cancelSleepTimer()
            isPresented = false
          } label: {
            Text("Turn off", bundle: .module)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.vertical, 10)
              .padding(.horizontal, 20)
              .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
          }
          .buttonStyle(.plain)
        }
        .padding(.top, 4)
      } else {
        Button {
          isPresented = false
        } label: {
          Text("Cancel", bundle: .module)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
      }
    }
    // No trailing Spacer: on Android the sheet is a Compose ModalBottomSheet that wraps its content
    // height, so a height-filling Spacer forced it to open near full-screen with the content
    // stranded in the top third. Without it the sheet sizes to its content. iOS keeps the medium
    // detent below (`presentationDetents` isn't in SkipUI's surface, so it's Apple-only).
    .padding(.horizontal, 24)
    .padding(.top, 8)
    .padding(.bottom, 28)
    .presentationDetentsMediumIfAvailable()
  }
}

/// A single duration chip: a light tinted capsule with orange text — the accent-not-slab treatment
/// that keeps the row airy. Flexible width (each chip takes an equal share of the row) so the row
/// fits any number of presets without overflowing the phone width; a fixed height keeps it readable.
struct DurationChipLabel: View {
  let minutes: Int

  var body: some View {
    Text(verbatim: "\(minutes)")
      .font(.body.weight(.semibold))
      .foregroundStyle(.orange)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      // Fixed HEIGHT + flexible width. The height must stay concrete: on Android the sheet (a
      // Compose ModalBottomSheet) presents tall on first open then animates down to the detent; its
      // content Box fills the remaining height via Modifier.weight(1), so a chip with no fixed
      // height gets vertically compressed during that pass into unreadable slivers (issue #56). The
      // width flexes so 5 or 7 (or more) presets share the row evenly instead of overflowing.
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .background(Color.orange.opacity(0.12), in: Capsule())
      .overlay(Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 1))
      .accessibilityLabel(Text(SleepTimerFormatting.minutesLabel(minutes)))
  }
}

/// The live "MM:SS remaining" line shown in the sheet while a timer is active. Ticks via the same
/// `PeriodicClock` as the countdown pill and reuses the view model's countdown formatter.
///
/// Sharing that clock also gives Android a ticking readout here for the first time: this view used to
/// pass a bare `Date()` on the Android branch, so the sheet's remaining time froze at whatever it was
/// when the sheet opened.
struct SleepTimerSheetRemaining: View {
  @Bindable var viewModel: RadioPlayerViewModel

  var body: some View {
    PeriodicClock(interval: 1) { now in
      SleepTimerSheetRemainingBody(viewModel: viewModel, now: now)
    }
  }
}

struct SleepTimerSheetRemainingBody: View {
  @Bindable var viewModel: RadioPlayerViewModel
  let now: Date

  var body: some View {
    let countdown = viewModel.sleepCountdownText(now: now) ?? "0:00"
    Text(verbatim: SleepTimerFormatting.remainingLabel(countdown))
      .font(.subheadline.weight(.medium))
      .foregroundStyle(.orange)
  }
}

/// Formatting helpers for sleep-timer duration/countdown strings. All lookups use `Bundle.module`
/// so the label localizes; `%d min` is the single format string in the catalog.
enum SleepTimerFormatting {
  /// A localized "%d min" label for a preset duration.
  static func minutesLabel(_ minutes: Int) -> String {
    let format = Bundle.module.localizedString(forKey: "%d min", value: nil, table: nil)
    return String(format: format, minutes)
  }

  /// A localized "%@ remaining" accessibility label wrapping the bare MM:SS countdown string.
  static func remainingLabel(_ countdown: String) -> String {
    let format = Bundle.module.localizedString(forKey: "%@ remaining", value: nil, table: nil)
    return String(format: format, countdown)
  }
}

extension View {
  /// Size the sleep-timer sheet.
  ///
  /// SkipUI honors `presentationDetents` on Android (it insets the Compose ModalBottomSheet by the
  /// detent height), but it does NOT support multiple detents — it takes `Set.first`, and a Swift
  /// `Set` has no defined order, so passing a two-element set makes the sheet open at a random one
  /// of the two heights across opens (the shorter one clips the bottom buttons — issue observed on
  /// device). So on Android pass a SINGLE detent for a deterministic height.
  ///
  /// iOS/iPadOS supports multiple detents fine, so there it opens compact (0.35) and stays draggable
  /// up to medium. macOS sheets aren't detented.
  @ViewBuilder
  func presentationDetentsMediumIfAvailable() -> some View {
    #if os(Android)
      // Single deterministic detent, tall enough that the picker's title, chip row, and the
      // Cancel/Extend row all fit without clipping.
      self.presentationDetents([.medium])
    #elseif !os(macOS)
      self.presentationDetents([.fraction(0.35), .medium])
    #else
      self
    #endif
  }
}

// MARK: - Preview

#if ENABLE_PREVIEWS
  #Preview("Playing with Metadata") {
    PlaybackControlsView(viewModel: PreviewMocks.makeViewModel(isPlaying: true))
      .padding()
      .background(Color(red: 0.15, green: 0.1, blue: 0.3))
  }

  #Preview("Paused — Share Disabled") {
    PlaybackControlsView(viewModel: PreviewMocks.makeViewModel(hasMetadata: false))
      .padding()
      .background(Color(red: 0.15, green: 0.1, blue: 0.3))
  }

  #Preview("Sleep Timer Sheet — Idle") {
    SleepTimerPickerSheet(
      viewModel: PreviewMocks.makeViewModel(isPlaying: true),
      isPresented: .constant(true))
  }

  #Preview("Sleep Timer Sheet — Active") {
    let vm = PreviewMocks.makeViewModel(isPlaying: true)
    vm.startSleepTimer(minutes: 30)
    return SleepTimerPickerSheet(viewModel: vm, isPresented: .constant(true))
  }
#endif
