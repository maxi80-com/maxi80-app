# Cover Flow inertial "wheel" coast — design (as built)

**Date:** 2026-08-03 (original design) · 2026-08-04 (updated to as-built after on-device iteration)
**Status:** Implemented on `feat/coverflow-inertial-coast`; verified on iPhone 15 Pro + Samsung A07

## Problem

The 5.x Cover Flow redesign replaced the old `ScrollView`-based carousel with a
stateless-math renderer (`CoverFlowStrip` + `CarouselGeometry`, selection owned by
`CarouselModel`). Users reported the browsing feel regressed:

- **Android phone:** one swipe moves exactly one position; no momentum, no "wheel with
  inertia" flywheel sensation the old ScrollView had.
- **iOS:** less severe but present — a small swipe moves one slot, a large swipe two.

### Root cause

`snapTarget` landed on the rounded effective anchor at the platform's **predicted** end
translation. On Android, Skip/Compose's `predictedEndTranslation` ≈ the raw translation
(no velocity), so no momentum signal ever reached the math; on iOS Apple projects only a
modest, capped velocity. Either way the settle was a short fixed spring — no
velocity-scaled coasting.

## Goal

Reproduce the old flywheel feel — a flick coasts across covers and decelerates to rest —
while preserving the invariant that a cover always lands **pinned at center**. Identical
behavior on iOS and Android, independent of `predictedEndTranslation`.

## As-built design

The stateless renderer, snap-to-slot guarantee, and the "renderer follows `selectedID`,
reports settled gestures via one `onSettled`" contract are all preserved. What was added,
by subsystem:

### 1. Inertia (`CarouselGeometry.settleTarget` — pure, unit-tested)

One entry point composes three feel rules on release, from the finger `translation` and a
**self-computed** release `velocity`:

1. **Deliberate drag** (speed < `flickVelocityThreshold` = 220 pt/s): lands purely by
   translation — precise one-cover-at-a-time control, immune to noisy low-speed velocity
   estimates from the A07's sparse `onChanged` delivery.
2. **Flick floor** (speed ≥ threshold): a flick ALWAYS advances at least one slot in its
   direction, even if the projection would round back — kills the "glued" brief-flick feel.
3. **Momentum:** `projectedTranslation = translation + velocity × decelerationRate`
   (`decelerationRate` = 0.13) carries a hard flick several covers; the existing
   `snapTarget` rounding/clamping keeps the landing pinned.

Velocity capture: a fixed-capacity ring of `(translation, Date)` samples appended per
`onChanged`; release velocity = Δtranslation/Δt over the trailing ~100 ms. The ring is a
**non-observable reference box** — appending must not invalidate the view or cross the
bridge per drag frame (measured overhead + GC pressure when it was `@State`-observable).

### 2. Drag start (Android `minimumDistance: 0`)

