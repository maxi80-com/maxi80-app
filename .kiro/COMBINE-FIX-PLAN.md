# Fix: Remove Combine Dependency for Android Compatibility

## Context

After fixing the Codable bridge errors, `skip app launch --android` now fails with:
```
error: no such module 'Combine'
```

`Combine` is an Apple-only framework — it doesn't exist on Android/Linux. The Skip framework provides `@Observable` (via SkipFuse/Observation) as the cross-platform alternative.

## Root Cause

`RadioPlayerCoordinator` uses `ObservableObject` + `@Published` (Combine), and `RadioPlayerViewModel` subscribes via Combine's `sink`/`AnyCancellable`. Neither of these are available on Android.

## Approach: Migrate to @Observable (Observation framework)

Per Skip docs and the user's CLAUDE.md preferences ("`@Observable` classes, Observation framework, not Combine `ObservableObject`"), convert both classes to use the Observation framework.

Since both `RadioPlayerCoordinator` and `RadioPlayerViewModel` are `@MainActor`, and the ViewModel just mirrors coordinator state, the ViewModel can directly read from the coordinator — SwiftUI's `@Observable` tracking handles reactivity automatically via `withObservationTracking`.

## Changes

### 1. Convert `RadioPlayerCoordinator` to `@Observable`

**File:** `Sources/Maxi80/RadioPlayerCoordinator.swift`

- Remove `ObservableObject` conformance
- Add `@Observable` macro
- Remove all `@Published` property wrappers (just plain `public var`)
- Mark private dependencies with `@ObservationIgnored`

### 2. Rewrite `RadioPlayerViewModel` without Combine

**File:** `Sources/Maxi80/RadioPlayerViewModel.swift`

- Remove `import Combine`
- Remove `Set<AnyCancellable>`
- Remove `observeCoordinator()` and all `.sink` subscriptions
- Instead, expose computed properties that delegate to the coordinator
- Keep action methods as pass-through to coordinator
- The `@Observable` macro + SwiftUI's observation tracking means views automatically re-render when coordinator properties change

### 3. Update any other files importing Combine

Check for any other `import Combine` in the native module.

## Verification

1. `swift build` — macOS build passes (no Combine import needed)
2. `skip app launch --android` — no more "no such module 'Combine'" error
3. `swift test` — all tests pass
