# Implementation Plan: Maxi80 Radio Player

## Overview

This plan implements the Maxi80 cross-platform radio player using the Skip framework with Swift 6 strict concurrency. Tasks are ordered by dependency: project scaffolding first, then data models, pure-logic services, platform-specific implementations, the central coordinator actor, the ViewModel, and finally UI views with integration wiring.

## Tasks

- [x] 1. Set up Skip project structure and platform entry points
  - [x] 1.1 Create Package.swift with Skip dependencies and module targets
    - Define `Maxi80` target (Skip Fuse native mode) and `Maxi80Services` target (Skip Bridge transpiled mode)
    - Add dependencies: skip, skip-fuse-ui, skip-foundation, skip-bridge
    - Add SKIP_BRIDGE conditional block at bottom of Package.swift (adds SkipBridge dependency to Maxi80Services when SKIP_BRIDGE=1)
    - Add SwiftCheck as a test dependency
    - _Requirements: 13.1, 13.2, 13.5_

  - [x] 1.2 Create skip.yml files and module directory structure
    - Create `Sources/Maxi80/Skip/skip.yml` with `mode: native`
    - Create `Sources/Maxi80Services/Skip/skip.yml` with `mode: transpiled`, `bridging: true`, and `build.contents` for Media3 gradle dependencies
    - Create subdirectories: Models/, Protocols/, Services/, Platform/iOS/, Platform/Android/
    - _Requirements: 13.1, 13.2, 13.5_

  - [x] 1.3 Create platform entry points
    - Create `Darwin/Sources/Main.swift` for iOS app entry point importing Maxi80 module
    - Create `Android/app/src/main/kotlin/Main.kt` for Android entry point
    - Create `Android/app/build.gradle.kts` with Media3/ExoPlayer dependencies
    - _Requirements: 13.1, 13.2_

- [x] 2. Implement data models
  - [x] 2.1 Create core data model types in Maxi80Services/Models/
    - Implement `Station` struct (name, streamUrl, image, shortDesc, longDesc, websiteUrl, donationUrl, defaultCoverUrl) — Sendable, Codable
    - Implement `SongMetadata` struct (artist, title) — Sendable, Equatable, Codable
    - Implement `HistoryEntry` struct (id, artist, title, artwork, timestamp, songMetadata computed) — Sendable, Identifiable, Codable
    - Implement `PlaybackState` enum (idle, loading, playing, paused, error, reconnecting) — Sendable
    - Implement `ArtworkResult` struct (image, dominantColor, isDefault) — Sendable
    - Implement `RemoteCommand` enum (play, pause, togglePlayPause) — Sendable
    - _Requirements: 4.2, 6.2, 8.1, 12.2_

- [x] 3. Implement MetadataParser and its property tests
  - [x] 3.1 Implement MetadataParser in Maxi80Services/Services/MetadataParser.swift
    - Implement `parse(_ rawString: String) -> SongMetadata` — split on first " - " separator
    - Implement `format(_ metadata: SongMetadata) -> String` — reconstruct canonical string
    - Handle edge cases: no separator (entire string as title), empty artist portion, leading/trailing whitespace
    - _Requirements: 4.2, 4.3, 4.4, 4.6_

  - [x] 3.2 Write property test for MetadataParser — P1: ICY Metadata Round-Trip
    - **Property 1: ICY Metadata Round-Trip**
    - Generate arbitrary SongMetadata (including empty artist, Unicode, special characters)
    - Assert: `MetadataParser.parse(MetadataParser.format(metadata)) == metadata`
    - Also test: for any raw ICY string, parse → format → parse produces same result as first parse
    - **Validates: Requirements 4.2, 4.3, 4.6**

  - [x] 3.3 Write unit tests for MetadataParser edge cases
    - Test empty string, " - " only, multiple separators ("A - B - C"), leading/trailing whitespace, Unicode/emoji, CJK characters
    - _Requirements: 4.2, 4.3, 4.4_

