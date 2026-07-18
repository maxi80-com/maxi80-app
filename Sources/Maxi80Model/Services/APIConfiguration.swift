import Foundation

public struct APIConfiguration: Sendable {
  public let baseURL: String
  public let authToken: String

  public static let authHeaderName = "Authorization"

  public init(baseURL: String, authToken: String) {
    self.baseURL = baseURL
    self.authToken = authToken
  }
}
