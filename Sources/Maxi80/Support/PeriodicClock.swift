import SwiftUI

/// Feeds its content a `Date` that refreshes every `interval` seconds, so a countdown can be
/// computed fresh from a stored absolute fire time rather than ticked into observable state.
///
/// The mechanism is platform-split because `TimelineView` isn't in SkipUI's surface: Apple uses it
/// directly, while Android re-reads the clock into `@State` from a `Task`. Both sleep-timer readouts
/// (the status-slot countdown pill and the picker sheet's remaining line) need exactly this, and each
/// had its own copy of the split — including one that was silently wrong (`SleepTimerSheetRemaining`
/// passed a bare `Date()` on Android with no ticker at all, so the sheet's countdown never advanced
/// while it was open). Having one implementation is what fixes that: there is no second copy left to
/// forget the ticker.
///
/// No `Timer` and no Combine on either path, per the project's concurrency conventions.
struct PeriodicClock<Content: View>: View {
  /// Seconds between ticks.
  let interval: TimeInterval
  @ViewBuilder let content: (Date) -> Content

  #if os(Android)
    // Internal, not private: Skip's bridge requires @State properties to be non-private.
    @State var now = Date()
  #endif

  var body: some View {
    #if os(Android)
      content(now)
        .task {
          while !Task.isCancelled {
            now = Date()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
          }
        }
    #else
      TimelineView(.periodic(from: Date(), by: interval)) { context in
        content(context.date)
      }
    #endif
  }
}
