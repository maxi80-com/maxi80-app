# Native Compose Cover Flow Carousel (Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the transpiled-SwiftUI carousel on Android with a native Jetpack Compose `LazyRow` (via `ComposeView`) that is *born* at the correct cover index across every view-tree recreation, so the Cover Flow carousel and the song title never desync.

**Architecture:** iOS keeps the existing SwiftUI `CoverFlowView` untouched. Android renders a new `AndroidCoverFlow` hosting a Compose `LazyRow` whose scroll state is created via `rememberSaveable(LazyListState.Saver)` + `LazyListState(firstVisibleItemIndex:)`. The bridge is `CarouselState`, a `/* SKIP @bridge */` class in the **transpiled `Maxi80Services`** module (like `AudioStreamPlayer`): the native `RadioPlayerViewModel` sets its primitive fields (`coverCount`/`coverURLs`/`targetIndex`/`pinNonce`) and is its `CarouselStateDelegate`; the Compose composer reads the fields and calls `notifyCentered(_:)` on settle → `carouselDidCenter(on:)`. The title/background derive from the reported centered index. **The object-in-transpiled-module bridge + born-at-index are already compile-proven (Task 0 spike, both build halves green); Task 0 below is the RUNTIME fail-fast (delegate fires + rememberSaveable survives).**

**Tech Stack:** Swift 6 + SwiftUI, Skip Fuse (native) module `Maxi80`, transpiled `#if SKIP` Kotlin, Jetpack Compose (`LazyRow`, `LazyListState`, `graphicsLayer`, `snapshotFlow`), Coil 3 (`coil3.compose.SubcomposeAsyncImage`), Swift Testing (`#expect`, `@Test`).

## Global Constraints

- Swift 6 strict concurrency; UI types `@MainActor`; `@Observable` (Observation), not Combine.
- `Maxi80` module is Skip **Fuse (native)** mode. On device, `#if SKIP` is DEAD; `#if os(Android)` is TRUE. Any Android-behavior code MUST use `#if os(Android)`, and `#if SKIP` only for transpiled-Kotlin composer bodies. Verify markers in the built `.so` / dex, never assume.
- `View.body` MUST inline `#if os(Android) … #else … #endif`; do NOT split platform branches into separate computed `@ViewBuilder` vars (renders empty on Android).
- Closures CANNOT bridge through a `ContentComposer` (compile error as ctor param; launch crash as settable var). Only bridgeable primitives (String/Double/Int/arrays) and bridged objects may cross.
- Build Android with `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer`. Use `make clean build-android` (hardened clean) when the skipstone composite may be stale; a bare `gradle :app:compileDebugKotlin` fails with environmental `Unresolved reference` errors (missing composite classpath) — not a real error.
- App package: `com.stormacq.android.maxi80`. Phone AVD: `Medium_Phone_API_36.1` (emulator-5554). Physical A07: `R8YL119N39J`. Target adb explicitly.
- Before trusting any on-device test, verify BOTH APK halves carry your change: `unzip -p base.apk 'lib/arm64-v8a/libMaxi80.so' | strings | grep <marker>` AND `unzip -p base.apk 'classes*.dex' | strings | grep <marker>`.
- Cover Flow visual constants (match iOS `CoverFlowView`): `coverSize = 260`, `spacing = -40`, `maxRotation = 55°`, `minScale = 0.72`, `verticalMargin = 40`.
- Logging: `import SkipFuse` + OSLog `Logger`; on Android only `.error` reaches Logcat. `Logger.error(...)` is an autoclosure — capture interpolated values into a `let` first (no `self.` inside the autoclosure).

---

## Task 0: Runtime fail-fast — closure fires + rememberSaveable survives (GATE)

**Bridge compile-proof is DONE** (spike, both build halves green; see spec "Spike findings"). This task proves the two RUNTIME behaviors on-device before building the full 3D carousel. It reuses the real `CarouselState` (Task 1) + a throwaway spike view. Do not proceed to the full carousel (Task 3 Step 2 onward) until both exit criteria pass.

