# State-driven Cover Flow carousel — design

**Date:** 2026-08-01
**Branch:** `new-caroussel-fable` (worktree `maxi80-caroussel-fable`)
**Scope:** Apple platforms (iPhone, iPad, macOS). Android keeps today's renderer unchanged.
Apple TV / CarPlay / Android Auto out of scope.

## 1. Problem

The Cover Flow carousel (session history + persistent rightmost "now" slot, id `"__now__"`) must
keep the *selected* cover dead-center through: async history load (R1), swipe-to-browse with no
recoil (R2), settle reporting only for user gestures (R3), back-to-live (R4), a new song arriving
while live (R5) or while browsing (R6), rotation live/browsing/rapid (R7/R8/R9), start-play when
the current title already exists in history (R10), and iPad/macOS resizes (R11). See
`~/Desktop/coverflow-ios-spec.md` §2 for the authoritative acceptance list.

Two prior implementations failed the same way: they let SwiftUI's `ScrollView` own position as a
pixel content offset and then tried to reconcile it with the model's selection after every
insertion/rotation. `ScrollView` preserves content offset across left-insertions and resizes, and
`.scrollPosition(id:)` re-scrolls only when the bound id *changes* — so the pinned cover drifts,
and every after-the-fact fix (imperative `scrollTo`, nil-nudge, pixel-anchor calibration, guard
windows with backstop timers) either left residual drift (P0–P4) or introduced visible artifacts.

## 2. Approach: position is a pure function of state

Drop `ScrollView` entirely on Apple. The carousel renders covers explicitly positioned in a
`ZStack`; the selected cover is centered **by construction**, so the entire drift bug class is
structurally impossible — there is no content offset to preserve and nothing to re-center.

### Rendering model

```
anchorIndex = covers.firstIndex { $0.id == selectedID } ?? covers.count - 1
relative(i) = CGFloat(i - anchorIndex) + dragProgress     // dragProgress = -dragTranslation / slotWidth
xOffset(i)  = relative(i) × slotWidth                     // 0 == dead center, always
scale(i)    = 1 - (1 - minScale) × |clamp(relative(i), -1, 1)|
tilt(i)     = -clamp(relative(i), -1, 1) × maxRotation    // Y-axis rotation3DEffect
zIndex(i)   = -|relative(i)|
```

Consequences, mapped to requirements:

- **Insertions can't drift.** A cover inserted left of the selection shifts `i` and `anchorIndex`
  equally → the browsed cover's `relative` is unchanged (R6). While live, `anchorIndex` is the now
  slot; history slides one slot left underneath and the now slot stays at `relative = 0` (R5, R10).
  Initial history load is the same case (R1).
- **Rotation/resize can't drift.** The math re-evaluates at the new width; even a full view
  teardown is harmless because a fresh view reads `selectedID` and renders it centered on frame
  one (R7/R8/R9/R11). No `AnyLayout` restructuring of `RadioPlayerView` is required and no
  recreation guard exists.
- **Virtualization by math.** Only covers with `|relative(i)| ≤ windowRadius` (~4) are
  instantiated; beyond that they are fully occluded/off-screen. A 100-entry history renders ≤ 9
  cells. No `LazyHStack`.

All geometry — slot math, snap target, rubber-band clamp, visible window, fan curve — lives in a
pure `CarouselGeometry` value type with no SwiftUI dependency, unit-tested exhaustively.

### Interaction

- **Drag:** a `DragGesture` writes `dragTranslation` (finger-tracking, unanimated — the gesture
  updates go through a transaction with animation disabled). On release the snap target is
  `round(anchorIndex − predictedEndTranslation/slot)` clamped to valid indices, with rubber-band
  resistance beyond the ends during the drag. One `withAnimation(.spring)` block zeroes
  `dragTranslation` and (if the target differs) calls `onSettled(targetID)` — position lands via a
  single spring from wherever the finger left it, so there is no recoil (R2).
- **Settle reporting:** `onSettled` is called from exactly two places — the drag-release handler
  and tap-to-focus. There is no scroll-phase detection, no debounce, no "was this user-driven?"
  heuristic (R3 by construction). The model's `userSettledOn` ignores unknown ids as a final
  belt-and-braces.
- **Tap-to-focus:** tapping a non-centered cover animates it to center and reports it settled
  (works on iOS and macOS; on macOS this plus click-drag replaces two-finger scroll — accepted
  trade-off).
- **Keyboard (macOS/iPad):** left/right arrows via `.onKeyPress` move the selection one slot.
- **External changes** (back-to-live, new-song insertion, history load) animate via
  `.animation(.spring, value: layoutKey)` where `layoutKey` folds the ordered cover ids and
  `anchorIndex`. `dragTranslation` is deliberately outside that key so finger tracking is never
  animated.
- **Crossfade** of the now slot's artwork stays inside `CoverImage` (opacity-based). Nothing binds
  `scrollPosition(id:)` anymore, so the historical "no inner `.id()` in the cell subtree" landmine
  is gone; the existing `.id(artworkURL)` crossfade keying is safe to keep.

