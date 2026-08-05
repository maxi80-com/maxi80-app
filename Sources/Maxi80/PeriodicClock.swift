import SwiftUI

/// A platform-split clock that provides a periodically-refreshed `Date` to its content.
///
/// On Apple platforms this wraps `TimelineView(.periodic(from:by:))`. On Android (SkipUI, which
/// lacks `TimelineView`), a `Task`-driven `@State` clock ticks at the given interval.
struct PeriodicClock<Content: View>: View {
  let interval: TimeInterval
  @ViewBuilder let content: (Date) -> Content

  #if os(Android)
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
      TimelineView(.periodic(from: .now, by: interval)) { context in
        content(context.date)
      }
    #endif
  }
}