- [x] 4. Implement APIClient
  - [x] 4.1 Implement APIClient class in Maxi80Services/Services/APIClient.swift
    - Create class with `/* SKIP @bridge */` annotation
    - Initialize with baseURL (String) and apiKey (String)
    - Implement `fetchStation(completion:)` — returns JSON string via closure
    - Implement `fetchArtworkURL(artist:title:completion:)` — returns URL string or nil on HTTP 204
    - Implement `fetchHistory(completion:)` — returns JSON string via closure
    - Include `X-API-Key` header in every request
    - Handle HTTP 401/403 with error callback
    - Use URLSession (transpiles to OkHttp on Android via Skip)
    - Wrap implementation in `#if !SKIP_BRIDGE` pattern
    - _Requirements: 8.1, 5.1, 6.1, 9.1, 9.2_

  - [x] 4.2 Write property test for APIClient — P8: API Key Inclusion
    - **Property 8: API Key Inclusion**
    - Generate arbitrary API endpoints (station, artwork with random params, history)
    - Assert: every constructed URLRequest contains "X-API-Key" header with the configured key value
    - **Validates: Requirements 9.1**

  - [x] 4.3 Write unit tests for APIClient response handling
    - Test valid Station JSON parsing, HTTP 204 for artwork, HTTP 401/403 error handling, malformed JSON, network timeout
    - _Requirements: 8.1, 5.1, 9.2_

- [x] 5. Checkpoint — Core services compile and pass tests
  - Ensure all tests pass, ask the user if questions arise.

- [x] 6. Implement AudioStreamPlayer protocol and platform implementations
  - [x] 6.1 Define AudioStreamPlayer class in Maxi80Services/AudioStreamPlayer.swift
    - Define class with `/* SKIP @bridge */` annotation
    - Public API: `play(url:)`, `stop()`, `setVolume(_:)`, `@Published isPlaying`, `@Published volume`
    - Callback closures: `onMetadataChanged: ((String) -> Void)?`, `onError: ((String) -> Void)?`, `onInterruption: ((Bool) -> Void)?`
    - Use simple bridgeable types only (String, Float, Bool, closures)
    - _Requirements: 1.1, 1.2, 14.2_

  - [x] 6.2 Implement AVPlayerStreamPlayer for iOS
    - Create `Sources/Maxi80Services/Platform/iOS/AVPlayerStreamPlayer.swift`
    - Wrap implementation in `#if !SKIP_BRIDGE` outer guard, then `#else` (iOS path) after `#if SKIP`
    - Use `AVPlayer` with `AVPlayerItem` for Icecast stream
    - Configure `AVAudioSession` with `.playback` category and `.default` mode for background support
    - Attach `AVPlayerItemMetadataOutput` for ICY metadata callbacks
    - Invoke `onMetadataChanged` closure when metadata arrives
    - Handle `AVAudioSession.interruptionNotification` — invoke `onInterruption` closure
    - Handle `AVAudioSession.routeChangeNotification` for headphone disconnect (pause on `.oldDeviceUnavailable`)
    - Implement volume via `AVAudioSession.sharedInstance().outputVolume` observation
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 3.1, 3.2, 3.3, 14.2, 14.3, 16.1, 16.2, 16.3, 16.4_

  - [x] 6.3 Implement ExoPlayerStreamPlayer for Android
    - Create `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift`
    - Wrap implementation in `#if !SKIP_BRIDGE` outer guard, then `#if SKIP` (Android path)
    - Use `androidx.media3.exoplayer.ExoPlayer` with `MediaItem.fromUri(streamUrl)`
    - Use named listener class (not anonymous object) for `Player.Listener.onMediaMetadataChanged`
    - Invoke `onMetadataChanged` closure when metadata arrives
    - Manage `AudioFocusRequest` for focus handling — invoke `onInterruption` closure
    - Register `BroadcastReceiver` for `ACTION_AUDIO_BECOMING_NOISY`
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 3.1, 3.2, 3.3, 14.2, 16.1, 16.2, 16.3, 16.4_

