// Tests/Maxi80Tests/SharingTests.swift
import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Verifies what the coordinator hands to the platform share sheet. Previously unobservable:
/// `ShareService` was a concrete no-op on Apple platforms, so nothing could be asserted.
@Suite("Sharing tests")
struct SharingTests {

  @Test("Sharing without an artwork URL forwards the text and no image")
  @MainActor
  func shareWithoutArtworkIsTextOnly() async {
    let share = FakeSharing()
    let (coordinator, _) = makeTestCoordinator(shareService: share)

    await coordinator.shareCurrentTrack(text: "listen to this", artworkURL: nil)

    #expect(share.shares.count == 1)
    #expect(share.shares.first?.text == "listen to this")
    #expect(share.shares.first?.imageData == nil, "a nil artwork URL must degrade to text-only")
  }

  @Test("A failed artwork download still shares the text")
  @MainActor
  func failedArtworkStillSharesText() async {
    let share = FakeSharing()
    let (coordinator, _) = makeTestCoordinator(shareService: share)

    // A `file://` URL for a path that does not exist. Deliberately not an `https://` host: this
    // must fail deterministically and offline. `ArtworkService.fetchImageData` requires a 200
    // `HTTPURLResponse`, and a file URL never produces one, so this returns nil on any machine —
    // whereas an unresolvable hostname depends on the DNS resolver not handing back a wildcard.
    await coordinator.shareCurrentTrack(
      text: "listen to this", artworkURL: "file:///maxi80-no-such-cover.jpg")

    #expect(share.shares.count == 1, "a download failure must not swallow the share")
    #expect(share.shares.first?.text == "listen to this")
    #expect(share.shares.first?.imageData == nil, "a failed fetch must degrade to text-only")
  }
}