**Files:**
- Depends on: `Sources/Maxi80Services/CarouselState.swift` (Task 1) and a minimal `AndroidCoverFlow`/composer (Task 3 Step 1).
- Create (throwaway): `Sources/Maxi80/CarouselRuntimeSpike.swift` — a spike view hosting the minimal composer, temporarily shown at app root.
- Modify (temporary): the app root (`Maxi80RootView.body` in `Sources/Maxi80/Maxi80App.swift`) to show the spike view instead of `RadioPlayerView` — REVERTED at end.

**Interfaces:**
- Consumes: `CarouselState` (Task 1), minimal composer (Task 3 Step 1).
- Produces: go/no-go on runtime closure firing + saveable index survival.

- [ ] **Step 1: Build a minimal runtime spike view (throwaway)**

Create `Sources/Maxi80/CarouselRuntimeSpike.swift`: an Android-only view owning a `CarouselState` (`coverCount = 7`, `targetIndex = 3`). Make a tiny delegate box (`final class SpikeDelegate: CarouselStateDelegate` capturing an `@State`-backed binding, or set `state.delegate` in `.task` to an object that updates a `@State var centeredIndex`), show `Text("centered=\(centeredIndex)")` above `ComposeView { CoverFlowComposer(state:) }` (the minimal composer from Task 3 Step 1). `@State` must be non-private (bridged views require it).

- [ ] **Step 2: Temporarily route the app root to the spike**

In `Sources/Maxi80/Maxi80App.swift`, in `Maxi80RootView.body`, temporarily return `CarouselRuntimeSpikeView()` on Android (inline `#if os(Android)`), so it renders on launch. Mark with a `// SPIKE — revert` comment.

- [ ] **Step 3: Build + install on the phone emulator**

```bash
cd /Users/sst/code/maxi80/maxi80-2026/Maxi80
DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer make clean build-android
adb -s emulator-5554 install -r .build/Android/app/outputs/apk/debug/app-debug.apk \
  || { adb -s emulator-5554 uninstall com.stormacq.android.maxi80; adb -s emulator-5554 install .build/Android/app/outputs/apk/debug/app-debug.apk; }
```

- [ ] **Step 4: Verify closure fires + born-at-index (you drive UI, I read logs)**

On the emulator: (a) confirm the row is initially centered on index 3 (`targetIndex`), NOT 0 — proves born-at-index. (b) Scroll to another cover; confirm `centered=N` updates — proves the delegate (`notifyCentered` → `carouselDidCenter`) fires across the bridge at runtime.

- [ ] **Step 5: Verify rememberSaveable survives recreation**

Developer Options → *Don't keep activities* ON. Scroll to index 5, background (Home), return. Confirm the row comes back on index 5, not 0. (If it resets to 0, apply the spec's backstop lever — re-pin `LaunchedEffect` keyed on `state.pinNonce` AND `listState.layoutInfo.viewportSize.width` — and re-verify before proceeding.)

- [ ] **Step 6: Revert the temporary routing + delete the spike view**

Restore `Maxi80RootView.body`; delete `Sources/Maxi80/CarouselRuntimeSpike.swift`. `CarouselState` and the composer STAY (they are real code from Tasks 1/3). Do not commit the spike view.

**Exit criteria (both must hold):** the closure fires on settle (Swift observes the index) AND the saved index survives a forced recreation. Only then build the full 3D carousel.

---

## Task 1: `CarouselState` (Maxi80Services bridge) + view-model index mapping (pure logic, TDD)

**Files:**
- Create: `Sources/Maxi80Services/CarouselState.swift` (transpiled module, `/* SKIP @bridge */`)
- Modify: `Sources/Maxi80/RadioPlayerViewModel.swift` (own a `CarouselState`, derive `targetIndex`, map reported index)
- Test: `Tests/Maxi80Tests/CarouselBridgeTests.swift`

