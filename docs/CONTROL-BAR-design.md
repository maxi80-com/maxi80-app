# Player Control Bar — Redesign Proposal

> **SCOPE OVERRIDE (2026-07-29, per user): TV is OUT OF SCOPE — leave it unchanged.**
> This redesign (and the sleep-timer feature) applies to **phone and tablet only**, on both iOS
> and Android. On **TV (tvOS and Android TV)** keep the current UI exactly as it ships today:
> the play/pause hero only, with **no** Share, Donate, or Sleep-timer controls. Do **not** touch
> `TVRadioPlayerView.controlStack()` / `playButton()`, and do **not** add a sleep-timer control or
> countdown to the TV UI. Any TV mockups/notes below (e.g. the "labeled focusable pills" tray and
> §4.5) are **superseded and should be ignored** — they predate this decision.

## Goal

Rebalance the player's action controls so the four actions — **Share**, **Play/Pause**,
**Donate**, and the new **Sleep timer** (see `SLEEP-TIMER-design.md`) — read as one intentional,
balanced cluster across iOS, macOS, tvOS, and Android on phone, tablet, and TV.

This is a **design proposal only**. No source files are changed here. It covers `PlaybackControlsView`
(phone/tablet/macOS) and `TVRadioPlayerView.controlStack()`/`playButton()` (TV), and it is deliberately
compatible with the sleep-timer plan (`SLEEP-TIMER-design.md`) and the iPad-layout plan
(`IPAD-LAYOUT-design.md`), both of which touch the same files.

---

## 1. Why the current layout feels unbalanced

Today `PlaybackControlsView` is a single `HStack(spacing: 36)`:

```
   ⬆            ⏸            ♥
 Share      Play/Pause     Donate
 (22/44)      (68pt)       (22/44)
```

- **One dominant element with satellites.** The 68pt play disc is ~3× the visual mass of the 22pt
  secondary glyphs. Three tiny glyphs orbiting one big one never resolves into a "control bar" — it
  reads as *one button plus decoration*.
- **The trio was only accidentally symmetric.** Share | Play | Donate happened to be a symmetric
  3-item row (one secondary each side of the hero). That symmetry is the only thing that held it
  together.
- **The 4th action breaks the symmetry.** Appending Sleep makes it `Share · Play · Donate · Sleep`
  — one secondary on the left of the hero, two on the right, play no longer centered:

  ```
    ⬆        ⏸        ♥        🌙
  Share  Play/Pause  Donate   Sleep    ← play is now left-of-center; lopsided
  ```

- **No grouping cue.** All four sit at the same tier with uniform 36pt gaps, so nothing signals
  "one primary, three utilities." The eye has to work out the hierarchy from size alone.

The fix is to make the hierarchy **explicit** (primary vs. utility) and make the utilities
**balanced as a set**, instead of relying on incidental left/right symmetry that only works for an
odd count.

---

## 2. Options

Icon legend used below: `⬆` Share · `♥` Donate · `🌙` Sleep · `▶ / ⏸` Play/Pause · `· · ·` the
existing reserved "Back to live / status" slot (`liveIndicator()`, `RadioPlayerView.swift:247`).

### Option A — Two-tier: Play hero + balanced utility tray *(recommended)*

Keep the big centered Play/Pause as an unambiguous **hero on its own tier**. Move the three
secondary actions into a **separate utility tier**: three equal ghost-circle buttons, evenly
spaced, forming a self-contained balanced trio. Nothing "orbits" the hero anymore — the two tiers
are read separately.

**Phone — portrait**

```
        ┌───────────────┐
        │   cover flow  │
        └───────────────┘
            Song Title
              Artist
          · · · · · · ·                ← status / sleep-countdown slot

               ⏸                       ← HERO  (orange filled disc, 72pt, centered)

      ╭─────╮   ╭─────╮   ╭─────╮
      │  ⬆  │   │ 🌙  │   │  ♥  │       ← utility tier: 3 equal 48pt ghost circles
      ╰─────╯   ╰─────╯   ╰─────╯

      ───────●───────────  volume
```

