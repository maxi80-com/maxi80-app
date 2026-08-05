# Protocol Seams for Platform Services — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce protocol seams for the three bridged platform services so the coordinator can be tested against fakes, and unify the two Now Playing publishing paths behind one protocol.

**Architecture:** Three protocols (`AudioPlaying`, `Sharing`, `NowPlayingPublishing`) declared in the **native `Maxi80` module**, with the bridged `Maxi80Services` classes conforming retroactively via empty extensions. The protocols never cross the JNI boundary, so bridging is untouched. The `#if SKIP` platform dispatch inside each service class stays exactly as-is. `RadioPlayerCoordinator` switches its stored dependencies to existentials (`any AudioPlaying`, etc.). Test doubles live in `Tests/Maxi80Tests/Fakes/`.

**Tech Stack:** Swift 6 (strict concurrency), Skip (Fuse native + Lite transpiled, bridging), Swift Testing (`#expect`, `@Test`), SwiftCheck for property tests.

## Global Constraints

- Swift 6 strict concurrency. All new types `Sendable` where possible; `@MainActor` on anything touching coordinator state.
- Protocols are declared in `Sources/Maxi80/` (native module) — **never** in `Maxi80Services`, to avoid touching the JNI bridge.
- Do **not** modify the `#if SKIP` / `#elseif os(iOS)` dispatch bodies inside `AudioStreamPlayer`, `NowPlayingController`, or `ShareService`.
- Do **not** remove the `/* SKIP @bridge */` or `#if !SKIP_BRIDGE` markers on the bridged classes.
- No force unwrapping (`!`) in production code; allowed in tests.
- Use `Logger` (OSLog), never `print()`.
- Tests use Swift Testing (`@Test`, `#expect`), not XCTest.
- Every task ends green on **both** `swift test` and `make build-android`.
- No production behavior changes in any task. This is seam insertion only. Task 8 is the sole exception (it deletes dead branches) and must preserve identical observable behavior.
- Commit after each task.

## Correction to the spec

The design doc's `AudioPlaying` sketch listed `volume` and `attenuation` as protocol members. Audit shows `RadioPlayerCoordinator` **never reads** either (it reads `isPlaying` and calls `currentVolume()`). Per YAGNI they are **omitted** from the protocol. The fake declares them as plain stored properties so tests can still assert the attenuation ramp.

`stopObservingVolume()` is likewise omitted — no caller anywhere in `Sources/` or `Tests/`.

## File Structure

**Create:**
| File | Responsibility |
|---|---|
| `Sources/Maxi80/Services/AudioPlaying.swift` | `AudioPlaying` protocol + `AudioStreamPlayer` conformance |
| `Sources/Maxi80/Services/Sharing.swift` | `Sharing` protocol + `ShareService` conformance |
| `Sources/Maxi80/Services/BridgedNowPlayingPublisher.swift` | Adapter conforming the bridged `NowPlayingController` to `NowPlayingPublishing` |
| `Tests/Maxi80Tests/Fakes/FakeAudioPlayer.swift` | Recording fake for `AudioPlaying` |
| `Tests/Maxi80Tests/Fakes/FakeSharing.swift` | Recording fake for `Sharing` |
| `Tests/Maxi80Tests/Fakes/FakeNowPlayingPublisher.swift` | Recording fake for `NowPlayingPublishing` |
| `Tests/Maxi80Tests/Fakes/StubAPIClient.swift` | One shared stub replacing 5 duplicated copies |
| `Tests/Maxi80Tests/Fakes/TestCoordinator.swift` | `makeTestCoordinator(...)` factory replacing 11 duplicated construction sites |
| `Tests/Maxi80Tests/PlayerCommandTests.swift` | New coverage: fade ramp, true-stop, cold-start adoption, reconnect |
| `Tests/Maxi80Tests/SharingTests.swift` | New coverage: share forwarding |
| `Tests/Maxi80Tests/NowPlayingPublishingTests.swift` | New coverage: publisher seam |

**Modify:**
| File | Change |
|---|---|
| `Sources/Maxi80/RadioPlayerCoordinator.swift` | Dependency types → existentials; injectable delays; Task 8 collapses the Now Playing `#if`s |
| `Sources/Maxi80/NowPlayingSession.swift` | Un-gate + widen `NowPlayingPublishing`; drop `deactivate()` |
| `Sources/Maxi80/ReconnectionManager.swift` | Add `timeScale` for fast tests |
| 9 existing test files | Migrate to shared factory + fakes |

## Task Sequencing

Task 1 is a **gate** — it answers the one unverified question and everything else depends on the answer.

---

### Task 1: Spike — verify retroactive conformance compiles for Android

**Files:**
- Create (temporary, reverted at end): `Sources/Maxi80/Services/SpikeAudioPlaying.swift`

**Interfaces:**
- Consumes: nothing
- Produces: a **decision** consumed by Task 2 — either "direct conformance works" or "use adapter fallback"

**Why this is first:** An empty retroactive conformance on a `/* SKIP @bridge */` class is the only part of this refactor whose Android-build behavior cannot be determined by reading code. If it fails, Task 2's approach changes entirely. Spike now, throw it away.

- [ ] **Step 1: Create the minimal spike file**

```swift
// Sources/Maxi80/Services/SpikeAudioPlaying.swift
import Maxi80Services

/// TEMPORARY SPIKE — delete before committing. Verifies that a retroactive protocol
/// conformance on a bridged class compiles under the Android Fuse build.
@MainActor
protocol SpikeAudioPlaying: AnyObject {
  var isPlaying: Bool { get }
  func play(url: String)
}

extension AudioStreamPlayer: SpikeAudioPlaying {}
```

- [ ] **Step 2: Verify the Apple build compiles**

Run: `swift build`
Expected: PASS. If it fails with "does not conform", the member signatures differ from what the spec recorded — read `Sources/Maxi80Services/AudioStreamPlayer.swift` and reconcile before continuing.

- [ ] **Step 3: Verify the Android build compiles (the real question)**

Run: `make build-android`
Expected: PASS.

If this **fails**, record the exact error and switch Task 2 to the **adapter fallback**: instead of `extension AudioStreamPlayer: AudioPlaying {}`, create a `final class AudioPlayerAdapter: AudioPlaying` in the native module holding an `AudioStreamPlayer` and forwarding every member (including bidirectional callback wiring in its `init`). All later tasks are unaffected — they depend only on the `AudioPlaying` protocol, not on how conformance is achieved.

Note from project memory: if this build fails with bogus "cannot find in scope" or "internal" errors, it may be stale transpile artifacts rather than a real failure — run `make clean build-android` once before concluding the spike failed.

- [ ] **Step 4: Delete the spike**

```bash
rm Sources/Maxi80/Services/SpikeAudioPlaying.swift
swift build
```
Expected: PASS. Nothing to commit — this task produces a decision, not code.

---

### Task 2: `AudioPlaying` protocol and conformance

**Files:**
- Create: `Sources/Maxi80/Services/AudioPlaying.swift`

