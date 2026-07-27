# Plan — Issue #25: iOS Cover Flow flashes when loading history

**Issue:** [#25 — iOS: Cover Flow : Flash when loading history](https://github.com/maxi80-com/maxi80-app/issues/25)
**Triage:** `bug` (worth doing).
**Platform:** Apple (iOS specifically — labelled "Apple OS"). Android drives the scroll position through `scrollPosition(id:)` on the SkipUI path and does not exhibit the flash (per the reverted commit's own comment).

---

## 1. Reproduction

Exact conditions (from the issue + code trace):

1. Cold-launch the iOS app **while not playing**.
2. On first render the carousel content is just the placeholder now-slot: `covers == [nowSlot]` (`RadioPlayerViewModel.covers`, `RadioPlayerViewModel.swift:143-163`).
3. History loads **asynchronously** a moment later. `pastEntries` populates, so `covers` grows to `[past…, nowSlot]` — the new covers are **prepended on the left** (oldest→newest, now slot stays rightmost).
4. Observe the carousel for the frame(s) right after history arrives.

**Observed:** a brief flash — "titles briefly appear on the right side" — as the oldest (leftmost) cover shows centered for a frame, then the carousel snaps back to the now slot. Short, but unpleasant.

**Expected:** the now slot stays centered across the history-load size change; no intermediate frame where a past cover is centered.

This reproduces on the live-not-playing launch path and on **every** history load that changes the cover set (each grows the content on the left).

## 2. Root cause (file/function level)

The flash is a **layout race** between the ScrollView's default leading anchor and the re-pin `.task`, in `CoverFlowView` (`Sources/Maxi80/CoverFlowView.swift`):

- The carousel is a horizontal `ScrollView` whose content order is oldest→newest with the now slot **last** (`CoverFlowView.body`, `CoverFlowView.swift:52-64`; order defined by `RadioPlayerViewModel.covers`, `RadioPlayerViewModel.swift:143-163`).
- iOS's ScrollView default scroll anchor is **leading**. When history loads and the `LazyHStack` grows *on the left* (`ForEach(covers)`, `CoverFlowView.swift:53-58`), iOS keeps the **leading edge pinned**. For a frame the new leftmost (oldest) cover sits at the visually-centered rest position — this is the flash.
- Re-centering is driven by `.task(id: repinToken(width:))` (`CoverFlowView.swift:74-97`). It reacts to `pinToken` changes — `coverPinToken` changes whenever the past-entry id list changes (`RadioPlayerViewModel.coverPinToken`, `RadioPlayerViewModel.swift:291-295`) — but it **deliberately sleeps `60_000_000` ns (60 ms)** before `proxy.scrollTo(target, …)` (`CoverFlowView.swift:80`). That sleep lets layout settle so the jump lands directly instead of sweeping through intermediate covers (and cancelling their `AsyncImage` loads). The cost is that the leading-pinned wrong frame is **visible for that ~60 ms window** — precisely the flash.

So the root cause is: **on iOS the ScrollView anchors leading, so growing the content on the left transiently centers the oldest cover, and the corrective re-pin is intentionally deferred ~60 ms — making that wrong frame visible.** (`CoverFlowView.swift:52-97`.)

### Why the previous fix was reverted (and what this plan must avoid)

Commit `98ec36e` ("Skip flash at history load") added, Apple-only:

```swift
#if !os(Android)
  .defaultScrollAnchor(pinTarget != nil ? .trailing : nil)
#endif
```

Trailing-anchoring **does** kill the flash (it holds the trailing now slot centered across the size change). But it introduced a regression: on the **first browse/swipe** the list jumped to the **beginning of history (position 82)**, requiring "Back to live" — subsequent browsing was fine. Commit `76cab255` reverted it (together with `879e764`).

Root of that regression: `.defaultScrollAnchor(.trailing)` changes the ScrollView's **content-size-change and initial rest behavior**, and it fights the `.viewAligned` snap + the `.task` `scrollTo` on the first user gesture — the first swipe resolves against the trailing anchor's frame of reference and lands at the far (oldest) end. The gate `pinTarget != nil ? .trailing : nil` also flips the anchor exactly at the browse/live boundary, so the transition into browsing is where it misbehaves.

**Constraint for this plan:** the fix must remove the visible wrong frame **without** globally re-anchoring the ScrollView (which perturbs gesture/snap math). The safest lever is the **timing/visibility of the wrong frame**, not the anchor.

## 3. Approach

Preferred approach (A) — **hide the carousel until the first re-pin completes**, so the leading-pinned wrong frame is never shown. This attacks the root cause (visible wrong frame) without touching the anchor, so it cannot reintroduce the position-82 regression.

Concrete changes, all in `Sources/Maxi80/CoverFlowView.swift` (shared SwiftUI file; iOS-scoped where noted):

1. Add private view state to `CoverFlowView`:
   ```swift
   #if !os(Android)
   @State private var hasPinned = false
   #endif
   ```
2. In the `.task(id: repinToken(width:))` block (`CoverFlowView.swift:74-97`), after the existing `proxy.scrollTo(target, anchor: .leading)` on the Apple branch, set `hasPinned = true`. Set it on **every** completion of the task (including when `target` is nil / early return) so the carousel can never get stuck hidden.
3. Make the content **invisible but laid out** until the first pin lands, so layout still settles for `scrollTo` to work:
   - Apply `.opacity(hasPinned ? 1 : 0)` to the `ScrollView` (Apple only via `#if !os(Android)`), and animate the reveal with a short fade (`.animation(.easeInOut(duration: 0.15), value: hasPinned)`) so the covers appear settled rather than popping.
   - Do **not** use `if hasPinned { … }` conditional inclusion — the ScrollView must be in the tree and laid out for `proxy.scrollTo` to have something to scroll. Opacity keeps it laid out while hidden.
4. Reset `hasPinned = false` at the *start* of the `.task` **only when the token change corresponds to a content-growth re-pin** (i.e., always safe to reset, then re-reveal after scrollTo). Because `repinToken` folds in width, a rotation also re-runs the task; hiding for the ~60 ms + 150 ms fade during a rotation re-pin is acceptable and consistent with the existing rotation recreation window. If the reveal-on-rotation proves jarring in testing, gate the reset so it only hides on the **first** pin (`if !hasPinned { reset }`) — see acceptance criteria.
5. Leave the Android branch (`#if os(Android)` → `proxy.scrollTo(target, anchor: .center)`) and the `scrollPosition(id:)` path untouched — Android has no flash.
6. Do **not** add `.defaultScrollAnchor`. Explicitly document in a code comment that trailing-anchoring was tried in `98ec36e` and reverted in `76cab255` because it broke the first browse (jump to history start / position 82), and that this fix instead hides the pre-pin frame.

Fallback approach (B) — if the fade-in is undesirable: shorten the re-pin delay on the **content-growth** path (not rotation) so the wrong frame is imperceptible. The 60 ms sleep exists to avoid animated sweeps; since this `scrollTo` is **non-animated**, an experiment reducing the growth-path delay toward `0` (a single `Task.yield()` / one runloop tick instead of 60 ms) may land the pin before the frame paints. Keep the 60 ms only where measured necessary. This is lower-confidence (it depends on iOS layout timing) so (A) is preferred.

### Files to change
- `Sources/Maxi80/CoverFlowView.swift` — add `hasPinned` gate + opacity reveal (approach A). **No other application source is modified.** No changes to `RadioPlayerViewModel.swift` or `RadioPlayerView.swift` are required; `coverPinToken` already fires the task on history load.

### Out of scope / non-goals
- **Issue #24** (Cover Flow not centered when starting playback and browsing) is a separate centering-correctness axis and is **not** addressed here; this plan must not regress it — verify the now slot is centered after the fade-in reveal.
- No change to Android behavior, the `CenteredCoverKey` selection path, or `CoverImageCache`.
- Do not reintroduce `.defaultScrollAnchor` in any form.

## 4. Acceptance criteria

1. Cold-launch iOS while not playing: when history finishes loading, **no frame** shows a past (leftmost/oldest) cover centered; the now slot is centered throughout. The "titles briefly appear on the right side" flash is gone.
2. Every subsequent history load that grows the cover set produces **no flash**.
3. **First browse/swipe does NOT jump to the start of history** (no position-82 regression): the first swipe moves exactly one cover from the now slot, as normal. This is the specific regression that got `98ec36e` reverted — it must be verified explicitly.
4. "Back to live" still recenters the now slot; browsing past covers and returning works as before.
5. Rotation (portrait↔landscape) still re-centers the browsed/live cover; the reveal gate does not leave the carousel permanently hidden after any re-pin (including the nil-target early-return path).
6. Android carousel behavior is unchanged (no flash existed; `scrollPosition(id:)` + `.center` path untouched); the file still compiles for the Android SDK Swift compile (guards use `#if !os(Android)` / `#if os(Android)`, not `#if SKIP`, matching the existing convention in this file).
7. macOS/tvOS unaffected (they use the same non-Android Apple branch — confirm the opacity gate reveals correctly there too).
8. Issue #24 is not regressed: initial centering on starting playback is unchanged.

## 5. Verification steps

- Build iOS target and run on device/simulator; watch the launch-not-playing → history-load transition frame-by-frame (screen recording) to confirm no centered past cover appears.
- Manually: launch, wait for history, **swipe once** — confirm it advances one cover, not to history start.
- Rotate the device while pinned to live and while browsing a past cover; confirm re-centering and that the carousel is never stuck invisible.
- Tap "Back to live" from a browsed position; confirm recenter.
- Smoke-test Android to confirm no visual/behavioral change.
