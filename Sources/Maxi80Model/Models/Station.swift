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

  public init(
    name: String,
    streamUrl: String,
    image: String,
    shortDesc: String,
    longDesc: String,
    websiteUrl: String,
    donationUrl: String,
    defaultCoverUrl: String
  ) {
    self.name = name
    self.streamUrl = streamUrl
    self.image = image
    self.shortDesc = shortDesc
    self.longDesc = longDesc
    self.websiteUrl = websiteUrl
    self.donationUrl = donationUrl
    self.defaultCoverUrl = defaultCoverUrl
  }
}
