import SwiftUI

/// The song-info block for the browsed or live track, shared by the phone/tablet and TV UIs.
///
/// Three lines of the same data in the same order of visual weight — a big bold primary line, a
/// smaller semibold secondary line, and the browsed entry's air time in a dim `subtitle.opacity(0.6)`
/// — differing only in what each surface can afford: type sizes, alignment, which field leads, and
/// where the air time goes.
///
/// **Air time placement** is the one genuinely conditional bit, and the caller picks it with
/// `inlineAirTime` according to the height it has: a discreet "Played at 14:30" third line where
/// there is room for one, or the bare parenthesized time inlined beside the secondary line on its
/// baseline where there is not. `airDate` is nil on the live slot, so both placements render nothing
/// there.
///
/// **Field order differs by surface and is deliberate**, not an inconsistency to fix here: the phone
/// leads with the artist, the 10-foot TV layout leads with the title. The caller passes whichever
/// field it wants in `primary`.
struct SongLabelView: View {
  /// The big bold line — the artist on phone, the title on TV.
  let primary: String
  /// The smaller semibold line — the title on phone, the artist on TV.
  let secondary: String
  /// When the browsed history entry aired, or `nil` on the live slot (which hides the line).
  let airDate: Date?

  let primarySize: CGFloat
  let secondarySize: CGFloat
  let airTimeSize: CGFloat

  var alignment: HorizontalAlignment = .center
  /// Put the air time in parentheses beside `secondary` instead of on its own third line. For short
  /// landscape info columns.
  var inlineAirTime: Bool = false

  /// Line cap for `primary` and `secondary`. At `1` the two lines truncate at full type size rather
  /// than wrapping, which keeps this block's height constant.
  ///
  /// That matters because the height is load-bearing for the caller: a surface whose column is
  /// already at its height budget cannot absorb a second line, and in the phone's landscape layout
  /// the column shares a height-linked `HStack` with the carousel. Defaults to 2 for the roomier
  /// surfaces (portrait, TV).
  var maxLines: Int = 2

  var contrast: ContrastStyle = .semantic

  var body: some View {
    VStack(alignment: alignment, spacing: 12) {
      Text(primary)
        .foregroundStyle(contrast.title)
        .font(.system(size: primarySize, weight: .bold))
        .lineLimit(maxLines)

      if inlineAirTime {
        // Baseline-aligned so the smaller time sits on the secondary line's baseline. Bare
        // parenthesized locale time (no "Played at" prefix) keeps the line short.
        // `shortTimeString(from:)` handles the Android locale workaround; on iOS it uses
        // `Date.formatted(date:time:)`.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          secondaryText
          if let airDate {
            Text(verbatim: "(\(shortTimeString(from: airDate)))")
              .font(.system(size: airTimeSize, weight: .regular))
              .foregroundStyle(contrast.subtitle.opacity(0.6))
              .lineLimit(1)
          }
        }
      } else {
        secondaryText

        // "Diffusé à 14:30", so the block reads as history.
        // `shortTimeString(from:)` handles the Android locale workaround; on iOS it uses
        // `Date.formatted(date:time:)`. Dimmed from `contrast.subtitle` so it tracks the
        // background like the lines above it.
        if let airDate {
          Text(
            String(
              format: Bundle.module.localizedString(forKey: "Played at %@", value: nil, table: nil),
              shortTimeString(from: airDate)
            )
          )
          .font(.system(size: airTimeSize, weight: .regular))
          .foregroundStyle(contrast.subtitle.opacity(0.6))
          .lineLimit(1)
        }
      }
    }
    .multilineTextAlignment(alignment == .leading ? .leading : .center)
  }

  private var secondaryText: some View {
    Text(secondary)
      .font(.system(size: secondarySize, weight: .semibold))
      .foregroundStyle(contrast.subtitle)
      .lineLimit(maxLines)
  }

  // MARK: - Time formatting

  /// Formats a date as a short locale-aware time string (e.g. "14:30" in French, "2:30 PM" in English).
  ///
  /// On iOS, `Date.formatted(date:time:)` correctly picks up the device locale. On Android (native
  /// fuse mode), both `Date.formatted` and `Locale.current` are broken — they don't reflect the
  /// Android app locale. Work around this by using an explicit `DateFormatter` with a localized
  /// date-format pattern from the string catalog (which uses the Android resource system that works).
  /// See: https://github.com/skiptools/skip-foundation/issues/128
  #if os(Android)
  private static let androidTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    // The pattern is looked up once from the string catalog: "HH:mm" for French, "h:mm a" for English.
    formatter.dateFormat = Bundle.module.localizedString(forKey: "h:mm a", value: nil, table: nil)
    return formatter
  }()
  #endif

  private func shortTimeString(from date: Date) -> String {
    #if os(Android)
    return Self.androidTimeFormatter.string(from: date)
    #else
    return date.formatted(date: .omitted, time: .shortened)
    #endif
  }
}
