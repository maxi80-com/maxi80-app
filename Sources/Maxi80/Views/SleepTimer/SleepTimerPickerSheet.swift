import SwiftUI

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
