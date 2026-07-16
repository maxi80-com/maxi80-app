# Task 1 Spike Report — MediaSessionService Transpilation

**Date:** 2026-07-16
**Decision: SERVICE_LANGUAGE = kotlin**

---

## What was built

A throwaway probe file `Sources/Maxi80Services/Platform/Android/SpikeMediaService.swift` was created, containing a `MediaSessionService` subclass gated under `#if SKIP` / `#if !SKIP_BRIDGE`. It overrides `onCreate()`, `onGetSession(controllerInfo:)`, and `onDestroy()` — the three lifecycle methods a media3 service must implement. The `Sources/Maxi80Services/Skip/skip.yml` media3 dependency was bumped from 1.2.1 to 1.9.4. The `<service>` entry was added to `Android/app/src/main/AndroidManifest.xml` using the confirmed package path `maxi80.services.SpikeMediaService`.

---

## Confirmed transpiled package name

**`maxi80.services`**

Confirmed by locating the generated Kotlin output at:
`.build/index-build/plugins/outputs/maxi80/Maxi80Services/destination/skipstone/Maxi80Services/src/main/kotlin/maxi80/services/`

The `package maxi80.services` declaration was verified in the top of the generated `SpikeMediaService.kt` and other Maxi80Services generated files (e.g. `ExoPlayerStreamPlayer.kt`). The brief's guess of `maxi80.services` was correct.

---

## Generated Kotlin

Skip transpiled the Swift correctly into this Kotlin (at `.build/.../maxi80/services/SpikeMediaService.kt`):

```kotlin
package maxi80.services

import skip.lib.*
import skip.foundation.*
import android.content.Intent
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import skip.foundation.ProcessInfo

internal open class SpikeMediaService: MediaSessionService {
    private var session: MediaSession? = null
        get() = field.sref({ this.session = it })
        set(newValue) { field = newValue.sref() }

    override fun onCreate() {
        super.onCreate()
        val ctx = ProcessInfo.processInfo.androidContext.sref()
        val player = ExoPlayer.Builder(ctx).build()
        session = MediaSession.Builder(ctx, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session.sref()

    override fun onDestroy() {
        session?.getPlayer()?.release()
        session?.release()
        session = null
        super.onDestroy()
    }
}
```

---

## Three-level gate results

### Gate 1: `swift build`
**PASSED** — `ok (build complete)`. iOS/macOS Swift branches unaffected by the #if SKIP-gated spike code.

### Gate 2: `rm -rf .build && skip android build`
**PASSED** — `Build complete! (25.52s)`. The Swift-for-Android toolchain compiled successfully and the transpiler emitted `SpikeMediaService.kt`.

### Gate 3: `JAVA_HOME=... /opt/homebrew/bin/gradle -p Android :app:compileDebugKotlin --console=plain`
**FAILED** — `BUILD FAILED in 3s`

Exact error:
```
> Task :skipstone:Maxi80Services:compileDebugKotlin FAILED
e: file:///.../maxi80/services/SpikeMediaService.kt:15:40 This type has a constructor, so it must be initialized here.
```

The failure is at line 15 of the generated Kotlin: `internal open class SpikeMediaService: MediaSessionService {`

---

## Root cause

Skip's transpiler emits class inheritance as `class Foo: Bar` (no parentheses). In Kotlin, this is valid when `Bar` is an **interface**, because interfaces have no constructor. But `MediaSessionService` is an **abstract class** (it extends `android.app.Service` through multiple levels). Kotlin requires `class Foo: Bar()` (with parentheses invoking the constructor) when inheriting from a class.

Skip knows this distinction for some cases (e.g. `BroadcastReceiver` subclasses — which also work), but the code generation for `MediaSessionService` fails: the transpiler does not emit the `()` constructor call.

The existing `BecomingNoisyReceiver: BroadcastReceiver` in `ExoPlayerStreamPlayer.swift` passes because `BroadcastReceiver` is treated as a class in the same way, but it appears Skip handles that specific case differently (or `BroadcastReceiver()` receives a no-arg constructor call that Kotlin allows). A deeper investigation of why `BroadcastReceiver` works while `MediaSessionService` does not is out of scope — the spike decision is made.

---

## Decision

**SERVICE_LANGUAGE = kotlin**

The `MediaSessionService` subclass (and any Service subclass) must be authored as a raw `.kt` file placed in `Sources/Maxi80Services/Skip/` (or an equivalent location that Skip copies verbatim to the Kotlin source tree). The Swift `#if SKIP` approach does not work for framework-instantiated Android Service subclasses due to the constructor-call generation gap.

Tasks 5–6 should author the `MediaSessionService` subclass directly as a `.kt` file.

---

## Revert confirmation

The following files were reverted/removed after the spike:
- `Sources/Maxi80Services/Platform/Android/SpikeMediaService.swift` — removed (`rm`)
- `Sources/Maxi80Services/Skip/skip.yml` — reverted to media3 1.2.1 (`git checkout`)
- `Android/app/src/main/AndroidManifest.xml` — reverted to original (`git checkout`)

`git status` after revert shows no spike-related tracked changes. Only pre-existing untracked/modified files remain (`Darwin/Maxi80.xcconfig` modified, unrelated untracked files).
