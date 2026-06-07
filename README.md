# Maxi80

Cross-platform iOS/Android radio player for the French 80s music station "Maxi 80". Built with [Skip](https://skip.tools) framework (Swift + SwiftUI on both platforms).

## Architecture

Three-module structure following the Skip Fuse pattern:

| Module | Mode | Purpose |
|--------|------|---------|
| `Maxi80` | Native (Fuse) | SwiftUI views, ViewModel, Coordinator |
| `Maxi80Model` | Native + Bridging | Data models (Codable), MetadataParser, APIClient |
| `Maxi80Services` | Transpiled (Bridge) | Platform audio (AVPlayer/ExoPlayer), NowPlayingController |

## Prerequisites

- Xcode 26+
- Skip CLI (`brew install skiptools/skip/skip`)
- Android SDK + emulator (`skip android sdk install`)
- Swift 6.1+ toolchain

## Build

```bash
# macOS/iOS (Swift)
swift build

# Android (Skip native)
skip android build

# Run tests
swift test

# Launch on both platforms (requires simulator + emulator)
skip app launch

# Verify project structure
skip verify
```

## Configuration

Copy the configuration template and fill in your API credentials:

```bash
cp Sources/Maxi80/Resources/Configuration.plist.template Sources/Maxi80/Resources/Configuration.plist
```

Edit `Configuration.plist` with your Maxi80 backend URL and auth token.

## Key Design Decisions

- **Native model module with bridging** for Codable compatibility (transpiled modules can't synthesize Codable)
- **@Observable** (Observation framework) instead of Combine for cross-platform reactivity
- **Callback-based bridging** from transpiled platform services to native module (closures bridge cleanly between Swift and Kotlin)
- **`#if !SKIP_BRIDGE`** guards for Apple-only code (previews, UIKit image processing, App protocol)
- **`#if canImport(UIKit)`** for platform-specific image/color extraction (falls back gracefully on Android)
