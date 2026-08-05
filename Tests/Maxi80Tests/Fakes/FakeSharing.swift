// Tests/Maxi80Tests/Fakes/FakeSharing.swift
import Foundation

@testable import Maxi80

/// Recording fake for `Sharing`.
@MainActor
final class FakeSharing: Sharing {
  /// Every share issued, in order.
  var shares: [(text: String, imageData: Data?)] = []

  func share(text: String, imageData: Data?) {
    shares.append((text: text, imageData: imageData))
  }
}