**Phone — landscape** (right column of the existing `landscapeView()` HStack)

```
 ┌──────────┐    Song Title
 │  cover   │      Artist
 │  flow    │   · · · · · ·
 │          │        ⏸                 ← hero
 └──────────┘  ╭───╮ ╭───╮ ╭───╮
               │ ⬆ │ │🌙 │ │ ♥ │       ← utility tier (compact, same trio)
               ╰───╯ ╰───╯ ╰───╯
               ─────●────── volume
```

**Tablet** — identical structure, scaled up: hero ~84pt, tray circles ~60pt, wider tray spacing.
The extra width comfortably carries the two-tier separation.

```
                 ⏸   (84pt)

      ╭──────╮    ╭──────╮    ╭──────╮
      │  ⬆   │    │  🌙  │    │  ♥   │   (60pt, generous gaps)
      ╰──────╯    ╰──────╯    ╰──────╯
```

**TV** — play is the large default-focus hero; the utility tier becomes a row of **labeled**,
individually focusable pill buttons (labels matter at 10 feet).

```
                    ⏸   (96pt, default focus)

     ╭────────╮   ╭────────╮   ╭────────╮
     │ ⬆ Share│   │🌙 Sleep│   │ ♥ Donate│   ← 3 focusable pills, D-pad left/right
     ╰────────╯   ╰────────╯   ╰────────╯
```

**Sleep active (all idioms).** The countdown pill (styled like `backToLiveLabel`) appears in the
already-reserved status slot above the hero; the tray's moon fills (`moon.zzz.fill`) to echo the
active state. Tapping the moon (or the pill) opens extend/cancel.

```
               ⏸
        ┌────────────────┐
        │ 🌙  29:12    ✕ │        ← countdown pill in the reserved status slot
        └────────────────┘
      ╭─────╮ ╭─────╮ ╭─────╮
      │  ⬆  │ │🌙•  │ │  ♥  │      ← moon filled while active
      ╰─────╯ ╰─────╯ ╰─────╯
```

- **Hierarchy rationale:** the tier break does the work size alone was failing to do — play is
  categorically "the primary," the trio is categorically "utilities."
- **Balance:** three equal circles, evenly spaced, are balanced by construction regardless of which
  action sits in the middle (no dependence on odd/even symmetry).
- **Sleep active fit:** natural — reuses the existing reserved slot for the pill and only toggles the
  tray glyph's fill. No layout reflow, no height jump.
- **Pros:** preserves the big-play hierarchy the user already likes; robust on Compose (three plain
  circular buttons, no dividers/segmented control); minimal per-idiom branching; the tray gracefully
  degrades to labeled pills on TV.
- **Cons:** adds one control-row's height (~56–68pt) in portrait; landscape must use the compact
  tray to stay within the right column's vertical budget.

---

### Option B — Equal-peer row: four co-equal buttons, emphasis by fill (single tier)

Keep one row, but drop the size hierarchy. All four become **equal-diameter circular buttons**;
Play/Pause earns prominence through a **filled orange disc** (56pt) while the other three are
**ghost/tinted** glyphs (48pt). A row of four evenly-spaced peers is inherently balanced.

**Phone — portrait**

```
   ╭─────╮   ╭─────╮   ╭─────╮   ╭─────╮
   │  ⬆  │   │ 🌙  │   │  ▶  │   │  ♥  │      ▶ = filled orange, 56pt; others ghost, 48pt
   ╰─────╯   ╰─────╯   ╰●────╯   ╰─────╯
     Share    Sleep     Play     Donate
```

Order places Play at slot 3 of 4 (near center) so the filled disc reads as the focal point.

**Phone — landscape / Tablet** — same row, tighter (landscape) or wider with larger discs (tablet).

