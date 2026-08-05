// Tests/Maxi80Tests/RemoteCommandTests.swift
import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Verifies that `handleRemote(_:)` — the entry point the composition root wires the bridged
/// controller's callback to — correctly dispatches each documented command string to the player.
///
/// This is the branch's real production-behavior change: remote-command wiring moved out of
/// `setupCallbacks()` into the caller (`SharedPlayer`). A mutation that silently discards the
/// command body would kill every lock-screen / notification / CarPlay / Android Auto transport
/// button on every platform. These tests pin that dispatch.
@Suite("Remote command dispatch tests")
struct RemoteCommandTests {

  /// Drive the coordinator to `.playing` so toggle-direction tests start from a known state.
  @MainActor
  private func startPlaying(_ coordinator: RadioPlayerCoordinator) async {
    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
  }

  // MARK: - "play"

  @Test("handleRemote play starts the player from paused")
  @MainActor
  func remotePlayStartsPlayer() async {
    let (coordinator, player) = makeTestCoordinator()
    // Start idle (default state) — remote "play" must issue a play command.
    player.reset()

    coordinator.handleRemote("play")

    #expect(player.playedURLs().count == 1, "remote play must issue exactly one play(url:)")
    #expect(coordinator.playbackState == .loading, "play transitions to .loading")
  }

  // MARK: - "pause"

  @Test("handleRemote pause stops the player and lands .paused")
  @MainActor
  func remotePauseStopsPlayer() async {
    let (coordinator, player) = makeTestCoordinator()
    await startPlaying(coordinator)
    player.reset()

    coordinator.handleRemote("pause")

    #expect(player.stopCount() == 1, "remote pause must issue a true stop")
    #expect(coordinator.playbackState == .paused)
  }

  // MARK: - "togglePlayPause"

  @Test("handleRemote togglePlayPause pauses when currently playing")
  @MainActor
  func remoteTogglePausesWhenPlaying() async {
    let (coordinator, player) = makeTestCoordinator()
    await startPlaying(coordinator)
    player.reset()

    coordinator.handleRemote("togglePlayPause")

    #expect(player.stopCount() == 1, "toggle from .playing must stop the player")
    #expect(coordinator.playbackState == .paused, "toggle from .playing must land .paused")
  }

  @Test("handleRemote togglePlayPause plays when currently paused")
  @MainActor
  func remoteTogglePlaysWhenPaused() async {
    let (coordinator, player) = makeTestCoordinator()
    await startPlaying(coordinator)
    coordinator.pause()   // land in .paused
    player.reset()

    coordinator.handleRemote("togglePlayPause")

    #expect(player.playedURLs().count == 1, "toggle from .paused must issue a play(url:)")
    #expect(coordinator.playbackState == .loading, "toggle from .paused transitions to .loading")
  }

  // MARK: - Unknown command

  @Test("handleRemote ignores unknown command strings")
  @MainActor
  func remoteIgnoresUnknownCommand() async {
    let (coordinator, player) = makeTestCoordinator()
    await startPlaying(coordinator)
    let stateBeforeCall = coordinator.playbackState
    player.reset()

    coordinator.handleRemote("unknownXYZ")

    #expect(player.commands.isEmpty, "an unrecognised command must not touch the player")
    #expect(coordinator.playbackState == stateBeforeCall, "state must be unchanged")
  }
}
