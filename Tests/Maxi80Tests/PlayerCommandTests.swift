import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Verifies the commands the coordinator issues to the player — the class of assertion that was
/// impossible before the `AudioPlaying` seam, because tests could only push callbacks inward.
@Suite("Player command tests")
struct PlayerCommandTests {

  /// Drive the coordinator to `.playing`: `play()` sets `.loading`, metadata promotes it.
  @MainActor
  private func startPlaying(_ coordinator: RadioPlayerCoordinator) async {
    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
  }

  // MARK: - Sleep-timer fade ramp

  @Test("Sleep timer fades attenuation to silence, then stops the player")
  @MainActor
  func sleepTimerFadesThenStops() async {
    // A tiny fade duration keeps the test in milliseconds instead of the production 2.5s.
    let (coordinator, player) = makeTestCoordinator(sleepFadeDuration: 12_000_000)
    await startPlaying(coordinator)
    player.reset()

    // Fire immediately: a 0-minute timer clamps to "now".
    coordinator.startSleepTimer(minutes: 0)

    // Poll until the stop lands rather than sleeping a fixed span.
    var waited = 0
    while player.stopCount() == 0 && waited < 200 {
      try? await Task.sleep(nanoseconds: 10_000_000)
      waited += 1
    }

    #expect(player.stopCount() == 1, "the fade must end in a true stop")

    // Only the writes BEFORE the stop are the fade ramp; the write after it is the restore-to-1.0
    // that the final assertion covers, and including it would make the ramp look non-monotonic.
    let ramp = player.attenuations(in: player.commandsBeforeStop())
    #expect(ramp.count >= 12, "expected one attenuation write per fade step; got \(ramp.count)")
    // Monotonically descending.
    #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 >= $1 }, "ramp must not increase: \(ramp)")
    // The ramp reaches true silence before stopping — a faded-but-audible stop is the bug guarded here.
    #expect(ramp.last == 0.0, "ramp must end at 0.0 before the stop; got \(ramp)")
    // Attenuation is restored so the next play isn't silent.
    #expect(player.attenuation == 1.0, "attenuation must be restored to 1.0 after the stop")
  }