```
 ╭───╮ ╭───╮ ╭───╮ ╭───╮        ╭────╮  ╭────╮  ╭────╮  ╭────╮
 │ ⬆ │ │🌙 │ │ ▶ │ │ ♥ │        │ ⬆  │  │ 🌙 │  │ ▶  │  │ ♥  │
 ╰───╯ ╰───╯ ╰───╯ ╰───╯        ╰────╯  ╰────╯  ╰────╯  ╰────╯
      landscape                        tablet (larger)
```

**TV**

```
  ╭────────╮ ╭────────╮ ╭─────────╮ ╭─────────╮
  │ ⬆ Share│ │🌙 Sleep│ │ ▶ Play  │ │ ♥ Donate│    Play default focus (larger/filled)
  ╰────────╯ ╰────────╯ ╰─────────╯ ╰─────────╯
```

**Sleep active.** Same as Option A — pill in the reserved status slot; the moon peer fills.

- **Hierarchy rationale:** prominence via *treatment* (fill + slight size) rather than dramatic
  scale, so the other three no longer look like decorations.
- **Balance:** four equal peers on a uniform rhythm — the most literally "balanced" of the three.
- **Sleep active fit:** clean; 4th peer is a first-class citizen.
- **Pros:** smallest layout change (still one `HStack`, one row height — best for tight landscape);
  no new tier; fits every idiom identically.
- **Cons:** Play is no longer *dramatically* bigger — the user currently likes a big play button, and
  shrinking it to 56pt (near-peer) may feel like a demotion. Play cannot sit at the exact geometric
  center of an even count, so the focal point relies on the orange fill carrying it.

---

### Option C — Relocate Sleep: restore the symmetric transport trio

Recognize that the original `Share · Play · Donate` trio was already balanced, and that **Sleep is a
"mode," not a transport action**. Keep the transport row as the clean symmetric trio and move Sleep
out to a header/overlay affordance.

**Phone — portrait**

```
  ┌───────────────────────────── 🌙 ┐   ← Sleep toggle top-trailing (nav-bar-style slot)
  │        ┌───────────────┐         │
  │        │   cover flow  │         │
  │        └───────────────┘         │
              Song Title
                Artist
            · · · · · · ·

     ⬆            ⏸            ♥          ← untouched symmetric transport trio
   Share      Play/Pause     Donate
```

When active, the top-trailing control *is* the countdown pill:

```
  ┌──────────────────── ┌ 🌙 29:12 ✕ ┐ ┐   ← same slot becomes the pill
```

**Landscape / Tablet / TV** — the transport trio is unchanged; the sleep control lives in a
top-trailing overlay (portrait/landscape), a toolbar item (tablet/macOS), or as an extra focusable
pill above the play button on TV (where `controlStack()` already stacks a "Back to live" pill above
`playButton()`, `TVRadioPlayerView.swift:76-95`).

- **Hierarchy rationale:** transport stays a focused, symmetric trio; sleep is spatially separated
  because it's a different *kind* of action (a session mode).
- **Balance:** restores the proven Share·Play·Donate symmetry exactly.
- **Sleep active fit:** excellent — the header slot naturally hosts the pill with cancel/extend.
- **Pros:** least disruption to the transport row; semantically honest; sleep and its countdown pill
  share one home.
- **Cons:** needs a *new* home in every layout (portrait overlay, landscape, tablet toolbar, TV
  stack) — the most cross-layout wiring; sleep is less discoverable than sitting inline with the
  controls; a top-trailing overlay competes with the dynamic island / status area on phones.

---

## 3. Recommendation — **Option A (two-tier hero + utility tray)**

Option A best satisfies the brief and the user's stated preference:

- **It keeps the big Play/Pause hero.** The user's complaint is imbalance, *not* the big play button
  — they like a clear primary. A keeps play dominant while fixing the imbalance, rather than
  demoting it (Option B) or leaving three small icons inline.
- **It makes the utilities balanced *as a set*.** A centered, evenly-spaced trio of equal ghost
  circles is balanced by construction and reads as "utilities," independent of the odd count that
  Option C depends on.
