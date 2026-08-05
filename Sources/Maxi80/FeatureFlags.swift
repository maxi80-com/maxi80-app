import Foundation
import Observation

/// A named feature flag delivered via the `/station` API.
///
/// The raw value is the JSON key expected in the `features` dictionary.
/// `defaultValue` is the behaviour when the API doesn't mention the flag
/// (absent key, absent `features` field, or API unreachable).
public enum FeatureFlag: String, CaseIterable, Sendable {
  /// Anniversary cover art shown in the placeholder carousel (25th anniversary mode).
  case anniversaryCover = "anniversary_cover"
  /// Sleep timer feature available in the controls bar.
  case sleepTimer = "sleep_timer"

  /// The compiled-in default used when no API override is present.
  public var defaultValue: Bool {
    switch self {
    case .anniversaryCover: false
    case .sleepTimer: true
    }
  }
}

/// Runtime feature-flag store, populated from the `/station` API response.
///
/// Singleton living on `@MainActor`; UI code reads `FeatureFlags.shared.isEnabled(.someFlag)`.
/// The coordinator / provider calls `update(from:)` once the station is decoded.
@MainActor
@Observable
public final class FeatureFlags {

  // MARK: - Shared instance

  public static let shared = FeatureFlags()

  // MARK: - Private state

  /// API-provided overrides; only the keys present in the response are stored.
  private var overrides: [String: Bool] = [:]

  /// Use `FeatureFlags.shared` in production code. The `internal` access level allows
  /// test targets (via `@testable import`) to create isolated instances.
  init() {}

  // MARK: - Public API

  /// Returns `true` when the flag is enabled.
  ///
  /// Resolution order:
  /// 1. API override (key present in the last `update(from:)` call)
  /// 2. The flag's own `defaultValue`
  public func isEnabled(_ flag: FeatureFlag) -> Bool {
    overrides[flag.rawValue] ?? flag.defaultValue
  }

  /// Replaces the current overrides with the values from the station's `features` dictionary.
  ///
  /// Call this every time a station is decoded. Passing an empty dict clears all overrides,
  /// reverting every flag to its coded default.
  public func update(from features: [String: Bool]) {
    overrides = features
  }
}
