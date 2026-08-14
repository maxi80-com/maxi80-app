# Skip Architecture: Native + Transpiled Module Integration

## Overview

This project is a Skip Fuse (native) app that integrates a transpiled (lite) module for audio streaming. The transpiled module (`AudioStreamPlayer`) uses platform-specific APIs directly — ExoPlayer/media3 on Android, AVPlayer on iOS — while the native fuse module (`HelloWorld`) consumes it via Skip's bridging system.

This document captures the architecture patterns discovered during implementation, for use by future agents or developers.

---

## Skip Module Modes

Skip has two compilation modes:

- **Native (Fuse)**: Swift code is compiled natively on both platforms. On Android, Swift compiles via the Skip toolchain and calls Android APIs through `SkipFuse` bridging. Used for app-level UI and model code.
- **Transpiled (Lite)**: Swift code is transpiled to Kotlin by the `skipstone` plugin. The Kotlin runs on Android; the original Swift runs on iOS. Used when you need direct platform API access (e.g., ExoPlayer, platform SDKs).

## Dependency Direction Rules

From studying all official Skip examples (Hiya, Ahoy, skip-av, skip-keychain):

| Direction | Example | Notes |
|-----------|---------|-------|
| Transpiled → Native | Hiya: `HiyaSkip` (transpiled UI) → `HiyaSkipModel` (native model) | Standard "mixed" pattern. Native model has `bridging: true`. |
| Native → Native | Ahoy: `AhoySkipper` → `SkipperModel` | Standard "split fuse" pattern. Both use `SkipFuse`. |
| Native → Transpiled | This project: `HelloWorld` (native) → `AudioStreamPlayer` (transpiled) | Works with `SKIP_BRIDGE` block + `bridging: true`. Same pattern as apps consuming `skip-av` or `skip-keychain`. |

The key insight: **any direction works**, but native → transpiled requires the `SKIP_BRIDGE` conditional wiring in `Package.swift`.

---

## The SKIP_BRIDGE Pattern

Every transpiled Skip library that supports consumption by native/fuse modules uses a conditional block at the bottom of `Package.swift`. When the Skip build system needs bridging, it sets `SKIP_BRIDGE=1`, and this block adds the `SkipBridge` dependency:

```swift
if Context.environment["SKIP_BRIDGE"] ?? "0" != "0" {
    package.dependencies += [
        .package(url: "https://source.skip.tools/skip-bridge.git", "0.0.0"..<"2.0.0")
    ]
    package.targets.forEach({ target in
        if target.name == "AudioStreamPlayer" {
            target.dependencies += [.product(name: "SkipBridge", package: "skip-bridge")]
        }
    })
}
```

Without this block, the native Android build tries to compile the transpiled Swift source directly (instead of using generated Kotlin + bridge stubs), causing `missing required module 'CJNI'` errors.

This pattern is used by `skip-av`, `skip-keychain`, and all other Skip integration libraries.

## skip.yml Configuration

The transpiled module's `skip.yml` must declare both its mode and bridging support:

```yaml
skip:
  mode: 'transpiled'
  bridging: true
build:
  contents:
    - block: 'dependencies'
      contents:
        - 'implementation("androidx.media3:media3-exoplayer:1.5.1")'
        - 'implementation("androidx.media3:media3-common:1.5.1")'
```

The native consuming module's `skip.yml` is simply:

```yaml
skip:
  mode: 'native'
```

---

## Transpiled Module Source Pattern

### Conditional compilation structure

Transpiled modules use a two-level conditional pattern:

```swift
#if !SKIP_BRIDGE
// Everything inside here — the bridge compiler skips this entirely
// and generates its own stubs from the public API surface

import Foundation

#if SKIP
// Android implementation (transpiled to Kotlin)
// Direct access to Android APIs: ExoPlayer, media3, etc.
#else
// iOS implementation (compiled as native Swift)
// Direct access to iOS APIs: AVPlayer, AVFoundation, etc.
#endif

#endif // !SKIP_BRIDGE
```

- `#if !SKIP_BRIDGE` — hides the full implementation from the bridge stub generator. The bridge only sees the public class/method signatures.
- `#if SKIP` — the inner block contains Android-specific code that gets transpiled to Kotlin.
- `#else` — iOS-specific Swift code, compiled natively.

### Public API design for bridging

The public API must be bridgeable — simple types, callbacks as closures:

```swift
public class AudioStreamPlayer: ObservableObject {
    @Published public var isPlaying: Bool = false
    public var onMetadataChanged: ((String) -> Void)?

    public init() { }
    public func play() { ... }
    public func stop() { ... }
}
```

---

## Kotlin Transpilation Gotchas