`DragGesture(minimumDistance: 10)` makes SkipUI take Compose's
`awaitPointerSlopOrCancellation` branch: `onChanged` stays silent until the system
touch-slop (~8–16 dp), felt as a dead zone at the start of every swipe ("glued at
start"). `0` takes the track-from-touch-down branch → immediate 1:1 response. Apple
platforms keep `10` (preserves tap-to-focus pass-through; no slop problem there).
Accepted trade-off: tap-to-focus on side covers may not work on Android (browse by swipe).

### 3. Settle animation — ONE spring, one driver

- A single `settleSpring` shared by every settle path (drag release, tap, arrow key,
  external cover-set change). A cover's offset is driven by BOTH `dragTranslation` and
  `anchorIndex`; two curves — or two spring instances — fight mid-settle (measured as
  "shaggy" glide / mid-move stall on Compose). A flick coasts far because the *target* is
  farther, not because the curve differs.
- Android runs the spring near-critically damped (`dampingFraction` 0.99 vs 0.85 on
  Apple): at the A07's settle framerate the 0.85 overshoot collapses into 2–3 frames and
  reads as a sloppy landing bump.

### 4. Alive-window invariance (`visibleIndexRange` centered on the ROUNDED anchor)

The instantiated-cell window is centered on the nearest slot to the effective anchor
(= `snapTarget`'s rounding, clamped), not the fractional anchor. This makes the alive set
**identical before and after a release** — previously the window shifted one slot at the
settle instant, instantiating a fresh off-screen cell (AsyncImage + shadow + re-diff) that
froze the A07's UI thread ~160 ms mid-glide. Pinned by a dedicated unit test
(`window(during drag) == window(after landing)` for all anchor × drag-fraction combos).

### 5. Render cost (Android shadow)

The 18 px shadow blur re-renders every animation frame for ~9 covers; on the A07's Mali
GPU that measured ~115 ms/frame (~9 fps) during any strip motion. Android draws a tight
radius-6 shadow; Apple keeps the deep radius-18 look.

### 6. Deferred display sync (`CarouselModel.displaySelectedID`, Android-only lag)

Flipping the selection recomposes most of the screen (labels, background, back-to-live
button); doing that at the release instant landed a 200 ms+ recomposition mid-glide (the
measured "mid-animation freeze" remnant). Display surfaces follow a second id that lags
~450 ms on Android (Apple: synchronous), letting the cover glide and pin first. Rapid
settles coalesce; back-to-live and sync-fallback snap immediately.

### 7. Background wash crossfade (per-platform)

- **Apple:** the original native implicit `.animation(_, value:)` over the
  wash/brand branch — interpolates gradient colors smoothly, never flashed.
- **Android:** SkipUI renders that modifier as a single-frame swap, and every naive
  crossfade flashed intermittently. As-built: **two persistent ping-pong layers** under
  these flash-proofing rules (distilled from repeated pixel-level measurement):
  1. A layer's COLOR may only be written while its rendered opacity is exactly 0
     (Compose can render new content a frame before the opacity meant to hide it).
  2. Visible opacities are only ever ANIMATED, never jumped — via per-layer implicit
     `.animation(_, value: fade)` tweens (wall-clock `withAnimation` started inside the
     recomposition storm loses most of its duration before the first rendered frame).
  3. A settle window guards rewriting a layer still fading out (its rendered opacity is
     nonzero even when its state target is 0).
  Result: direct old→new dissolve (0.5 s easeInOut), no dip through the brand base,
  verified monotonic (no flash frames) by frame-by-frame pixel measurement.
- The driver lives on the MAIN view tree — on SkipUI/Android, lifecycle modifiers
  attached to `.background {}` content never fire.

### 8. Contrast (text, tray, play glyph) — Android

`isBackgroundDark` (Rec. 601 luminance of the displayed dominant color) decides
light-vs-dark foregrounds; the forced `colorScheme` environment doesn't recolor anything
on Android and the device scheme is irrelevant to what's behind the text.

- **Song label:** instant color, no fade — the string and color flip in the same update,
  and the label is `.id(isBackgroundDark)`-keyed on Android so a contrast flip
  structurally REPLACES the label (string + color born in one frame; in-place updates to
  a visible Text tear on the bridge — string can render a frame before its color).
  `REVERT-OPTION(text-contrast-fade)` in `RadioPlayerView.songLabel` documents the
  two-layer fade alternative if this ever proves insufficient.
- **Utility tray + play button center:** two fixed-tint layers cross-faded by
  `textDarkFade` (colors never animated, never changed while visible), tweened by an
  explicit `.animation(_, value:)` on the controls' root — the parent's `withAnimation`
  transaction does not propagate across the bridged view boundary, which had the icons
  snapping while the wash tweened. Curve/duration match the wash so everything dissolves
  as one. The play glyph's contrast disc sits behind the Material icon's knocked-out
  center (half the hero size — no ring outside the orange disc); the sleep timer's
  active orange bypasses the crossfade.

## What did NOT change

`CarouselModel`'s settle contract, `relativePosition` / `xOffset` / `scale` /
`rotationDegrees` / `zIndex` / `rubberBanded`, virtualization-by-math, and the iOS text
styling (semantic `.primary`/`.secondary`).

## Testing

- `CarouselGeometryTests` (24 tests): projection monotonicity + dead-zone; zero-velocity
  regression guard; clamping at both ends; flick floor (un-glue, no-floor-on-drag,
  floor-is-a-minimum); alive-window release invariance; the pre-existing fan/rubber-band
  suites.
- Full suite: 155 tests, 27 suites, green.
- On-device verification (Samsung A07): frame-gap analysis via `screenrecord` +
  `gfxinfo framestats` for the freezes; pixel-sampling of recorded swipes for the wash
  (monotonic fade curves, no flash frames, no brand dip).

## Known limitations / follow-ups

- Sub-cover-flow render rate on the A07 is bounded by the device GPU; residual ~100 ms
  hitches can still appear under memory pressure.
- Tap-to-focus on side covers is unavailable on Android (`minimumDistance: 0` trade).
- **Separate issue to file:** iOS and Android disagree on the LIVE song's dominant color
  (local artwork sampling vs backend/fallback), e.g. "La vie est cadeau" — dark on
  Android, light on iOS. Consider preferring the backend palette on both platforms.
