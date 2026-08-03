# Cover Flow inertial "wheel" coast — design

**Date:** 2026-08-03
**Status:** Approved, ready for implementation

## Problem

The 5.x Cover Flow redesign replaced the old `ScrollView`-based carousel with a
stateless-math renderer (`CoverFlowStrip` + `CarouselGeometry`, selection owned by
`CarouselModel`). Users report the browsing feel regressed:

- **Android phone + Android Auto:** one swipe moves exactly one position. No momentum,
  no "wheel with inertia" flywheel sensation the old ScrollView had.
- **iOS:** less severe but still wrong — a small swipe moves one slot, a large swipe two.

### Root cause

On release, `CarouselGeometry.snapTarget` lands on the rounded *effective anchor* at
SwiftUI's **predicted** end translation:

```
effectiveAnchor = anchorIndex − predictedEndTranslation / slotWidth
target          = round(effectiveAnchor)          // clamped to valid indices
```

- On **Android**, Skip/Compose's `DragGesture.predictedEndTranslation` ≈ the raw
  `translation` (no velocity projection), so a ~1-slot swipe rounds to 1 slot. No
  momentum signal ever reaches the math.
- On **iOS**, Apple projects a modest, capped velocity into `predictedEndTranslation`,
  hence the occasional 2-slot move.
- Either way the coast is a single fixed `settleSpring` (response 0.35) to a near
  neighbor — there is no velocity-scaled coasting through intermediate covers.

The old ScrollView had real inertia because UIScrollView / Compose scroll physics
project release velocity into a long decelerating fling.

## Goal

Reproduce the old flywheel feel — a flick coasts across many covers and decelerates to
rest — while preserving the invariant that a cover is always **pinned at center on
settle**. Identical behavior on iOS, Android, and Android Auto, independent of
`predictedEndTranslation`.

### Decisions locked during brainstorming

1. **Inertia reach:** unbounded, decelerating (like the old ScrollView). A hard flick
   can traverse many covers.
2. **Velocity source:** compute it ourselves from drag samples — do **not** rely on
   `predictedEndTranslation` (that is the Android defect). Cross-platform-identical.
3. **Coast animation:** a single velocity-parameterized decelerating (ease-out) curve
   whose duration scales with distance traversed — **not** a per-frame physics tick
   loop. Rationale below.
4. **Code placement:** projection + duration are pure functions on `CarouselGeometry`
   (like `snapTarget` / `rubberBanded`); the drag-sample ring buffer is `@State` in
   `CoverFlowStrip`. Maximizes unit coverage; matches existing separation.

### Why a decelerating curve, not a physics loop

The "wheel" sensation is three effects; only one would need a physics loop:

1. **Throw distance scales with velocity** — handled entirely by the projection math.
2. **Covers visibly sweep past center during the coast** — free from a single
   continuous offset animation over a multi-slot distance: every intermediate cover
   flips through center as the strip travels.
3. **Decelerating motion, longer for farther throws** — an ease-out curve whose
   *duration grows with distance* gives exactly this.

A frame-by-frame driver adds only marginal friction *feel* on top, while introducing a
timer/animation driver that must behave identically across SwiftUI and Compose-via-Skip.
Given this codebase's history with cross-bridge animation subtleties (the very reason
the renderer was rewritten to be stateless math), we avoid a per-frame driver. The
decelerating curve reuses the existing single-`withAnimation` settle path — the
architecture that made the drift/recoil bug class structurally impossible.

## Design

Inertia only changes *which slot* we land on and *how we travel there*. The stateless
renderer, snap-to-slot guarantee, and the "renderer follows `selectedID`, reports
settled gestures via one `onSettled`" contract all stay intact.

### Component 1 — Velocity capture (`CoverFlowStrip`, new `@State`)

A small fixed-size ring buffer of recent drag samples `(translationWidth, timestamp)`,
timestamped with `Date()` (available in app code on both platforms; unrelated to the
workflow-script `Date.now()` restriction).

- `dragGesture.onChanged` appends a sample.
- `dragGesture.onEnded` computes `v = Δtranslation / Δt` (points/sec) over the most
  recent ~100 ms window, falling back to `0` if too few samples or `Δt ≈ 0`.
- Buffer cleared on release.

This is the only new view state. `Date()` timestamps must be confirmed to tick
sub-frame on Skip/Android during implementation; the ~100 ms window + clamping mitigate
sparse `onChanged` delivery from Compose.

### Component 2 — Projection (`CarouselGeometry`, new pure func)

```
projectedTranslation(translation, velocity) = translation + velocity * decelerationRate
```

`decelerationRate` is a seconds-equivalent constant (~0.30–0.40 s to start) converting
velocity into coast distance via the standard exponential-deceleration approximation
UIScrollView / Compose use. The **existing** `snapTarget` then consumes this projected
value instead of `predictedEndTranslation`. Its rounding + clamping already guarantee a
pinned landing; the unbounded/decelerating reach falls straight out of a large
`velocity`.

### Component 3 — Coast animation (duration helper + release path)

A new pure helper on `CarouselGeometry` returns an ease-out `Animation` whose **duration
scales with slots traversed**, e.g. `base + perSlot * min(slots, cap)` clamped to a sane
max (~0.9 s), so a far throw coasts long and eases in while a near move stays snappy.

- Small drags / taps / arrow keys keep today's `settleSpring`.
- On a flick release: one `withAnimation(coastCurve) { dragTranslation = 0; onSettled(target) }`
  — the same single-animation settle path, no per-frame driver, no new bridge-sensitive
  code.

## What does NOT change

- `CarouselModel` (selection state), the callback/settle contract, `relativePosition`,
  `xOffset`, `scale`, `rotationDegrees`, `zIndex`, `rubberBanded`, `visibleIndexRange`
  (virtualization) — all untouched.
- The "renderer follows `selectedID`, reports settled gestures" architecture — untouched.
  A coast still ends in exactly one `onSettled`.

## Testing

Pure-function unit tests in `CarouselGeometryTests` (Swift Testing, `#expect`):

- Projection is monotonic in velocity.
- **Zero velocity ⇒ current behavior** (regression guard: matches `snapTarget` on raw
  translation).
- High velocity ⇒ far target, still clamped to valid indices.
- Duration is monotonic in distance and capped at the max.
- A hard flick from the last cover lands on a valid pinned slot (boundary + clamp).

Feel constants (`decelerationRate`, duration `base`/`perSlot`/`cap`/`max`) are named
tunables validated by these tests.

## Risks / open items

- **Clock:** confirm `Date()` timestamps tick sub-frame on Skip/Android. If not, find a
  monotonic clock Skip surfaces.
- **Sample rate:** sparse Compose `onChanged` delivery → noisy velocity; the ~100 ms
  window + clamping mitigate; tunable.
- **Constants are feel-driven:** `decelerationRate` and the duration curve need one
  on-device tuning pass (A07 phone + Android Auto DHU) after the math is in.
