import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests for the Android Auto cold-start metadata path (issues #61 / #80).
///
/// On Android the process can start for the media service ALONE — Android Auto connecting and
/// pressing play never creates an Activity. The native Swift half is loaded in that process, but
/// nothing referenced `SharedPlayer.coordinator`, whose only other caller is `Maxi80RootView.init()`.
/// So the whole native metadata pipeline (`MetadataParser` split → `ArtworkService` → Now Playing
/// publish) sat dormant behind a UI that never appeared, and the car card was left to the service's
/// deliberately display-only Kotlin listener: raw unsplit "ARTIST - TITLE" text with the station logo
/// for every song, however much real artwork existed. `SharedPlayer.handleProcessStart()` (called
/// from `Maxi80AppDelegate.onInit()`) fixes that by building the pipeline at process start.
///
/// What is host-testable is the pipeline contract that fix depends on: a coordinator that never ran
/// `play()` — the cold-start shape, where playback was started externally through the media session —
/// must still split metadata and publish artwork. The wiring itself (`Application.onCreate` →
/// `onInit()`) is Android-only and verified on the DHU; see
/// `docs/testing/android-auto-dhu-procedure.md` Test C/D.
@Suite("Service Cold-Start Metadata Tests")
struct ServiceColdStartMetadataTests {

  /// Records the artist/title every artwork lookup was made with.
  ///
  /// Records rather than serves: `ArtworkService.fetchArtwork` downloads the resolved URL through
  /// `URLSession`, so a stub cannot produce a real (non-default) `ArtworkResult` without a live HTTP
  /// server. What matters here is host-testable without one — that a cold start *asks the backend at
  /// all*, with properly split terms. Before this fix nothing asked, because the pipeline that asks
  /// was never built. Whether the answer then renders is the DHU's job (Test D).
  actor ArtworkLookupRecorder: APIClientProtocol {
    private(set) var lookups: [(artist: String, title: String)] = []

    func fetchStation() async throws(APIClientError) -> String { throw .noContent }
    func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
      lookups.append((artist: artist, title: title))
      throw .noContent
    }
    func fetchHistory() async throws(APIClientError) -> String { throw .noContent }
  }

  /// Builds a coordinator in the cold-start shape: `play()` was never called, and the player reports
  /// externally-started playback the way the Android sync does after adopting the shared ExoPlayer.
  @MainActor
  private func makeColdStartCoordinator(apiClient: (any APIClientProtocol)? = nil) -> (
    coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer,
    nowPlaying: FakeNowPlayingPublisher
  ) {
    let nowPlaying = FakeNowPlayingPublisher()
    let (coordinator, player) = makeTestCoordinator(
      apiClient: apiClient, nowPlaying: nowPlaying,
      placeholderArtworkURL: "file:///tmp/placeholder.png")
    player.isPlaying = false
    player.syncResult = true
    return (coordinator, player, nowPlaying)
  }

  @Test("Adopting external playback attaches the metadata subscription without a play() call")
  @MainActor
  func processStartAdoptsExternalPlaybackWithoutPlaying() {
    let (coordinator, player, _) = makeColdStartCoordinator()

    // What `handleProcessStart()` does. `syncWithExternalPlayback` is the call that adopts the
    // shared ExoPlayer and attaches the native ICY listener on Android — the actual subscription to
    // song changes, without which nothing below ever fires.
    coordinator.reconcileWithPlayer()

    #expect(player.commands.contains(.syncWithExternalPlayback))
    #expect(coordinator.playbackState == .playing)
    // Must not start a second stream: the car is already playing, and a process started for a mere
    // bind (Auto browsing, the media-app scanner) must not begin streaming at all.
    #expect(player.playedURLs().isEmpty)
  }

  @Test("A cold-start metadata event is split into artist and title, not published raw")
  @MainActor
  func coldStartMetadataIsSplit() async {
    let (coordinator, _, nowPlaying) = makeColdStartCoordinator()
    coordinator.reconcileWithPlayer()

    await coordinator.handleMetadataChanged("Lisa Stansfield - This is the right time")

    // The service's Kotlin listener publishes the whole line as the title with "Maxi 80" as the
    // artist. The native pipeline must supersede that with a real split.
    let published = nowPlaying.updates.last
    #expect(published?.artist == "Lisa Stansfield")
    #expect(published?.title == "This is the right time")
    #expect(coordinator.currentSong?.artist == "Lisa Stansfield")
  }

  @Test("A cold-start song asks the backend for its cover, with split search terms")
  @MainActor
  func coldStartResolvesArtworkFromTheBackend() async {
    let recorder = ArtworkLookupRecorder()
    let (coordinator, _, _) = makeColdStartCoordinator(apiClient: recorder)
    coordinator.reconcileWithPlayer()

    await coordinator.handleMetadataChanged("Lisa Stansfield - This is the right time")

    // The bug this closes: the service can only ever publish `drawable/media_placeholder`, so every
    // song showed the station logo on an app-never-opened start no matter what artwork existed —
    // because nothing in that process ever asked. `/artwork` needs the terms split, which is the
    // other half of why this must run through `MetadataParser` rather than Kotlin.
    let lookups = await recorder.lookups
    #expect(lookups.count == 1)
    #expect(lookups.first?.artist == "Lisa Stansfield")
    #expect(lookups.first?.title == "This is the right time")
  }

  @Test("A coverless cold-start song publishes the generic cover the carousel shows")
  @MainActor
  func coldStartCoverlessSongPublishesGenericCover() async {
    let (coordinator, _, nowPlaying) = makeColdStartCoordinator()
    coordinator.reconcileWithPlayer()

    await coordinator.handleMetadataChanged("Maxi 80 - DJ Program")

    let published = nowPlaying.updates.last
    // Android has no image APIs, so it resolves this NAME to a drawable; Apple gets the file URL.
    // Either way it is the cover the carousel's now slot shows, never the station logo (issue #80).
    #expect(published?.artworkAssetName != nil)
    #expect(published?.artworkAssetName == coordinator.nowPlaceholderCover)
  }

  @Test("Process start is idempotent, so an app launch after a cold start is unaffected")
  @MainActor
  func processStartIsIdempotent() async {
    let (coordinator, _, nowPlaying) = makeColdStartCoordinator()

    // `handleProcessStart()` runs from `onInit()`, then `Maxi80RootView.init()` resolves the same
    // singletons and `onResume()` reconciles again — the same coordinator, reconciled repeatedly.
    coordinator.reconcileWithPlayer()
    await coordinator.handleMetadataChanged("Lisa Stansfield - This is the right time")
    let afterFirst = nowPlaying.updates.last
    coordinator.reconcileWithPlayer()

    #expect(coordinator.playbackState == .playing)
    #expect(coordinator.currentSong?.artist == "Lisa Stansfield")
    // The republish carries the same song forward rather than reverting to a station placeholder.
    #expect(nowPlaying.updates.last?.artist == afterFirst?.artist)
    #expect(nowPlaying.updates.last?.title == afterFirst?.title)
  }

  @Test("A re-delivered identical title publishes nothing, so nothing may overwrite the card")
  @MainActor
  func repeatedIdenticalMetadataDoesNotRepublish() async {
    let (coordinator, _, nowPlaying) = makeColdStartCoordinator()
    coordinator.reconcileWithPlayer()

    await coordinator.handleMetadataChanged("Lisa Stansfield - This is the right time")
    let countAfterFirst = nowPlaying.updates.count
    // What a transport pause→play does: the stream reconnects and ICY re-delivers the SAME line.
    await coordinator.handleMetadataChanged("Lisa Stansfield - This is the right time")

    #expect(nowPlaying.updates.count == countAfterFirst)

    // This skip is why `Maxi80MediaService` must have NO ICY listener of its own. It briefly had a
    // display-only one that wrote the raw line with "Maxi 80" as the artist, relying on the native
    // publish to overwrite it — which held for a NEW song but not here: the native side skips, so the
    // raw write stayed as the last writer and the card degraded to exactly the #61 symptom after a
    // pause→play. One writer, and it is the one that splits. If you ever need the native side to
    // republish unchanged metadata, that is fine — but it must not become the excuse for a second
    // writer to exist.
    #expect(nowPlaying.updates.last?.artist == "Lisa Stansfield")
    #expect(nowPlaying.updates.last?.title == "This is the right time")
  }

  @Test("Process start does not fabricate playback when the player is genuinely idle")
  @MainActor
  func processStartOnBindDoesNotStartPlayback() {
    let nowPlaying = FakeNowPlayingPublisher()
    let (coordinator, player) = makeTestCoordinator(nowPlaying: nowPlaying)
    // A process started for a BIND (Android Auto browsing, the media-app scanner): the service is
    // alive but nothing is playing.
    player.syncResult = false

    coordinator.reconcileWithPlayer()

    #expect(coordinator.playbackState == .idle)
    #expect(player.playedURLs().isEmpty)
    #expect(nowPlaying.updates.isEmpty)
  }
}
