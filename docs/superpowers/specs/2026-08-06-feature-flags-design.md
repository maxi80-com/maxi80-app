# Runtime feature flags via the station API

**Issue:** [maxi80-app#72](https://github.com/maxi80-com/maxi80-app/issues/72) — toggle features at runtime, without an app update, using the `/station` call the app already makes at launch.

## Goal

Ship a flag system with no third-party SDK: the backend adds an optional `features` object to the
`/station` response, the client reads it into an observable store, and views ask
`isEnabled(_:)` synchronously. Absent/failed/garbage flag data always degrades to compiled-in
defaults, so a backend problem can never remove a shipped feature by accident.

## Contract

```json
{
  "name": "Maxi 80",
  "streamUrl": "...",
  "features": { "anniversary_cover": true, "sleep_timer": true }
}
```

- `features` is optional. Omitted, `null`, or `{}` → compiled-in defaults.
- Values are booleans; keys are `lower_snake_case`.
- Unknown keys are ignored (forward-compatible: the backend can enable a flag before the client
  build that reads it exists).

## Design

### `Station.features` (`Maxi80Model`)

One new field, `public let features: [String: Bool]?`, with `nil` as the `init` default so every
existing construction site keeps compiling.

`Station` gains a hand-written `init(from:)`. The synthesized one would fail the **whole** decode on
a malformed `features` value (`"anniversary_cover": "yes"`), which would drop the app to the
hardcoded fallback station — losing the stream URL and descriptions over a flag typo. The manual
decoder instead does `try? decodeIfPresent` for `features` only, so bad flag data degrades to `nil`
while the rest of the station still decodes. `encode(to:)` stays synthesized.

`Maxi80Model` is native+bridging mode, so real Swift `Codable` works here; the decode itself still
happens in the native coordinator.

### `FeatureFlags` (`Maxi80`, native Fuse)

```swift
@MainActor @Observable
public final class FeatureFlags {
  public static let shared = FeatureFlags()

  public enum Flag: String, CaseIterable, Sendable {
    case anniversaryCover = "anniversary_cover"
    case sleepTimer = "sleep_timer"
  }

  public func isEnabled(_ flag: Flag) -> Bool  // overrides[raw] ?? defaults[flag] ?? true
  public func update(from features: [String: Bool]?)
}
```

Lives in the native module because SwiftUI views read it and it must be `@Observable` — reading
`isEnabled(_:)` in a `body` registers a dependency, so the UI re-renders when the station response
lands mid-launch. It never crosses the JNI boundary; only the primitive `[String: Bool]` on
`Station` does.

`update(from:)` **replaces** the whole override set rather than merging. Flags are fetched fresh each
launch with no persistence, so a wholesale replace makes the state a pure function of the last
station load — no stale override can survive a response that stopped mentioning it.

Compiled-in defaults:

| Flag | Default | Why |
|------|---------|-----|
| `anniversary_cover` | `false` | Off until the backend turns it on for the celebration window (consumer arrives with #71). |
| `sleep_timer` | `true` | Already shipped; the flag exists as a kill switch, so it must default on. |

An unrecognized flag read (`defaults` missing an entry) returns `true` — fail-open, matching
"a flag system must never be the reason a feature disappears".

### Injection

`RadioPlayerCoordinator.init` takes `featureFlags: FeatureFlags = .shared`. Production gets the
process-wide instance through the default; tests inject a fresh one, so no test mutates global state
or depends on ordering. This keeps the issue's singleton ergonomics for views (which are too deep to
thread a dependency through) while respecting the repo's constructor-injection rule for the
coordinator.

### Application point

At the end of `loadStation()`, after the 3-tier fallback has settled on a `Station`:

```swift
featureFlags.update(from: station?.features)
```

Applying it to the *resolved* station — not just the fresh API response — means the cached-station
path carries the last-known flags forward, and the hardcoded-fallback path (`features == nil`) lands
on defaults.

### First consumer

`PlaybackControlsView.sleepControl` gates on `.sleepTimer`, and `RadioPlayerViewModel` exposes
`isSleepTimerAvailable` so the gate is unit-testable without rendering. This gives the system a real
end-to-end consumer in this PR; `anniversary_cover` is declared but unconsumed until #71 adds the
asset.

## Out of scope

- The 25th-anniversary cover asset and its `PlaceholderCover` entry (#71).
- Local debug overrides (`UserDefaults` / debug menu) — follow-up.
- Persistence/caching of flags across launches — the station call is the app's first request.
