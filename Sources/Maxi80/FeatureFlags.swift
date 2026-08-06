import Foundation
// `@Observable` comes from Observation; import it explicitly rather than relying on SwiftUI to
// re-export it, because the Android cross-compile fails with "unknown attribute 'Observable'" in a
// file that imports neither (same reason `CarouselModel` imports it).
import Observation
import SkipFuse

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "FeatureFlags")

/// Runtime feature switches, delivered by the backend in the `features` object of the `/station`
/// response (GitHub issue #72) and read synchronously by views and view models.
///
/// Lives in the native (Fuse) module rather than `Maxi80Model` because it must be `@Observable` for
/// SwiftUI: a `body` that calls `isEnabled(_:)` registers a dependency, so the UI re-renders when the
/// station response lands mid-launch. Only the primitive `[String: Bool]` on `Station` crosses the
/// JNI boundary — this type never does.
///
/// Every degraded path is **fail-open**: no network, no `features` object, or an unreadable payload
/// all leave the compiled-in `defaults` in charge, so a backend problem can never take away a
/// shipped feature. Flags are fetched fresh each launch and deliberately not persisted — the station
/// call is the app's first request.
@MainActor
@Observable
public final class FeatureFlags {

  /// Process-wide instance, applied by `RadioPlayerCoordinator.loadStation()` and read from views
  /// that sit too deep to have the store threaded through them.
  public static let shared = FeatureFlags()

  /// Known flags. Raw values are the `lower_snake_case` names the backend sends; adding a case here
  /// requires a matching entry in `defaults`, which `FeatureFlagsTests` enforces.
  public enum Flag: String, CaseIterable, Sendable {
    case anniversaryCover = "anniversary_cover"
    case sleepTimer = "sleep_timer"
  }

  /// Compiled-in, ship-safe values used until (and unless) the backend says otherwise.
  private let defaults: [Flag: Bool] = [
    // Off until the backend turns it on for the celebration window (consumer arrives with #71).
    .anniversaryCover: false,
    // Already shipped — the flag is a kill switch, so it must default on.
    .sleepTimer: true,
  ]

  /// Backend overrides from the last station load, keyed by raw flag name. Unknown keys are kept but
  /// never read, so the backend may enable a flag before the client build that consumes it exists.
  private var overrides: [String: Bool] = [:]

  /// Deliberately not `public`: production code shares `shared`, so a stray instance elsewhere in
  /// the app can't end up never receiving backend updates. Tests build their own via
  /// `@testable import`.
  init() {}

  /// Whether `flag` is currently on: the backend override if the last station response carried one,
  /// otherwise the compiled-in default, otherwise `true` (fail-open).
  public func isEnabled(_ flag: Flag) -> Bool {
    overrides[flag.rawValue] ?? defaults[flag] ?? true
  }

  /// The compiled-in default for `flag`, ignoring any backend override. Exposed so tests can assert
  /// that every declared flag ships with a default.
  func defaultValue(for flag: Flag) -> Bool? {
    defaults[flag]
  }

  /// Apply the `features` object from a station load, replacing any previous overrides.
  ///
  /// A wholesale replace (rather than a merge) makes the state a pure function of the most recent
  /// station response: a flag the backend stopped mentioning reverts to its default instead of
  /// leaving a stale override behind. `nil` — no `features` object, or one we couldn't read — clears
  /// the overrides and puts the defaults back in charge.
  public func update(from features: [String: Bool]?) {
    let incoming = features ?? [:]
    // Skip identical payloads: every station load would otherwise invalidate observers and
    // recompose the controls tray, and on Android `loadStation()` re-runs on every foreground.
    guard incoming != overrides else { return }
    overrides = incoming

    logger.info(
      "flags applied: \(Flag.allCases.map { "\($0.rawValue)=\(isEnabled($0))" }.joined(separator: " "))"
    )
    // Neither side validates flag names, so a backend typo would otherwise be completely silent.
    let known = Set(Flag.allCases.map(\.rawValue))
    let unrecognized = incoming.keys.filter { !known.contains($0) }.sorted()
    if !unrecognized.isEmpty {
      logger.info("ignoring unrecognized flags: \(unrecognized.joined(separator: " "))")
    }
  }
}
