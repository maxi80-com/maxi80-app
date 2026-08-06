import Foundation

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
