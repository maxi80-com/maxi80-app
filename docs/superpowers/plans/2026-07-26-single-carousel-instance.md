# Single Carousel Instance Across Orientations — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution environment:** the user asked for a separate git worktree — create it with superpowers:using-git-worktrees before Task 1 (branch name suggestion: `single-carousel-instance`).

**Goal:** Make `RadioPlayerView` host ONE `CoverFlowView` instance in both portrait and landscape so the carousel survives rotation on Apple platforms, then delete the rotation-specific guard machinery that only existed because rotation destroyed and recreated it.

**Architecture:** Replace the `if isPortrait { portraitView() } else { landscapeView() }` branch (which puts the carousel in two different structural slots, forcing SwiftUI to tear it down on every rotation) with a single `AnyLayout(VStackLayout/HStackLayout)` container on Apple platforms. `AnyLayout` swaps the layout algorithm without changing view identity, so the carousel's `@State`, scroll offset, and `AsyncImage` loads survive rotation. Android keeps the existing branches (`AnyLayout` is absent from SkipSwiftUI, and Android is portrait-locked via `nosensor` so it never rotates at runtime). The rotation guard (`beginReorientation` + `.onChange(of: isPortrait)`) becomes dead and is removed; the foreground-resume guard stays (Android activity recreation is a real, separate recreation path).

**Tech Stack:** Swift 6 / SwiftUI (`AnyLayout`, iOS 16+ — project floor is iOS 17), Skip Fuse (native mode for the `Maxi80` module), Swift Testing.

## Global Constraints

- Platform conditionals for Android behavior in this Fuse module MUST use `#if os(Android)`, never `#if !SKIP` (`SKIP` is not defined in the native Android compile — proven at the binary level, see memory `coverflow-rotation-pin-findings`).
- Keep `#if os(Android)` branches INLINE in `body` (a `@ViewBuilder` computed var wrapping the whole platform split has rendered empty on Android before). Calling existing `private func portraitView()`-style helpers from inside an inline `#if` branch is the current, working pattern.
- Both build legs must stay green: `swift build` (macOS) AND `skip android build` + `cd Android && gradle :app:compileDebugKotlin`. If gradle's Swift pre-build fails with "linked as a static library", prefix with `DEVELOPER_DIR=/Applications/Xcode-26.6.app` (Xcode 27 beta issue).
- `swift test` may fail in the Android/Robolectric Gradle harness with package-identity conflicts — that failure is pre-existing and environmental (memory `skip-android-test-harness-broken`). Judge test health by the macOS/Swift Testing results.
- Do NOT touch: `CoverFlowView`'s geometry/tilt code, the `CenteredCoverKey` preference machinery, `defaultScrollAnchor` (prevents the history-load flash — independent of rotation), the `repinToken` width-fold (still wanted: a surviving view still resizes on rotation and must re-center), the non-animated `scrollTo` jump, or `beginForegroundTransition`/`setSelectionFromCarousel`/`isCarouselRecreating` (foreground-resume path needs them).
- `Skip.env` has an unrelated local modification — leave it out of all commits.

## File Structure

- `Sources/Maxi80/RadioPlayerView.swift` — the only production file that changes. Gains an Apple-only `adaptiveView()`; `portraitView()`/`landscapeView()` become Android-only; loses `.onChange(of: isPortrait)`.
- `Sources/Maxi80/RadioPlayerViewModel.swift` — loses `beginReorientation()` only.
- No new files. No test-file changes required (no test references `beginReorientation`; `ResumeReconciliationTests` covers the guard that stays).

---

### Task 1: Unified adaptive layout on Apple platforms

Keep the rotation guard in place for this task (belt and suspenders); it is removed separately in Task 2 so regressions are attributable.

**Files:**
- Modify: `Sources/Maxi80/RadioPlayerView.swift:23-52` (body), `:107-146` (portrait/landscape funcs)

**Interfaces:**
- Consumes: existing `coverFlow()`, `songLabel()`, `liveIndicator()`, `volumeControl()`, `PlaybackControlsView`, `isPortrait`.
- Produces: `private func adaptiveView() -> some View` (Apple-only), used by `body`. Task 2 relies on `body` no longer branching the carousel per orientation on Apple.

- [ ] **Step 1: Replace the body branch**

In `body`, replace:

```swift
      Group {
        if isPortrait {
          portraitView()
        } else {
          landscapeView()
        }
      }
```

with:

```swift
      Group {
        #if os(Android)
          // Android never rotates at runtime (the phone activity is portrait-locked via
          // `nosensor`; TV/Auto render separate views), so hosting the carousel in a
          // branch-per-orientation layout is safe there — and SkipSwiftUI has no AnyLayout.
          if isPortrait {
            portraitView()
          } else {
            landscapeView()
          }
        #else
          adaptiveView()
        #endif
      }
```

