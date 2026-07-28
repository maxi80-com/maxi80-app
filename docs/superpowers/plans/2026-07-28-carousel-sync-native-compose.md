# Native Compose Cover Flow Carousel (Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the transpiled-SwiftUI carousel on Android with a native Jetpack Compose `LazyRow` (via `ComposeView`) that is *born* at the correct cover index across every view-tree recreation, so the Cover Flow carousel and the song title never desync.

**Architecture:** iOS keeps the existing SwiftUI `CoverFlowView` untouched. Android renders a new `AndroidCoverFlow` hosting a Compose `LazyRow` whose scroll state is created via `rememberSaveable(LazyListState.Saver)` + `initialFirstVisibleItemIndex`. A bridged observable state holder (`CarouselBridgeState`) is the single source of truth: the Swift view model writes `covers`/`targetIndex`/`pinNonce` in, Compose writes the settled `centeredIndex` out, and the title/background derive from the visible cover. A prototype spike in the hello-world reference project validates the bridge mechanism before any app code is written.

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

## Task 0: Prototype spike — validate the bridge (GATE)

**This task produces NO app code.** It is a throwaway proof in the reference prototype. Do not proceed to Task 1 until all three exit criteria pass. If the object-bridge fails, record it and switch the plan to the primitives-only fallback (noted in each affected task).

**Files:**
- Work in: `/Users/sst/code/maxi80/skip-tutorial/hello-world` (OUTSIDE this repo; throwaway edits, do not commit to Maxi80).

**Interfaces:**
- Produces (knowledge, recorded in the spike notes): the exact, working shape of (a) a bridged observable object passed into `ComposeView`, (b) how Compose reads its fields and reacts to Swift writes, (c) how Swift observes a value Compose wrote, (d) that `rememberSaveable(LazyListState.Saver)` + `initialFirstVisibleItemIndex` survives recreation.

- [ ] **Step 1: Add a minimal bridged state class in the prototype**

In hello-world, add a class mirroring the intended shape:

```swift
@Observable @MainActor final class SpikeState {
  var items: [String] = ["a", "b", "c", "d", "e"]
  var targetIndex: Int = 3
  var centeredIndex: Int = 0
}
```

Wire it into a view that hosts `ComposeView { SpikeComposer(state: state) }`.

- [ ] **Step 2: Implement a Compose LazyRow composer that reads + writes the state**

```swift
#if SKIP
struct SpikeComposer: ContentComposer {
  let state: SpikeState
  @Composable func Compose(context: ComposeContext) {
    let listState = rememberSaveable(saver: LazyListState.Saver) {
      LazyListState(firstVisibleItemIndex: state.targetIndex)
    }
    LaunchedEffect(listState) {
      snapshotFlow { Pair(listState.isScrollInProgress, listState.firstVisibleItemIndex) }
        .collect { pair in
          if pair.first == false { state.centeredIndex = pair.second }
        }
    }
    LazyRow(state: listState, modifier: context.modifier.fillMaxWidth()) {
      // render state.items as simple boxes
    }
  }
}
#endif
```

Goal: confirm (a) `state.items`/`state.targetIndex` are readable in Compose, (b) writing `state.centeredIndex` from Compose compiles and runs.

- [ ] **Step 3: Observe the Compose→Swift write on the Swift side**

Add a SwiftUI `Text("\(state.centeredIndex)")` (or a Logger line) that must update when the LazyRow settles on a new item. Build + run on the emulator:

Run: `cd /Users/sst/code/maxi80/skip-tutorial/hello-world && DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer skip android build` then install/run.

- [ ] **Step 4: Verify born-at-index + survives recreation**

