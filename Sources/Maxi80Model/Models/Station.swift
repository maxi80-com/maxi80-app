import Foundation

public struct Station: Sendable, Codable {
  public let name: String
  public let streamUrl: String
  public let image: String
  public let shortDesc: String
  public let longDesc: String
  public let websiteUrl: String
  public let donationUrl: String
  public let defaultCoverUrl: String

  /// Runtime feature flags from the backend, keyed by `lower_snake_case` flag name. `nil` when the
  /// response omits the object (older backends) or carries a payload we can't read — in both cases
  /// the client falls back to its compiled-in defaults. See `FeatureFlags` in the app module.
  public let features: [String: Bool]?

  public init(
    name: String,
    streamUrl: String,
    image: String,
    shortDesc: String,
    longDesc: String,
    websiteUrl: String,
    donationUrl: String,
    defaultCoverUrl: String,
    features: [String: Bool]? = nil
  ) {
    self.name = name
    self.streamUrl = streamUrl
    self.image = image
    self.shortDesc = shortDesc
    self.longDesc = longDesc
    self.websiteUrl = websiteUrl
    self.donationUrl = donationUrl
    self.defaultCoverUrl = defaultCoverUrl
    self.features = features
  }

  /// Any flag name the backend sends, so `features` can be walked key by key.
  private struct FeatureKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  /// Hand-written so a malformed `features` payload degrades that one field instead of failing the
  /// whole decode. The synthesized initializer would throw on, say, `"anniversary_cover": "yes"`,
  /// dropping the app to its hardcoded fallback station — losing the real stream URL and
  /// descriptions over a flag typo. Every other field stays strict.
  ///
  /// The flags are decoded one key at a time rather than as a whole `[String: Bool]`, so a single
  /// bad value costs only its own flag. An all-or-nothing decode would let an unrelated typo turn an
  /// emergency kill switch in the same payload into a silent no-op. A missing, `null`, or
  /// non-object `features` still yields `nil` — the compiled-in defaults.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    streamUrl = try container.decode(String.self, forKey: .streamUrl)
    image = try container.decode(String.self, forKey: .image)
    shortDesc = try container.decode(String.self, forKey: .shortDesc)
    longDesc = try container.decode(String.self, forKey: .longDesc)
    websiteUrl = try container.decode(String.self, forKey: .websiteUrl)
    donationUrl = try container.decode(String.self, forKey: .donationUrl)
    defaultCoverUrl = try container.decode(String.self, forKey: .defaultCoverUrl)

    if let flags = try? container.nestedContainer(keyedBy: FeatureKey.self, forKey: .features) {
      var decoded: [String: Bool] = [:]
      for key in flags.allKeys {
        if let value = try? flags.decode(Bool.self, forKey: key) {
          decoded[key.stringValue] = value
        }
      }
      features = decoded
    } else {
      features = nil
    }
  }
}
