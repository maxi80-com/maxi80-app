import Foundation
import Maxi80Model
import Maxi80Services

/// Loads API configuration from Configuration.plist bundled as a resource.
/// This is the Swift/SPM equivalent of a .env file — values are not hardcoded in source.
///
/// To configure:
/// 1. Edit Sources/Maxi80/Resources/Configuration.plist
/// 2. Set API_BASE_URL and API_AUTH_TOKEN
/// 3. Add Configuration.plist to .gitignore to keep secrets out of source control
enum ConfigurationLoader {

  /// Load the API configuration from the bundled plist.
  /// Falls back to empty values if the plist is missing or malformed.
  static func loadAPIConfiguration() -> APIConfiguration {
    guard let url = Bundle.module.url(forResource: "Configuration", withExtension: "plist"),
      let data = try? Data(contentsOf: url),
      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: String]
    else {
      assertionFailure(
        "Configuration.plist not found or invalid. Add it to Sources/Maxi80/Resources/")
      return APIConfiguration(baseURL: "", authToken: "")
    }

    let baseURL = dict["API_BASE_URL"] ?? ""
    let authToken = dict["API_AUTH_TOKEN"] ?? ""

    return APIConfiguration(baseURL: baseURL, authToken: authToken)
  }
}
