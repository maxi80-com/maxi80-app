# iPad Layout Fix — Design & Implementation Plan (#52)

## Context

Issue [#52](https://github.com/maxi80-com/maxi80-app/issues/52): on iPad the player never uses the phone-style portrait layout — **both portrait and landscape render the landscape layout**, and the Cover Flow carousel is not enlarged for the bigger screen.

**Root cause (confirmed in code):** `RadioPlayerView.isPortrait` (`Sources/Maxi80/RadioPlayerView.swift:56-58`) is defined as:

```swift
private var isPortrait: Bool {
  horizontalSizeClass == .compact && verticalSizeClass == .regular
}
```

On iPad, `horizontalSizeClass` is `.regular` in **both** orientations (full-screen), so `isPortrait` is always `false` and `landscapeView()` is always chosen. The `body` selects layout via a plain `Group { if isPortrait { portraitView() } else { landscapeView() } }` (lines 24–31).

Separately, `CoverFlowView.coverSize` (`Sources/Maxi80/CoverFlowView.swift:35`) defaults to a fixed `260` and the call site in `RadioPlayerView.coverFlow()` (lines 152–165) does not override it, so the carousel is the same size on iPad as on iPhone.

### Desired behavior

- iPad **portrait** → phone **portrait** layout.
- iPad **landscape** → phone **landscape** layout.
- Cover Flow carousel **noticeably larger on iPad only** (unchanged on iPhone, macOS, tvOS, Android).
- Scope: **iOS/iPad only** per the reporter.

### Decision (confirmed with the user)

Detect orientation via **`GeometryReader` width-vs-height** rather than size class. This is cross-platform (no UIKit guard needed for the detection itself), survives iPad split-view / Slide Over (uses the actual pane size, not the device), and — crucially — lets us **keep the existing `if/else` structure** so the carousel-recreation compensation contract stays valid (see caveat below). The larger-carousel knob is gated behind an iOS-only `userInterfaceIdiom == .pad` check.

> **Layout-structure caveat (important).** An earlier memory claimed `RadioPlayerView` uses `AnyLayout` for a single carousel instance across rotation. That refactor lives **only in an unmerged worktree branch** — current `main` has **no `AnyLayout`** anywhere. On `main`, `portraitView()`/`landscapeView()` are separate branches of a `Group { if }`, so **rotation recreates `CoverFlowView`**, and that recreation is compensated by `beginReorientation()` (`RadioPlayerView.swift:38`, opens a window dropping the carousel's selection write-back) plus the width-folded re-pin in `CoverFlowView.repinToken(width:)`. **Do not convert the `if/else` to `AnyLayout`** as part of this fix — that would silently break the recreation-compensation assumptions. Keep the branch structure; only change what drives the boolean and the cover size.

---

## B1. Orientation via container size

**File:** `Sources/Maxi80/RadioPlayerView.swift`

- Wrap the layout selection in a `GeometryReader` so `isPortrait` is derived from geometry, not size class:
  - Inside the reader, `let isPortrait = geo.size.height > geo.size.width`.
  - Keep the existing `Group { if isPortrait { portraitView() } else { landscapeView() } }` unchanged in structure — only its input changes.
- `isPortrait` is also read by `dynamicBackground()` (lines 69–70, for gradient direction). Thread the geometry-derived value to it — pass it as a parameter to `dynamicBackground(isPortrait:)`, or hoist the value so both the layout `Group` and the background read the same source. Avoid keeping two independent definitions of "portrait."
- **Retire** the size-class `isPortrait` computed property (lines 56–58). The `@Environment(\.horizontalSizeClass)` / `verticalSizeClass` reads (lines 14–15) can be removed if nothing else uses them (verify — a grep of the file), or left if harmless.
- Keep `.onChange(of: isPortrait) { _, _ in viewModel.beginReorientation() }` (line 38) firing against the new geometry-derived boolean, so the carousel re-pin still runs on rotation. Since `isPortrait` will now live inside the `GeometryReader` scope rather than as a view property, place the `.onChange` where it can observe that value (e.g. on the inner content), preserving the current semantics.

**Watch:** wrapping `body` content in a `GeometryReader` changes how the content sizes/positions (a `GeometryReader` fills and top-left-aligns its children). Verify the existing `.background { dynamicBackground().ignoresSafeArea() }`, the `.overlay` version footer (line 45), and the top error banner overlay (lines 47–51) still lay out correctly; add framing/alignment if the wrap shifts anything.

---

## B2. Larger carousel on iPad only

**Files:** `Sources/Maxi80/RadioPlayerView.swift` + `Sources/Maxi80/CoverFlowView.swift`

- `CoverFlowView.coverSize` (`CoverFlowView.swift:35`) is already a `var` defaulting to `260` and drives all downstream layout: cover frame (lines 254, 283), horizontal centering padding `(outer.size.width - coverSize)/2` (line 74), tilt/scale normalization (line 239), and overall view height `coverSize + verticalMargin*2` (line 143). So **one knob** is sufficient — pass a larger value in and the whole carousel scales.
- Add an **iPad check**. There is no existing `isPad` helper. Preferred home: extend `PlatformEnvironment` (`Sources/Maxi80Services/PlatformEnvironment.swift`), which already models idiom flags (`isTVMode`, lines 18–31) with the correct `#if` guarding:
  - `public static let isPad: Bool` → `#if os(iOS)` return `UIDevice.current.userInterfaceIdiom == .pad` (guarded with `#if canImport(UIKit)`); `#else` return `false` (macOS/tvOS/Android). Follow the exact `#if` shape of `computeIsTVMode()`. Note `PlatformEnvironment` is a bridged module (`/* SKIP @bridge */`, `#if !SKIP_BRIDGE`) — keep those annotations intact.
  - Alternatively inline a `#if canImport(UIKit)` + `userInterfaceIdiom == .pad` check in the view, but the helper keeps it reusable and consistent with `isTVMode`.
- In `RadioPlayerView.coverFlow()` (lines 152–165), pass `coverSize:` to the `CoverFlowView(...)` init: use a larger value (start ~`380`, **tune visually**) when `PlatformEnvironment.isPad`, else omit / pass `260`. iPhone, macOS, tvOS, and Android keep the `260` default unchanged.

---

## Files touched (summary)

| File | Change |
|------|--------|
| `Sources/Maxi80/RadioPlayerView.swift` | `GeometryReader`-driven `isPortrait`; thread it to `dynamicBackground` + `.onChange`; pass iPad `coverSize` |
| `Sources/Maxi80/CoverFlowView.swift` | no logic change expected (verify `coverSize` scaling reads well at the larger size) |
| `Sources/Maxi80Services/PlatformEnvironment.swift` | add `isPad` idiom flag (iOS-only, UIKit-guarded) |

> **`RadioPlayerView.swift` is also touched by the Sleep Timer plan (#1)** (it adds a countdown pill in the two layout branches). Coordinate ordering between the two workstreams to avoid a merge conflict in this file.

---

## Verification

Shared setup: ensure `Sources/Maxi80/Resources/Configuration.plist` exists. Trigger the Skip transpiler by building the **macOS** destination.

- **iPad Air 13" (M3) simulator** (the reporter's device): portrait now shows the **phone portrait** layout; landscape shows the **phone landscape** layout. Rotate both ways and confirm the carousel keeps its browsed cover (`beginReorientation` + width re-pin still work) and the background gradient direction flips correctly.
- Confirm the carousel is **visibly larger on iPad** and **unchanged on iPhone** (still 260), macOS, tvOS, and Android.
- **iPad split-view / Slide Over:** geometry-based detection picks portrait/landscape from the actual pane size, not the physical device orientation.
- iPhone regression check: portrait and landscape unchanged from today.
- `swift build` (macOS) + `skip android build` still compile — the `#if canImport(UIKit)` / `#if os(iOS)` idiom check must not break Android/macOS/tvOS builds.