**Interfaces:**
- Consumes: Task 1's conformance decision
- Produces: `protocol AudioPlaying` with members — `var isPlaying: Bool { get }`; settable closure properties `onMetadataChanged: ((String) -> Void)?`, `onError: ((String) -> Void)?`, `onInterruption: ((Bool) -> Void)?`, `onDisconnectStop: (() -> Void)?`, `onPlaybackStateChanged: ((Bool) -> Void)?`, `onVolumeChanged: ((Double) -> Void)?`; methods `play(url: String)`, `stop()`, `updateVolume(_ newVolume: Double)`, `setPlaybackAttenuation(_ multiplier: Double)`, `currentVolume() -> Double`, `startObservingVolume()`, `syncWithExternalPlayback() -> Bool`

- [ ] **Step 1: Create the protocol and conformance**

```swift
// Sources/Maxi80/Services/AudioPlaying.swift
import Foundation
import Maxi80Services

/// The audio-playback surface the coordinator depends on, abstracting the bridged
/// `AudioStreamPlayer` so tests can inject a recording fake.
///
/// Declared in the native module deliberately: it never crosses the JNI boundary, so the
/// `Maxi80Services` bridge is untouched. Mirrors the existing `NowPlayingPublishing` seam.
///
/// `AnyObject` because the coordinator mutates the callback properties on a shared reference and
/// relies on reference semantics for the player's lifetime.
@MainActor
protocol AudioPlaying: AnyObject {
  /// Whether audio is currently playing, as the player last reported it. May be stale-`false` when
  /// playback was started externally (e.g. Android Auto cold start) — see `syncWithExternalPlayback()`.
  var isPlaying: Bool { get }

  var onMetadataChanged: ((String) -> Void)? { get set }
  var onError: ((String) -> Void)? { get set }
  var onInterruption: ((Bool) -> Void)? { get set }
  var onDisconnectStop: (() -> Void)? { get set }
  var onPlaybackStateChanged: ((Bool) -> Void)? { get set }
  var onVolumeChanged: ((Double) -> Void)? { get set }

  func play(url: String)
  func stop()
  func updateVolume(_ newVolume: Double)
  func setPlaybackAttenuation(_ multiplier: Double)
  func currentVolume() -> Double
  func startObservingVolume()
  func syncWithExternalPlayback() -> Bool
}

/// `AudioStreamPlayer`'s signatures already match exactly, so the conformance is empty.
extension AudioStreamPlayer: AudioPlaying {}
```

- [ ] **Step 2: Verify both platforms build**

Run: `swift build && make build-android`
Expected: PASS both. (Task 1 already proved the Android half; this confirms the full member list.)

- [ ] **Step 3: Verify the existing suite is untouched**

Run: `swift test`
Expected: PASS — nothing consumes the protocol yet.

- [ ] **Step 4: Commit**

```bash
git add Sources/Maxi80/Services/AudioPlaying.swift
git commit -m "refactor: add AudioPlaying protocol seam over the bridged player"
```

---

### Task 3: `FakeAudioPlayer` and shared test scaffolding

**Files:**
- Create: `Tests/Maxi80Tests/Fakes/FakeAudioPlayer.swift`
- Create: `Tests/Maxi80Tests/Fakes/StubAPIClient.swift`

**Interfaces:**
- Consumes: `AudioPlaying` (Task 2)
- Produces:
  - `final class FakeAudioPlayer: AudioPlaying` with `var commands: [PlayerCommand]`, `var isPlaying: Bool` (settable), `var syncResult: Bool`, `var systemVolume: Double`, `var attenuation: Double`, `var volume: Double`, and helpers `attenuations() -> [Double]`, `playedURLs() -> [String]`, `stopCount() -> Int`, `reset()`
  - `enum PlayerCommand: Equatable` with cases `play(url: String)`, `stop`, `updateVolume(Double)`, `setAttenuation(Double)`, `startObservingVolume`, `syncWithExternalPlayback`
  - `actor StubAPIClient: APIClientProtocol` — all three methods `throw .noContent`

- [ ] **Step 1: Create the recording fake**

```swift
// Tests/Maxi80Tests/Fakes/FakeAudioPlayer.swift
import Foundation

@testable import Maxi80

/// One recorded interaction the coordinator had with the player, in order.
enum PlayerCommand: Equatable {
  case play(url: String)
  case stop
  case updateVolume(Double)
  case setAttenuation(Double)
  case startObservingVolume
  case syncWithExternalPlayback
}

/// Recording fake for `AudioPlaying`.
///
/// Exists because the real `AudioStreamPlayer` spins up the platform AVPlayer path and only allows
/// pushing callbacks inward — tests could not observe what the coordinator asked the player to DO.
@MainActor
final class FakeAudioPlayer: AudioPlaying {

  /// Every command the coordinator issued, in order.
  var commands: [PlayerCommand] = []

  /// Staged state the coordinator reads.
  var isPlaying: Bool = false
  /// What `syncWithExternalPlayback()` returns — stage `true` to simulate externally-started
  /// playback (Android Auto cold start) that the `isPlaying` flag hasn't caught up with.
  var syncResult: Bool = false
  /// What `currentVolume()` returns.
  var systemVolume: Double = 1.0

  /// Mirrors the real player's stored values so tests can read the final state.
  var volume: Double = 1.0
  var attenuation: Double = 1.0

  var onMetadataChanged: ((String) -> Void)?
  var onError: ((String) -> Void)?
  var onInterruption: ((Bool) -> Void)?
  var onDisconnectStop: (() -> Void)?
  var onPlaybackStateChanged: ((Bool) -> Void)?
  var onVolumeChanged: ((Double) -> Void)?

  func play(url: String) {
    commands.append(.play(url: url))
    isPlaying = true
  }

  func stop() {
    commands.append(.stop)
    isPlaying = false
  }

  func updateVolume(_ newVolume: Double) {
    commands.append(.updateVolume(newVolume))
    volume = newVolume
  }

  func setPlaybackAttenuation(_ multiplier: Double) {
    commands.append(.setAttenuation(multiplier))
    attenuation = multiplier
  }

  func currentVolume() -> Double { systemVolume }

  func startObservingVolume() {
    commands.append(.startObservingVolume)
  }

  func syncWithExternalPlayback() -> Bool {
    commands.append(.syncWithExternalPlayback)
    return syncResult
  }

  // MARK: - Assertion helpers

  /// The attenuation values written, in order — used to verify the sleep-timer fade ramp.
  func attenuations() -> [Double] {
    commands.compactMap { if case .setAttenuation(let value) = $0 { return value } else { return nil } }
  }

  /// The URLs played, in order.
  func playedURLs() -> [String] {
    commands.compactMap { if case .play(let url) = $0 { return url } else { return nil } }
  }

  /// How many true-stops were issued.
  func stopCount() -> Int {
    commands.filter { $0 == .stop }.count
  }

  /// Clear the recording — useful to isolate the commands from one phase of a test.
  func reset() {
    commands.removeAll()
  }
}
```