- [x] 7. Implement NowPlayingController protocol and platform implementations
  - [x] 7.1 Define NowPlayingController class in Maxi80Services/NowPlayingController.swift
    - Define class with `/* SKIP @bridge */` annotation
    - Public API: `updateNowPlaying(artist:title:artworkURL:isPlaying:)`, `updatePlaybackState(isPlaying:)`, `tearDown()`
    - Callback closure: `onRemoteCommand: ((String) -> Void)?` (values: "play", "pause", "togglePlayPause")
    - Use simple bridgeable types only (String, Bool, closures)
    - _Requirements: 7.1, 7.2, 7.3_

  - [x] 7.2 Implement IOSNowPlayingController
    - Create `Sources/Maxi80Services/Platform/iOS/IOSNowPlayingController.swift`
    - Wrap in `#if !SKIP_BRIDGE` → `#else` pattern
    - Set `MPNowPlayingInfoCenter.default().nowPlayingInfo` with artist, title, artwork
    - Register play/pause/togglePlayPause on `MPRemoteCommandCenter.shared()`
    - Invoke `onRemoteCommand` closure when commands received
    - Report `isLiveStream = true`, `playbackRate` = 1.0 or 0.0
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_

  - [x] 7.3 Implement AndroidNowPlayingController
    - Create `Sources/Maxi80Services/Platform/Android/AndroidNowPlayingController.swift`
    - Wrap in `#if !SKIP_BRIDGE` → `#if SKIP` pattern
    - Use named listener class for `MediaSession.Callback` (no anonymous objects)
    - Use `MediaSession` for metadata publishing (title, artist, artworkUri)
    - Invoke `onRemoteCommand` closure when transport controls used
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_

- [x] 8. Implement ArtworkService
  - [x] 8.1 Implement ArtworkService actor in Maxi80Services/Services/ArtworkService.swift
    - Create actor with in-memory cache keyed by "artist|title"
    - Implement `fetchArtwork(artist:title:) async -> ArtworkResult`
    - Call APIClient for artwork URL, download image, extract dominant color
    - Return default Maxi80 cover on HTTP 204 or network failure
    - Retain previous artwork during loading (cache hit returns immediately)
    - Implement `dominantColor(from:) async -> PlatformColor` with average-color extraction
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 10.4_

- [x] 9. Implement RadioPlayerActor (central coordinator)
  - [x] 9.1 Implement RadioPlayerCoordinator in Sources/Maxi80/RadioPlayerCoordinator.swift
    - Create `@MainActor` `ObservableObject` class in the native (Fuse) module
    - Wire AudioStreamPlayer and NowPlayingController callback closures to state updates
    - Implement `play()`: start streaming immediately via `player.play(url:)`, launch fetchHistory() concurrently in a background Task without awaiting it before audio begins
    - Implement `pause()`: stop streaming, update state
    - Implement `setVolume(_:)`: delegate to player
    - Implement `retryConnection()`: reset reconnect counter, call play()
    - Manage @Published state: playbackState, currentSong, currentArtwork, history, station, errorMessage
    - On `onMetadataChanged`: parse → fetch artwork → update now playing → append to history
    - On `onRemoteCommand`: dispatch play/pause accordingly
    - _Requirements: 1.1, 1.2, 1.5, 4.5, 5.4, 6.1, 6.5, 6.6, 7.1, 7.3, 13.4_

  - [x] 9.2 Implement station metadata fetching with fallback chain
    - On launch, fetch station from API; cache result
    - On failure: return cached station if available
    - If no cache: return hardcoded Station (name: "Maxi 80", shortDesc: "La radio de toute une génération")
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6_

  - [x] 9.3 Implement reconnection logic with exponential backoff
    - On stream drop: transition to `.reconnecting(attempt:)`
    - Attempt reconnect up to 3 times with delays: 2s, 4s, 8s (2^n formula)
    - On all attempts exhausted: transition to `.error` state
    - On success: reset counter, transition to `.playing`
    - _Requirements: 12.1, 12.2, 12.3, 12.4_

  - [x] 9.4 Write property test for history logic — P2: History Append Preserves Order
    - **Property 2: History Append Preserves Order and Size**
    - Generate arbitrary history list of length N + new SongMetadata
    - Assert: result length == N+1, last element matches appended entry
    - **Validates: Requirements 6.5, 6.6**

  - [x] 9.5 Write property test for station fallback — P5: Station Fallback Chain
    - **Property 5: Station Fallback Chain**
    - Generate optional Station (cached or nil) + simulated API failure
    - Assert: cached Station returned if present; hardcoded defaults if no cache
    - **Validates: Requirements 8.5, 8.6**

  - [x] 9.6 Write property test for reconnection — P6: Reconnection Backoff Sequence
    - **Property 6: Reconnection Backoff Sequence**
    - Generate failure counts 1–5
    - Assert: delays follow 2^n for n=1..3 (2s, 4s, 8s); stops after 3 failures
    - **Validates: Requirements 12.2, 12.3**

