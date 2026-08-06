import Foundation

extension String {

  /// Decode this string's UTF-8 bytes as `type`.
  ///
  /// Every backend payload reaches the native module as a raw `String`: `APIClient` lives in the
  /// transpiled `Maxi80Services` world, which can't synthesize `Codable`, so decoding happens here
  /// and every call site had to spell out the same String → Data → decode dance. This is that dance,
  /// written once.
  ///
  /// Throws rather than returning `nil` so a caller that wants the decode error for diagnostics can
  /// have it (`StationProvider` logs it); callers that only want the value use `try?`.
  func decodedJSON<T: Decodable>(as type: T.Type) throws -> T {
    guard let data = data(using: .utf8) else {
      throw JSONDecodingError.notUTF8
    }
    return try JSONDecoder().decode(type, from: data)
  }
}

/// Failure modes of `String.decodedJSON(as:)` that aren't already a `DecodingError`.
enum JSONDecodingError: Error {
  /// The string could not be represented as UTF-8 bytes.
  case notUTF8
}