- [ ] **Step 2: Create the shared API stub**

This replaces byte-identical copies currently duplicated in `SleepTimerTests`, `AudioFocusInterruptionTests`, `ResumeReconciliationTests`, and `VolumeSyncTests`.

```swift
// Tests/Maxi80Tests/Fakes/StubAPIClient.swift
@testable import Maxi80Model

/// A backend that always returns no content. Coordinator tests that don't exercise the network
/// use this so `loadStation()` / `fetchHistory()` are inert.
actor StubAPIClient: APIClientProtocol {
  func fetchStation() async throws(APIClientError) -> String { throw .noContent }
  func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
    throw .noContent
  }
  func fetchHistory() async throws(APIClientError) -> String { throw .noContent }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build --build-tests`
Expected: PASS. Duplicate `StubAPIClient` declarations in existing files are **nested inside their `@Suite` structs**, so the new top-level one does not collide. Task 5 removes the nested copies.

- [ ] **Step 4: Commit**

```bash
git add Tests/Maxi80Tests/Fakes/
git commit -m "test: add FakeAudioPlayer and shared StubAPIClient"
```

---

### Task 4: Coordinator depends on `AudioPlaying`

**Files:**
- Modify: `Sources/Maxi80/RadioPlayerCoordinator.swift:25` (property) and `:102-108` (init signature)

**Interfaces:**
- Consumes: `AudioPlaying` (Task 2)
- Produces: `RadioPlayerCoordinator.init(player: any AudioPlaying, nowPlaying: NowPlayingController, apiClient: any APIClientProtocol, artworkService: ArtworkService, shareService: ShareService = ShareService())` — only the `player` parameter type changes in this task

- [ ] **Step 1: Change the stored property type**

In `Sources/Maxi80/RadioPlayerCoordinator.swift`, change:

```swift
  @ObservationIgnored
  private let player: AudioStreamPlayer
```

to:

```swift
  @ObservationIgnored
  private let player: any AudioPlaying
```

- [ ] **Step 2: Change the init parameter type**

Change `player: AudioStreamPlayer,` to `player: any AudioPlaying,` in the `public init`.

- [ ] **Step 3: Verify both platforms build**

Run: `swift build && make build-android`
Expected: PASS. `SharedPlayer.coordinator` passes a concrete `AudioStreamPlayer()`, which satisfies `any AudioPlaying` with no change needed at the composition root.

- [ ] **Step 4: Verify the existing suite still passes**

Run: `swift test`
Expected: PASS. Existing tests still pass a real `AudioStreamPlayer()`; it now binds as the existential. Behavior identical.

- [ ] **Step 5: Commit**

```bash
git add Sources/Maxi80/RadioPlayerCoordinator.swift
git commit -m "refactor: coordinator depends on AudioPlaying, not the concrete player"
```

---

### Task 5: Shared test-coordinator factory; migrate all 11 construction sites

**Files:**
- Create: `Tests/Maxi80Tests/Fakes/TestCoordinator.swift`
- Modify: `Tests/Maxi80Tests/SleepTimerTests.swift`, `AudioFocusInterruptionTests.swift`, `ResumeReconciliationTests.swift`, `VolumeSyncTests.swift`, `CarPlayNowPlayingTests.swift`, `RadioPlayerViewModelTests.swift`, `ViewModelPropertyTests.swift`, `HistoryMergeTests.swift`, `ShareTextPropertyTests.swift`

**Interfaces:**
- Consumes: `FakeAudioPlayer`, `StubAPIClient` (Task 3); coordinator init (Task 4)
- Produces: `@MainActor func makeTestCoordinator(apiClient: (any APIClientProtocol)? = nil, player: FakeAudioPlayer? = nil) -> (coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer)` — returns the fake as its **concrete** type so tests can stage state and read `commands`

- [ ] **Step 1: Create the factory**

```swift
// Tests/Maxi80Tests/Fakes/TestCoordinator.swift
@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Builds a coordinator wired to fakes. Replaces the near-identical `makeCoordinator()` helpers
/// that were duplicated across nine test files, so future seam changes touch one place.
///
/// Returns the player as the concrete `FakeAudioPlayer` (not `any AudioPlaying`) so callers can
/// stage `isPlaying`/`syncResult` and assert against `commands`.
@MainActor
func makeTestCoordinator(
  apiClient: (any APIClientProtocol)? = nil,
  player: FakeAudioPlayer? = nil
) -> (coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer) {
  let fakePlayer = player ?? FakeAudioPlayer()
  let client = apiClient ?? StubAPIClient()
  let coordinator = RadioPlayerCoordinator(
    player: fakePlayer,
    nowPlaying: NowPlayingController(),
    apiClient: client,
    artworkService: ArtworkService(apiClient: client)
  )
  return (coordinator, fakePlayer)
}
```

- [ ] **Step 2: Migrate the four files that have a `makeCoordinator()` returning a player**

In `SleepTimerTests.swift`, `AudioFocusInterruptionTests.swift`, and `ResumeReconciliationTests.swift`: delete the nested `actor StubAPIClient { ... }` block and replace the whole private `makeCoordinator()` helper with a delegating one, so call sites need no edits:

```swift
  @MainActor
  private func makeCoordinator() -> (coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer) {
    makeTestCoordinator()
  }
```

In `VolumeSyncTests.swift`, delete its nested `StubAPIClient` and replace `make()`:

```swift
  @MainActor
  private func make() -> (
    vm: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer
  ) {
    let (coordinator, player) = makeTestCoordinator()
    return (RadioPlayerViewModel(coordinator: coordinator), coordinator, player)
  }
```

Then fix the type annotations these files use: `AudioFocusInterruptionTests.fireInterruption(_ player: AudioStreamPlayer, began: Bool)` becomes `fireInterruption(_ player: FakeAudioPlayer, began: Bool)`.

- [ ] **Step 3: Migrate the five remaining files**

These construct inline and use a real `APIClient` with a dummy base URL. Keep that client (some assert artwork-URL shapes); swap only the player.

`CarPlayNowPlayingTests.swift` — replace the body of `makeCoordinator()`:

```swift
  @MainActor
  private func makeCoordinator() -> RadioPlayerCoordinator {
    let apiClient = APIClient(baseURL: "https://test.example.com", authToken: "test-key")
    return makeTestCoordinator(apiClient: apiClient).coordinator
  }
```

`RadioPlayerViewModelTests.swift` — replace the body of `makeViewModel()`:

```swift
  @MainActor
  private func makeViewModel() -> (vm: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator) {
    let apiClient = APIClient(baseURL: "https://test.example.com", authToken: "test-key")
    let (coordinator, _) = makeTestCoordinator(apiClient: apiClient)
    return (RadioPlayerViewModel(coordinator: coordinator), coordinator)
  }
```

`ViewModelPropertyTests.swift` — inside the `for iteration` loop, replace the five construction lines with:

```swift
      let apiClient = APIClient(baseURL: "https://test.example.com", authToken: "test-key")
      let (coordinator, _) = makeTestCoordinator(apiClient: apiClient)
      let vm = RadioPlayerViewModel(coordinator: coordinator)
```

`HistoryMergeTests.swift` — both sites. Replace `makeCoordinator(historyJSON:servesArtwork:)`'s return expression and `makeGatedCoordinator(client:)`:

```swift
  @MainActor
  private func makeCoordinator(historyJSON: String, servesArtwork: Bool = false)
    -> RadioPlayerCoordinator
  {
    let apiClient = HistoryMockAPIClient(historyJSON: historyJSON, servesArtwork: servesArtwork)
    return makeTestCoordinator(apiClient: apiClient).coordinator
  }

  @MainActor
  private func makeGatedCoordinator(client: GatedArtworkAPIClient) -> RadioPlayerCoordinator {
    makeTestCoordinator(apiClient: client).coordinator
  }
```

`ShareTextPropertyTests.swift` — both sites. In `shareTextFormatting()` replace the five construction lines, and replace `makeViewModel()`:

```swift
    let apiClient = APIClient(baseURL: "https://test.com", authToken: "test-key")
    let (coordinator, _) = makeTestCoordinator(apiClient: apiClient)
    let vm = RadioPlayerViewModel(coordinator: coordinator)
```

```swift
  @MainActor
  private func makeViewModel() -> (RadioPlayerViewModel, RadioPlayerCoordinator) {
    let apiClient = APIClient(baseURL: "https://test.com", authToken: "test-key")
    let (coordinator, _) = makeTestCoordinator(apiClient: apiClient)
    return (RadioPlayerViewModel(coordinator: coordinator), coordinator)
  }
```

- [ ] **Step 4: Confirm no real player remains in the test suite**

Run: `grep -rn "AudioStreamPlayer()" Tests/`
Expected: **no output**. Any remaining hit is a missed site.

- [ ] **Step 5: Run the full suite — this is the behavior-preservation gate**

Run: `swift test`
Expected: PASS, with **no assertion changed** in any migrated file. Only construction changed, so a failure here means the fake diverges from the real player's behavior. Most likely culprit: `FakeAudioPlayer.play(url:)` sets `isPlaying = true` whereas the real AVPlayer path is asynchronous. If a test depended on `isPlaying` staying `false` right after `play()`, fix the **fake** to match reality rather than editing the assertion — and note it.

- [ ] **Step 6: Commit**

```bash
git add Tests/
git commit -m "test: route all coordinator tests through a shared fake-backed factory"
```

---

### Task 6: New player-command coverage (TDD)

**Files:**
- Create: `Tests/Maxi80Tests/PlayerCommandTests.swift`
- Modify: `Sources/Maxi80/ReconnectionManager.swift` (add `timeScale`)
- Modify: `Sources/Maxi80/RadioPlayerCoordinator.swift` (injectable `reconnectConfirmationDelay`)

**Interfaces:**
- Consumes: `makeTestCoordinator` (Task 5), `FakeAudioPlayer` (Task 3)
- Produces: `ReconnectionManager.init(timeScale: Double = 1.0)`; `RadioPlayerCoordinator.init(..., reconnectConfirmationDelay: UInt64 = 3_000_000_000, reconnectTimeScale: Double = 1.0)`

**Why the production edits:** `ReconnectionManager` sleeps `2^attempt` seconds (`:49`) before the first reconnect, and the coordinator then waits `reconnectConfirmationDelay` = 3s (`:94`). A reconnect test would take 5+ real seconds. Scaling both is the minimum change that makes the path testable; defaults keep production timing byte-identical.

**Also required:** `handleError(_:)` is `private` at `RadioPlayerCoordinator.swift:747`, so the reconnect test cannot call it. Widen it to internal (Step 4a below), matching the existing convention in this file — `handleMetadataChanged`, `handleDisconnectStop`, and `handlePlaybackStateChanged` are all already internal-with-a-comment precisely so tests can drive them.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/Maxi80Tests/PlayerCommandTests.swift
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
    let player = FakeAudioPlayer()
    let client = StubAPIClient()
    let coordinator = RadioPlayerCoordinator(
      player: player,
      nowPlaying: NowPlayingController(),
      apiClient: client,
      artworkService: ArtworkService(apiClient: client),
      sleepFadeDuration: 12_000_000
    )
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

    let ramp = player.attenuations()
    #expect(player.stopCount() == 1, "the fade must end in a true stop")
    #expect(ramp.count >= 12, "expected one attenuation write per fade step")
    // Monotonically descending.
    #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 >= $1 }, "ramp must not increase: \(ramp)")
    // The ramp reaches true silence before stopping — a faded-but-audible stop is the bug guarded here.
    #expect(ramp.contains(0.0), "ramp must reach 0.0; got \(ramp)")
    // Attenuation is restored so the next play isn't silent.
    #expect(player.attenuation == 1.0, "attenuation must be restored to 1.0 after the stop")
  }

  @Test("Cancelling a sleep timer restores full volume and issues no stop")
  @MainActor
  func cancelSleepTimerRestoresVolume() async {
    let (coordinator, player) = makeTestCoordinator()
    await startPlaying(coordinator)
    coordinator.startSleepTimer(minutes: 15)
    player.reset()

    coordinator.cancelSleepTimer()

    #expect(coordinator.sleepTimerFiresAt == nil)
    #expect(player.stopCount() == 0, "cancelling must not stop playback")
    #expect(player.attenuation == 1.0)
  }

  // MARK: - True-stop semantics (issue #49 / StopOnPausePlayer invariant)

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
    // Scale both delays down so the 2s backoff + 3s confirmation don't dominate the test.
    let player = FakeAudioPlayer()
    let client = StubAPIClient()
    let coordinator = RadioPlayerCoordinator(
      player: player,
      nowPlaying: NowPlayingController(),
      apiClient: client,
      artworkService: ArtworkService(apiClient: client),
      reconnectConfirmationDelay: 1_000_000,
      reconnectTimeScale: 0.001
    )
    coordinator.station = Station(
      name: "Maxi 80", streamUrl: "https://stream.example/live.mp3", image: "",
      shortDesc: "", longDesc: "", websiteUrl: "", donationUrl: "", defaultCoverUrl: "")
    player.reset()

    // The player will report healthy playback, so the first attempt should succeed.
    player.isPlaying = true
    coordinator.handleError("stream dropped")

    var waited = 0
    while player.playedURLs().isEmpty && waited < 100 {
      try? await Task.sleep(nanoseconds: 10_000_000)
      waited += 1
    }

    #expect(player.playedURLs() == ["https://stream.example/live.mp3"])
    #expect(coordinator.playbackState == .playing, "a confirmed replay resolves to playing")
  }
}
```

- [ ] **Step 2: Run to verify they fail for the right reason**

Run: `swift test --filter PlayerCommandTests`
Expected: **compile failure** — `RadioPlayerCoordinator.init` has no `reconnectConfirmationDelay` / `reconnectTimeScale` parameters. That is the correct first failure; the remaining tests can't run until it's addressed.

- [ ] **Step 3: Add `timeScale` to `ReconnectionManager`**

In `Sources/Maxi80/ReconnectionManager.swift`, add the stored property and init, and thread it through `delay(for:)`:

```swift
  /// Multiplies every backoff delay. `1.0` in production; tests pass a tiny value so the
  /// 2s/4s/8s ladder doesn't dominate the suite. Does not change the 2^n shape.
  private let timeScale: Double

  public init(timeScale: Double = 1.0) {
    self.timeScale = timeScale
  }
