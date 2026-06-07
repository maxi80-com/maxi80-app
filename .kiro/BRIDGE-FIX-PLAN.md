# Fix: Redesign Module Architecture for Skip Bridge Codable Compatibility

## Context

The Skip Android build fails because `Station`, `SongMetadata`, and `HistoryEntry` live in `Maxi80Services` (a `mode: 'transpiled'` module). The bridge code generator creates JNI-backed stubs with `Codable` conformance but only computed properties — Swift can't synthesize `Codable` for computed-only types.

The existing code also has incorrect SKIP annotations. The `// SKIP @nobridge` + `#if !SKIP_BRIDGE` pattern is wrong for types that need to be bridged — it was likely cargo-culted rather than following the official patterns. The truth is the [skipapp-travelposters-native](https://github.com/skiptools/skipapp-travelposters-native) example: plain structs with `Codable`, no SKIP annotations, in a **native module with `bridging: true`**.

## Root Cause

In `mode: 'transpiled'` modules, types are transpiled to Kotlin, then the bridge generator creates Swift stubs with JNI getters (computed properties). Swift can't synthesize `Codable` from computed properties.

In `mode: 'native'` modules (with `bridging: true`), Swift code compiles natively on Android — stored properties are preserved, `Codable` synthesis works normally.

## Approach: Create a Native `Maxi80Model` Module

Following the travel-posters pattern, extract all pure-logic code (models, MetadataParser, APIClient) into a new **native module with bridging**. Keep only platform-specific code (AudioStreamPlayer, NowPlayingController) in the transpiled module.

### New Module Layout

```
Sources/
├── Maxi80Model/                    # NEW — native + bridging: true
│   ├── Skip/skip.yml               # mode: native, bridging: enabled: true
│   ├── Models/
│   │   ├── Station.swift           # moved from Maxi80Services — plain Codable struct
│   │   ├── SongMetadata.swift      # moved from Maxi80Services — plain Codable struct
│   │   ├── HistoryEntry.swift      # moved from Maxi80Services — plain Codable struct
│   │   ├── PlaybackState.swift     # moved from Maxi80Services — plain enum
│   │   └── RemoteCommand.swift     # moved from Maxi80Services — plain enum
│   ├── Services/
│   │   ├── MetadataParser.swift    # moved from Maxi80Services — uses SongMetadata
│   │   ├── APIClient.swift         # moved from Maxi80Services — uses URLSession
│   │   └── APIConfiguration.swift  # moved from Maxi80Services — pure config struct
│   └── Maxi80Model.swift           # module placeholder
│
├── Maxi80Services/                 # KEPT — transpiled, platform-only
│   ├── Skip/skip.yml               # mode: transpiled, bridging: true (unchanged)
│   ├── AudioStreamPlayer.swift     # only platform code remains
│   ├── NowPlayingController.swift
│   ├── Maxi80Services.swift
│   └── Platform/
│       ├── iOS/...
│       └── Android/...
│
└── Maxi80/                         # KEPT — native UI module
    ├── Skip/skip.yml               # mode: native (unchanged)
    └── ... (views, coordinator, etc.)
```

### Key Differences from Current Code

1. **No `// SKIP @nobridge` or `#if !SKIP_BRIDGE` guards** on model types, MetadataParser, or APIClient — they're plain Swift in a native module
2. **`Maxi80Model` uses `mode: 'native'` with `bridging: enabled: true`** — Swift compiles natively on both platforms, stored properties preserved, Codable works
3. **`Maxi80Services` stays transpiled** but only contains AudioStreamPlayer + NowPlayingController (which use `/* SKIP @bridge */` + `#if !SKIP_BRIDGE` correctly since they have platform-specific implementations)
4. **Dependency chain**: `Maxi80` → `Maxi80Model` + `Maxi80Services`; `Maxi80Services` has NO dependency on `Maxi80Model` (it only uses primitive types in callbacks)

## Changes

### 1. Create `Sources/Maxi80Model/Skip/skip.yml`

```yaml
skip:
  mode: 'native'
  bridging:
    enabled: true
```

### 2. Update `Package.swift`

- Add `Maxi80Model` target with dependencies: `SkipFuse` (for native bridging support)
- `Maxi80` depends on both `Maxi80Model` and `Maxi80Services`
- `Maxi80Services` has NO dependency on `Maxi80Model`
- Add `Maxi80ModelTests` test target
- Remove `SwiftCheck` from `Maxi80ServicesTests` if MetadataParser/APIClient tests move

### 3. Move files from `Maxi80Services` → `Maxi80Model`

Move and **strip all SKIP annotations / `#if !SKIP_BRIDGE` guards**:
- `Models/Station.swift` → plain `public struct Station: Sendable, Codable { ... }`
- `Models/SongMetadata.swift` → plain `public struct SongMetadata: Sendable, Equatable, Codable { ... }`
- `Models/HistoryEntry.swift` → plain `public struct HistoryEntry: Sendable, Identifiable, Codable { ... }`
- `Models/PlaybackState.swift` → plain `public enum PlaybackState: Sendable { ... }`
- `Models/RemoteCommand.swift` → plain `public enum RemoteCommand: Sendable { ... }`
- `Services/MetadataParser.swift` → plain `public struct MetadataParser: Sendable { ... }`
- `Services/APIClient.swift` → plain `public class APIClient { ... }`
- `Services/APIConfiguration.swift` → plain `public struct APIConfiguration: Sendable { ... }`

### 4. Clean up `Maxi80Services`

Remove the `Models/` and `Services/` directories. Only keep:
- `AudioStreamPlayer.swift` (keeps `/* SKIP @bridge */` + `#if !SKIP_BRIDGE` — correctly transpiled)
- `NowPlayingController.swift` (same)
- `Platform/iOS/` and `Platform/Android/` implementations
- `Maxi80Services.swift` placeholder

### 5. Update imports across the codebase

All files that `import Maxi80Services` and use model types will need to also `import Maxi80Model`. Key files:
- `Sources/Maxi80/RadioPlayerCoordinator.swift`
- `Sources/Maxi80/RadioPlayerViewModel.swift`
- `Sources/Maxi80/StationProvider.swift`
- `Sources/Maxi80/HistoryCarouselView.swift`
- `Sources/Maxi80/PlaybackControlsView.swift`
- `Sources/Maxi80/ArtworkService.swift`
- `Sources/Maxi80/ConfigurationLoader.swift`
- `Sources/Maxi80/PreviewHelpers.swift`
- `Sources/Maxi80/Maxi80App.swift`
- `Sources/Maxi80/RadioPlayerView.swift`
- `Sources/Maxi80/ShareSheet.swift`

### 6. Move tests

- Move `Tests/Maxi80ServicesTests/MetadataParserTests.swift` → `Tests/Maxi80ModelTests/`
- Move `Tests/Maxi80ServicesTests/MetadataParserPropertyTests.swift` → `Tests/Maxi80ModelTests/`
- Move `Tests/Maxi80ServicesTests/APIClientTests.swift` → `Tests/Maxi80ModelTests/`
- Move `Tests/Maxi80ServicesTests/APIClientPropertyTests.swift` → `Tests/Maxi80ModelTests/`
- Update `@testable import Maxi80Services` → `@testable import Maxi80Model`

## Verification

1. `swift build` — macOS build passes
2. `skip app launch --android` — Android build no longer fails on Codable (may still fail on "no emulator" which is OK)
3. `swift test` — all tests pass
4. `skip verify` — project structure is valid