- **It is the most robust across Skip/Compose and all idioms.** Three plain circular `Button`s (no
  segmented control, no dividers, no material-capsule tricks that transpile unreliably), one big
  play button, and a per-idiom size table. TV degrades cleanly to labeled focusable pills.
- **It absorbs the sleep active state with zero reflow** by reusing the existing reserved status
  slot for the countdown pill and only toggling the tray glyph's fill.
- **It coordinates cleanly with the two adjacent workstreams.** The sleep-timer plan already wants
  a moon control in `PlaybackControlsView` plus a `backToLive`-styled pill; A gives both a home. The
  iPad plan only scales the carousel and adds `PlatformEnvironment.isPad`, which A reuses for its
  size table.

Option B is the fallback if landscape vertical space proves too tight for a second tier — its single
row is the most space-efficient. Option C is attractive semantically but carries the most
cross-layout wiring and a discoverability cost.

---

## 4. Implementation notes for Option A

Scope: rework `PlaybackControlsView` into hero + tray; add the sleep control to the tray; host the
countdown pill in `RadioPlayerView`'s existing status slot; extend `TVRadioPlayerView.controlStack()`
to a labeled focusable tray. Follows repo conventions (value types, `@Bindable var viewModel`,
`Text(..., bundle: .module)`, `#if os(Android)` platform splits, no restating comments).

### 4.1 View structure — `PlaybackControlsView`

Replace the single `HStack(spacing: 36)` with a `VStack` of two tiers:

```swift
var body: some View {
  VStack(spacing: tierSpacing) {
    playButton                 // hero tier
    utilityTray                // secondary tier
  }
  #if os(macOS)
    .buttonStyle(.plain)
  #endif
  #if !os(Android)
    .shareSheet(isPresented: $showShareSheet, text: { viewModel.shareMessage },
                imageData: { await viewModel.shareImageData() })
  #endif
}
```

- **`playButton`** — lift the existing hero button out of the `HStack` unchanged (ProgressView while
  `viewModel.isLoading`, `pause.circle.fill`/`play.circle.fill` on Apple, `AndroidIcon(.pause/.play)`
  on Android), only bumping the size constant (below). Keep its accessibility label.
- **`utilityTray`** — an `HStack` of three equal `secondaryControl(...)` buttons distributed with
  fixed spacing (portrait/tablet) so the trio stays centered:

  ```swift
  private var utilityTray: some View {
    HStack(spacing: traySpacing) {
      shareControl
      sleepControl
      donateControl
    }
  }
  ```

  Order is Share · Sleep · Donate: Sleep (a session/transport-adjacent action) sits centrally
  between the two "outbound" actions.

- **Ghost-circle secondary style.** Generalize the current `secondaryIcon(_:android:tint:)` to render
  the glyph inside a subtle circular background so the three read as deliberate peer buttons rather
  than bare glyphs:

  ```swift
  private func secondaryControl<Label: View>(tint: Color, @ViewBuilder label: () -> Label) -> some View {
    label()
      .frame(width: secondaryFrame, height: secondaryFrame)   // ≥44pt hit target preserved
      .background(Circle().fill(secondaryControlColor.opacity(0.12)))
  }
  ```

  Keep the existing `secondaryIcon` glyph normalization (fixed `secondaryGlyphSize` in a square
  frame) inside the label, and keep `secondaryControlColor` (the Android tint workaround,
  `PlaybackControlsView.swift:40-47`) for glyph + background tint. Retain the disabled-share
  treatment (`.opacity(0.5)` + `.disabled(!viewModel.canShare)`) and the donate `Link`-or-hidden-
  placeholder pattern (`:97-111`) verbatim — only their wrapper changes.

- **Sleep control** — new tray member:

  ```swift
  Button { showSleepTimerSheet = true } label: {
    secondaryControl(tint: secondaryControlColor) {
      sleepGlyph          // moon.zzz / moon.zzz.fill via secondaryIcon
    }
  }
  .accessibilityLabel(Text(viewModel.isSleepTimerActive ? "Sleep timer active" : "Set sleep timer",
                            bundle: .module))
  ```

  A `.sheet` (works on all platforms per the sleep-timer plan) presents the preset picker. The
  countdown pill itself lives in `RadioPlayerView` (4.3), not here, so the tray height is stable
  whether or not the timer is running.