```

Change `delay(for:)`'s body to:

```swift
    let seconds = pow(2.0, Double(attempt)) * timeScale
    return UInt64(seconds * 1_000_000_000)
```

- [ ] **Step 3a: Make the sleep-timer fade duration injectable**

`sleepFadeDurationNanos` is a hardcoded `private static let` at `RadioPlayerCoordinator.swift:255`, so the fade test would otherwise poll for the full production 2.5s. Convert it to an instance property set by `init`. Replace:

```swift
  /// How long the fade-out runs before playback stops, in nanoseconds.
  private static let sleepFadeDurationNanos: UInt64 = 2_500_000_000
```

with:

```swift
  /// How long the fade-out runs before playback stops, in nanoseconds. Injectable so tests can
  /// drive the ramp in milliseconds; production keeps the 2.5s default.
  private let sleepFadeDuration: UInt64
```

Then in `fireSleepTimer()` at `:338`, change `Self.sleepFadeDurationNanos` to `sleepFadeDuration`:

```swift
    let stepDelay = sleepFadeDuration / UInt64(Self.sleepFadeSteps)
```

Leave `sleepFadeSteps` and `fadeMultiplier(step:)` alone — they are `static`/`nonisolated` because pure tests already exercise them.

- [ ] **Step 4: Make the coordinator's delays injectable**

In `Sources/Maxi80/RadioPlayerCoordinator.swift`, change the hardcoded constant at `:94` from a `let` initialized inline to one set by the init, and build the manager with the scale. Replace the declaration:

```swift
  /// How long to wait after issuing a reconnect `play()` before checking whether the
  /// stream actually resumed.
  private let reconnectConfirmationDelay: UInt64
```

Change the `reconnectionManager` declaration at `:63-64` from its inline initializer:

```swift
  @ObservationIgnored
  private let reconnectionManager = ReconnectionManager()
```

to one assigned in `init`:

```swift
  @ObservationIgnored
  private let reconnectionManager: ReconnectionManager