### Canonical state: `CarouselModel`

`@MainActor @Observable final class`, unchanged contract from the prior spec (the future Android
Compose renderer will share it):

```swift
static let nowSlotID = "__now__"
private(set) var coverIDs: [String]          // oldest → newest, now slot last
private(set) var selectedID: AnyHashable     // defaults to nowSlotID
var isBrowsing: Bool                         // selected ≠ nowSlot && still present
var focusedEntryID: String?                  // browsed id, nil when live
func userSettledOn(_ id: AnyHashable)        // now slot always accepted; others must be in coverIDs
func returnToLive()
func syncCoverIDs(_ ids: [String])           // no-op when unchanged; drops vanished selection to now slot
```

`RadioPlayerViewModel`: `covers` stays a computed property (pull-based from the coordinator) and
calls `carousel.syncCoverIDs(ids)` at the end; `selectedCoverID` becomes a computed proxy
(`get` → `carousel.selectedID`, `set` → `userSettledOn`); `isBrowsingHistory` → `carousel.isBrowsing`;
`returnToLive()` → `carousel.returnToLive()`. Public surface unchanged — TV files keep compiling.

## 3. Platform split

New thin dispatcher `CoverFlowCarousel` (the only carousel type `RadioPlayerView` references),
with the `#if os(Android)` branch **inlined in `body`** (Skip Fuse rule):

- `#if os(Android)` → today's `CoverFlowView`, byte-identical behavior, including its
  `pinTarget`/`pinToken` plumbing and the view-model guard tower it depends on
  (`beginReorientation`, `beginForegroundTransition`, `setSelectionFromCarousel`,
  `isCarouselRecreating`) — all of which become Android-only: call sites in `RadioPlayerView` /
  `SharedPlayer` are gated `#if os(Android)`, and the members are marked as Android-legacy.
  They are deleted when the native Compose renderer lands (separate project).
- `#else` → new `AppleCoverFlow(covers:selectedID:coverSize:onSettled:)`.

Skip Fuse bridging rules that bind `AppleCoverFlow`/`CoverFlowCarousel`: no `private @State` on a
bridged view type (use internal `@State var`); no `#if SKIP`-only stored properties; both build
legs must pass.

`Cover` is extracted from `CoverFlowView.Cover` to a top-level `Cover` type in
`Sources/Maxi80/CoverFlow/Cover.swift`; `CoverImage`/`CoverImageCache` move to
`CoverFlow/CoverImage.swift`. TV files (`TVHistoryRow`, `TVRadioPlayerView`) retarget the type
name only.

**Deployment floor stays iOS 17 / macOS 14 / tvOS 17.** This design uses no iOS 18 scroll APIs
(the floor bump on the dead `redesign-coverflow-carousel` branch existed only for
`onScrollPhaseChange`, which this design doesn't need).

## 4. File layout

```
Sources/Maxi80/CoverFlow/
├── CarouselModel.swift       — canonical state (new)
├── CarouselGeometry.swift    — pure slot/snap/fan math (new)
├── Cover.swift               — value type (extracted)
├── CoverImage.swift          — artwork view + cache + crossfade (extracted)
├── CoverFlowCarousel.swift   — dispatcher: Android → CoverFlowView, else AppleCoverFlow (new)
└── AppleCoverFlow.swift      — state-driven renderer (new)
Sources/Maxi80/CoverFlowView.swift — Android-only legacy renderer (kept, shrunk)
```

## 5. Error handling / edge cases

- `selectedID` not found in `covers` (transient during rollover): render anchored on the now slot;
  the model's `syncCoverIDs` resolves the selection to the now slot on the same tick.
- Empty history: strip renders just the now slot; drag rubber-bands and snaps back.
- Drag in flight when covers change: `relative` shifts are index-stable (see §2), so the drag
  continues smoothly; the release snap resolves against the current array.
- `userSettledOn` with a stale id (cover rolled off mid-drag): model ignores it, spring returns to
  the anchor.

## 6. Testing

- `CarouselModelTests` — the 7 model cases from the prior plan (start state, browse, return to
  live, append-while-browsing preserves selection, dropped-id fallback, stale-id ignored, now-slot
  always accepted).
- `CarouselGeometryTests` — snap rounding, flick prediction, index clamping, rubber-band, visible
  window, fan curve symmetry, insertion index-stability (`relative` invariant under left-insert).
- Build gates: `swift build`, `swift test`, and
  `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer skip android build`.
- Manual simulator pass of R1–R11 (user-driven; instrument with OSLog category `CoverFlow` if
  traces are needed — do not script the simulator).

## 7. Trade-offs accepted

- We own ~30 lines of swipe physics (spring, predicted-end snap, rubber-band) instead of
  UIScrollView's native deceleration feel. Tunable constants, unit-tested math.
- macOS loses two-finger trackpad scrolling on the strip; click-drag, tap-to-focus, and arrow keys
  replace it.
- Android intentionally unchanged (its real fix is the separate native Compose renderer).
