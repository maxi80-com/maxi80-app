# Cover Flow carousel sync — native Compose carousel on Android

**Date:** 2026-07-28
**Status:** Design (approved, pre-implementation)
**Platform:** Android only (iOS unchanged)

## Problem

The Cover Flow carousel keeps its focus in **two** places that must always agree:

1. **`selectedCoverID`** — a value in `RadioPlayerViewModel`; drives the title, artist, and
   background wash.
2. **The scroll container's own visual offset** — owned by the SwiftUI `ScrollView` (iOS) or the
   transpiled Compose scroll container (Android); drives what the user actually sees.

On iOS these stay coupled: the `ScrollView` survives, and a programmatic `scrollTo` reliably lands.

On Android, **any view-tree recreation** (rotation, background→foreground resume, low-memory
activity recreation) makes the Compose scroll container **authoritatively reset its offset to the
leftmost/oldest cover** — and that reset is *late* relative to any re-pin we issue. A `scrollTo`
after relayout is a no-op. Result: the visual drifts to the oldest cover while `selectedCoverID`
(and the title) stay where they were → **desync**.

This has surfaced repeatedly:

- **Rotation** (issue #25/#26 era): shipped workaround was locking the phone to portrait
  (`android:screenOrientation="nosensor"`), because no `scrollTo`-based fix survived rotation.
- **Background→foreground resume** (issue #9): partially guarded with a selection write-drop window.
- **Notification-tap resume** (issue #44): the guard's blind 700 ms timer expired mid-relayout and
  a transient leftmost write-back landed → carousel stranded on the oldest cover.
- **#44 follow-on desync:** the settle-based guard (PR #46) protects `selectedCoverID` but does
  nothing about the *visual* offset. On activity recreation the re-pin still calls `scrollTo(live)`
  and the Compose reset still wins → carousel visually on oldest, title still live. Confirmed
  on-device via instrumentation: the return went through `onCreate` (activity recreated), the re-pin
  `.task` fired and called `scrollTo(__now__)`, yet the carousel sat on the oldest cover, with
  **zero** carousel selection write-backs (so the guard was not even involved).

## Root cause

Every fix so far has tried to **command** the scroll position after the container is laid out
(`scrollTo`, re-assert loops, nudge, `.id()` remount, selection-binding writes). On the transpiled
Compose path, all of them lose to Compose's authoritative reset-to-leftmost, which fires *after* the
command. The two sources of truth diverge and no post-layout command can reconcile them.

The one lever that has **worked on-device** (proven during the rotation investigation, 2026-07-16)
is initializing the Compose scroll state at the target index as part of the container's own creation:
`rememberSaveable(saver: LazyListState.Saver)` + `LazyListState(firstVisibleItemIndex: targetIndex)`.
The container is **born** at the right cover; there is no reset to lose to.

## Decision

**Core principle:** *a recreated carousel must be **born** at the correct cover, never commanded
there afterward — and the title must be a pure function of the visible cover, never a separately
stored value that can drift.*

Concretely:

- **iOS: unchanged.** The SwiftUI `CoverFlowView` works. Do not touch it. (This is why iOS "has no
  problem" and must stay that way.)
- **Android: a native Compose carousel** rendered via `ComposeView` (available in Skip Fuse mode),
  using a saveable `LazyListState` born at the target index, with full 3D Cover Flow parity.
- **One source of truth:** a small bridged **observable state holder** carries `covers` + the target
  index *into* Compose and receives the settled `centeredIndex` *out*. The view model derives the
  title/background from `centeredIndex`, so the visible cover and the title are, by construction,
  the same cover. **Desync becomes unrepresentable, not merely fixed.**

**Guarantee targeted:** after any recreation, restore the *exact* cover (live OR the browsed history
cover), with the title always matching the visible cover.

### Alternatives considered (rejected)

- **Keep a single shared SwiftUI `CoverFlowView`** and set an initial scroll position expressible in
  SwiftUI (`defaultScrollAnchor`, initial `scrollPosition`). Rejected: SkipUI does not reliably map
  "initial position" to Compose's `initialFirstVisibleItemIndex`; the transpiled path still emits a
  scrollTo-after-layout, which is what fails.
- **Prevent recreation instead** (launchMode/onNewIntent/configChanges so resume is `onRestart`, not
  `onCreate`). Rejected as the *primary* fix: it does not cover true low-memory activity death, so it
  cannot "solve once for all." (Still worth doing opportunistically, but not the guarantee.)
- **"Title follows whatever is visible; never command scroll"** (accept landing on oldest and just
  keep the title consistent). Rejected: violates the chosen guarantee (preserve exact position).

## Architecture

`RadioPlayerView.body` selects the platform carousel with an **inlined** `#if os(Android)` branch
(a Skip Fuse gotcha: splitting the branch into a separate computed `@ViewBuilder var` renders empty
on Android — the whole `#if os(Android) … #else … #endif` must sit directly in `body`).

```
RadioPlayerView.body
  #if os(Android)
    AndroidCoverFlow(state: viewModel.carouselBridge)   // new
  #else
    CoverFlowView(covers:selection:pinTarget:pinToken:)  // unchanged iOS impl
  #endif
```

Both platforms read/write the same view-model state; the title/background derive from the centered
cover on both (iOS already does this via its `CenteredCoverKey` preference).

## Components

### New (Android-only, `#if os(Android)`)

1. **`AndroidCoverFlow: View`** — a thin wrapper hosting
   `ComposeView { CoverFlowComposer(state:) }`. Referenced only from the inlined `#if os(Android)`
   branch in `RadioPlayerView.body`.

2. **`CoverFlowComposer: ContentComposer` (`#if SKIP`)** — the real Compose UI:
   - `rememberSaveable(saver: LazyListState.Saver) { LazyListState(firstVisibleItemIndex: state.targetIndex) }`
     — born at the right cover; survives recreation.
   - Full 3D Cover Flow parity per item via `graphicsLayer { rotationY, scaleX, scaleY }`, z-index,
     and shadow, driven by each item's distance from center (computed from `layoutInfo`), matching
     the iOS cover size (260) and spacing.
   - `coil3.compose.SubcomposeAsyncImage` for artwork; explicit row height
     (`fillMaxWidth().height((coverSize + 80).dp)`); a `SnapFlingBehavior` to center items.
   - A `snapshotFlow` observing the centered item that writes `centeredIndex` back into the shared
     state **only when the scroll is settled** (`!listState.isScrollInProgress`) — no transient
     writes during the settling sweep.
   - A `LaunchedEffect(state.pinNonce)` that calls `animateScrollToItem(liveIndex)` for the
     "Back to live" action (a user-initiated, post-layout scroll on a stable layout — which works;
     it is not fighting a reset).

### Bridge — shared observable state holder

3. **`CarouselBridgeState`** — a small bridged class holding only bridgeable primitives (no
   closures — closures cannot bridge through a `ContentComposer`: as a ctor param they fail to
   compile, as a settable var they crash at launch):
   - **In (Swift → Compose):** `covers: [String]` (ordered cover ids/urls), `targetIndex: Int`,
     `pinNonce: Int` (bumped by "Back to live").
   - **Out (Compose → Swift):** `centeredIndex: Int` (written on settle).

   The view model **owns** it, populates the "in" fields from `covers`/`selectedCoverID`, and
   observes `centeredIndex` to update `selectedCoverID` → title/background. Single source of truth
   stays in Swift; Compose is a pure render-and-report of it.

## Data flow

**Steady state (user swiping):** `LazyRow` scroll settles → `snapshotFlow` writes `centeredIndex`
→ view model maps index → cover id → sets `selectedCoverID` → title/background recompute. The title
always equals the centered cover. No `scrollTo` involved.

**Recreation (rotation / resume / low-memory):** `selectedCoverID` survives in the process-wide view
model. On rebuild, the view model computes `targetIndex` from it; `rememberSaveable` also restores the
index; they agree → the `LazyRow` is **born centered** on the right cover. Title derives from the same
index → in sync from the first frame. Nothing to command, nothing to race.

**"Back to live":** `returnToLive()` sets `selectedCoverID = liveCoverID` and bumps `pinNonce`; a
`LaunchedEffect(pinNonce)` animates the scroll to the live index. (iOS keeps its existing
`returnToLiveNonce` path.)

**Invariant that removes the bug class:** the title/background derive from `centeredIndex` (what is
actually visible), never from a separately stored selection that could drift. iOS already holds this
via its centered-cover preference key. On both platforms: **the title is a pure function of the
visible cover**, so desync is unrepresentable.

### Edge cases

- **Empty / single-cover history:** `targetIndex` clamps to the live slot.
- **New song appends on the right while browsing:** index is derived from stable cover **ids**, not
  positions, so the browsed position does not shift.
- **Artwork arriving late:** Coil swaps the image in place; no scroll reset.

## The one real risk, and how it is de-risked

How Compose reacts to Swift-side writes, and how Swift observes Compose's `centeredIndex`, **across
the `ComposeView` boundary**, is version-sensitive in Skip and is the highest-risk part. It is gated
by a **prototype spike before any app code**:

In `/Users/sst/code/maxi80/skip-tutorial/hello-world` (the known-good native+transpiled+bridging
reference prototype), prove:

1. A bridged `CarouselBridgeState` object passed into a `ComposeView { LazyRow }`.
2. Compose writes `centeredIndex` on settle; the Swift side observes the change.
3. `rememberSaveable(LazyListState.Saver)` + `initialFirstVisibleItemIndex` survives a rotation and a
   forced activity recreation, landing on the saved index.

**Exit criteria:** all three verified on the emulator. The spec/implementation then documents the
*exact proven* bridging pattern.

**Fallback if bidirectional object reactivity fails:** pass primitives in (`covers: [String]`,
`targetIndex: Int`) and drive the re-pin from a `LaunchedEffect` keyed on `pinNonce` **and**
`listState.layoutInfo.viewportSize.width` (the exact lever proven on-device during the rotation
investigation), reporting the centered index out via a single bridged `Int`. The spec documents
whichever mechanism the spike proves.

## Testing

**Unit (native, `swift test`)** — pure view-model logic, no bridge required:

- index ↔ cover-id mapping;
- `targetIndex` derivation from `selectedCoverID`;
- clamping for empty / single-cover history;
- "new song appends while browsing keeps the browsed index stable."

**On-device (the real proof)** — the recreation matrix, each from **both** live and a browsed history
cover, verifying born-centered + title-in-sync:

- resume via **notification** tap;
- resume via **app icon** / recents;
- **low-memory** activity recreation (Developer Options → *Don't keep activities*, and the Android
  Studio Debug-button launch path, since that is what reliably forces `onCreate` recreation);
- iOS regression pass (code unchanged, but confirm no behavior change).

Verification must confirm **both halves** of the built APK carry the change (native `.so` and the
transpiled dex) before trusting on-device results (see the hybrid-APK staleness caveat in project
memory). Build the instrumented/verification APK via a hardened `make clean build-android`
(DEVELOPER_DIR set to Xcode 26.6).

## Rollout

Feature branch → **prototype gate** (must pass before app code) → implement Android carousel →
device matrix → PR. The iOS diff should be effectively zero (only the `#if os(Android)` selection
point in `RadioPlayerView.body`).

## Out of scope (YAGNI)

- iOS carousel changes.
- Any change to playback / notification / coordinator logic.
- **Android rotation unlock — explicitly deferred**, but *enabled* by this design (see below).

## Enables (future follow-on): Android rotation unlock

Rotation was disabled (`android:screenOrientation="nosensor"`) *because* of this exact sync problem.
Once the carousel is born at the saved index, a rotation relayout lands on the right cover for the
same structural reason a resume does — the hard part is solved by this design. The remaining,
smaller work for a focused follow-up:

1. Remove `android:screenOrientation="nosensor"` from `AndroidManifest.xml` (1 line).
2. Verify/polish the Android **landscape** layout in `RadioPlayerView` (currently dead code on phones
   since they are portrait-locked).
3. Add a width-change re-pin: key the Compose re-pin `LaunchedEffect` on
   `listState.layoutInfo.viewportSize.width` as well (proven lever), for a config-change relayout
   that keeps the activity alive.
4. Device matrix: rotate-while-live and rotate-while-browsing, both directions, plus rapid rotations.

Estimated as a small follow-up (roughly half a day of landscape layout + width-keyed re-pin +
device testing), not a project — the risky part (the scroll reset) is eliminated here.