### 4.2 Sizing / spacing constants (per idiom)

Centralize as computed properties so phone/tablet/TV differ without duplicating layout. Reuse the
`PlatformEnvironment.isPad` flag the iPad plan adds (`IPAD-LAYOUT-design.md`) — no new idiom check.

| Constant             | Phone | Tablet (`isPad`) | Notes |
|----------------------|-------|------------------|-------|
| `heroSize`           | 72    | 84               | bump from 68 for a touch more presence |
| `secondaryFrame`     | 48    | 60               | hit target ≥44pt on touch (keep 44 floor) |
| `secondaryGlyphSize` | 24    | 30               | up from 22 so tray glyphs don't look faint under a bigger hero |
| `traySpacing`        | 28    | 44               | fixed spacing keeps the trio centered |
| `tierSpacing`        | 20    | 28               | gap between hero and tray |

Landscape (compact height): reuse the phone column but keep `tierSpacing` tight (≈16) so hero + tray
fit the right column's vertical budget between the existing `Spacer()`s
(`RadioPlayerView.swift:135-143`). Detect via the same width/height signal the app already uses; do
**not** grow the hero in landscape.

### 4.3 Countdown pill placement — `RadioPlayerView`

Host the pill in the existing reserved status slot so there is no layout jump. `liveIndicator()`
(`:247-266`) already renders either the "Back to live" pill or a `Color.clear.frame(height: 32)`
placeholder. Generalize that slot to show, in priority order: the back-to-live pill (browsing) →
the sleep countdown pill (`viewModel.isSleepTimerActive`) → the clear placeholder. Style the sleep
pill exactly like `backToLiveLabel` (`:272-285`): capsule, moon glyph + `MM:SS` + `✕`. Drive the
ticking label with `TimelineView(.periodic(from:by:))` at 1s cadence (per the sleep-timer plan,
A3) — no `Timer`, no per-second observable writes. Because the slot is shared by both branches and
already present in `portraitView()` and `landscapeView()`, one helper covers both and keeps the
`if/else` layout structure intact (the layout-structure caveat in `SLEEP-TIMER-design.md` A4).

### 4.4 Icon choices (SF Symbol + Material)

| Action | SF Symbol (Apple) | Material (`AndroidIcon`) | Status |
|--------|-------------------|--------------------------|--------|
| Share  | `square.and.arrow.up` | `.share` → `Icons.Filled.Share` | existing |
| Play   | `play.circle.fill` | `.play` → `Icons.Filled.PlayCircle` | existing |
| Pause  | `pause.circle.fill` | `.pause` → `Icons.Filled.PauseCircle` | existing |
| Donate | `heart.circle` | `.favorite` → `Icons.Filled.FavoriteBorder` | existing |
| Sleep (idle)   | `moon.zzz` | **new** `.bedtime` → `Icons.Filled.Bedtime` | add case |
| Sleep (active) | `moon.zzz.fill` | `.bedtime` → `Icons.Filled.Bedtime` (already filled) | active toggles SF fill |

Add one `MaterialSymbol` case `.bedtime` (with `iconKey "bedtime"`) to the enum
(`AndroidIcon.swift:17-38`) and one `case "bedtime": Icons.Filled.Bedtime` mapping in
`MaterialIconComposer.Compose` (`:76-90`). `Icons.Filled.Bedtime` is in `material-icons-extended`
(already on the classpath). Fallbacks if `Bedtime` is unavailable in the pinned artifact:
`Icons.Filled.NightsStay` or `Icons.Filled.Timer` — verify at build. `moon.zzz`/`moon.zzz.fill` are
standard SF Symbols on all Apple targets.

### 4.5 TV focus wiring — `TVRadioPlayerView`

