import SwiftUI

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