- [x] 10. Checkpoint — All services and actor logic compile and pass tests
  - Ensure all tests pass, ask the user if questions arise.

- [x] 11. Implement RadioPlayerViewModel
  - [x] 11.1 Implement RadioPlayerViewModel in Sources/Maxi80/RadioPlayerViewModel.swift
    - Create `@Observable` class bridging RadioPlayerActor state to SwiftUI
    - Expose: isPlaying, isLoading, currentSong, currentArtwork, dominantColor, history, station, volume, errorMessage, canShare, selectedHistoryIndex
    - Implement `displayedArtist` / `displayedTitle` computed properties — return history[selectedHistoryIndex] data when viewing history, else current live song
    - Implement `togglePlayback()`, `setVolume(_:)`, `retry()` delegating to actor
    - Implement `shareCurrentTrack() -> ShareContent` with formatted text and artwork
    - Set `canShare = false` when no metadata available
    - _Requirements: 6.7, 8.2, 8.3, 8.4, 17.2, 17.5_

  - [x] 11.2 Write property test for ViewModel — P3: Displayed Metadata Matches Index
    - **Property 3: Displayed Metadata Matches Selected History Index**
    - Generate non-empty history list + valid index i
    - Assert: displayedArtist == history[i].artist, displayedTitle == history[i].title
    - **Validates: Requirements 6.7**

  - [x] 11.3 Write property test for share text — P7: Share Text Formatting
    - **Property 7: Share Text Formatting**
    - Generate SongMetadata with non-empty artist and title
    - Assert: share text == "I'm listening to {title} by {artist} on Maxi 80 via Maxi80 for iOS. Check it out at https://www.maxi80.com"
    - **Validates: Requirements 17.2**

  - [x] 11.4 Write unit tests for RadioPlayerViewModel state
    - Test: station info displayed when idle, station as placeholder during initial stream, share button disabled when no metadata, displayed metadata switches on history index change
    - _Requirements: 8.2, 8.3, 17.5, 6.7_

