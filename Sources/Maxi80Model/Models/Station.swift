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
  /// Runtime feature flags from the /station API. `nil` when the field is absent (older backends).
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
}
