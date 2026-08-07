import Maxi80Model
import SwiftUI

/// One of the generic "Maxi'80" covers shown before any song has played, paired with the
/// dominant color sampled from that image (precomputed so the startup gradient is consistent
/// on both iOS and Android — Android has no runtime image-color APIs).
struct PlaceholderCover: Equatable, Sendable {
  /// Asset name in the module bundle.
  let imageName: String
  /// Dominant color of the image, driving the startup background gradient.
  let dominantColor: Color

  /// The bundled generic covers with their sampled dominant colors.
  static let all: [PlaceholderCover] = [
    PlaceholderCover(
      imageName: "NoCover-a", dominantColor: Color(red: 96 / 255, green: 81 / 255, blue: 72 / 255)),
    PlaceholderCover(
      imageName: "NoCover-b", dominantColor: Color(red: 69 / 255, green: 67 / 255, blue: 67 / 255)),
    PlaceholderCover(
      imageName: "NoCover-c", dominantColor: Color(red: 61 / 255, green: 42 / 255, blue: 28 / 255)),
  ]

  /// The 25th-anniversary covers (issue #71), which join the pool only while the
  /// `anniversary_cover` flag is on so the celebration artwork can be switched off once the window
  /// closes without shipping a build. Kept out of `all` rather than filtered back out of it, so the
  /// default pool needs no knowledge of the flag.
  static let anniversary: [PlaceholderCover] = [
    PlaceholderCover(
      imageName: "NoCover-25ans",
      dominantColor: Color(red: 47 / 255, green: 31 / 255, blue: 55 / 255)),
    PlaceholderCover(
      imageName: "NoCover-25ans-2",
      dominantColor: Color(red: 84 / 255, green: 50 / 255, blue: 65 / 255)),
    PlaceholderCover(
      imageName: "NoCover-25ans-3",
      dominantColor: Color(red: 76 / 255, green: 53 / 255, blue: 57 / 255)),
    PlaceholderCover(
      imageName: "NoCover-25ans-4",
      dominantColor: Color(red: 82 / 255, green: 68 / 255, blue: 89 / 255)),
  ]

  /// The cover to show when there is nothing to pick for yet — before the first song of a session.
  static let `default` = all[0]

  /// The covers a coverless song may be given. **The one place the `anniversary_cover` flag is
  /// read** (issue #71): every generic cover — the now slot's and every history entry's — comes from
  /// this pool, so gating it here gates the feature everywhere without a second flag check.
  ///
  /// Which flag that is belongs here, not to callers: they ask for a cover and get whichever ones are
  /// currently eligible. Resolved per call, not once, because flags arrive with the station response,
  /// well after the app's objects are built. The parameter exists only so tests can inject a store
  /// instead of mutating the process-wide one; production calls it bare.
  @MainActor
  static func pool(for featureFlags: FeatureFlags = .shared) -> [PlaceholderCover] {
    guard featureFlags.isEnabled(.anniversaryCover) else { return all }
    return all + anniversary
  }

  /// One cover at random from the flag-resolved pool. Call only where a coverless entry is
  /// *created*, never from a SwiftUI computed property — a roll during rendering would give the same
  /// song a new cover on every redraw.
  @MainActor
  static func random(for featureFlags: FeatureFlags = .shared) -> PlaceholderCover {
    pool(for: featureFlags).randomElement() ?? `default`
  }
}
