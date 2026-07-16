# tvOS & Android TV Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Maxi80 on Apple TV (tvOS 17+) and Android TV as a 10-foot, remote/D-pad-driven radio player, reusing the existing view model, coordinator, audio, and Now Playing pipeline unchanged.

**Architecture:** A single shared SwiftUI TV view tree (`TVRadioPlayerView` + `TVHistoryRow`) lives under `Sources/Maxi80/TV/` and transpiles to Compose for Android TV. A `PlatformEnvironment.isTVMode` helper (in the transpiled `Maxi80Services` module, so it can read the Android UI mode) drives root-view selection in `Maxi80RootView`. Phone/tablet `RadioPlayerView` is not modified. tvOS gets a new Xcode destination; Android TV rides the existing single app via manifest changes.

**Tech Stack:** Swift 6 + SwiftUI, Skip (native `Maxi80`/`Maxi80Model`, transpiled `Maxi80Services`), Skip Fuse bridging, ExoPlayer/media3 (Android), AVPlayer + MediaPlayer (Apple), Swift Testing.

## Global Constraints

- Swift 6 strict concurrency; `@MainActor` / `@Observable`; value types by default. (from CLAUDE.md)
- Use `Logger` (OSLog via `SkipFuse`) for new diagnostics, never `print()` — `print()` does not reach Logcat.
- SwiftUI APIs that pass the iOS build but fail Android must be gated with `#if os(Android)`, not `#if !SKIP`.
- SF Symbols render as ⚠️ on Android — use `AndroidIcon` (`MaterialSymbol`) for any new Android-facing icon.
- Edit dependencies in `Package.swift` / `skip.yml` directly, never via the Xcode/Android-Studio GUI.
- New preview code stays behind the `ENABLE_PREVIEWS` gate.
- Trigger the Skip transpiler/Android compile from Xcode by **building against the macOS destination** (iOS destinations don't run skipstone).
- tvOS is already declared (`.tvOS(.v17)` in `Package.swift`) and the whole `Maxi80Services` audio/Now-Playing layer is already guarded `#if os(iOS) || os(tvOS)`. Do not re-add audio/session code.
- Project metadata (package name, version) lives in `Skip.env`.

---

## File Structure

**Create:**
- `Sources/Maxi80Services/PlatformEnvironment.swift` — `PlatformEnvironment.isTVMode` bridged helper (transpiled module, reads Android UI mode).
- `Sources/Maxi80/TV/TVRadioPlayerView.swift` — shared 10-foot now-playing hero + history row; focus/input diverges per platform.
- `Sources/Maxi80/TV/TVHistoryRow.swift` — focus/D-pad-navigable recently-played row.
- `Tests/Maxi80ServicesTests/PlatformEnvironmentTests.swift` — `isTVMode` behavior.
- `Tests/Maxi80Tests/TVRootSelectionTests.swift` — root-view selection logic.
- `Android/app/src/main/res/drawable/tv_banner.xml` (or PNG) — 320×180 leanback banner.

**Modify:**
- `Sources/Maxi80/Maxi80App.swift` — `Maxi80RootView.body` selects TV vs phone view via `isTVMode`.
- `Sources/Maxi80/SystemVolumeSlider.swift` — narrow guard so it excludes tvOS.
- `Sources/Maxi80/AirPlayRoutePickerView.swift` — narrow guard so tvOS uses the `EmptyView` fallback.
- `Sources/Maxi80/ShareSheet.swift` — narrow the `UIActivityViewController` guard to exclude tvOS.
- `Sources/Maxi80/VolumeSliderView.swift` — the `#if !SKIP && canImport(UIKit)` volume branch must exclude tvOS.
- `Android/app/src/main/AndroidManifest.xml` — leanback launcher category, `uses-feature`, banner.
- `Darwin/Maxi80.xcodeproj/project.pbxproj` — add a tvOS target/scheme (done via Xcode UI, see Task 8).

**Do NOT modify:** `RadioPlayerView.swift`, `PlaybackControlsView.swift`, `CoverFlowView.swift`, `RadioPlayerViewModel.swift`, `RadioPlayerCoordinator.swift`, the `Maxi80Services` audio/Now-Playing files.

---

## Task 1: `PlatformEnvironment.isTVMode` helper

Detects whether the app is running in a 10-foot TV context. Lives in the transpiled `Maxi80Services` module because only that module holds `android.*` imports and the `ProcessInfo.processInfo.androidContext` pattern (see `Sources/Maxi80Services/Platform/Android/ExoPlayerStreamPlayer.swift:80-85`).

**Files:**
- Create: `Sources/Maxi80Services/PlatformEnvironment.swift`
- Test: `Tests/Maxi80ServicesTests/PlatformEnvironmentTests.swift`

**Interfaces:**
- Produces: `public enum PlatformEnvironment { public static var isTVMode: Bool { get } }` — `true` on tvOS; on Android `true` when `UI_MODE_TYPE_TELEVISION`; `false` otherwise (iOS, macOS).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/Maxi80ServicesTests/PlatformEnvironmentTests.swift
import Testing
@testable import Maxi80Services

@Suite("PlatformEnvironment")
struct PlatformEnvironmentTests {

    /// On non-TV Apple platforms (the swift-test host is macOS), isTVMode is false.
    @Test("isTVMode is false on the macOS test host")
    func isTVModeFalseOnMac() {
        #if os(macOS)
        #expect(PlatformEnvironment.isTVMode == false)
        #endif
    }

    /// The property is callable on every platform without throwing or trapping.
    @Test("isTVMode is callable")
    func isTVModeCallable() {
        _ = PlatformEnvironment.isTVMode
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PlatformEnvironmentTests`
Expected: FAIL — `cannot find 'PlatformEnvironment' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/Maxi80Services/PlatformEnvironment.swift
import Foundation
#if SKIP
import android.content.res.Configuration
import android.content.Context
#endif

/// Whether the app is running in a 10-foot TV context (Apple TV or Android TV).
///
/// Lives in the transpiled `Maxi80Services` module because reading the Android UI mode needs the
/// `android.*` APIs and the `ProcessInfo.processInfo.androidContext` accessor, which only this
/// module imports. The native `Maxi80` UI module consumes it to pick the TV vs phone root view.
public enum PlatformEnvironment {

    /// `true` on tvOS; on Android `true` when the device UI mode is television; `false` otherwise.
    public static var isTVMode: Bool {
        #if os(tvOS)
        return true
        #elseif SKIP
        let context = ProcessInfo.processInfo.androidContext
        let uiModeManager = context.getSystemService(Context.UI_MODE_SERVICE) as! android.app.UiModeManager
        return uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        #else
        return false
        #endif
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PlatformEnvironmentTests`
Expected: PASS (both tests).

- [ ] **Step 5: Verify the Android transpile compiles**

Run: `skip android build`
Expected: BUILD SUCCESSFUL. If `UiModeManager` / `Configuration` symbols fail to resolve, confirm the `#if SKIP` imports match the pattern in `ExoPlayerStreamPlayer.swift` (fully-qualified `android.app.UiModeManager` is also acceptable inline instead of an import).

- [ ] **Step 6: Commit**

```bash
git add Sources/Maxi80Services/PlatformEnvironment.swift Tests/Maxi80ServicesTests/PlatformEnvironmentTests.swift
git commit -m "feat: add PlatformEnvironment.isTVMode TV-context helper"
```

---

## Task 2: Focus-navigable TV history row

The 10-foot analog of `CoverFlowView` — a horizontal row of recently-played covers that moves by focus (tvOS `@FocusState` / Android D-pad) rather than drag. Reuses the same `viewModel.covers` data (`[CoverFlowView.Cover]`, oldest → newest, rightmost is the live "now" slot).

**Files:**
- Create: `Sources/Maxi80/TV/TVHistoryRow.swift`

**Interfaces:**
- Consumes: `RadioPlayerViewModel.covers` → `[CoverFlowView.Cover]`; `CoverFlowView.Cover` (in `CoverFlowView.swift:18-24`) has `id: String`, `artworkURL: String? = nil`, `assetName: String? = nil`. `RadioPlayerViewModel.selectedCoverID: AnyHashable?` (assigning a `String` to it wraps implicitly).
- Produces: `struct TVHistoryRow: View { init(viewModel: RadioPlayerViewModel) }`.

- [ ] **Step 1: Write the view (no separate unit test — exercised via TVRadioPlayerView and manual acceptance)**

```swift
// Sources/Maxi80/TV/TVHistoryRow.swift
import SwiftUI
import Maxi80Model

/// A focus-navigable horizontal row of recently-played covers for the TV UI. The rightmost item is
/// the live "now" slot; focus moves left through history via the remote D-pad. Reuses the same
/// `viewModel.covers` data the phone Cover Flow uses, but navigates by focus, not drag.
struct TVHistoryRow: View {
    @Bindable var viewModel: RadioPlayerViewModel
    #if os(tvOS)
    // `Cover.id` is `String`, so the FocusState value type is `String?` — assigning it into the
    // view model's `AnyHashable?` selection wraps implicitly.
    @FocusState private var focusedID: String?
    #endif

    init(viewModel: RadioPlayerViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(viewModel.covers, id: \.id) { cover in
                    coverThumbnail(cover)
                }
            }
            .padding(.horizontal, 60)
        }
        #if os(tvOS)
        .onChange(of: focusedID) { _, newValue in
            if let newValue { viewModel.selectedCoverID = newValue }
        }
        #endif
    }

    @ViewBuilder
    private func coverThumbnail(_ cover: CoverFlowView.Cover) -> some View {
        let image = Group {
            if let urlString = cover.artworkURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fit)
                    } else if let asset = cover.assetName {
                        Image(asset, bundle: .module).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.black.opacity(0.3)
                    }
                }
            } else if let asset = cover.assetName {
                Image(asset, bundle: .module).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.black.opacity(0.3)
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        #if os(tvOS)
        Button { viewModel.selectedCoverID = cover.id } label: { image }
            .buttonStyle(.card)
            .focused($focusedID, equals: cover.id)
        #else
        image
        #endif
    }
}
```

- [ ] **Step 2: Verify Apple build compiles**

Run: `swift build`
Expected: Build complete. (`buttonStyle(.card)` and `@FocusState` compile only inside `#if os(tvOS)`, so the macOS/iOS build ignores them.)

- [ ] **Step 3: Verify Android transpile compiles**

Run: `skip android build`
Expected: BUILD SUCCESSFUL. If `Image(_:bundle:)` or `AsyncImage` misbehaves on Android, mirror the exact pattern already used in `CoverFlowView.swift` for cover rendering.

- [ ] **Step 4: Commit**

```bash
git add Sources/Maxi80/TV/TVHistoryRow.swift
git commit -m "feat: add focus-navigable TV history row"
```

---

## Task 3: Shared TV now-playing hero view

The main 10-foot screen: full-bleed cover + station-color gradient background, large title/artist, a play/pause control, and `TVHistoryRow` beneath. Reuses `viewModel.dominantColor` and `Maxi80Palette` for the background exactly as the phone view does.

**Files:**
- Create: `Sources/Maxi80/TV/TVRadioPlayerView.swift`

**Interfaces:**
- Consumes: `RadioPlayerViewModel` — `displayedTitle: String`, `displayedArtist: String`, `dominantColor: Color?`, `isPlaying: Bool`, `isLoading: Bool`, `togglePlayback()`, `errorMessage: String?`, `retry()`. `TVHistoryRow(viewModel:)` from Task 2. `Maxi80Palette` (`duskTop`/`night`/`duskBottom`/`violet`/`orange`).
- Produces: `public struct TVRadioPlayerView: View { public init(viewModel: RadioPlayerViewModel) }`.

- [ ] **Step 1: Write the view**

```swift
// Sources/Maxi80/TV/TVRadioPlayerView.swift
import SwiftUI
import Maxi80Model

/// The 10-foot now-playing screen for tvOS and Android TV. A station-color gradient background (or
/// the branded dusk gradient when no artwork color is available), a large title/artist, a play/pause
/// control, and a focus-navigable history row beneath. Shares `RadioPlayerViewModel` with the phone
/// UI; focus and remote input diverge per platform behind `#if os(tvOS)` / `#if os(Android)`.
public struct TVRadioPlayerView: View {
    @Bindable var viewModel: RadioPlayerViewModel
    @Environment(\.colorScheme) var colorScheme
    #if os(tvOS)
    @FocusState private var playFocused: Bool
    #endif

    public init(viewModel: RadioPlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            background().ignoresSafeArea()
            VStack(spacing: 40) {
                Spacer()
                songLabel()
                playButton()
                Spacer()
                TVHistoryRow(viewModel: viewModel)
                Spacer().frame(height: 40)
            }
            if let errorMessage = viewModel.errorMessage {
                errorBanner(message: errorMessage)
            }
        }
        .environment(\.colorScheme, viewModel.dominantColor == nil ? .dark : colorScheme)
    }

    @ViewBuilder
    private func background() -> some View {
        Group {
            if let color = viewModel.dominantColor {
                LinearGradient(
                    gradient: Gradient(colors: [color, color.opacity(0.9)]),
                    startPoint: .top, endPoint: .bottom
                )
                .opacity(0.9)
            } else {
                LinearGradient(
                    colors: [Maxi80Palette.duskTop, Maxi80Palette.night, Maxi80Palette.duskBottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        .animation(.easeInOut(duration: 0.6), value: viewModel.dominantColor)
    }

    @ViewBuilder
    private func songLabel() -> some View {
        VStack(spacing: 16) {
            Text(viewModel.displayedTitle)
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(titleColor)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(viewModel.displayedArtist)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(subtitleColor)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 80)
    }

    @ViewBuilder
    private func playButton() -> some View {
        let button = Button {
            viewModel.togglePlayback()
        } label: {
            Group {
                if viewModel.isLoading {
                    ProgressView().tint(.orange)
                } else {
                    #if os(Android)
                    AndroidIcon(symbol: viewModel.isPlaying ? .pause : .play, size: 96, tint: .orange)
                    #else
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.orange)
                    #endif
                }
            }
            .frame(width: 96, height: 96)
        }
        .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

        #if os(tvOS)
        button.focused($playFocused).defaultFocus($playFocused, true)
        #else
        button
        #endif
    }

    private var titleColor: Color {
        #if os(Android)
        (viewModel.dominantColor == nil ? true : colorScheme == .dark) ? .white : .black
        #else
        .primary
        #endif
    }

    private var subtitleColor: Color {
        #if os(Android)
        (viewModel.dominantColor == nil ? true : colorScheme == .dark)
            ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
        #else
        .secondary
        #endif
    }

    @ViewBuilder
    private func errorBanner(message: String) -> some View {
        VStack {
            HStack(spacing: 16) {
                Text(message).font(.title3).foregroundStyle(.primary).lineLimit(2)
                Button("Retry") { viewModel.retry() }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 40)
            Spacer()
        }
    }
}
```

- [ ] **Step 2: Verify Apple build compiles**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Verify Android transpile compiles**

Run: `skip android build`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Sources/Maxi80/TV/TVRadioPlayerView.swift
git commit -m "feat: add shared TV now-playing hero view"
```

---

## Task 4: Root-view selection via `isTVMode`

Wire `Maxi80RootView` to render `TVRadioPlayerView` when `PlatformEnvironment.isTVMode` is true, else the existing `RadioPlayerView`. This is the single switch that activates the TV UI on both platforms.

**Files:**
- Modify: `Sources/Maxi80/Maxi80App.swift:37-45` (the `body` of `Maxi80RootView`)
- Test: `Tests/Maxi80Tests/TVRootSelectionTests.swift`

**Interfaces:**
- Consumes: `PlatformEnvironment.isTVMode` (Task 1), `TVRadioPlayerView(viewModel:)` (Task 3), existing `RadioPlayerView(viewModel:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/Maxi80Tests/TVRootSelectionTests.swift
import Testing
import SwiftUI
@testable import Maxi80
@testable import Maxi80Services

@Suite("TV root-view selection")
struct TVRootSelectionTests {

    /// On the macOS test host isTVMode is false, so the phone UI is selected.
    @Test("selects phone UI when not in TV mode")
    @MainActor
    func selectsPhoneUIOffTV() {
        #if os(macOS)
        #expect(PlatformEnvironment.isTVMode == false)
        #expect(Maxi80RootView.shouldUseTVUI == false)
        #endif
    }

    /// The selection flag is a pure passthrough to isTVMode.
    @Test("shouldUseTVUI mirrors isTVMode")
    @MainActor
    func mirrorsIsTVMode() {
        #expect(Maxi80RootView.shouldUseTVUI == PlatformEnvironment.isTVMode)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TVRootSelectionTests`
Expected: FAIL — `type 'Maxi80RootView' has no member 'shouldUseTVUI'`.

- [ ] **Step 3: Modify `Maxi80RootView`**

In `Sources/Maxi80/Maxi80App.swift`, add the import if missing and replace the `body`:

```swift
// at top of file, alongside the existing imports (Maxi80Services is already imported)

// inside Maxi80RootView, add:
    /// Whether to render the 10-foot TV UI. Pure passthrough to `PlatformEnvironment.isTVMode`,
    /// exposed as a static flag so the selection is unit-testable without constructing the view.
    static var shouldUseTVUI: Bool { PlatformEnvironment.isTVMode }

    public var body: some View {
        Group {
            if Self.shouldUseTVUI {
                TVRadioPlayerView(viewModel: viewModel)
            } else {
                RadioPlayerView(viewModel: viewModel)
            }
        }
        .tint(.orange)
        .task {
            await coordinator.loadStation()
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TVRootSelectionTests`
Expected: PASS.

- [ ] **Step 5: Verify both builds compile**

Run: `swift build && skip android build`
Expected: Both succeed.

- [ ] **Step 6: Commit**

```bash
git add Sources/Maxi80/Maxi80App.swift Tests/Maxi80Tests/TVRootSelectionTests.swift
git commit -m "feat: select TV UI at root when isTVMode is true"
```

---

## Task 5: Fix tvOS build guards on phone-only iOS views

`SystemVolumeSlider` (MPVolumeView), `AirPlayRoutePicker` (AVRoutePickerView), and `ShareSheetRepresentable` (UIActivityViewController) are guarded on `canImport(UIKit)`, which is **true on tvOS** — but those APIs don't exist on tvOS, so the tvOS binary won't link. Narrow each guard to exclude tvOS. These views are never rendered on TV (they live only in the phone `RadioPlayerView`), so excluding them is safe.

**Files:**
- Modify: `Sources/Maxi80/SystemVolumeSlider.swift:10`
- Modify: `Sources/Maxi80/AirPlayRoutePickerView.swift:9`
- Modify: `Sources/Maxi80/ShareSheet.swift:22,43`
- Modify: `Sources/Maxi80/VolumeSliderView.swift:52`

- [ ] **Step 1: Narrow `SystemVolumeSlider` guard**

In `Sources/Maxi80/SystemVolumeSlider.swift`, change:

```swift
#if !SKIP && canImport(UIKit)
```
to:
```swift
#if !SKIP && canImport(UIKit) && !os(tvOS)
```

- [ ] **Step 2: Narrow `AirPlayRoutePicker` iOS guard**

In `Sources/Maxi80/AirPlayRoutePickerView.swift`, change the first branch:

```swift
#if !SKIP && canImport(UIKit)
```
to:
```swift
#if !SKIP && canImport(UIKit) && !os(tvOS)
```

The existing `#elseif !SKIP` fallback (`struct AirPlayRoutePicker: View { … EmptyView() }`) then covers tvOS, so the type still resolves.

- [ ] **Step 3: Narrow `ShareSheet` UIKit guards**

In `Sources/Maxi80/ShareSheet.swift`, change **both** occurrences of:

```swift
#if canImport(UIKit)
```
to:
```swift
#if canImport(UIKit) && !os(tvOS)
```

(Line 22 in `ShareSheetContent.body` and line 43 wrapping `ShareSheetRepresentable`.) tvOS then falls into the non-UIKit branch — a plain text + copy view — which is fine because the share sheet isn't presented on TV anyway.

- [ ] **Step 4: Narrow `VolumeSliderView` slider guard**

In `Sources/Maxi80/VolumeSliderView.swift:52`, change:

```swift
#if !SKIP && canImport(UIKit)
```
to:
```swift
#if !SKIP && canImport(UIKit) && !os(tvOS)
```

so tvOS uses the plain `Slider` fallback rather than `SystemVolumeSlider`. (This view is never shown on TV, but must still compile into the binary.)

- [ ] **Step 5: Verify Apple + Android builds still pass**

Run: `swift build && skip android build`
Expected: Both succeed (this changes only tvOS-conditional compilation; macOS/iOS/Android paths are unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/Maxi80/SystemVolumeSlider.swift Sources/Maxi80/AirPlayRoutePickerView.swift Sources/Maxi80/ShareSheet.swift Sources/Maxi80/VolumeSliderView.swift
git commit -m "fix: exclude tvOS from iOS-only volume/AirPlay/share views"
```

---

## Task 6: Android TV manifest — leanback launcher + features

Make the single Android app appear on the Android TV home screen and installable on TVs (no touchscreen), while remaining a normal phone app.

**Files:**
- Modify: `Android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Add the leanback launcher category to `MainActivity`**

In the `MainActivity` `<intent-filter>`, add the leanback category alongside the existing launcher category:

```xml
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
            </intent-filter>
```

- [ ] **Step 2: Add `uses-feature` declarations**

Add these two elements as direct children of `<manifest>`, before `<application>`:

```xml
    <!-- TV support: leanback UI available but not required; no touchscreen required, so the one
         app installs on both phones and TVs. -->
    <uses-feature android:name="android.software.leanback" android:required="false" />
    <uses-feature android:name="android.hardware.touchscreen" android:required="false" />
```

- [ ] **Step 3: Reference the TV banner on `<application>`**

Add `android:banner` to the `<application>` element (the drawable is created in Task 7):

```xml
    <application
        android:label="${PRODUCT_NAME}"
        android:name=".AndroidAppMain"
        android:supportsRtl="true"
        android:allowBackup="true"
        android:banner="@drawable/tv_banner"
        android:theme="@style/Theme.Maxi80"
        android:icon="@mipmap/ic_launcher">
```

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/AndroidManifest.xml
git commit -m "feat: declare Android TV leanback launcher + features"
```

> **Note:** The build will not succeed until Task 7 adds `tv_banner`. Task 6 and Task 7 are committed separately for reviewability but should be built/verified together — run the Task 7 build step to confirm the manifest resolves.

---

## Task 7: Android TV banner asset

Play requires a 320×180 banner for the leanback launcher. Provide a simple branded vector drawable so no binary asset needs to be checked in.

**Files:**
- Create: `Android/app/src/main/res/drawable/tv_banner.xml`

- [ ] **Step 1: Create the banner drawable**

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- Android TV leanback launcher banner (320x180). Branded dusk gradient placeholder; replace with
     final artwork before store submission. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="320dp"
    android:height="180dp"
    android:viewportWidth="320"
    android:viewportHeight="180">
    <path
        android:pathData="M0,0 h320 v180 h-320 z">
        <aapt:attr xmlns:aapt="http://schemas.android.com/aapt"
            name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="0" android:startY="0"
                android:endX="320" android:endY="180">
                <item android:offset="0" android:color="#FF291238" />
                <item android:offset="0.5" android:color="#FF0D0D17" />
                <item android:offset="1" android:color="#FF38170D" />
            </gradient>
        </aapt:attr>
    </path>
</vector>
```

- [ ] **Step 2: Build the Android app to confirm the manifest + banner resolve**

Run: `skip android build`
Expected: BUILD SUCCESSFUL (resolves `@drawable/tv_banner` referenced in Task 6).

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/res/drawable/tv_banner.xml
git commit -m "feat: add Android TV leanback banner asset"
```

---

## Task 8: tvOS Xcode destination

Add a tvOS app target to `Darwin/Maxi80.xcodeproj` so the app can be built and launched on Apple TV. This is done through the Xcode UI (the `.pbxproj` is not hand-edited), reusing `Darwin/Sources/Main.swift` (its `#if canImport(UIKit)` branch already covers tvOS).

**Files:**
- Modify: `Darwin/Maxi80.xcodeproj/project.pbxproj` (via Xcode)

- [ ] **Step 1: Add a tvOS target in Xcode**

Open `Darwin/Maxi80.xcodeproj`. Duplicate the existing iOS app target (or add a new tvOS App target) named `Maxi80-tvOS`. Set:
- Deployment target: tvOS 17.0.
- Sources: the same `Darwin/Sources/Main.swift` (already tvOS-compatible via `canImport(UIKit)`).
- Package dependency: the `Maxi80` library product (same as the iOS target).
- Bundle id: `com.stormacq.sebastien.iphone.maxi80` (a tvOS variant can share the base id family; adjust if the App Store requires a distinct id).

- [ ] **Step 2: Add a tvOS app icon**

In the tvOS target's asset catalog, add a tvOS App Icon & Top Shelf image set. A placeholder brand image is acceptable for now (final art before submission). Top Shelf content is out of scope.

- [ ] **Step 3: Build for the tvOS destination**

Select the `Maxi80-tvOS` scheme and an Apple TV simulator, then Build (⌘B).
Expected: Build succeeds. If MPVolumeView/AVRoutePickerView/UIActivityViewController link errors appear, Task 5's guards were not applied — re-check them.

- [ ] **Step 4: Commit**

```bash
git add Darwin/Maxi80.xcodeproj/project.pbxproj Darwin
git commit -m "feat: add tvOS app target/scheme to Xcode project"
```

---

## Task 9: tvOS acceptance verification

Manual verification on the tvOS simulator. No code changes — this task is a checklist that gates the tvOS deliverable.

- [ ] **Step 1: Launch on the tvOS simulator**

Run the `Maxi80-tvOS` scheme on an Apple TV simulator. Expected: `TVRadioPlayerView` appears (hero + history row), not the phone layout, and audio starts after `loadStation()`.

- [ ] **Step 2: Focus navigation**

Using the simulator remote (or ⌃-arrow keys), move focus. Expected: default focus lands on the play/pause button; arrowing down moves focus into the history row; left/right moves across covers and updates the background/title via `selectedCoverID`.

- [ ] **Step 3: Play/pause via Siri Remote**

Press the remote's play/pause. Expected: playback toggles (the remote's play/pause maps to the button / the existing `MPRemoteCommandCenter` handlers in `IOSNowPlayingController`).

- [ ] **Step 4: Background audio (the key requirement)**

While audio is playing, press the Home button to background the app. Expected: audio continues; the tvOS Control Center Now Playing shows the current track and can pause/resume it.

- [ ] **Step 5: Record results**

Note any failures. If all pass, mark the tvOS deliverable complete. No commit (verification only).

---

## Task 10: Android TV acceptance verification

Manual verification on an Android TV emulator. No code changes — checklist gating the Android TV deliverable.

- [ ] **Step 1: Launch from the leanback home screen**

Start an Android TV emulator image, install the app (`skip android build` then deploy, or via Android Studio), and launch it from the TV home screen's app row. Expected: the app appears with the `tv_banner`, launches, shows `TVRadioPlayerView`, and audio starts.

- [ ] **Step 2: D-pad focus navigation**

Use the emulator D-pad. Expected: focus moves onto play/pause and into the history row; left/right across covers updates the background/title.

- [ ] **Step 3: Play/pause**

Activate the play/pause button with the D-pad center. Expected: playback toggles.

- [ ] **Step 4: Background audio (the key requirement)**

While playing, navigate the history row — audio must not stop. Then press Home to background the app. Expected: audio continues (foreground `MediaSessionService`), and the Android media notification controls it.

- [ ] **Step 5: Record results**

Note any failures. If all pass, mark the Android TV deliverable complete. No commit (verification only).

---

## Task 11: Full test + build sweep

Final gate before declaring the feature done.

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: All tests pass, including `PlatformEnvironmentTests` and `TVRootSelectionTests`.

- [ ] **Step 2: Verify all four platforms build**

Run: `swift build` (macOS/iOS Swift), `skip android build` (Android), and build the `Maxi80-tvOS` scheme in Xcode.
Expected: all succeed.

- [ ] **Step 3: Confirm phone/tablet UI is unchanged**

Launch the existing iOS scheme. Expected: `RadioPlayerView` looks and behaves exactly as before (no TV regressions leaked into the phone path).

- [ ] **Step 4: Final commit if any fixups were needed**

```bash
git add -A
git commit -m "chore: tvOS + Android TV support test/build sweep"
```

---

## Self-Review Notes

- **Spec coverage:** Now-playing hero + focus history row (Tasks 2-3), separate TV views + shared VM (Tasks 2-4, phone views untouched), shared SwiftUI transpiled to both (Tasks 2-3), same-app Android TV via `UI_MODE_TYPE_TELEVISION` (Tasks 1, 6-7), dropped volume/AirPlay/share on tvOS (Task 5 removes them from the binary; they're absent from `TVRadioPlayerView`), kept Now Playing/remote (reused, verified Task 9), background-audio requirement (Tasks 9-10 explicit acceptance). tvOS destination (Task 8). All covered.
- **Type consistency:** `PlatformEnvironment.isTVMode`, `Maxi80RootView.shouldUseTVUI`, `TVRadioPlayerView(viewModel:)`, `TVHistoryRow(viewModel:)`, `CoverFlowView.Cover` fields (`id`/`artworkURL`/`assetName`), and the `RadioPlayerViewModel` members consumed are used consistently across tasks and match the current source.
- **Note on `CoverFlowView.Cover` visibility:** it is `internal` within the `Maxi80` module; `TVHistoryRow`/`TVRadioPlayerView` are in the same module, so access is fine.