**Interfaces:**
- Consumes: `RadioPlayerViewModel.covers: [CoverFlowView.Cover]`, `.selectedCoverID: AnyHashable?`, `.liveCoverID: AnyHashable?` (== `nowSlotID` == `"__now__"`), `.nowSlotID`, `.returnToLive()`.
- Produces:
  - `Maxi80Services.CarouselStateDelegate` — `public protocol CarouselStateDelegate: AnyObject { @MainActor func carouselDidCenter(on index: Int) }`.
  - `Maxi80Services.CarouselState` — `/* SKIP @bridge */ @MainActor public final class` (in `#if !SKIP_BRIDGE`) with `public var coverCount: Int`, `public var coverURLs: [String]`, `public var targetIndex: Int`, `public var pinNonce: Int`, `public weak var delegate: (any CarouselStateDelegate)?`, and `public func notifyCentered(_ index: Int)` (calls `delegate?.carouselDidCenter(on: index)`).
  - `RadioPlayerViewModel.carouselState: CarouselState` (stored, `@ObservationIgnored`), with `RadioPlayerViewModel: CarouselStateDelegate` conformance whose `carouselDidCenter(on:)` calls `handleCenteredIndex(_:)`.
  - `RadioPlayerViewModel.syncCarouselState()` — recomputes `coverCount`/`coverURLs`/`targetIndex` from `covers`/`selectedCoverID`.
  - `RadioPlayerViewModel.handleCenteredIndex(_ index: Int)` — maps index → cover id → sets `selectedCoverID`.
  - `RadioPlayerViewModel.carouselTargetIndex(covers:selectedCoverID:) -> Int` — static pure helper (index of selected in covers, clamped to `covers.count-1`, default last/live).

- [ ] **Step 1: Write the failing test for `carouselTargetIndex` mapping**

```swift
import Testing
@testable import Maxi80
@testable import Maxi80Model

@Suite("Carousel bridge index mapping")
@MainActor
struct CarouselBridgeTests {

  private func covers(_ ids: [String]) -> [CoverFlowView.Cover] {
    ids.map { CoverFlowView.Cover(id: $0) }
  }

  @Test("target index is the live (last) slot when selection is the now slot")
  func targetIndexLiveIsLast() {
    let cs = covers(["old1", "old2", "__now__"])
    let idx = RadioPlayerViewModel.carouselTargetIndex(
      covers: cs, selectedCoverID: AnyHashable("__now__"))
    #expect(idx == 2)
  }

  @Test("target index resolves a browsed history cover by id")
  func targetIndexBrowsed() {
    let cs = covers(["old1", "old2", "__now__"])
    let idx = RadioPlayerViewModel.carouselTargetIndex(
      covers: cs, selectedCoverID: AnyHashable("old1"))
    #expect(idx == 0)
  }

  @Test("target index falls back to last slot when selection is unknown/nil")
  func targetIndexFallbackLast() {
    let cs = covers(["old1", "__now__"])
    #expect(RadioPlayerViewModel.carouselTargetIndex(covers: cs, selectedCoverID: nil) == 1)
    #expect(
      RadioPlayerViewModel.carouselTargetIndex(
        covers: cs, selectedCoverID: AnyHashable("missing")) == 1)
  }

  @Test("target index clamps for single-cover history")
  func targetIndexSingle() {
    let cs = covers(["__now__"])
    #expect(RadioPlayerViewModel.carouselTargetIndex(covers: cs, selectedCoverID: AnyHashable("__now__")) == 0)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CarouselBridgeTests`
Expected: FAIL — `carouselTargetIndex` / `CoverFlowView.Cover(id:)` compile errors or missing symbol.

- [ ] **Step 3: Create `CarouselState` + delegate in `Maxi80Services`**

