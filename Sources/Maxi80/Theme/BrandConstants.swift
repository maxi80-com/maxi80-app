import Foundation

/// Non-localized brand strings and endpoints shared across the app.
///
/// These are intentionally NOT in the string catalog: the brand name, slogan, and URLs are
/// identical in every language. Centralizing them here keeps them out of hardcoded literals and
/// gives the two fallback `Station` definitions (StationProvider / RadioPlayerCoordinator) a single
/// source of truth. The French slogan is a brand tagline, kept verbatim for English and French.
enum BrandConstants {
  /// The station name, shown as a title/Now Playing fallback.
  static let name = "Maxi 80"

  /// The station tagline — a French brand slogan, displayed verbatim in every language.
  static let tagline = "La radio de toute une génération"

  /// The long-form station description.
  static let longDescription = "Maxi 80, la radio de toute une génération"

  /// The public website, used in the share text and as the station website fallback.
  static let websiteURL = "https://www.maxi80.com"

  /// The donation page.
  static let donationURL = "https://www.maxi80.com/don"

  /// The audio stream endpoint used before the station API has loaded.
  static let streamURL = "https://audio1.maxi80.com"
}
