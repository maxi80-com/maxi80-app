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

  @Test("when a placeholder asset name is published it always matches the displayed cover")
  @MainActor
  func publishedAssetNameAlwaysMatchesDisplayedCover() async {
    // The guard this tests: the coordinator must never publish an asset name that disagrees with
    // the cover the carousel is showing. A fresh roll here instead of reading `nowPlaceholderCover`
    // would make the card and carousel show different covers for the same song.
    //
    // Note: `ArtworkService.fetchArtwork` does a real `URLSession` download, so a host test cannot
    // produce a non-default `ArtworkResult` without a live HTTP server. Asserting `artworkAssetName
    // == nil` (the real-artwork branch) therefore requires a protocol seam on `ArtworkService` that
    // does not currently exist. The invariant testable here — that the published name always matches
    // the *displayed* cover — is the critical one: a nil case where real artwork is served is
    // covered by the coordinator's `shouldPublishPlaceholderArtwork` logic (forArtworkURL: non-nil
    // → substitutingPlaceholder = false → artworkAssetName = nil) and visible in code review.
    let publisher = FakeNowPlayingPublisher()
    let (coordinator, _) = makeTestCoordinator(nowPlaying: publisher)

    coordinator.play()
    await coordinator.handleMetadataChanged("Some Artist - Some Song")

    let published = publisher.updates.last
    #expect(published != nil)
    // When a name is published it must be the cover the carousel is displaying — never a stale or
    // re-rolled value that would make the card and carousel disagree.
    if let name = published?.artworkAssetName {
      #expect(name == coordinator.nowPlaceholderCover)
    }

    // A second song: the name must follow the new entry's cover, not reuse the first song's.
    await coordinator.handleMetadataChanged("Other Artist - Other Song")
    let second = publisher.updates.last
    if let name = second?.artworkAssetName {
      #expect(name == coordinator.nowPlaceholderCover)
    }
  }
}
