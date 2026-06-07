# Requirements Document

## Introduction

Maxi80 is a cross-platform web radio player application for the French 80s music station "Maxi 80". The application streams live radio from the Maxi80 Icecast server, displays current and historical song metadata (artist, title, album artwork), and integrates with platform-native media controls. Built with the Skip framework (Skip Fuse for SwiftUI UI, Skip Bridge for platform services), it targets iOS and Android with a modular architecture that supports future expansion to tvOS and CarPlay.

## Glossary

- **Radio_Player**: The Maxi80 cross-platform radio application responsible for streaming audio and displaying metadata
- **Audio_Service**: The platform-specific audio playback module using AVPlayer on iOS and ExoPlayer (androidx.media3) on Android
- **Metadata_Parser**: The component that extracts artist and title information from ICY metadata in the Icecast audio stream
- **API_Client**: The HTTP client module that communicates with the Maxi80 backend API using API key authentication
- **Now_Playing_Controller**: The platform-specific module that publishes track metadata and playback state to the OS media controls (MPNowPlayingInfoCenter on iOS, MediaSession on Android)
- **Artwork_Service**: The component that fetches album artwork URLs from the backend API and downloads artwork images for display
- **History_Carousel**: The swipeable UI component displaying current and previously broadcast songs with their artwork
- **Station_Info**: The data model representing station metadata retrieved from the GET /station endpoint
- **Stream_URL**: The Icecast audio stream URL (https://audio1.maxi80.com) from which live radio is played
- **ICY_Metadata**: In-stream metadata embedded in the Icecast audio stream containing the current "Artist - Title" string
- **Skip_Fuse**: The native-mode Skip framework layer used for SwiftUI views running natively on both iOS and Android
- **Skip_Bridge**: The transpiled-mode Skip framework layer used for platform-specific code (audio, media sessions)
- **Interruption_Event**: An external event (phone call, alarm, other audio app) that causes the audio session to be interrupted
- **Audio_Route**: The active output path for audio playback (device speaker, wired headphones, Bluetooth device, or AirPlay device)

## Requirements

### Requirement 1: Live Audio Streaming

**User Story:** As a listener, I want to stream Maxi80 live radio, so that I can listen to 80s music on my phone.

#### Acceptance Criteria

1. WHEN the user taps the play button, THE Audio_Service SHALL begin streaming audio from the Stream_URL within 5 seconds
2. WHEN the user taps the pause button, THE Audio_Service SHALL stop audio playback and release the audio stream connection
3. WHILE streaming is active, THE Audio_Service SHALL maintain a continuous audio output without user-perceptible gaps under stable network conditions
4. THE Audio_Service SHALL support AAC and MP3 audio codec formats used by the Icecast stream
5. WHEN the Audio_Service starts playback, THE Radio_Player SHALL display a loading indicator until audio output begins

### Requirement 2: Background Playback

**User Story:** As a listener, I want the radio to continue playing when I switch to another app or lock my phone, so that I can listen without keeping the app in the foreground.

#### Acceptance Criteria

1. WHILE the Radio_Player is in background mode, THE Audio_Service SHALL continue streaming audio without interruption
2. WHEN the app transitions from foreground to background, THE Audio_Service SHALL maintain the current playback state
3. WHEN the app returns to foreground from background, THE Radio_Player SHALL display the current playback state and metadata accurately
4. IF the background transition fails, THEN THE Audio_Service SHALL restore the playback state that existed before the transition

### Requirement 3: Audio Interruption Handling

**User Story:** As a listener, I want the radio to respond gracefully to phone calls and other audio interruptions, so that I don't miss important calls or have overlapping audio.

#### Acceptance Criteria

1. WHEN an Interruption_Event begins, THE Audio_Service SHALL pause playback immediately
2. WHEN an Interruption_Event ends with the resume option available, THE Audio_Service SHALL resume playback automatically
3. WHEN an Interruption_Event ends without the resume option, THE Audio_Service SHALL remain paused and update the UI to reflect the paused state
4. WHEN another audio app takes the audio session, THE Audio_Service SHALL pause playback and update the UI accordingly

### Requirement 4: ICY Metadata Extraction

**User Story:** As a listener, I want to see the currently playing song's artist and title, so that I know what music is being broadcast.

#### Acceptance Criteria

1. WHILE streaming is active, THE Metadata_Parser SHALL extract ICY metadata from the Icecast audio stream
2. WHEN ICY metadata containing an "Artist - Title" string is received, THE Metadata_Parser SHALL parse the artist name and song title as separate fields
3. WHEN the metadata string does not contain a " - " separator, THE Metadata_Parser SHALL treat the entire string as the title with an empty artist field
4. WHEN the metadata string contains a " - " separator with an empty artist portion, THE Metadata_Parser SHALL set the artist field to an empty string and the title to the text after the separator
5. WHEN new metadata is received, THE Radio_Player SHALL update the displayed artist and title within 1 second
6. FOR ALL valid ICY metadata strings, parsing then formatting back to "Artist - Title" then parsing again SHALL produce equivalent artist and title fields (round-trip property)

### Requirement 5: Album Artwork Display

**User Story:** As a listener, I want to see album artwork for the current song, so that I have a visually rich listening experience.

#### Acceptance Criteria

1. WHEN new song metadata is parsed, THE Artwork_Service SHALL request the artwork URL from the API endpoint GET /artwork?artist={artist}&title={title}
2. WHEN the artwork API returns a URL, THE Artwork_Service SHALL download and cache the artwork image
3. WHEN artwork loading completes with an HTTP 204 response, THE Radio_Player SHALL display the default Maxi80 cover image
4. WHEN artwork loading is in progress, THE Radio_Player SHALL continue displaying the previous artwork until the new artwork is available
5. IF the artwork download fails due to a network error, THEN THE Radio_Player SHALL display the default Maxi80 cover image

### Requirement 6: Song History Carousel

**User Story:** As a listener, I want to swipe through previously played songs, so that I can see what was broadcast earlier.

#### Acceptance Criteria

1. WHEN the Audio_Service starts or resumes streaming after a playback interruption, THE API_Client SHALL fetch the song history from the GET /history endpoint concurrently in a background task without delaying audio playback
2. THE History_Carousel SHALL display song entries with artwork, artist name, and song title for each entry
3. WHEN the user swipes left on the History_Carousel, THE Radio_Player SHALL display the next older song entry
4. WHEN the user swipes right on the History_Carousel, THE Radio_Player SHALL display the next newer song entry
5. THE History_Carousel SHALL position the current live song as the rightmost (newest) entry
6. WHILE streaming is active and new ICY metadata is received, THE History_Carousel SHALL append the new entry as the rightmost item to the local history list without re-fetching from the API
7. WHILE the user is viewing a historical entry, THE Radio_Player SHALL display the artist and title corresponding to that entry (not the live song)

### Requirement 7: Platform Now Playing Integration

**User Story:** As a listener, I want to control playback and see song info from the lock screen and notification shade, so that I can manage playback without opening the app.

#### Acceptance Criteria

1. WHILE streaming is active, THE Now_Playing_Controller SHALL publish the current artist, title, and artwork to the platform media controls
2. WHEN the user taps play or pause on the platform media controls, THE Now_Playing_Controller SHALL toggle the Audio_Service playback state accordingly
3. WHEN song metadata changes, THE Now_Playing_Controller SHALL update the published metadata within 2 seconds
4. THE Now_Playing_Controller SHALL report the stream as live content (no seek bar, no duration)
5. WHEN the playback state changes, THE Now_Playing_Controller SHALL update the published playback rate (1.0 for playing, 0.0 for paused)

### Requirement 8: Station Information Display

**User Story:** As a listener, I want to see station branding and description when the app is idle or waiting for stream metadata, so that I have meaningful content on screen before song information becomes available.

#### Acceptance Criteria

1. WHEN the Radio_Player launches, THE API_Client SHALL fetch station metadata from the GET /station endpoint
2. WHILE streaming is not active, THE Radio_Player SHALL display the station name and short description from Station_Info as the primary content in the playback display area
3. WHILE streaming is active and no ICY metadata has been received yet, THE Radio_Player SHALL display the station name and short description from Station_Info as placeholder content
4. WHEN the Metadata_Parser delivers the first ICY metadata for the current streaming session, THE Radio_Player SHALL replace the station information with the parsed artist and title in the playback display area
5. IF the station metadata request fails, THEN THE Radio_Player SHALL display cached station metadata from the previous successful fetch
6. IF no cached station metadata is available and the request fails, THEN THE Radio_Player SHALL display hardcoded station metadata including name "Maxi 80", description "La radio de toute une génération", stream URL, and default cover

### Requirement 9: API Key Authentication

**User Story:** As a developer, I want all API requests to include proper authentication, so that the backend remains protected from unauthorized access.

#### Acceptance Criteria

1. THE API_Client SHALL include the X-API-Key header with the configured API key in every request to the Maxi80 backend
2. IF an API request returns HTTP 401 or HTTP 403, THEN THE API_Client SHALL log the authentication failure and return an appropriate error to the caller
3. THE Radio_Player SHALL store the API key in the platform-appropriate secure storage (Keychain on iOS, EncryptedSharedPreferences on Android)

### Requirement 10: Adaptive User Interface

**User Story:** As a listener, I want the app to look good in both portrait and landscape orientations, so that I can use it however I hold my phone.

#### Acceptance Criteria

1. WHEN the device is in portrait orientation, THE Radio_Player SHALL display the artwork prominently above the playback controls
2. WHEN the device is in landscape orientation, THE Radio_Player SHALL display the artwork beside the playback controls in a side-by-side layout
3. THE Radio_Player SHALL adapt its layout to different screen sizes without content clipping or overlap for devices with screen widths of 320pt or greater
4. THE Radio_Player SHALL extract a dominant color from the current artwork and apply it as a dynamic background gradient
5. WHEN artwork transitions from one image to another, THE Radio_Player SHALL animate the transition using a smooth crossfade or equivalent SwiftUI animation

### Requirement 11: AirPlay Support

**User Story:** As an iOS listener, I want to stream audio to AirPlay-compatible speakers, so that I can listen on my home audio system.

#### Acceptance Criteria

1. WHERE the platform supports AirPlay (iOS/macOS), THE Radio_Player SHALL display an AirPlay route picker button
2. WHEN the user selects an AirPlay device, THE Audio_Service SHALL route audio output to the selected device
3. WHILE streaming to an AirPlay device, THE Audio_Service SHALL maintain playback continuity without restart

### Requirement 12: Network Error Resilience

**User Story:** As a listener, I want the app to handle network issues gracefully, so that I understand what's happening and can resume listening when connectivity returns.

#### Acceptance Criteria

1. IF the audio stream connection is lost, THEN THE Radio_Player SHALL display a connectivity error message to the user
2. IF the audio stream connection is lost, THEN THE Audio_Service SHALL attempt to reconnect automatically up to 3 times with exponential backoff (2s, 4s, 8s delays)
3. IF all reconnection attempts fail, THEN THE Audio_Service SHALL stop playback and THE Radio_Player SHALL display an option to retry manually
4. WHEN network connectivity is restored after a failure, THE Radio_Player SHALL enable the retry option

### Requirement 13: Cross-Platform Architecture

**User Story:** As a developer, I want a modular architecture with shared Swift code and platform-specific bridges, so that I can maintain one codebase for iOS and Android with minimal duplication.

#### Acceptance Criteria

1. THE Radio_Player SHALL implement the UI layer using Skip Fuse native mode with SwiftUI views shared across iOS and Android
2. THE Audio_Service SHALL implement platform-specific audio playback using Skip Bridge transpiled mode (AVPlayer on iOS, ExoPlayer on Android) with the `#if !SKIP_BRIDGE` outer guard and `#if SKIP` / `#else` inner guards
3. THE Now_Playing_Controller SHALL implement platform-specific media session integration using Skip Bridge transpiled mode
4. THE Radio_Player SHALL use Swift concurrency with async/await in the native module for all asynchronous coordination
5. THE Radio_Player architecture SHALL separate concerns into a UI module (Skip Fuse native) and a platform-services module (Skip Bridge transpiled) to allow addition of tvOS and CarPlay targets without restructuring
6. THE API_Client SHALL use URLSession-compatible HTTP for all network requests (Skip transpiles URLSession to OkHttp on Android automatically)
7. THE bridged platform modules SHALL expose simple-type APIs (String, closures) that bridge cleanly between Swift and Kotlin via Skip Bridge

### Requirement 14: Volume Control

**User Story:** As a listener, I want to adjust the playback volume from within the app, so that I can set a comfortable listening level.

#### Acceptance Criteria

1. THE Radio_Player SHALL display a volume slider control
2. WHEN the user adjusts the volume slider, THE Audio_Service SHALL change the audio output volume to match the slider position
3. WHEN the system volume changes externally, THE Radio_Player SHALL update the volume slider to reflect the current system volume

### Requirement 15: Donation Link Access

**User Story:** As a listener who wants to support the station, I want easy access to the donation page, so that I can contribute financially to Maxi80.

#### Acceptance Criteria

1. THE Radio_Player SHALL display an accessible donation button or link
2. WHEN the user taps the donation button, THE Radio_Player SHALL open the donation URL from Station_Info in the platform's default web browser

### Requirement 16: Dynamic Audio Route Switching

**User Story:** As a listener, I want the audio to seamlessly switch to new output devices when I connect or disconnect headphones or Bluetooth speakers, so that I don't have to manually restart playback after changing audio hardware.

#### Acceptance Criteria

1. WHEN a Bluetooth audio device connects while streaming is active, THE Audio_Service SHALL route audio output to the Bluetooth device without interrupting playback
2. WHEN a Bluetooth audio device disconnects while streaming is active, THE Audio_Service SHALL route audio output to the device speaker without interrupting playback
3. WHEN wired headphones are connected while streaming is active, THE Audio_Service SHALL route audio output to the wired headphones without interrupting playback
4. WHEN wired headphones are disconnected while streaming is active, THE Audio_Service SHALL pause playback and route audio output to the device speaker
5. WHEN the audio route changes during playback, including during rapid multi-device transitions, THE Now_Playing_Controller SHALL maintain the published metadata and playback state without reset
6. WHEN multiple audio output devices are available, THE Radio_Player SHALL route audio to the device selected by the platform audio routing policy
7. IF an audio route change fails, THEN THE Audio_Service SHALL fall back to the device speaker and THE Radio_Player SHALL continue playback on the fallback output

### Requirement 17: Share Current Track

**User Story:** As a listener, I want to share what I'm currently listening to with friends, so that I can recommend songs and promote the station.

#### Acceptance Criteria

1. THE Radio_Player SHALL display a share button accessible from the main playback interface
2. WHEN the user taps the share button, THE Radio_Player SHALL present the platform share sheet with a text message formatted as "I'm listening to {title} by {artist} on Maxi 80 via Maxi80 for iOS. Check it out at https://www.maxi80.com" where {title} and {artist} are the currently displayed track metadata
3. WHEN the user taps the share button, THE Radio_Player SHALL include the current album artwork image as a share attachment IF available; IF artwork attachment fails, THE share SHALL proceed with text content only
4. WHEN the current artwork is the default Maxi80 cover image, THE Radio_Player SHALL include the default cover image as the share sheet attachment
5. WHILE no track metadata is available, THE Radio_Player SHALL disable the share button