- [x] 12. Implement UI views
  - [x] 12.1 Implement RadioPlayerView (root view)
    - Create `Sources/Maxi80/RadioPlayerView.swift`
    - Layout: artwork area, song info (artist/title), playback controls, volume slider
    - Portrait: artwork above controls; landscape: artwork beside controls (side-by-side)
    - Apply dynamic gradient background from dominantColor
    - Display station info as placeholder when no metadata
    - Display loading indicator during stream buffering
    - Display error banner with retry button on connection failure
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 8.2, 8.3, 1.5, 12.1, 12.3_

  - [x] 12.2 Implement HistoryCarouselView
    - Create `Sources/Maxi80/HistoryCarouselView.swift`
    - Swipeable TabView/Pager displaying HistoryEntry items (artwork, artist, title)
    - Current live song positioned as rightmost (newest) entry
    - Swipe left for older, swipe right for newer
    - Update selectedHistoryIndex on swipe to change displayed metadata
    - _Requirements: 6.2, 6.3, 6.4, 6.5, 6.7_

  - [x] 12.3 Implement PlaybackControlsView
    - Create `Sources/Maxi80/PlaybackControlsView.swift`
    - Play/pause toggle button reflecting current state
    - Share button (disabled when canShare is false)
    - Donation link button opening donationUrl in browser
    - AirPlay route picker button (iOS only, hidden on Android via `#if !SKIP`)
    - _Requirements: 1.1, 1.2, 11.1, 15.1, 15.2, 17.1, 17.5_

  - [x] 12.4 Implement ArtworkView with crossfade animation
    - Create `Sources/Maxi80/ArtworkView.swift`
    - Display current artwork image or default Maxi80 cover
    - Animate transitions between artwork with crossfade (`.transition(.opacity)`)
    - _Requirements: 5.3, 5.4, 10.5_

  - [x] 12.5 Implement VolumeSliderView
    - Create `Sources/Maxi80/VolumeSliderView.swift`
    - Volume slider control bound to ViewModel volume state
    - Reflect system volume changes externally
    - _Requirements: 14.1, 14.2, 14.3_

- [x] 13. Integration wiring and platform configuration
  - [x] 13.1 Wire app entry point and dependency injection
    - Update `Maxi80App.swift` to create RadioPlayerActor with platform-appropriate implementations
    - Inject platform-specific AudioStreamPlayer and NowPlayingController using `#if SKIP` / `#else`
    - Create RadioPlayerViewModel and pass to RadioPlayerView via environment or init
    - _Requirements: 13.1, 13.2, 13.3, 13.5_

  - [x] 13.2 Configure iOS platform settings
    - Add `UIBackgroundModes: audio` to Info.plist
    - Add `NSAppTransportSecurity` exception for audio1.maxi80.com if needed
    - Configure audio session category `.playback` at app launch
    - _Requirements: 2.1, 2.2, 11.1_

  - [x] 13.3 Configure Android platform settings
    - Add `INTERNET`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permissions to AndroidManifest.xml
    - Register `MediaSessionService` in manifest
    - Configure Media3 foreground notification
    - _Requirements: 2.1, 2.2, 7.1_

  - [x] 13.4 Implement share sheet integration
    - Wire share button to platform share sheet (UIActivityViewController on iOS, Intent.ACTION_SEND on Android)
    - Pass formatted text + artwork image as share content
    - Handle artwork attachment failure gracefully (share text only)
    - _Requirements: 17.2, 17.3, 17.4_

- [x] 14. Final checkpoint — Full app builds and all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- All tasks are required
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- Swift 6 strict concurrency (`Sendable`, `actor`, `async/await`) is used throughout
- Platform-specific code uses `#if SKIP` / `#else` conditional compilation pattern
- Tests use Swift Testing framework (`@Test`) + SwiftCheck for property-based tests

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2", "1.3"] },
    { "id": 2, "tasks": ["2.1"] },
    { "id": 3, "tasks": ["3.1", "6.1", "7.1"] },
    { "id": 4, "tasks": ["3.2", "3.3", "4.1", "6.2", "6.3", "7.2", "7.3"] },
    { "id": 5, "tasks": ["4.2", "4.3", "8.1"] },
    { "id": 6, "tasks": ["9.1", "9.2", "9.3"] },
    { "id": 7, "tasks": ["9.4", "9.5", "9.6"] },
    { "id": 8, "tasks": ["11.1"] },
    { "id": 9, "tasks": ["11.2", "11.3", "11.4"] },
    { "id": 10, "tasks": ["12.1", "12.2", "12.3", "12.4", "12.5"] },
    { "id": 11, "tasks": ["13.1", "13.2", "13.3", "13.4"] }
  ]
}
```
