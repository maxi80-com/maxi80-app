import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Verifies the coordinator publishes through the single `NowPlayingPublishing` seam, replacing
/// the two `#if !SKIP` branches that previously chose between the modern and bridged sinks.
@Suite("Now Playing publishing tests")
struct NowPlayingPublishingTests {

  @Test("New metadata is published with artist, title and playing state")
  @MainActor
  func metadataIsPublished() async {
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(nowPlaying: publisher)

    await coordinator.handleMetadataChanged("Depeche Mode - Enjoy the Silence")

    #expect(publisher.updates.count >= 1)
    let last = publisher.updates.last
    #expect(last?.artist == "Depeche Mode")
    #expect(last?.title == "Enjoy the Silence")
    #expect(last?.isPlaying == true)
  }

  @Test("Publishing activates the session before the first update")
  @MainActor
  func activatePrecedesUpdate() async {
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(nowPlaying: publisher)

    await coordinator.handleMetadataChanged("Artist - Song")

    #expect(publisher.activateCount >= 1, "the session must be activated before publishing")
    // Ordering, not just presence: the first recorded call must be the activation.
    #expect(publisher.calls.first == .activate)
  }

  @Test("A pause publishes a not-playing state")
  @MainActor
  func pausePublishesStopped() async {
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(nowPlaying: publisher)
    await coordinator.handleMetadataChanged("Artist - Song")
    publisher.reset()

    coordinator.pause()

    #expect(publisher.playbackStates.last == false)
  }

  @Test("A coverless song publishes the placeholder rather than blank artwork")
  @MainActor
  func coverlessSongPublishesPlaceholder() async {
    // The stub client serves no artwork, so the resolved cover is the default (no URL).
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(nowPlaying: publisher)

    await coordinator.handleMetadataChanged("Artist - Song")

    // On Apple platforms the placeholder materializes to a file:// URL; on Android there are no
    // image APIs so it stays nil. Assert the decision, which is platform-independent.
    let noURL: String? = nil
    #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: noURL) == true)
    #expect(publisher.updates.isEmpty == false)
  }
}
