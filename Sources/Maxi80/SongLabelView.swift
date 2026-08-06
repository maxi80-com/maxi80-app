import SwiftUI

/// The song-info block for the browsed or live track, shared by the phone/tablet and TV UIs.
///
/// Three lines of the same data in the same order of visual weight — a big bold primary line, a
/// smaller semibold secondary line, and the browsed entry's air time in a dim `subtitle.opacity(0.6)`
/// — differing only in what each surface can afford: type sizes, alignment, which field leads, and
/// where the air time goes.
///
/// **Air time placement** is the one genuinely conditional bit. Portrait canvases have room for a
/// discreet "Played at 14:30" third line; a short landscape info column does not (a third line made
/// `minimumScaleFactor` shrink the lines above it), so there the bare parenthesized time is inlined
/// beside the secondary line on its baseline. `airDate` is nil on the live slot, so both placements
/// simply render nothing there.
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

  var contrast: ContrastStyle = .semantic

  var body: some View {
    VStack(alignment: alignment, spacing: 12) {
      Text(primary)
        .foregroundStyle(contrast.title)
        .font(.system(size: primarySize, weight: .bold))
        .lineLimit(2)
        .minimumScaleFactor(0.5)

      if inlineAirTime {
        // Baseline-aligned so the smaller time sits on the secondary line's baseline. Bare
        // parenthesized locale time (no "Played at" prefix) keeps the line short;
        // `formatted(date:time:)` is the SkipFoundation-safe form and picks 24h vs AM-PM.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          secondaryText
          if let airDate {
            Text(verbatim: "(\(airDate.formatted(date: .omitted, time: .shortened)))")
              .font(.system(size: airTimeSize, weight: .regular))
              .foregroundStyle(contrast.subtitle.opacity(0.6))
              .lineLimit(1)
          }
        }
      } else {
        secondaryText

        // "Diffusé à 14:30", so the block reads as history. Locale picks 24h vs AM-PM.
        // `formatted(date:time:)` and `Bundle.localizedString` (not the `.hour().minute()` builder /
        // `String(localized:)`) because those are the forms SkipFoundation provides. Dimmed from
        // `contrast.subtitle` so it tracks the background like the lines above it.
        if let airDate {
          Text(
            String(
              format: Bundle.module.localizedString(forKey: "Played at %@", value: nil, table: nil),
              airDate.formatted(date: .omitted, time: .shortened)
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
      .lineLimit(2)
      .minimumScaleFactor(0.5)
  }
}
