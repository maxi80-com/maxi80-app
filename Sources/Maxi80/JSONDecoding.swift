import Foundation

/// Decodes a JSON string into a `Decodable` type.
///
/// This pattern (String → Data → Decode) exists because `APIClient` returns raw `String`
/// (a Skip bridging constraint: transpiled modules can't synthesize `Codable`).
func decodeJSON<T: Decodable>(_ json: String, as type: T.Type) -> T? {
  guard let data = json.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(type, from: data)
}
