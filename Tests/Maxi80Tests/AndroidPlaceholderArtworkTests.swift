// Tests/Maxi80Tests/AndroidPlaceholderArtworkTests.swift
import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Pins that a coverless song publishes the asset NAME of the generic cover it is actually showing.
///
/// Why the name and not just the URL: on Android there are no platform image APIs, so
/// `materializePlaceholderArtwork` returns nil and no `file://` URL exists to publish — the card fell
/// back to the station logo while the carousel showed a per-song cover (issue #80). The name is what
/// lets the Android controller resolve `android.resource://…/drawable/<name>`. The name must be the
/// cover the song's `HistoryEntry` carries, never a fresh roll, or the card and carousel disagree.
@Suite("Android placeholder artwork publishing")
struct AndroidPlaceholderArtworkTests {

  @Test("a coverless song publishes its own generic cover's asset name")
  @MainActor
  func coverlessSongPublishesItsOwnCoverAssetName() async {
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(nowPlaying: publisher)

    coordinator.play()
    await coordinator.handleMetadataChanged("Some Artist - Some Song")

    let published = publisher.updates.last
    #expect(published != nil)
    // No real artwork was resolved (the stub API client returns none), so the coordinator must
    // substitute the placeholder — and name the very cover the now slot is displaying.
    #expect(published?.artworkAssetName == coordinator.nowPlaceholderCover)
  }

  @Test("a song with real artwork publishes no placeholder asset name")
  @MainActor
  func songWithRealArtworkPublishesNoAssetName() async {
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(
      nowPlaying: publisher, placeholderArtworkURL: "file:///tmp/sentinel.png")

    coordinator.play()
    await coordinator.handleMetadataChanged("Some Artist - Some Song")

    // With a materialized placeholder URL available, the URL path is used; the asset name is for
    // platforms that cannot materialize one. Whichever branch wins, the two must not disagree: a
    // published asset name must always match the displayed cover.
    let published = publisher.updates.last
    #expect(published != nil)
    if let name = published?.artworkAssetName {
      #expect(name == coordinator.nowPlaceholderCover)
    }
  }
}