  @Test("Cancelling a sleep timer restores full volume and issues no stop")
  @MainActor
  func cancelSleepTimerRestoresVolume() async {
    let (coordinator, player) = makeTestCoordinator()
    await startPlaying(coordinator)
    coordinator.startSleepTimer(minutes: 15)
    // Stand in for a partially-faded player. Without this the `attenuation == 1.0` assertion below
    // would pass on the fake's default value even if the coordinator never restored anything.
    player.attenuation = 0.25
    player.reset()

    coordinator.cancelSleepTimer()

    #expect(coordinator.sleepTimerFiresAt == nil)
    #expect(player.stopCount() == 0, "cancelling must not stop playback")
    #expect(
      player.commands == [.setAttenuation(1.0)],
      "cancelling must restore full volume and do nothing else; got \(player.commands)")
    #expect(player.attenuation == 1.0)
  }

  // MARK: - Stop semantics
  //
  // Scope note: these two tests prove that `stopForDisconnect()` issues exactly one `stop()` and
  // lands `.paused` — reached via the user pause button and via the headset-disconnect callback.
  // They do NOT prove "stop rather than pause": `AudioPlaying` exposes no `pause()` at all, and both
  // entry points funnel into the same `stopForDisconnect()`, so this is one code path asserted from
  // two callers. The real issue-#49 invariant — that a media3 transport pause must be a stop that
  // KEEPS the media item — lives in `ExoPlayerStreamPlayer`/`StopOnPausePlayer` on the Android side
  // and is not reachable from this suite. Don't mistake these for end-to-end #49 coverage.

  @Test("User pause issues exactly one true stop")
  @MainActor
  func pauseIssuesTrueStop() async {
    let (coordinator, player) = makeTestCoordinator()
    await startPlaying(coordinator)
    player.reset()

    coordinator.pause()

    #expect(player.stopCount() == 1)
    #expect(coordinator.playbackState == .paused)
  }

  @Test("A headset disconnect issues a true stop, not a pause")
  @MainActor
  func disconnectIssuesTrueStop() async {
    let (coordinator, player) = makeTestCoordinator()
    await startPlaying(coordinator)
    player.reset()

    coordinator.handleDisconnectStop()

    #expect(player.stopCount() == 1, "disconnect must release the buffer, not merely pause")
    #expect(coordinator.playbackState == .paused)
  }

  // MARK: - Play routing

  @Test("Play uses the loaded station's stream URL rather than the fallback")
  @MainActor
  func playUsesStationURL() async {
    let (coordinator, player) = makeTestCoordinator()
    coordinator.station = Station(
      name: "Maxi 80", streamUrl: "https://stream.example/live.mp3", image: "",
      shortDesc: "", longDesc: "", websiteUrl: "", donationUrl: "", defaultCoverUrl: "")
    player.reset()

    coordinator.play()

    #expect(player.playedURLs() == ["https://stream.example/live.mp3"])
  }

  // MARK: - Cold-start external adoption (PR #62 / issue #41)

  @Test("Reconciling adopts externally-started playback when isPlaying is stale-false")
  @MainActor
  func reconcileAdoptsExternalPlayback() {
    let (coordinator, player) = makeTestCoordinator()
    // Android Auto cold start: the service drove the shared player directly, so this process
    // never ran play(url:) — the flag is stale-false but the sync reports real playback.
    player.isPlaying = false
    player.syncResult = true

    coordinator.reconcileWithPlayer()

    #expect(coordinator.playbackState == .playing)
    #expect(player.commands.contains(.syncWithExternalPlayback))
  }

  @Test("Reconciling never fabricates playback from a genuinely stopped player")
  @MainActor
  func reconcileDoesNotFabricatePlayback() {
    let (coordinator, player) = makeTestCoordinator()
    player.syncResult = false
    coordinator.pause()
    let stopsAfterPause = player.stopCount()

    coordinator.reconcileWithPlayer()

    #expect(coordinator.playbackState == .paused, "a user pause must survive reconciliation")
    #expect(player.stopCount() == stopsAfterPause)
  }

  // MARK: - Reconnection

  @Test("A stream error drives a reconnect that replays the station URL")
  @MainActor
  func reconnectReplaysStationURL() async {
    // Scale both delays down so the 2s backoff + 3s confirmation don't dominate the test, but keep
    // them well above the poll interval below so the intermediate `.reconnecting` state is
    // observable rather than raced past.
    let (coordinator, player) = makeTestCoordinator(
      reconnectConfirmationDelay: 20_000_000,
      reconnectTimeScale: 0.05
    )
    coordinator.station = Station(
      name: "Maxi 80", streamUrl: "https://stream.example/live.mp3", image: "",
      shortDesc: "", longDesc: "", websiteUrl: "", donationUrl: "", defaultCoverUrl: "")
    player.reset()

    // Decouple `play(url:)` from `isPlaying` so the staged flag below — not a side effect of the
    // replay itself — is what the confirmation reads. Without this, the fake's `play(url:)` would
    // set `isPlaying = true` on its own and the staging would be dead code.
    player.playEstablishesPlayback = false
    // The player will report healthy playback, so the first attempt should succeed.
    player.isPlaying = true
    coordinator.handleError("stream dropped")

    // Poll for the settled outcome, not merely for the replay: the confirmation wait sits between
    // `play(url:)` and the promotion to `.playing`. Record every state seen so the test asserts the
    // whole ladder ran, not just its endpoint.
    var observed: [PlaybackState] = []
    var waited = 0
    while coordinator.playbackState != .playing && waited < 200 {
      if observed.last != coordinator.playbackState { observed.append(coordinator.playbackState) }
      try? await Task.sleep(nanoseconds: 5_000_000)
      waited += 1
    }

    // The error must enter the backoff ladder rather than surfacing straight to the user.
    #expect(observed.contains(.reconnecting(1)), "expected a reconnect attempt; saw \(observed)")
    #expect(!observed.contains(where: { if case .error = $0 { return true } else { return false } }),
      "a recoverable drop must not surface as .error; saw \(observed)")
    #expect(player.playedURLs() == ["https://stream.example/live.mp3"])
    #expect(coordinator.playbackState == .playing, "a confirmed replay resolves to playing")
    #expect(coordinator.errorMessage == nil, "a successful reconnect must clear the error message")
  }

  @Test("An unrecovered reconnect attempt is not confirmed and the ladder advances")
  @MainActor
  func unrecoveredReconnectAdvancesLadder() async {
    let (coordinator, player) = makeTestCoordinator(
      reconnectConfirmationDelay: 20_000_000,
      reconnectTimeScale: 0.05
    )
    coordinator.station = Station(
      name: "Maxi 80", streamUrl: "https://stream.example/live.mp3", image: "",
      shortDesc: "", longDesc: "", websiteUrl: "", donationUrl: "", defaultCoverUrl: "")
    player.reset()

    // The replay reaches the player but audio never recovers (dead stream / no live edge), so
    // `isPlaying` stays false through the confirmation window. This is the half of the ladder that
    // is unreachable while `play(url:)` establishes playback by itself, and it is what makes the
    // confirmation's POSITIVE direction load-bearing: a coordinator that declares success without
    // reading the player would settle on `.playing` here instead of advancing.
    player.playEstablishesPlayback = false
    player.isPlaying = false
    coordinator.handleError("stream dropped")

    // Wait for the ladder to reach attempt 2, i.e. for attempt 1 to have been REJECTED.
    var observed: [PlaybackState] = []
    var waited = 0
    while coordinator.playbackState != .reconnecting(2) && waited < 200 {
      if observed.last != coordinator.playbackState { observed.append(coordinator.playbackState) }
      try? await Task.sleep(nanoseconds: 5_000_000)
      waited += 1
    }

    #expect(
      coordinator.playbackState == .reconnecting(2),
      "an unconfirmed attempt must advance the ladder, not settle; saw \(observed)")
    #expect(
      !observed.contains(.playing),
      "playback must never be reported as playing over dead audio; saw \(observed)")
    #expect(
      player.playedURLs() == ["https://stream.example/live.mp3"],
      "attempt 1 must have replayed the station URL exactly once by now")
  }
}