- [ ] **Step 2: Add `adaptiveView()` and gate the old layouts to Android**

Replace the `// MARK: - Portrait Layout` and `// MARK: - Landscape Layout` sections (both funcs) with:

```swift
  // MARK: - Adaptive Layout (Apple)

  #if !os(Android)
    /// One layout tree for both orientations. `AnyLayout` swaps the stack axis WITHOUT changing
    /// structural identity, so the Cover Flow carousel is the same view instance before and
    /// after a rotation — its scroll position, image loads, and internal state all survive.
    /// (The previous `if isPortrait` branches hosted the carousel in two different slots,
    /// which tore it down and recreated it on every rotation.)
    @ViewBuilder
    private func adaptiveView() -> some View {
      let layout =
        isPortrait
        ? AnyLayout(VStackLayout(spacing: 24))
        : AnyLayout(HStackLayout(spacing: 24))

      layout {
        coverFlow()
          // Portrait: breathing room below the dynamic island (was Spacer(minHeight: 40)).
          .padding(.top, isPortrait ? 40 : 0)

        VStack(spacing: isPortrait ? 24 : 16) {
          if !isPortrait { Spacer() }
          songLabel()
          liveIndicator()
          Spacer()
          PlaybackControlsView(viewModel: viewModel)
          volumeControl()
          if isPortrait {
            Spacer().frame(minHeight: 20)
          } else {
            Spacer()
          }
        }
      }
      .padding(isPortrait ? 0 : 16)
    }
  #endif

  // MARK: - Portrait / Landscape Layouts (Android — never rotates, so the
  // branch-per-orientation identity change is harmless there)

  #if os(Android)
    private func portraitView() -> some View {
      VStack(spacing: 24) {
        Spacer().frame(minHeight: 40)  // avoid the dynamic island

        coverFlow()

        songLabel()

        liveIndicator()

        Spacer()

        PlaybackControlsView(viewModel: viewModel)

        volumeControl()

        Spacer().frame(minHeight: 20)
      }
    }

    private func landscapeView() -> some View {
      HStack(spacing: 24) {
        coverFlow()

        VStack(spacing: 16) {
          Spacer()
          songLabel()
          liveIndicator()
          Spacer()
          PlaybackControlsView(viewModel: viewModel)
          volumeControl()
          Spacer()
        }
      }
      .padding()
    }
  #endif
```

Note: the funcs' bodies are byte-identical to today's — only the `#if os(Android)` gate is new.

- [ ] **Step 3: Build both legs**

Run: `swift build` — expected: succeeds.
Run: `skip android build` — expected: succeeds (if the Swift pre-build complains about static libraries, retry with `DEVELOPER_DIR=/Applications/Xcode-26.6.app skip android build`).
Run: `cd Android && gradle :app:compileDebugKotlin` — expected: succeeds.

- [ ] **Step 4: Run the test suite**

Run: `swift test`
Expected: all Swift Testing suites pass. If ONLY the Gradle/Robolectric harness fails with package-identity conflicts, that's the known pre-existing environmental failure — proceed.

- [ ] **Step 5: Visual parity check (previews)**

Open the three `#Preview`s in `RadioPlayerView.swift` (or `mcp__xcode__RenderPreview`) and compare portrait rendering against `main`: cover size/position, title spacing, controls, footer. Minor spacing drift (±a few points from Spacer→padding conversion) is acceptable; anything structural is not.

- [ ] **Step 6: Commit**

```bash
git add Sources/Maxi80/RadioPlayerView.swift
git commit -m "refactor: host one CoverFlowView across orientations via AnyLayout (Apple)

The portrait/landscape branches gave the carousel two structural
identities, so every rotation destroyed and recreated it. AnyLayout
swaps the stack axis while preserving identity, so the carousel's
scroll state survives rotation. Android keeps the branches: SkipSwiftUI
has no AnyLayout and the activity is portrait-locked (never rotates).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Remove the now-dead rotation guard

Only after Task 1 is verified. The recreation window itself (`isCarouselRecreating`, `beginCarouselRecreationWindow`, `setSelectionFromCarousel`, `beginForegroundTransition`) STAYS — the Android background→foreground resume recreates the whole view tree and still needs it (`SharedPlayer.handleForeground()` → `beginForegroundTransition()`, covered by `ResumeReconciliationTests`).

**Files:**
- Modify: `Sources/Maxi80/RadioPlayerView.swift:36-38` (the `.onChange(of: isPortrait)`)
- Modify: `Sources/Maxi80/RadioPlayerViewModel.swift:201-205` (`beginReorientation()`)

**Interfaces:**
- Consumes: Task 1's `adaptiveView()` (the reason the guard is dead on Apple).
- Produces: nothing new — pure deletion. No other code or test references `beginReorientation` (verified by grep).

- [ ] **Step 1: Delete the rotation trigger from the view**

In `RadioPlayerView.body`, delete these three lines:

```swift
      // A rotation recreates the CoverFlowView; open a short window where its selection write-back
      // is dropped so the browsed cover survives the recreation.
      .onChange(of: isPortrait) { _, _ in viewModel.beginReorientation() }