Create `Sources/Maxi80Services/CarouselState.swift` (transpiled module; mirrors `AudioStreamPlayer`'s `/* SKIP @bridge */` + `#if !SKIP_BRIDGE` structure):

```swift
import Foundation

/// Delegate for the Android Compose carousel to report its settled centered cover back to native
/// code. A protocol (not a stored closure) keeps the cross-bridge callback typed, weak, and Swift-6
/// clean. Implemented by RadioPlayerViewModel.
public protocol CarouselStateDelegate: AnyObject {
  @MainActor func carouselDidCenter(on index: Int)
}

/// Bridge conduit between the native view model and the Android Compose `LazyRow` (see the native
/// `AndroidCoverFlow`). Lives in the transpiled module — like `AudioStreamPlayer` — so its fields
/// generate as real Kotlin the composer can read, and `notifyCentered` reaches the native delegate.
/// The native side sets the "in" fields and is the `delegate`; Compose reads the fields and calls
/// `notifyCentered` on settle.
/* SKIP @bridge */
#if !SKIP_BRIDGE
  @MainActor
  public final class CarouselState {
    /// Number of covers to render.
    public var coverCount: Int = 0
    /// Artwork URL per cover, positionally parallel to the covers (empty string == draw the bundled
    /// generic placeholder). `[String]` (not `[String?]`) so it bridges as a plain string list.
    public var coverURLs: [String] = []
    /// The cover index the carousel must be born on / re-pin to.
    public var targetIndex: Int = 0
    /// Bumped to command a "Back to live" animated scroll even when `targetIndex` is unchanged.
    public var pinNonce: Int = 0
    /// Receives the settled centered index. Weak to avoid a retain cycle with the owning view model.
    public weak var delegate: (any CarouselStateDelegate)?

    public init() {}

    /// Called from the Compose composer when the scroll settles on `index`.
    public func notifyCentered(_ index: Int) {
      delegate?.carouselDidCenter(on: index)
    }
  }
#endif
```

- [ ] **Step 4: Add the pure helper + wiring + delegate conformance to `RadioPlayerViewModel`**

In `Sources/Maxi80/RadioPlayerViewModel.swift` add (import `Maxi80Services` is already present):

```swift
@ObservationIgnored
let carouselState = CarouselState()

/// Index of `selectedCoverID` within `covers`, clamped; defaults to the last (live) slot when the
/// selection is nil or not present. Pure so it is unit-testable without the bridge.
static func carouselTargetIndex(
  covers: [CoverFlowView.Cover], selectedCoverID: AnyHashable?
) -> Int {
  guard !covers.isEmpty else { return 0 }
  if let id = selectedCoverID?.base as? String,
    let i = covers.firstIndex(where: { $0.id == id }) {
    return i
  }
  return covers.count - 1
}

/// Recompute the Compose carousel's input fields from the current covers + selection.
func syncCarouselState() {
  let cs = covers
  carouselState.coverCount = cs.count
  // Positional URL per cover; empty string == draw the generic placeholder in Compose.
  carouselState.coverURLs = cs.map { $0.artworkURL ?? "" }
  carouselState.targetIndex = Self.carouselTargetIndex(covers: cs, selectedCoverID: selectedCoverID)
}

/// Map a settled centered index to a cover id and update the selection (drives title/background).
/// Defensive against out-of-range indices.
func handleCenteredIndex(_ index: Int) {
  let cs = covers
  guard cs.indices.contains(index) else { return }
  selectedCoverID = AnyHashable(cs[index].id)
}
```

And add the delegate conformance (assign `carouselState.delegate = self` in `init`, after storing dependencies):

```swift
extension RadioPlayerViewModel: CarouselStateDelegate {
  func carouselDidCenter(on index: Int) { handleCenteredIndex(index) }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CarouselBridgeTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Verify the delegate bridges (compile both halves)**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer skip android build` then `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer make build-android`.
Expected: both green — confirms `CarouselState` + delegate transpile. (If the delegate does NOT bridge, fall back to the compile-proven `public var onCenteredIndexChanged: ((Int) -> Void)?` + `emitCenteredIndex` invoking it via `if let` — NOT `?.()`, which yields `Unit?` and fails Kotlin's `-> Void` check — and adjust the composer/VM to match.)

- [ ] **Step 7: Commit**

```bash
git add Sources/Maxi80Services/CarouselState.swift Sources/Maxi80/RadioPlayerViewModel.swift Tests/Maxi80Tests/CarouselBridgeTests.swift
git commit -m "feat(android): CarouselState bridge (Maxi80Services) + view-model index mapping"
```

---

## Task 2: `handleCenteredIndex` selection semantics (TDD, browsing/append edge cases)

**Files:**
- Modify: `Sources/Maxi80/RadioPlayerViewModel.swift` (only if a test exposes a gap)
- Test: `Tests/Maxi80Tests/CarouselBridgeTests.swift` (extend)

**Interfaces:**
- Consumes: `handleCenteredIndex(_:)`, `syncCarouselState()`, `carouselTargetIndex(...)` from Task 1; `isBrowsingHistory`, `selectedCoverID`.
- Produces: verified round-trip invariant (index → selection → targetIndex is stable) that later on-device behavior relies on.

- [ ] **Step 1: Write the failing tests for the round-trip + append-stability invariants**

Append to `CarouselBridgeTests`:

```swift
@Test("centered index round-trips back to the same target index")
func centeredIndexRoundTrips() {
  let cs = covers(["old1", "old2", "__now__"])
  // Simulate Compose settling on index 0 (oldest).
  let selected = AnyHashable(cs[0].id)
  let back = RadioPlayerViewModel.carouselTargetIndex(covers: cs, selectedCoverID: selected)
  #expect(back == 0)
}

@Test("a new song appended on the right keeps a browsed index stable by id")
func browsedIndexStableOnAppend() {
  let before = covers(["old1", "old2", "__now__"])
  // User browsing old1 (index 0).
  let sel = AnyHashable("old1")
  #expect(RadioPlayerViewModel.carouselTargetIndex(covers: before, selectedCoverID: sel) == 0)
  // A new song appends: previous now-song becomes a history entry, new now slot added.
  let after = covers(["old1", "old2", "old3", "__now__"])
  // The browsed cover id is unchanged, so its index is still 0 (position preserved by id, not slot).
  #expect(RadioPlayerViewModel.carouselTargetIndex(covers: after, selectedCoverID: sel) == 0)
}
```

- [ ] **Step 2: Run to verify pass/fail**

Run: `swift test --filter CarouselBridgeTests`
Expected: PASS (both new tests) — the Task 1 helper already satisfies these; if either FAILS, fix `carouselTargetIndex` to resolve by id first (it already does) before adding logic.

- [ ] **Step 3: Commit**

```bash
git add Tests/Maxi80Tests/CarouselBridgeTests.swift
git commit -m "test(android): carousel index round-trip + append-stability invariants"
```

---

## Task 3: `AndroidCoverFlow` view + `CoverFlowComposer` (native Compose LazyRow)

**Files:**
- Create: `Sources/Maxi80/AndroidCoverFlow.swift`
- Reference (do not modify): `Sources/Maxi80/AndroidIcon.swift` (the working `ComposeView`/`ContentComposer`/`#if SKIP` pattern), `Sources/Maxi80/CoverFlowView.swift` (visual constants + tilt math).

**Interfaces:**
- Consumes: `Maxi80Services.CarouselState` (Task 1) — the compile-proven bridge shape.
- Produces:
  - `AndroidCoverFlow: View` (`#if os(Android)`) — `init(state: CarouselState)`.
  - `CoverFlowComposer: ContentComposer` (`#if os(Android)` + `#if SKIP`) — renders the `LazyRow`.

- [ ] **Step 1: Create the Android wrapper view + minimal composer (born-at-index, delegate write-back)**

Create `Sources/Maxi80/AndroidCoverFlow.swift`. This is the exact shape proven to compile both halves in Task 0 (imports matter — `rememberSaveable` is in `androidx.compose.runtime.saveable`, layout modifiers need their imports). Step 2 fills in the 3D cells; this step is the minimal render used by the Task 0 runtime gate.

```swift
import SwiftUI
import Maxi80Services

#if SKIP
  import androidx.compose.foundation.layout.Box
  import androidx.compose.foundation.layout.fillMaxWidth
  import androidx.compose.foundation.layout.height
  import androidx.compose.foundation.layout.width
  import androidx.compose.foundation.lazy.LazyRow
  import androidx.compose.foundation.lazy.LazyListState
  import androidx.compose.runtime.LaunchedEffect
  import androidx.compose.runtime.snapshotFlow
  import androidx.compose.runtime.saveable.rememberSaveable
  import androidx.compose.ui.Alignment
  import androidx.compose.ui.Modifier
  import androidx.compose.ui.unit.dp
#endif

/// Android-only native Cover Flow carousel. Renders a Compose `LazyRow` whose scroll state is born
/// at `state.targetIndex` (via a saveable list state), so a view-tree recreation (resume, rotation,
/// low-memory) lands on the correct cover instead of resetting to the leftmost one — the root fix
/// for the recurring carousel/title desync. iOS keeps the SwiftUI `CoverFlowView`.
#if os(Android)
  struct AndroidCoverFlow: View {
    let state: CarouselState

    var body: some View {
      ComposeView {
        CoverFlowComposer(state: state)
      }
    }
  }

  #if SKIP
    /// Transpiled Compose body. `rememberSaveable(LazyListState.Saver)` seeded with
    /// `firstVisibleItemIndex` so the row is BORN centered on the target; reports the settled centered
    /// index back via `state.notifyCentered`. 3D tilt (Step 2) applied via `graphicsLayer`.
    struct CoverFlowComposer: ContentComposer {
      let state: CarouselState

      @Composable func Compose(context: ComposeContext) {
        let listState = rememberSaveable(saver: LazyListState.Saver) {
          LazyListState(firstVisibleItemIndex: state.targetIndex)
        }

        // Report the settled centered item back to Swift (no transient writes).
        LaunchedEffect(listState) {
          snapshotFlow {
            listState.firstVisibleItemIndex
          }.collect { index in
            if !listState.isScrollInProgress { state.notifyCentered(index) }
          }
        }

        // "Back to live" / re-pin: animate to the target when pinNonce changes.
        LaunchedEffect(state.pinNonce) {
          listState.animateScrollToItem(state.targetIndex)
        }

        LazyRow(
          state: listState,
          modifier: context.modifier.fillMaxWidth().height(340.dp)
        ) {
          // items rendered in Step 2
        }
      }
    }
  #endif
#endif
```

- [ ] **Step 2: Render items with Coil artwork + 3D tilt (full parity)**

Fill the `LazyRow` content with `items(state.coverCount) { i in … }` (URL is `state.coverURLs[i]`, empty == placeholder). Compute each item's distance from viewport center from `listState.layoutInfo` and apply `graphicsLayer { rotationY, scaleX, scaleY }`, z-index, shadow, matching iOS constants (`coverSize=260`, `spacing=-40`, `maxRotation=55`, `minScale=0.72`). Use `coil3.compose.SubcomposeAsyncImage(model: url, contentScale: ContentScale.Crop)` for a non-empty URL; draw the bundled generic placeholder asset for an empty URL.

- [ ] **Step 3: Build the native `.so` to type-check the Swift/bridge surface**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer skip android build`
Expected: `Build complete!` (compiles `libMaxi80.so`). Fix any Swift-side bridge/type errors.

- [ ] **Step 4: Build the transpiled Kotlin half**

Run: `cd /Users/sst/code/maxi80/maxi80-2026/Maxi80 && DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer make build-android`
Expected: `BUILD SUCCESSFUL`. This compiles the `#if SKIP` composer as real Kotlin — fix Compose/Coil reference errors here (both halves must compile; see Global Constraints).

- [ ] **Step 5: Commit**

```bash
git add Sources/Maxi80/AndroidCoverFlow.swift Sources/Maxi80/RadioPlayerViewModel.swift
git commit -m "feat(android): native Compose LazyRow carousel born at saved index"
```

---

## Task 4: Wire `AndroidCoverFlow` into `RadioPlayerView`; keep carousel state synced

**Files:**
- Modify: `Sources/Maxi80/RadioPlayerView.swift` (the `coverFlow()` builder + resync on resume)
- Modify: `Sources/Maxi80/RadioPlayerViewModel.swift` (bump `pinNonce` in `returnToLive()`; sync on relevant changes)

**Interfaces:**
- Consumes: `AndroidCoverFlow(state:)` (Task 3), `viewModel.carouselState`, `syncCarouselState()`, `returnToLive()`. The write-back runs through the `CarouselStateDelegate` conformance (Task 1) — no `onChange` observer needed.
- Produces: the platform-selected carousel; the running data-flow loop.

- [ ] **Step 1: Select the carousel per-platform inside `coverFlow()` (inlined `#if os(Android)`)**

In `Sources/Maxi80/RadioPlayerView.swift`, replace the body of `coverFlow()` so the platform branch is inlined (never a separate var). The `.task(id:)` re-syncs the input fields whenever covers/selection change (its identity is `coverPinToken`); the write-back arrives via the delegate the view model already set on `carouselState` in Task 1.

```swift
@ViewBuilder
private func coverFlow() -> some View {
  #if os(Android)
    AndroidCoverFlow(state: viewModel.carouselState)
      .frame(height: 340)
      .accessibilityLabel(
        Text("Song history. Swipe to browse previously played tracks.", bundle: .module))
      .task(id: viewModel.coverPinToken) { viewModel.syncCarouselState() }
  #else
    CoverFlowView(
      covers: viewModel.covers,
      selection: Binding(
        get: { viewModel.selectedCoverID },
        set: { viewModel.setSelectionFromCarousel($0) }
      ),
      pinTarget: viewModel.isBrowsingHistory ? nil : viewModel.liveCoverID,
      pinToken: viewModel.coverPinToken
    )
    .accessibilityLabel(
      Text("Song history. Swipe to browse previously played tracks.", bundle: .module))
  #endif
}
```

- [ ] **Step 2: Make `returnToLive()` drive the Android re-pin**

In `Sources/Maxi80/RadioPlayerViewModel.swift`, extend `returnToLive()`:

```swift
func returnToLive() {
  selectedCoverID = liveCoverID
  returnToLiveNonce += 1
  syncCarouselState()
  carouselState.pinNonce += 1
}
```

- [ ] **Step 3: Sync carousel state when covers change on resume**

Ensure `SharedPlayer.handleForeground()` path refreshes inputs. In `RadioPlayerView.swift`, the existing `.onChange(of: scenePhase)` already calls `SharedPlayer.handleForeground()`; add a resync right after it in the same modifier:

```swift
.onChange(of: scenePhase) { _, newPhase in
  if newPhase == .active {
    SharedPlayer.handleForeground()
    viewModel.syncCarouselState()
  }
}
```

(The Android activity `onResume` path also runs `handleForeground`; the `.task(id: coverPinToken)` from Step 1 re-syncs on the recreated view. Both cover the resume.)

- [ ] **Step 4: Build both halves**

Run (from the repo root `/Users/sst/code/maxi80/maxi80-2026/Maxi80`): `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer skip android build` then `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer make build-android`
Expected: both green. Also run `swift build` to confirm the iOS/native path still compiles.

- [ ] **Step 5: Commit**

```bash
git add Sources/Maxi80/RadioPlayerView.swift Sources/Maxi80/RadioPlayerViewModel.swift
git commit -m "feat(android): wire native carousel into RadioPlayerView + re-pin on back-to-live"
```

---

## Task 5: On-device verification (the real proof)

**Files:** none (verification only). Add temporary `RepinDiag` logging if needed, and REMOVE it before the final commit.

**Interfaces:** Consumes the full feature. Produces the go/no-go evidence.

- [ ] **Step 1: Clean build + install the APK on the phone emulator**

```bash
cd /Users/sst/code/maxi80/maxi80-2026/Maxi80
DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer make clean build-android
# verify BOTH halves carry the new type before trusting the device:
APK=.build/Android/app/outputs/apk/debug/app-debug.apk
unzip -p "$APK" 'lib/arm64-v8a/libMaxi80.so' | strings | grep -c CoverFlowComposer
unzip -p "$APK" 'classes*.dex' | strings | grep -c CoverFlowComposer
adb -s emulator-5554 install -r "$APK" || { adb -s emulator-5554 uninstall com.stormacq.android.maxi80; adb -s emulator-5554 install "$APK"; }
```

Expected: both grep counts > 0; install Success.

- [ ] **Step 2: Run the recreation matrix (you drive the UI; capture logs via adb)**

For EACH of: resume via notification tap, resume via app icon, low-memory recreation (Developer Options → *Don't keep activities* ON, and the Android Studio Debug-button launch), AND each starting from BOTH the live cover and a browsed history cover:

- Confirm on return the carousel is **visually on the correct cover** (the one left) AND the **title matches** it.

Capture: `adb -s emulator-5554 logcat -v time | grep -aE "starting activity|onRestart"` to confirm which returns went through recreation (`starting activity`) vs. `onRestart`.

- [ ] **Step 3: Verify "Back to live" still animates to live**

Browse to an old cover, tap Back to live, confirm the carousel animates to the live slot and the title updates.

- [ ] **Step 4: Verify on the physical A07 (the original bug device)**

Repeat Step 2's notification-resume case on `R8YL119N39J` (install the same APK). Confirm no desync across several recreations.

- [ ] **Step 5: iOS regression pass**

```bash
xcodebuild -project Darwin/Maxi80.xcodeproj -scheme "Maxi80 App" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' SKIP_ACTION=none build
```
Install/run on the sim; confirm the carousel + browsing + Back to live are unchanged (iOS code untouched).

- [ ] **Step 6: Remove any temporary diagnostics; run the full native suite**

Run: `swift test`
Expected: all green (existing suite + `CarouselBridgeTests`).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "test(android): device-verify native carousel sync across recreation matrix"
```

---

## Task 6: PR

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin design/carousel-sync-native-compose  # or the impl branch in use
gh pr create --repo maxi80-com/maxi80-app --base main \
  --title "fix(android): native Compose carousel born at saved index — durable Cover Flow sync" \
  --body-file <(cat <<'EOF'
Implements docs/superpowers/specs/2026-07-28-carousel-sync-native-compose-design.md.

Root-cause fix for the recurring carousel/title desync (rotation, resume, #44):
Android now renders a native Compose LazyRow born at the saved cover index via
rememberSaveable(LazyListState.Saver). CarouselState (a bridge class in the
transpiled Maxi80Services module) carries primitive fields in and reports the
settled centered index back via a CarouselStateDelegate, so the title is a pure
function of the visible cover. iOS SwiftUI carousel unchanged.

## Testing
- Unit: CarouselBridgeTests (index mapping, round-trip, append-stability).
- On-device (emulator + A07): recreation matrix — notification/icon/low-memory,
  from live and browsed covers — all land born-centered with title in sync.
- iOS regression: unchanged, verified on simulator.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)
```

---

## Self-Review

**1. Spec coverage:**
- Born-at-index principle → Task 0 (runtime proof) + Task 3 (`rememberSaveable` + `LazyListState(firstVisibleItemIndex:)`). ✓
- iOS unchanged → Task 4 keeps `CoverFlowView` in the `#else`. ✓
- Bridge = CarouselState in transpiled Maxi80Services → Task 1. ✓
- Title = pure function of visible cover → Task 1 delegate (`carouselDidCenter` → `handleCenteredIndex`). ✓
- Full 3D parity → Task 3 Step 2. ✓
- Back to live → Task 3 (`LaunchedEffect(state.pinNonce)`) + Task 4 Step 2. ✓
- Edge cases (empty/single/append) → Task 1 + Task 2 tests. ✓
- Bridge compile-proof (done) + delegate/runtime fail-fast → Task 1 Step 6 + Task 0. ✓
- On-device matrix + both-halves verification → Task 5. ✓
- Rotation unlock deferred → not in plan (correct; spec marks it future). ✓

**2. Placeholder scan:** No "TBD/TODO/handle edge cases" left as work items. Task 3 Step 2 names the exact constants and APIs; the URL representation is a concrete default (parallel `coverURLs: [String]`, empty == placeholder).

**3. Type consistency:** `CarouselState` fields (`coverCount`, `coverURLs`, `targetIndex`, `pinNonce`) + `delegate`/`notifyCentered` used identically in Tasks 0, 1, 3, 4. `CarouselStateDelegate.carouselDidCenter(on:)`, `carouselTargetIndex(covers:selectedCoverID:)`, `syncCarouselState()`, `handleCenteredIndex(_:)` names consistent across tasks. `AndroidCoverFlow(state:)` init matches Task 4 call site.