Things that don't transpile cleanly from Swift to Kotlin via skipstone:

1. **No anonymous `object` expressions** — Use named classes for listeners:
   ```swift
   // BAD: anonymous object won't transpile
   // GOOD: named class
   class AudioStreamEventListener: Player.Listener {
       override func onMediaMetadataChanged(metadata: MediaMetadata) { ... }
   }
   ```

2. **No `@OptIn` annotations** — Skip doesn't handle Kotlin opt-in annotations. Remove them; use stable APIs or suppress warnings in gradle instead.

3. **Avoid `Unit?` return types** — Kotlin listener overrides that return `Unit` can cause issues if the transpiler infers `Unit?`. Keep listener methods returning `Void`.

4. **Use `SkipFoundation` not `SkipFuse`** — Transpiled modules depend on `SkipFoundation`. `SkipFuse` is for native modules only.

---

## Project Layout

```
hello-world/
├── Package.swift                    # SPM manifest with SKIP_BRIDGE conditional
├── Sources/
│   ├── HelloWorld/                  # Native fuse module
│   │   ├── ContentView.swift        # App UI, imports AudioStreamPlayer
│   │   ├── HelloWorldApp.swift
│   │   ├── Resources/
│   │   └── Skip/
│   │       └── skip.yml             # mode: native
│   └── AudioStreamPlayer/           # Transpiled lite module
│       ├── AudioStreamPlayer.swift  # #if !SKIP_BRIDGE → #if SKIP / #else
│       └── Skip/
│           └── skip.yml             # mode: transpiled, bridging: true, gradle deps
├── Darwin/                          # iOS app entry point
├── Android/                         # Android app entry point
└── SKIP_ARCHITECTURE.md             # This file
```

## Package.swift Dependencies

```swift
// HelloWorld (native) depends on:
//   - AudioStreamPlayer (transpiled, in-project)
//   - SkipFuseUI (native UI framework)

// AudioStreamPlayer (transpiled) depends on:
//   - SkipFoundation (transpiled foundation)
//   - SkipBridge (conditionally, when SKIP_BRIDGE=1)
```

---

## How to Add Another Transpiled Module

1. Create `Sources/NewModule/` with Swift source using the `#if !SKIP_BRIDGE` + `#if SKIP` / `#else` pattern.
2. Create `Sources/NewModule/Skip/skip.yml` with `mode: 'transpiled'` and `bridging: true`.
3. Add the target to `Package.swift` with `SkipFoundation` dependency and `skipstone` plugin.
4. Add it as a dependency of the consuming native module.
5. Add it to the `SKIP_BRIDGE` conditional block so it gets `SkipBridge` when bridging is active.
6. Add any Android gradle dependencies in `skip.yml` under `build.contents`.

---

## References

- [Skip Documentation — Modules](https://skip.tools/docs/modules/)
- [skip-av Package.swift](https://github.com/skiptools/skip-av/blob/main/Package.swift) — reference for SKIP_BRIDGE pattern
- [skip-keychain Package.swift](https://github.com/skiptools/skip-keychain/blob/main/Package.swift) — same pattern
- [skipapp-hiya](https://github.com/nicklama/skipapp-hiya) — transpiled → native example
- [skipapp-ahoy](https://github.com/nicklama/skipapp-ahoy) — native → native example

---

## Android Build Pitfalls (Native Fuse Modules)

Hard-won lessons from debugging Android build failures:

### Always verify with `skip android build`

The macOS `swift build` only compiles the Apple path. It will miss Android-specific errors. Always run `skip android build` before considering a change done.

### Never `import Foundation` alongside `import SwiftUI`

In native fuse modules, `import Foundation` introduces a `CGFloat` ambiguity: both CoreGraphics (via Foundation) and SkipSwiftUI define `CGFloat`. The compiler cannot resolve it. `SwiftUI` already re-exports everything you need from Foundation — use it alone.

```swift
// BAD — CGFloat ambiguity on Android
import Foundation
import SwiftUI

// GOOD
import SwiftUI
```

If you need Foundation-only (no SwiftUI), e.g. a pure formatting helper, `import Foundation` alone is fine.

### `Bundle.module.preferredLocalizations` is unavailable on Android

The Android bridge context does not support `preferredLocalizations`. Use `Locale.current` instead when you need locale information for formatting.

### `Date.formatted(date:time:)` doesn't respect locale on Android

SkipFoundation's implementation creates a `DateFormatter` without setting `.locale`, so `java.text.DateFormat` falls back to the JVM default which may not match the app locale. Workaround: use an explicit `DateFormatter` with `formatter.locale = Locale.current` inside `#if os(Android)`.