```

- [ ] **Step 2: Delete `beginReorientation()` from the view model**

In `RadioPlayerViewModel.swift`, delete:

```swift
  /// Begin the recreation lock for an orientation change, auto-clearing once the recreated
  /// carousel has settled.
  func beginReorientation() {
    beginCarouselRecreationWindow()
  }
```

Also update the doc comment above `isCarouselRecreating` (lines ~187–195): remove the "orientation change" bullet so it documents only the background→foreground recreation path. Example replacement for the two-bullet list:

```swift
  /// The carousel is recreated on a background→foreground resume (the Android activity is
  /// destroyed and recreated, rebuilding the whole view tree). This lock lives in the view
  /// model — which survives the recreation, being a process-wide singleton — so the carousel's
  /// transient selection write-back can be dropped while set, preserving the browsed/live cover.
```

- [ ] **Step 3: Build both legs + tests**

Run: `swift build && swift test` — expected: build succeeds; `ResumeReconciliationTests` (which exercise `beginForegroundTransition`) still pass.
Run: `skip android build` and `cd Android && gradle :app:compileDebugKotlin` — expected: succeed.

- [ ] **Step 4: Commit**

```bash
git add Sources/Maxi80/RadioPlayerView.swift Sources/Maxi80/RadioPlayerViewModel.swift
git commit -m "refactor: drop rotation guard obsoleted by identity-stable carousel

The carousel now survives rotation (AnyLayout), so the reorientation
write-drop window is dead on Apple and Android never rotates. The
foreground-resume guard stays: Android activity recreation is a real,
separate recreation path (ResumeReconciliationTests).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: On-simulator rotation verification (user checkpoint)

Layout identity can only be proven by rotating a running app. Past sessions proved `@State`-level assumptions wrong on device twice — do not skip this.

**Files:** none (verification only).

- [ ] **Step 1: Build and install on an iPhone simulator**

```bash
xcodebuild -scheme Maxi80 -destination 'platform=iOS Simulator,name=iPhone 16' SKIP_ACTION=none build
xcrun simctl install booted <path-to-built-.app>
xcrun simctl launch booted com.stormacq.mobile.maxi80
```

(`SKIP_ACTION=none` skips the broken Android test leg; the bundle id is in `Skip.env` — verify before launching.)

- [ ] **Step 2: Exercise the four rotation scenarios**

Rotate via Simulator menu (⌘← / ⌘→) or ask the user. Verify:

1. **Pinned live + rotate** (P→L and L→P): carousel stays centered on the now cover; no flash of the oldest cover; no "Back to live" pill.
2. **Browsing history + rotate** (swipe back ~5 covers first): the SAME browsed cover stays centered after rotation; title/artist unchanged; "Back to live" still shown.
3. **Rapid repeated rotations** while browsing: selection must not latch onto a random history cover (this was a residual flake under the old recreate-and-guard design — expected to be structurally fixed now, confirm).
4. **Back to live after rotation**: tap the pill; carousel jumps (not sweeps) to the now cover.

- [ ] **Step 3: Ask the user to confirm on their device/simulator**

This is a hard checkpoint: the user verifies before anything merges. Also ask them to sanity-check macOS window resize (narrow↔wide) since macOS always uses the landscape branch and should be unaffected.

- [ ] **Step 4: Optional cleanup commit (only if verification passed)**

If scenario 2/3 show the carousel surviving rotation without the re-pin ever firing, the stale comment in `CoverFlowView.swift:88-92` ("a rotation recreates this view…") can be updated to describe resize-only re-pinning. Comment-only change:

```bash
git add Sources/Maxi80/CoverFlowView.swift
git commit -m "docs: update CoverFlowView re-pin comment — rotation no longer recreates the view

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** single-instance carousel (Task 1), guard removal (Task 2), rotation-preserving verification (Task 3). ✓
- **Placeholder scan:** all code steps contain full code; no TBDs. ✓
- **Type consistency:** `adaptiveView()` name used consistently; `beginReorientation` deleted everywhere it exists (view + VM; grep confirmed no other references). ✓
- **Known risk, called out:** `AnyLayout` preserves identity only if the carousel occupies the same structural slot in both configurations — that's why `coverFlow()` is the unconditional first child of the `layout` block and orientation differences are expressed via modifiers/inner-column conditionals only. Do not "clean up" by moving `coverFlow()` inside a conditional.