On the emulator: confirm the row initially shows item index 3 centered (`targetIndex`), NOT index 0. Then rotate the device (or toggle Developer Options → *Don't keep activities* and background/foreground) and confirm it returns to the saved index, not index 0.

- [ ] **Step 5: Record the proven pattern**

Write the exact working code shapes into a scratch note (paste into Task 2/3 as the reference). If Step 2 or 3 FAILED (object bridge doesn't do bidirectional reactivity): record that, and for Tasks 2–4 use the FALLBACK — pass `items: [String]` and `targetIndex: Int` as primitive ctor params, report `centeredIndex` via a single bridged `Int` holder, and drive re-pin from `LaunchedEffect(pinNonce, listState.layoutInfo.viewportSize.width)`.

- [ ] **Step 6: Clean up the prototype**

Revert the throwaway edits in hello-world (`git -C /Users/sst/code/maxi80/skip-tutorial/hello-world checkout .`). Nothing to commit in this repo.

**Exit criteria (all must hold):** row is born at `targetIndex`; Compose write of `centeredIndex` is observed by Swift; saved index survives a forced recreation. Only then proceed.

---

## Task 1: `CarouselBridgeState` + view-model index mapping (pure logic, TDD)

**Files:**
- Create: `Sources/Maxi80/CarouselBridgeState.swift`
- Modify: `Sources/Maxi80/RadioPlayerViewModel.swift` (add `carouselBridge`, `targetIndex` derivation, `centeredIndex` handling)
- Test: `Tests/Maxi80Tests/CarouselBridgeTests.swift`

**Interfaces:**
- Consumes: `RadioPlayerViewModel.covers: [CoverFlowView.Cover]`, `.selectedCoverID: AnyHashable?`, `.liveCoverID: AnyHashable?` (== `nowSlotID` == `"__now__"`), `.nowSlotID`, `.returnToLive()`.
- Produces:
  - `CarouselBridgeState` — `@Observable @MainActor final class` with `var coverIDs: [String]`, `var targetIndex: Int`, `var pinNonce: Int`, `var centeredIndex: Int`.
  - `RadioPlayerViewModel.carouselBridge: CarouselBridgeState` (stored, `@ObservationIgnored`).
  - `RadioPlayerViewModel.syncCarouselBridgeInputs()` — recomputes `coverIDs` + `targetIndex` from `covers`/`selectedCoverID`.
  - `RadioPlayerViewModel.handleCenteredIndex(_ index: Int)` — maps index → cover id → sets `selectedCoverID`.
  - `RadioPlayerViewModel.carouselTargetIndex(covers:selectedCoverID:) -> Int` — static-style pure helper (index of selected in covers, clamped to `covers.count-1`, default last/live).

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

- [ ] **Step 3: Create `CarouselBridgeState`**

Create `Sources/Maxi80/CarouselBridgeState.swift`:

```swift
import Foundation

/// Single source of truth shared with the Android native Compose carousel across the `ComposeView`
/// bridge. The Swift view model owns it and writes the "in" fields (`coverIDs`, `targetIndex`,
/// `pinNonce`); the Compose `LazyRow` writes the "out" field (`centeredIndex`) when its scroll
/// settles. Only bridgeable primitives — closures cannot cross a `ContentComposer` bridge.
@Observable
@MainActor
final class CarouselBridgeState {
  /// Ordered cover ids, oldest → newest; the last is the live "now" slot. Index into this is what
  /// Compose reports and consumes.
  var coverIDs: [String] = []
  /// Artwork URL per cover, positionally parallel to `coverIDs`. Empty string == no URL → the
  /// bundled generic placeholder is drawn. Kept as `[String]` (not `[String?]`) so the array
  /// bridges as a plain string list.
  var coverURLs: [String] = []
  /// The cover index the carousel must be born on / re-pin to.
  var targetIndex: Int = 0
  /// Bumped to command a "Back to live" animated scroll even when `targetIndex` is unchanged.
  var pinNonce: Int = 0
  /// The settled centered index Compose reports back. The view model maps it to a cover id.
  var centeredIndex: Int = 0
}
```

- [ ] **Step 4: Add the pure helper + wiring to `RadioPlayerViewModel`**

In `Sources/Maxi80/RadioPlayerViewModel.swift`, add near the Cover Flow section:

```swift
@ObservationIgnored
let carouselBridge = CarouselBridgeState()

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

/// Recompute the Compose carousel's input state from the current covers + selection.
func syncCarouselBridgeInputs() {
  let cs = covers
  carouselBridge.coverIDs = cs.map(\.id)
  // Positional URL per cover; empty string == draw the generic placeholder in Compose.
  carouselBridge.coverURLs = cs.map { $0.artworkURL ?? "" }
  carouselBridge.targetIndex = Self.carouselTargetIndex(covers: cs, selectedCoverID: selectedCoverID)
}

/// Handle a settled centered index reported by the Compose carousel: map it back to a cover id and
/// update the selection (which drives title/background). Ignores out-of-range indices defensively.
func handleCenteredIndex(_ index: Int) {
  let cs = covers
  guard cs.indices.contains(index) else { return }
  selectedCoverID = AnyHashable(cs[index].id)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CarouselBridgeTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Maxi80/CarouselBridgeState.swift Sources/Maxi80/RadioPlayerViewModel.swift Tests/Maxi80Tests/CarouselBridgeTests.swift
git commit -m "feat(android): carousel bridge state + view-model index mapping"
```

---

## Task 2: `handleCenteredIndex` selection semantics (TDD, browsing/append edge cases)

**Files:**
- Modify: `Sources/Maxi80/RadioPlayerViewModel.swift` (only if a test exposes a gap)
- Test: `Tests/Maxi80Tests/CarouselBridgeTests.swift` (extend)

**Interfaces:**
- Consumes: `handleCenteredIndex(_:)`, `syncCarouselBridgeInputs()`, `carouselTargetIndex(...)` from Task 1; `isBrowsingHistory`, `selectedCoverID`.
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
- Consumes: `CarouselBridgeState` (Task 1). Uses the bridge shape proven in Task 0 (object bridge, or the primitives fallback if Task 0 required it).
- Produces:
  - `AndroidCoverFlow: View` (`#if os(Android)`) — `init(state: CarouselBridgeState)`.
  - `CoverFlowComposer: ContentComposer` (`#if os(Android)` + `#if SKIP`) — renders the `LazyRow`.

- [ ] **Step 1: Create the Android wrapper view (born-at-index LazyRow, object-bridge shape)**

Create `Sources/Maxi80/AndroidCoverFlow.swift`. (If Task 0 required the fallback, pass `coverIDs`/`targetIndex`/`pinNonce` as primitive ctor params instead of `state`, and add a bridged `Int` out-holder per the spike notes.)

```swift
import SwiftUI
import SkipFuse

#if SKIP
  import androidx.compose.foundation.layout.fillMaxWidth
  import androidx.compose.foundation.layout.height
  import androidx.compose.foundation.lazy.LazyRow
  import androidx.compose.foundation.lazy.rememberLazyListState
  import androidx.compose.runtime.snapshotFlow
  import androidx.compose.ui.unit.dp
#endif

/// Android-only native Cover Flow carousel. Renders a Compose `LazyRow` whose scroll state is born
/// at `state.targetIndex` (via a saveable list state), so a view-tree recreation (resume, rotation,
/// low-memory) lands on the correct cover instead of resetting to the leftmost one — the root fix
/// for the recurring carousel/title desync. iOS keeps the SwiftUI `CoverFlowView`.
#if os(Android)
  struct AndroidCoverFlow: View {
    let state: CarouselBridgeState

    var body: some View {
      ComposeView {
        CoverFlowComposer(state: state)
      }
    }
  }

  #if SKIP
    /// Transpiled Compose body. Uses `rememberSaveable(LazyListState.Saver)` seeded with
    /// `initialFirstVisibleItemIndex` so the row is BORN centered on the target; reports the settled
    /// centered index back through the shared state. 3D tilt applied via `graphicsLayer`.
    struct CoverFlowComposer: ContentComposer {
      let state: CarouselBridgeState

      @Composable func Compose(context: ComposeContext) {
        let listState = androidx.compose.foundation.lazy.rememberSaveable(
          saver: androidx.compose.foundation.lazy.LazyListState.Saver
        ) {
          androidx.compose.foundation.lazy.LazyListState(
            firstVisibleItemIndex: state.targetIndex)
        }

        // Report the settled centered item back to Swift (no transient writes).
        androidx.compose.runtime.LaunchedEffect(listState) {
          snapshotFlow {
            Pair(listState.isScrollInProgress, listState.firstVisibleItemIndex)
          }.collect { pair in
            if pair.first == false { state.centeredIndex = pair.second }
          }
        }

        // "Back to live" / re-pin: animate to the target when pinNonce changes.
        androidx.compose.runtime.LaunchedEffect(state.pinNonce) {
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

Fill the `LazyRow` content, iterating indices of `state.coverIDs` (URL is `state.coverURLs[i]`, empty == placeholder). Compute each item's distance from viewport center from `listState.layoutInfo` and apply `graphicsLayer { rotationY, scaleX, scaleY }`, z-index, shadow, matching iOS constants (`coverSize=260`, `spacing=-40`, `maxRotation=55`, `minScale=0.72`). Use `coil3.compose.SubcomposeAsyncImage(model: url, contentScale: ContentScale.Crop)` for a non-empty URL; draw the bundled generic placeholder asset for an empty URL.

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

## Task 4: Wire `AndroidCoverFlow` into `RadioPlayerView`; keep bridge inputs synced

**Files:**
- Modify: `Sources/Maxi80/RadioPlayerView.swift` (the `coverFlow()` builder + an `onChange` to sync bridge inputs)
- Modify: `Sources/Maxi80/RadioPlayerViewModel.swift` (bump `pinNonce` in `returnToLive()`; sync on relevant changes)

**Interfaces:**
- Consumes: `AndroidCoverFlow(state:)` (Task 3), `viewModel.carouselBridge`, `syncCarouselBridgeInputs()`, `handleCenteredIndex(_:)`, `returnToLive()`.
- Produces: the platform-selected carousel; the running data-flow loop.

- [ ] **Step 1: Select the carousel per-platform inside `coverFlow()` (inlined `#if os(Android)`)**

In `Sources/Maxi80/RadioPlayerView.swift`, replace the body of `coverFlow()` so the platform branch is inlined (never a separate var):

```swift
@ViewBuilder
private func coverFlow() -> some View {
  #if os(Android)
    AndroidCoverFlow(state: viewModel.carouselBridge)
      .frame(height: 340)
      .accessibilityLabel(
        Text("Song history. Swipe to browse previously played tracks.", bundle: .module))
      .task(id: viewModel.coverPinToken) { viewModel.syncCarouselBridgeInputs() }
      .onChange(of: viewModel.carouselBridge.centeredIndex) { _, newIndex in
        viewModel.handleCenteredIndex(newIndex)
      }
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
  syncCarouselBridgeInputs()
  carouselBridge.pinNonce += 1
}
```

- [ ] **Step 3: Sync bridge inputs when covers change on resume**

Ensure `SharedPlayer.handleForeground()` path refreshes inputs. In `RadioPlayerView.swift`, the existing `.onChange(of: scenePhase)` already calls `SharedPlayer.handleForeground()`; add a bridge resync right after it in the same modifier:

```swift
.onChange(of: scenePhase) { _, newPhase in
  if newPhase == .active {
    SharedPlayer.handleForeground()
    viewModel.syncCarouselBridgeInputs()
  }
}
```

(The Android activity `onResume` path also runs `handleForeground`; the `.task(id: coverPinToken)` from Step 1 re-syncs on the recreated view. Both cover the resume.)

- [ ] **Step 4: Build both halves**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer skip android build` then `cd Android-less repo root && DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer make build-android`
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
rememberSaveable(LazyListState.Saver), with CarouselBridgeState as the single
source of truth so the title is a pure function of the visible cover. iOS
SwiftUI carousel unchanged.

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
- Born-at-index principle → Task 0 (proof) + Task 3 (`rememberSaveable`/`initialFirstVisibleItemIndex`). ✓
- iOS unchanged → Task 4 keeps `CoverFlowView` in the `#else`. ✓
- Single source of truth (bridge state) → Task 1 (`CarouselBridgeState`), Task 4 (data-flow loop). ✓
- Title = pure function of visible cover → Task 1 `handleCenteredIndex` + Task 4 `onChange(centeredIndex)`. ✓
- Full 3D parity → Task 3 Step 2. ✓
- Back to live → Task 3 (`LaunchedEffect(pinNonce)`) + Task 4 Step 2. ✓
- Edge cases (empty/single/append) → Task 1 + Task 2 tests. ✓
- Bridge-risk spike gate → Task 0 with fallback recorded. ✓
- On-device matrix + both-halves verification → Task 5. ✓
- Rotation unlock deferred → not in plan (correct; spec marks it future). ✓

**2. Placeholder scan:** No "TBD/TODO/handle edge cases" left as work items. Task 3 Step 2 names the exact constants and APIs; the id→URL representation decision is stated with a concrete default (parallel `coverURLs: [String]`, empty == placeholder).

**3. Type consistency:** `CarouselBridgeState` fields (`coverIDs`, `targetIndex`, `pinNonce`, `centeredIndex`) used identically in Tasks 1, 3, 4. `carouselTargetIndex(covers:selectedCoverID:)`, `syncCarouselBridgeInputs()`, `handleCenteredIndex(_:)` names consistent across tasks. `AndroidCoverFlow(state:)` init matches Task 4 call site.
