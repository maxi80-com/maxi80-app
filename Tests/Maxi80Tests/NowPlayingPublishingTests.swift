import Foundation
import SwiftUI
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
    // The stub client serves no artwork, so the resolved cover is the default (no URL) and the
    // publish site must substitute the placeholder. The real placeholder is materialized from the
    // asset catalog, which the host test bundle lacks — it would resolve to `nil` here, making the
    // substitution indistinguishable from publishing nothing. Injecting a sentinel makes the
    // substitution observable, so deleting it at the publish site fails this test.
    let placeholder = "file:///test-placeholder.png"
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(
      nowPlaying: publisher, placeholderArtworkURL: placeholder)

    await coordinator.handleMetadataChanged("Artist - Song")

    #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: nil) == true)
    #expect(publisher.updates.last?.artworkURL == placeholder)
  }

  @Test("A present cover is published unmodified, never replaced by the placeholder")
  @MainActor
  func presentCoverIsPassedThrough() {
    // Staged through `carPlayDidConnect()` → `republishNowPlaying()`, which reads `currentArtwork`
    // directly, so a real cover URL reaches the publish site without needing a network fetch.
    let cover = "https://cover.example/enjoy-the-silence.jpg"
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(
      nowPlaying: publisher, placeholderArtworkURL: "file:///test-placeholder.png")
    coordinator.currentSong = SongMetadata(artist: "Depeche Mode", title: "Enjoy the Silence")
    coordinator.currentArtwork = ArtworkResult(
      image: nil, dominantColor: .black, isDefault: false, url: cover)
    publisher.reset()

    coordinator.carPlayDidConnect()

    #expect(publisher.updates.last?.artworkURL == cover)
  }

  @Test("A default-cover artwork is suppressed and the placeholder is published instead")
  @MainActor
  func defaultCoverIsFilteredToPlaceholder() {
    // The `republishNowPlaying()` path contains `$0.isDefault ? nil : $0.url` at :363.
    // Dropping that filter passes with the two existing tests because both stage `isDefault: false`.
    // This case stages `isDefault: true` so the filter is load-bearing: removing it publishes the
    // default-cover URL instead of the placeholder sentinel, failing the assertion below.
    let placeholder = "file:///test-placeholder.png"
    let defaultCoverURL = "https://cover.example/default-cover.jpg"
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(
      nowPlaying: publisher, placeholderArtworkURL: placeholder)
    coordinator.currentSong = SongMetadata(artist: "Unknown", title: "Live")
    coordinator.currentArtwork = ArtworkResult(
      image: nil, dominantColor: .black, isDefault: true, url: defaultCoverURL)
    publisher.reset()

    coordinator.carPlayDidConnect()

    // The default cover's URL must be suppressed; the placeholder must be published instead.
    #expect(
      publisher.updates.last?.artworkURL == placeholder,
      "a default-cover artwork must be replaced by the placeholder; got \(String(describing: publisher.updates.last?.artworkURL))")
  }
}
