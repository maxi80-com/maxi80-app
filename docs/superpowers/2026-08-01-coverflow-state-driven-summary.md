# Cover Flow carousel: the state-driven rewrite (project history)

**Date:** 2026-08-01 · **Branch:** `new-caroussel-fable` · **Commits:** `3807d19`…`bf3ce26`
**Design spec:** `docs/superpowers/specs/2026-08-01-state-driven-coverflow-design.md`
**Prior art:** the dead `redesign-coverflow-carousel` branch (bugs P0–P4) and its requirements
list R1–R11, summarized inline below and in the design spec — those working notes were never
committed to this repo.

## Why the previous implementations kept failing

Every prior Apple renderer — the original pixel-calibration one and the two ScrollView rewrites —
shared one architecture: **SwiftUI's `ScrollView` owned the carousel's position** as a pixel
content offset, and the app tried to keep that offset reconciled with the model's selected cover.

That architecture has two framework behaviors working against it, permanently:

1. `ScrollView` **preserves its content offset** across content insertions and container resizes.
   History loads and new songs *prepend covers to the left*, so the preserved offset now points at
   the wrong cover — the strip drifts.
2. `.scrollPosition(id:)` **re-scrolls only when the bound id changes.** The pinned id is usually
   unchanged when the layout shifts (same selected cover, new content around it), so the framework
   never re-centers on its own.

Everything that grew around the old renderers — the recreation guard tower with backstop timers,
the `pinToken` re-pin tasks, the per-width anchor calibration, the settle debouncing — was
compensation for those two behaviors. Each fix patched one symptom and created another (post-swipe
recoil, animated correction scrolls, initial load centered on the oldest cover).

## The inversion that fixed it

**Don't reconcile the position with the state — make the position a pure function of the state.**
There is no ScrollView on Apple anymore, so there is no content offset to preserve and nothing to
re-center. Every cover is explicitly placed:

```
anchorIndex = index of selectedID in covers          (identity, never pixels)
relative(i) = (i − anchorIndex) + dragTranslation/slotWidth
xOffset(i)  = relative(i) × slotWidth                 (0 = dead center, by construction)
scale/tilt  = f(clamp(relative(i), −1…1))             (the 3D fan)
```

Why the edge cases became free:

- **Insertion left of the selection** (history load, new song): `i` and `anchorIndex` shift by the
  same amount → `relative` is unchanged → the selected cover does not move. R1, R5, R6, R10.
- **Rotation / resize**: the math just re-evaluates at the new width. Even a full view teardown is
  harmless — a fresh view reads `selectedID` and renders it centered on frame one. R7–R9, R11.
- **No recoil** (R2): drag release computes the snap target from the predicted end translation,
  then a *single* `withAnimation(.spring)` transaction zeroes the drag and reports the settle —
  one spring from wherever the finger left the strip.
- **No false settles** (R3): `onSettled` is called from exactly two places, the drag-release
  handler and tap-to-focus. There is no scroll-phase heuristic because there is no scroll.

## The pieces

| Piece | Role |
|-------|------|
| `CoverFlow/CarouselModel.swift` | Canonical selection (`selectedID`, `coverIDs`). Renderers *follow* it and report settled user gestures via `userSettledOn`, which ignores unknown ids. Will be shared by the future Android Compose renderer. |
| `CoverFlow/CarouselGeometry.swift` | All the math above as a pure `Sendable` struct — slot positions, snap target, rubber-band, visible window, fan curve. Unit-tested, including the left-insertion drift-immunity invariant. |
| `CoverFlow/AppleCoverFlow.swift` | The renderer: `ZStack` + `ForEach` over only the visible window (~9 cells regardless of history size), `DragGesture`, tap-to-focus, unmodified-arrow-key navigation. Entirely `#if !os(Android)`. |
| `CoverFlow/CoverFlowCarousel.swift` | Dispatcher: Android → legacy `CoverFlowView` (byte-identical call), Apple → `AppleCoverFlow`. |
| `CoverFlow/Cover.swift`, `CoverImage.swift` | Extracted value type + artwork view (crossfade intact — safe now, nothing binds scroll position to inner ids). |
| `RadioPlayerViewModel` | `selectedCoverID` is a computed proxy over `CarouselModel`; `covers` stays computed and syncs ids into the model. The guard tower (`beginReorientation`, `beginForegroundTransition`, `setSelectionFromCarousel`, `coverPinToken`, nonce) is retained but marked **ANDROID LEGACY ONLY** — delete it when the native Compose renderer lands. |

Deployment floor stayed **iOS 17 / macOS 14** (the iOS 18 bump on the dead branch existed only for
`onScrollPhaseChange`, which this design doesn't need).

## Post-test fixes (device + simulator pass, 2026-08-01)

- **`.clipped()` on the strip** — with no ScrollView viewport, side covers painted over the
  landscape info/controls column. The old ScrollView clipped for free; this is its replacement.
- **Arrow keys require no modifiers** — the simulator's rotate shortcut (Cmd+←/→) is *also*
  delivered to the app as an arrow key press, so rotation moved the selection one slot: the
  "simulator-only rotation drift" was never drift at all. Devices have no keyboard, hence clean.
- **Zero `dragTranslation` on width change** — a rotation mid-drag can cancel the gesture without
  `onEnded`, which would strand a permanent off-center offset.

## Postscript: Android reuse (same day)

The planned separate Compose renderer turned out to be unnecessary. An audit of SkipSwiftUI's
native Fuse API showed every primitive the renderer needs exists there (`rotation3DEffect` maps
to a Compose `graphicsLayer`; `DragGesture` carries `predictedEndTranslation`), so
`AppleCoverFlow` was renamed **`CoverFlowStrip`** and now renders on ALL platforms, with four
small `#if os(Android)` gates for APIs SkipSwiftUI marks unavailable (`withTransaction`,
`contentShape`, `focusable`/`onKeyPress`, `accessibilityElement`). Android field test passed the
full scenario table, including the historically 100%-repro resume-strand cases and rotation —
which is now UNLOCKED in the manifest (the `nosensor` lock existed only for the old renderer).

Consequently the legacy `CoverFlowView` and the entire view-model guard tower
(`beginReorientation`, `beginForegroundTransition`, `setSelectionFromCarousel`,
`isCarouselRecreating`, recreation window + backstop timer) are **deleted**. `coverPinToken` +
`returnToLiveNonce` remain solely for the tvOS `TVHistoryRow`. Android TV and CarPlay/Android
Auto are untouched (separate views / MediaSession surfaces; TV keeps its token-keyed row).

## Verification status

- `swift build` zero warnings; `skip android build` (Xcode 26.6) green; full test suite green
  except the 2 pre-existing environmental `ImageColorSampler` failures and the environmentally
  broken `XCSkipTests` Gradle harness.
- Manual pass on iPhone 17e (device + simulator): R1–R10 all pass.
- Known follow-ups: compact-landscape hero slightly too large on device (neighbor covers don't
  peek — needs a width-derived `coverSize` in `RadioPlayerView.landscapeView` like the expanded
  layout already does); R11 (iPad split-view / macOS resize) still to be tested.

## Trade-offs accepted

- We own the swipe physics (spring, predicted-end snap, rubber-band) instead of UIScrollView's
  native deceleration; a flick moves to the snapped target rather than momentum-scrolling through
  many covers. Constants live in `CarouselGeometry` / `AppleCoverFlow.settleSpring`.
- macOS: click-drag, tap-to-focus, and arrow keys replace two-finger trackpad scrolling.
- Android untouched by design — its real fix is the separate native Compose renderer, which will
  reuse `CarouselModel` and retire the guard tower for good.