TV keeps the hero via `playButton()` unchanged (default focus, `TVGlyphButtonStyle` on tvOS;
`.plain` + `.focused` + `.scaleEffect` on Android — `:304-341`). Extend `controlStack()`
(`:71-99`) so the utility tray becomes a **row of labeled focusable pills** *below* the play
button, inside the existing focus grouping:

- **tvOS:** add an `HStack` of `Share / Sleep / Donate` pills styled with the existing
  `TVPillButtonStyle` (`:448-461`), placed under `playButton()` inside the current
  `VStack { ... }.focusSection()`. Keep `playButton()`'s `.defaultFocus($playFocused, true)` so play
  is the initial focus; D-pad down from play reaches the tray, left/right moves across the three
  pills. The full-width `HStack { Spacer(); ...; Spacer() }.focusSection()` wrapper (and its
  up/down routing contract, `:66-84`) stays.
- **Android TV:** add the same three pills using the proven `backToLiveButtonAndroid()` pattern
  (`:373-392`) — `.buttonStyle(.plain)` + per-button `@FocusState` + `.focused` + `.scaleEffect` +
  capsule background — since `TVPillButtonStyle`/`@Environment(\.isFocused)` are tvOS-only. Each pill
  needs its own `@FocusState` (declared like `playFocused`/`backToLiveFocused`, internal not private,
  `:12-17`, for bridge compatibility). Seed initial focus on play via the existing `.task { playFocused = true }`.

The sleep preset sheet and the countdown pill's cancel/extend must be remote-reachable and
dismissible (sleep-timer plan A4/TV): present the picker as a focusable `.sheet`, and on tvOS give
the pill's `✕`/extend their own `@FocusState`.

### 4.6 State nuances (all preserved)

- **Loading:** hero shows `ProgressView().tint(.orange)` while `viewModel.isLoading` (unchanged).
- **Share disabled:** `.disabled(!viewModel.canShare)` + 0.5 glyph opacity (unchanged; now inside the
  ghost circle).
- **Donate absent:** the `Link`-or-hidden-placeholder branch (`:97-111`) stays, so the tray keeps a
  stable three-slot width even when no donation URL exists.
- **Sleep idle vs active:** idle = `moon.zzz` ghost circle opening the preset sheet; active =
  `moon.zzz.fill` + countdown pill in the status slot (4.3) with cancel/extend, driven by
  `viewModel.isSleepTimerActive` / `viewModel.sleepTimerFiresAt`.

### 4.7 Accessibility

Keep `Text(..., bundle: .module)` labels for all four; add the sleep label (idle vs. active, and
"%@ remaining" for the pill per the sleep-timer plan A5). Ghost-circle wrappers keep ≥44pt touch
targets. The three tray buttons remain distinct `Button`s (free VoiceOver traits); do not combine
them into one accessibility element.

---

## 5. Files this proposal would touch (when implemented)

| File | Change |
|------|--------|
| `Sources/Maxi80/PlaybackControlsView.swift` | two-tier hero + ghost-circle utility tray; add sleep control; per-idiom size table |
| `Sources/Maxi80/RadioPlayerView.swift` | generalize the status slot (`liveIndicator()`) to also host the sleep countdown pill |
| `Sources/Maxi80/TV/TVRadioPlayerView.swift` | labeled focusable pill tray under the play hero in `controlStack()` (tvOS + Android TV) |
| `Sources/Maxi80/AndroidIcon.swift` | add `MaterialSymbol.bedtime` + composer mapping |
| `Sources/Maxi80Services/PlatformEnvironment.swift` | reuse `isPad` (added by the iPad plan) for the size table — no new flag if that lands first |
| `Sources/Maxi80/Resources/Localizable.xcstrings` | TV tray button labels ("Share"/"Sleep"/"Donate") + sleep accessibility strings (shared with sleep-timer plan) |

Coordinate ordering with `SLEEP-TIMER-design.md` (same three UI files) and `IPAD-LAYOUT-design.md`
(shares `TVRadioPlayerView`/`PlatformEnvironment`) to avoid merge conflicts.