```

Add the two parameters to the end of `public init` (before the body) and assign them **before** `setupCallbacks()` / `setupReconnection()` run:

```swift
    shareService: ShareService = ShareService(),
    reconnectConfirmationDelay: UInt64 = 3_000_000_000,
    reconnectTimeScale: Double = 1.0,
    sleepFadeDuration: UInt64 = 2_500_000_000
  ) {
    self.player = player
    self.nowPlaying = nowPlaying
    self.apiClient = apiClient
    self.artworkService = artworkService
    self.shareService = shareService
    self.reconnectConfirmationDelay = reconnectConfirmationDelay
    self.reconnectionManager = ReconnectionManager(timeScale: reconnectTimeScale)
    self.sleepFadeDuration = sleepFadeDuration

    setupCallbacks()
    setupReconnection()
```

All three injected values default to the current production constants, so production timing is byte-identical.

- [ ] **Step 4a: Make `handleError` reachable from tests**

At `Sources/Maxi80/RadioPlayerCoordinator.swift:747`, change:

```swift
  private func handleError(_ message: String) {
```

to internal, with a comment matching the file's existing convention for test-driven entry points:

```swift
  // Internal (not private) so tests can drive the reconnection cycle directly — the production
  // caller is the `player.onError` closure wired in `setupCallbacks()`.
  func handleError(_ message: String) {
```

- [ ] **Step 5: Run the new tests**

Run: `swift test --filter PlayerCommandTests`
Expected: PASS, all nine.

If `sleepTimerFadesThenStops` fails on `ramp.contains(0.0)`, that is a **real product finding**, not a test bug: `fadeMultiplier(step:)` at the final step must yield exactly `0.0`. Report it rather than loosening the assertion.

- [ ] **Step 6: Run the whole suite for regressions**

Run: `swift test && make build-android`
Expected: PASS. `ReconnectionPropertyTests` exercises `delay(for:)` and must still pass with the default `timeScale` of `1.0`.

- [ ] **Step 7: Commit**

```bash
git add Tests/Maxi80Tests/PlayerCommandTests.swift Sources/Maxi80/ReconnectionManager.swift Sources/Maxi80/RadioPlayerCoordinator.swift
git commit -m "test: cover fade ramp, true-stop, cold-start adoption and reconnect"
```

---

### Task 7: `Sharing` protocol and coverage (TDD)

**Files:**
- Create: `Sources/Maxi80/Services/Sharing.swift`
- Create: `Tests/Maxi80Tests/Fakes/FakeSharing.swift`
- Create: `Tests/Maxi80Tests/SharingTests.swift`
- Modify: `Sources/Maxi80/RadioPlayerCoordinator.swift` (property + init type), `Sources/Maxi80/SharedPlayer.swift` (pass it explicitly)
- Modify: `Tests/Maxi80Tests/Fakes/TestCoordinator.swift` (thread the fake through)

**Interfaces:**
- Consumes: `makeTestCoordinator` (Task 5)
- Produces: `protocol Sharing { func share(text: String, imageData: Data?) }`; `final class FakeSharing: Sharing` with `var shares: [(text: String, imageData: Data?)]`; `makeTestCoordinator` gains `shareService: FakeSharing? = nil` and returns a 3-tuple `(coordinator:player:shareService:)`

- [ ] **Step 1: Write the failing test**

```swift
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
    let (coordinator, _, share) = makeTestCoordinator()

    await coordinator.shareCurrentTrack(text: "listen to this", artworkURL: nil)

    #expect(share.shares.count == 1)
    #expect(share.shares.first?.text == "listen to this")
    #expect(share.shares.first?.imageData == nil, "a nil artwork URL must degrade to text-only")
  }

  @Test("A failed artwork download still shares the text")
  @MainActor
  func failedArtworkStillSharesText() async {
    // The stub API client serves no artwork, so the image fetch fails.
    let (coordinator, _, share) = makeTestCoordinator()

    await coordinator.shareCurrentTrack(
      text: "listen to this", artworkURL: "https://nonexistent.invalid/cover.jpg")

    #expect(share.shares.count == 1, "a download failure must not swallow the share")
    #expect(share.shares.first?.text == "listen to this")
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SharingTests`
Expected: compile failure — `makeTestCoordinator` returns a 2-tuple and `FakeSharing` doesn't exist.

- [ ] **Step 3: Create the protocol and conformance**

```swift
// Sources/Maxi80/Services/Sharing.swift
import Foundation
import Maxi80Services

/// The share surface the coordinator depends on, abstracting the bridged `ShareService`.
/// Declared in the native module so it never crosses the JNI boundary — see `AudioPlaying`.
@MainActor
protocol Sharing: AnyObject {
  /// Present the platform share chooser. Fire-and-forget.
  func share(text: String, imageData: Data?)
}

extension ShareService: Sharing {}
```

- [ ] **Step 4: Create the fake**

```swift
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
```

- [ ] **Step 5: Switch the coordinator to the protocol and drop the defaulted argument**

In `Sources/Maxi80/RadioPlayerCoordinator.swift` change the property:

```swift
  @ObservationIgnored
  private let shareService: any Sharing
```

and the init parameter from `shareService: ShareService = ShareService()` to `shareService: any Sharing`. Removing the default is deliberate — it stops any call site from silently constructing a real share service.

- [ ] **Step 6: Pass it explicitly at the composition root**

In `Sources/Maxi80/SharedPlayer.swift`, add the service to the graph:

```swift
    // 5. Platform share chooser (Android presents the system sheet; Apple uses SwiftUI ShareSheet).
    let shareService = ShareService()

    // 6. Coordinator with all dependencies injected.
    return RadioPlayerCoordinator(
      player: player,
      nowPlaying: nowPlaying,
      apiClient: apiClient,
      artworkService: artworkService,
      shareService: shareService
    )
```

- [ ] **Step 7: Thread the fake through the test factory**

In `Tests/Maxi80Tests/Fakes/TestCoordinator.swift`, replace the function with:

```swift
@MainActor
func makeTestCoordinator(
  apiClient: (any APIClientProtocol)? = nil,
  player: FakeAudioPlayer? = nil,
  shareService: FakeSharing? = nil
) -> (coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer, shareService: FakeSharing) {
  let fakePlayer = player ?? FakeAudioPlayer()
  let fakeShare = shareService ?? FakeSharing()
  let client = apiClient ?? StubAPIClient()
  let coordinator = RadioPlayerCoordinator(
    player: fakePlayer,
    nowPlaying: NowPlayingController(),
    apiClient: client,
    artworkService: ArtworkService(apiClient: client),
    shareService: fakeShare
  )
  return (coordinator, fakePlayer, fakeShare)
}
```

Existing callers destructure a 2-tuple and will now fail to compile. Fix each by ignoring the third element — `let (coordinator, player, _) = makeTestCoordinator()` — or, where the file's helper returns `.coordinator` / `.player` by label, no change is needed. Also update Task 6's `reconnectReplaysStationURL`, which constructs the coordinator directly, to pass `shareService: FakeSharing()`.

- [ ] **Step 8: Run the new tests, then everything**

Run: `swift test --filter SharingTests`
Expected: PASS both.

Run: `swift test && make build-android`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/Maxi80/Services/Sharing.swift Tests/Maxi80Tests/Fakes/ Tests/Maxi80Tests/SharingTests.swift Sources/Maxi80/RadioPlayerCoordinator.swift Sources/Maxi80/SharedPlayer.swift
git commit -m "refactor: add Sharing protocol seam and cover share forwarding"
```

---

### Task 8: Unify the two Now Playing publishing paths

**Files:**
- Modify: `Sources/Maxi80/NowPlayingSession.swift` (widen + un-gate the protocol, drop `deactivate()`)
- Create: `Sources/Maxi80/Services/BridgedNowPlayingPublisher.swift`
- Modify: `Sources/Maxi80/RadioPlayerCoordinator.swift` (single publisher; delete both `#if !SKIP` branches)
- Create: `Tests/Maxi80Tests/Fakes/FakeNowPlayingPublisher.swift`
- Create: `Tests/Maxi80Tests/NowPlayingPublishingTests.swift`
- Modify: `Tests/Maxi80Tests/Fakes/TestCoordinator.swift`

**Interfaces:**
- Consumes: `makeTestCoordinator` (Task 7)
- Produces: `protocol NowPlayingPublishing { func activate(); func update(stationName: String, artist: String, title: String, artworkURL: String?, isPlaying: Bool); func updatePlaybackState(isPlaying: Bool) }`; `final class BridgedNowPlayingPublisher: NowPlayingPublishing`; `makeTestCoordinator` gains `nowPlaying: FakeNowPlayingPublisher? = nil` and returns a 4-tuple

**Behavior contract — must not change:** the modern iOS-27 publisher is still preferred where available; the bridged MediaPlayer path remains the fallback and the only path on Android; `activate()` still precedes the first update; the CarPlay placeholder substitution (`shouldPublishPlaceholderArtwork`) still applies.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/Maxi80Tests/NowPlayingPublishingTests.swift
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
    let (coordinator, _, _, publisher) = makeTestCoordinator()

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
    let (coordinator, _, _, publisher) = makeTestCoordinator()

    await coordinator.handleMetadataChanged("Artist - Song")

    #expect(publisher.activateCount >= 1, "the session must be activated before publishing")
  }

  @Test("A pause publishes a not-playing state")
  @MainActor
  func pausePublishesStopped() async {
    let (coordinator, _, _, publisher) = makeTestCoordinator()
    await coordinator.handleMetadataChanged("Artist - Song")
    publisher.reset()

    coordinator.pause()

    #expect(publisher.playbackStates.last == false)
  }

  @Test("A coverless song publishes the placeholder rather than blank artwork")
  @MainActor
  func coverlessSongPublishesPlaceholder() async {
    // The stub client serves no artwork, so the resolved cover is the default (no URL).
    let (coordinator, _, _, publisher) = makeTestCoordinator()

    await coordinator.handleMetadataChanged("Artist - Song")

    // On Apple platforms the placeholder materializes to a file:// URL; on Android there are no
    // image APIs so it stays nil. Assert the decision, which is platform-independent.
    #expect(coordinator.shouldPublishPlaceholderArtwork(forArtworkURL: nil) == true)
    #expect(publisher.updates.isEmpty == false)
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter NowPlayingPublishingTests`
Expected: compile failure — `makeTestCoordinator` returns a 3-tuple and `FakeNowPlayingPublisher` doesn't exist.

- [ ] **Step 3: Widen and un-gate the protocol**

In `Sources/Maxi80/NowPlayingSession.swift`, move the protocol **outside** the `#if !SKIP` block (its body is pure Swift and Android-safe) and change it to:

```swift
/// Abstraction the coordinator uses to publish Now Playing info, so it depends on neither the
/// iOS-27-only NowPlaying framework nor the bridged MediaPlayer controller directly.
///
/// Two conformances: `NowPlayingSession` (modern framework, iOS/macOS/tvOS 27+) and
/// `BridgedNowPlayingPublisher` (MediaPlayer on Apple, MediaSession on Android).
@MainActor
protocol NowPlayingPublishing: AnyObject {
  /// Begin publishing the session to the system (Lock Screen, Control Center, accessories).
  func activate()
  /// Update the currently-playing metadata.
  func update(
    stationName: String, artist: String, title: String, artworkURL: String?, isPlaying: Bool)
  /// Update only the play/pause state.
  func updatePlaybackState(isPlaying: Bool)
}
```

`deactivate()` is dropped — it has no caller anywhere in `Sources/` or `Tests/`.

Keep `makeModernNowPlaying(onPlay:onPause:)` inside `#if !SKIP` as-is.

In the `NowPlayingSession` class (inside `#if !SKIP && canImport(NowPlaying)`, which already declares `: MediaSessionRepresentable, NowPlayingPublishing`), replace this exact method:

```swift
    func update(stationName: String, programName: String, artworkURL: String?, isPlaying: Bool) {
      self.stationName = stationName
      self.programName = programName
      self.artworkURL = artworkURL
      self.isPlaying = isPlaying
      self.startedAt = Date()
    }
```

with the widened signature, which folds in the `"title — artist"` formatting the coordinator previously did at the call site:

```swift
    func update(
      stationName: String, artist: String, title: String, artworkURL: String?, isPlaying: Bool
    ) {
      self.stationName = stationName
      // Preserves the exact format the coordinator built inline before unification.
      self.programName = "\(title) — \(artist)"
      self.artworkURL = artworkURL
      self.isPlaying = isPlaying
      self.startedAt = Date()
    }
```

Also delete this method (no caller anywhere):

```swift
    func deactivate() {
      session = nil
    }
```

Leave `activate()`, `updatePlaybackState(isPlaying:)`, `content`, `playbackSnapshot`, and `commands` untouched.

- [ ] **Step 4: Create the bridged adapter**

```swift
// Sources/Maxi80/Services/BridgedNowPlayingPublisher.swift
import Foundation
import Maxi80Services

/// Publishes Now Playing info through the bridged `NowPlayingController` — MediaPlayer
/// (`MPNowPlayingInfoCenter`) on Apple platforms, the media3 `MediaSession` on Android.
///
/// This is the fallback path where the modern NowPlaying framework is unavailable, and the ONLY
/// path on Android. Exists so the coordinator can hold a single `any NowPlayingPublishing` instead
/// of branching on `#if !SKIP` at every publish site.
@MainActor
final class BridgedNowPlayingPublisher: NowPlayingPublishing {
  private let controller: NowPlayingController

  init(controller: NowPlayingController) {
    self.controller = controller
  }

  /// No-op: the MediaPlayer info center and the Android MediaSession are both implicitly active —
  /// there is no separate activation step to mirror the modern framework's.
  func activate() {}

  /// `stationName` is unused here: the bridged surface carries artist/title directly, whereas the
  /// modern framework models a station with a current program.
  func update(
    stationName: String, artist: String, title: String, artworkURL: String?, isPlaying: Bool
  ) {
    controller.updateNowPlaying(
      artist: artist, title: title, artworkURL: artworkURL, isPlaying: isPlaying)
  }

  func updatePlaybackState(isPlaying: Bool) {
    controller.updatePlaybackState(isPlaying: isPlaying)
  }
}
```

- [ ] **Step 5: Collapse the coordinator's two branches into one publisher**

In `Sources/Maxi80/RadioPlayerCoordinator.swift`:

Replace the `nowPlaying` stored property and the `#if !SKIP modernNowPlaying` property with one:

```swift
  @ObservationIgnored
  private let nowPlayingPublisher: any NowPlayingPublishing
```

Change the init parameter from `nowPlaying: NowPlayingController` to `nowPlaying: any NowPlayingPublishing`, assign `self.nowPlayingPublisher = nowPlaying`, and **delete** the `#if !SKIP modernNowPlaying = makeModernNowPlaying(...)` block from the init body (publisher selection moves to `SharedPlayer`).

Replace `publishNowPlaying`'s body — the placeholder logic is unchanged, only the sink selection collapses:

```swift
  private func publishNowPlaying(
    artist: String, title: String, artworkURL: String?, isPlaying: Bool
  ) {
    // On CarPlay, substitute the bundled generic cover for a missing remote one so the car's
    // Now Playing template is never blank. Both sinks load artwork by URL and accept a `file://`
    // URL, so the placeholder rides the same path.
    let publishedArtworkURL =
      shouldPublishPlaceholderArtwork(forArtworkURL: artworkURL)
      ? placeholderArtworkFileURL
      : artworkURL

    nowPlayingPublisher.activate()
    nowPlayingPublisher.update(
      stationName: station?.name ?? BrandConstants.name,
      artist: artist,
      title: title,
      artworkURL: publishedArtworkURL,
      isPlaying: isPlaying
    )
  }
```

Replace `publishPlaybackState`'s body:

```swift
  private func publishPlaybackState(isPlaying: Bool) {
    nowPlayingPublisher.updatePlaybackState(isPlaying: isPlaying)
  }
```

Finally, remove the now-unused `nowPlaying.onRemoteCommand` wiring from `setupCallbacks()` — it must move to `SharedPlayer`, which now owns the `NowPlayingController`. To keep remote commands working, add a public entry point the composition root can wire:

```swift
  /// Handle a transport command from a system surface (lock screen, notification, car).
  /// Public so the composition root can forward the bridged controller's callback, which it now
  /// owns. Values: "play", "pause", "togglePlayPause".
  public func handleRemote(_ command: String) {
    handleRemoteCommand(command)
  }
```

- [ ] **Step 6: Select the publisher at the composition root**

In `Sources/Maxi80/SharedPlayer.swift`, replace step 2 of the graph and wire the callback:

```swift
    // 2. Now Playing publisher: prefer the modern NowPlaying framework (iOS 27+), else the
    //    bridged MediaPlayer / MediaSession controller. The bridged controller is also the
    //    remote-command source, so it is retained and wired below regardless.
    let controller = NowPlayingController()
    var publisher: any NowPlayingPublishing = BridgedNowPlayingPublisher(controller: controller)
```

After the coordinator is built, wire remote commands to it:

```swift
    controller.onRemoteCommand = { command in
      Task { @MainActor in coordinator.handleRemote(command) }
    }
```

Note the ordering problem this creates: `coordinator` must exist before the closure captures it, so restructure the closure body to `SharedPlayer.coordinator.handleRemote(command)` — referencing the static lazily avoids capturing a value mid-initialization. Verify no initialization cycle at runtime by launching the app.

For the modern path, keep it Apple-only:

```swift
    #if !SKIP
      if let modern = makeModernNowPlaying(
        onPlay: { Task { @MainActor in SharedPlayer.coordinator.handleRemote("play") } },
        onPause: { Task { @MainActor in SharedPlayer.coordinator.handleRemote("pause") } }
      ) {
        publisher = modern
      }
    #endif
```

- [ ] **Step 7: Create the fake and thread it through the factory**

```swift
// Tests/Maxi80Tests/Fakes/FakeNowPlayingPublisher.swift
import Foundation

@testable import Maxi80

/// Recording fake for `NowPlayingPublishing`.
@MainActor
final class FakeNowPlayingPublisher: NowPlayingPublishing {
  struct Update: Equatable {
    let stationName: String
    let artist: String
    let title: String
    let artworkURL: String?
    let isPlaying: Bool
  }

  var activateCount = 0
  var updates: [Update] = []
  var playbackStates: [Bool] = []

  func activate() { activateCount += 1 }

  func update(
    stationName: String, artist: String, title: String, artworkURL: String?, isPlaying: Bool
  ) {
    updates.append(
      Update(
        stationName: stationName, artist: artist, title: title, artworkURL: artworkURL,
        isPlaying: isPlaying))
  }

  func updatePlaybackState(isPlaying: Bool) { playbackStates.append(isPlaying) }

  func reset() {
    activateCount = 0
    updates.removeAll()
    playbackStates.removeAll()
  }
}
```

Update `Tests/Maxi80Tests/Fakes/TestCoordinator.swift` to a 4-tuple:

```swift
@MainActor
func makeTestCoordinator(
  apiClient: (any APIClientProtocol)? = nil,
  player: FakeAudioPlayer? = nil,
  shareService: FakeSharing? = nil,
  nowPlaying: FakeNowPlayingPublisher? = nil
) -> (
  coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer, shareService: FakeSharing,
  nowPlaying: FakeNowPlayingPublisher
) {
  let fakePlayer = player ?? FakeAudioPlayer()
  let fakeShare = shareService ?? FakeSharing()
  let fakeNowPlaying = nowPlaying ?? FakeNowPlayingPublisher()
  let client = apiClient ?? StubAPIClient()
  let coordinator = RadioPlayerCoordinator(
    player: fakePlayer,
    nowPlaying: fakeNowPlaying,
    apiClient: client,
    artworkService: ArtworkService(apiClient: client),
    shareService: fakeShare
  )
  return (coordinator, fakePlayer, fakeShare, fakeNowPlaying)
}
```

Fix every caller's destructuring to the 4-tuple (add a trailing `_` where the publisher is unused), including Task 6's direct construction.

- [ ] **Step 8: Run the new tests, then everything**

Run: `swift test --filter NowPlayingPublishingTests`
Expected: PASS all four.

Run: `swift test && make build-android`
Expected: PASS. `CarPlayNowPlayingTests` must still pass unchanged — it asserts the placeholder decision, which this task preserves.

- [ ] **Step 9: Device verification — required before merge**

Unit tests cannot cover the system surfaces this task touches. Verify manually:

1. iOS (`skip app launch` or Xcode, iPhone 17e simulator per project convention): play, then confirm the **lock screen** shows artist/title/artwork and that its play/pause button controls playback.
2. Android emulator: confirm the **media3 notification** shows the song and its transport works.
3. If available, confirm CarPlay and/or Android Auto still show artwork and respond to transport.

Expected: identical behavior to before this task. Any regression means the publisher selection or the remote-command rewiring in Step 6 is wrong — most likely the `SharedPlayer.coordinator` self-reference.

- [ ] **Step 10: Commit**

```bash
git add Sources/Maxi80/ Tests/Maxi80Tests/
git commit -m "refactor: unify Now Playing publishing behind one protocol"
```

---

### Task 9: Update the architecture docs

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above
- Produces: nothing

- [ ] **Step 1: Document the seam in the bridging-rules section**

`CLAUDE.md`'s "Cross-module bridging rules" section describes the services as concrete. Add after the existing callback-based bullet:

```markdown
- **The coordinator depends on protocols, not the bridged classes.** `AudioPlaying`, `Sharing`, and
  `NowPlayingPublishing` are declared in the **native `Maxi80` module** (`Sources/Maxi80/Services/`)
  and the bridged `Maxi80Services` classes conform retroactively. Declare any future service seam
  the same way — a protocol in the native module never crosses the JNI boundary, so it can't break
  the bridge. The `#if SKIP` platform dispatch stays inside the bridged class.
- Coordinator tests inject fakes via `makeTestCoordinator(...)` in `Tests/Maxi80Tests/Fakes/`.
  Never construct a real `AudioStreamPlayer()` in a test — it starts the platform audio path.
```

- [ ] **Step 2: Verify and commit**

Run: `swift test && make build-android`
Expected: PASS (docs-only change; this confirms the tree is still green).

```bash
git add CLAUDE.md
git commit -m "docs: record the protocol-seam convention for platform services"
```

---

## Self-Review

**Spec coverage:** every spec section maps to a task — `AudioPlaying` → 2/4, `Sharing` → 7, Now Playing unification → 8, fakes → 3/7/8, shared factory → 5, the eleven-site migration → 5, all seven new-coverage rows → 6/7/8, the spike → 1, device verification → 8 Step 9. The spec's "out of scope" list is respected: no `#if SKIP` dispatch edits, no `Platform/` moves, no `tearDown()` removal, no DI container, no `ArtworkService` protocol.

**Deviations from the spec, both deliberate and recorded above:**
1. `volume`/`attenuation`/`stopObservingVolume()` dropped from `AudioPlaying` — the coordinator never uses them (YAGNI).
2. Task 6 adds injectable `timeScale`/`reconnectConfirmationDelay`. The spec said "no production behavior changes"; these are production *signature* changes with unchanged defaults, needed because the reconnect path otherwise costs 5s of real time per test. Production timing is byte-identical.
3. Task 8 moves `NowPlayingController` ownership and remote-command wiring to `SharedPlayer`, which the spec did not anticipate. It follows necessarily from the coordinator no longer holding the concrete controller.

**Type consistency:** `makeTestCoordinator` grows 2-tuple (Task 5) → 3-tuple (Task 7) → 4-tuple (Task 8); each growth step explicitly instructs fixing callers. `PlayerCommand` cases, `FakeAudioPlayer` members, and the `NowPlayingPublishing` signature are used identically wherever referenced.

**Access levels verified:** the members tests call are reachable — `pause()`, `reconcileWithPlayer()`, `startSleepTimer(minutes:)`, `cancelSleepTimer()` are `public`; `handleMetadataChanged`, `handleDisconnectStop` are internal. `handleError` was `private` and Task 6 Step 4a widens it. `handleRemoteCommand` stays `private` — Task 8 adds the `public handleRemote(_:)` wrapper instead of widening it.

**Known risk left in the plan:** Task 8 Step 6's `SharedPlayer.coordinator` self-reference inside the callback closures is the most fragile point — a `static let` referencing itself during initialization can deadlock or recurse. Step 9's device launch is the check. If it does misbehave, the fallback is to wire `controller.onRemoteCommand` in a separate `SharedPlayer.start()` called from `Maxi80AppDelegate.onLaunch()` instead of inside the `coordinator` initializer.

**Task ordering note:** Task 1 is a hard gate — do not start Task 2 until the spike's Android build result is known, because a failure changes Task 2's approach from an empty conformance to an adapter class.
