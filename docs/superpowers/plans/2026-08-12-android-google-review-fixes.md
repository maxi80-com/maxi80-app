# Android Google Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address the three issues flagged by Google's automated app review: edge-to-edge display compliance for Android 15+, deprecated window APIs, and low R8 optimization rates.

**Architecture:** All three fixes are Android-only. Issue 1 & 2 are already substantially addressed in `Android/app/src/main/kotlin/Main.kt` (which calls `enableEdgeToEdge()` and uses `SystemBarStyle`). The deprecated APIs reported by Google come from third-party libraries (media3, activity-compose), not from app code — they are false alarms. The R8 issue stems from overly-broad `-keep` rules in `Android/app/proguard-rules.pro` that block shrinking and obfuscation of classes the app doesn't actually use.

**Tech Stack:** Kotlin (hand-authored), Gradle/Kotlin DSL, Android R8/ProGuard, androidx.activity 1.x, media3 1.9.4, Skip framework transpiler.

## Global Constraints

- **Android only.** Do not touch any Swift/SwiftUI code or any file that compiles for iOS.
- The files you may edit are: `Android/app/src/main/kotlin/Main.kt`, `Android/app/proguard-rules.pro`, `Android/app/src/main/res/values/themes.xml`, `Android/app/src/main/res/values-v31/themes.xml`.
- The `skip.yml` files are source-of-truth for Gradle dependencies; edit them to change library versions (don't edit generated `.build/` files).
- Keep `maxi80.services.**`, `maxi80.module.**`, `skip.**`, `tools.skip.**`, and JNI-related keeps — they are load-bearing.
- Build the release APK to verify R8 changes: `cd Android && ./gradlew assembleRelease 2>&1 | tail -30`
- Build the debug APK to verify edge-to-edge: `cd Android && ./gradlew assembleDebug 2>&1 | tail -30`
- **Do not run `rm -rf .build`** — use `make clean` if a clean build is needed.

---

## Scope Assessment

The three Google issues map to three largely independent changes:

1. **Edge-to-edge + deprecated window APIs** (Issues 1 & 2) — these are the same root cause: how the activity configures the system bars. App code already calls `enableEdgeToEdge()` correctly. The deprecated calls are in library code (media3, activity-compose). Need to verify the theme doesn't re-introduce deprecated status/nav bar colors, and update theme to use `Theme.Material3` base for SDK 35 compliance.
2. **R8 optimization** (Issue 3) — the `-keep class androidx.media3.** { *; }` rule in `proguard-rules.pro` keeps the entire media3 library verbatim, blocking 100% of R8's work on its ~2 MB bytecode. Fix: replace with targeted keeps for only the classes the JNI bridge actually touches by name.

These are two independent tasks.

---

## Task 1: Verify and harden edge-to-edge + system bar configuration

**Context:**
- `enableEdgeToEdge()` is already called in `MainActivity.onCreate()` (line 62, `Main.kt`).
- `SyncSystemBarsWithTheme()` (lines 144–162, `Main.kt`) sets transparent status/nav bars via `SystemBarStyle` — the modern API.
- The deprecated APIs reported by Google (`Window.setStatusBarColor`, `Window.setNavigationBarColor`, `LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES`) trace back to **library internals** (`androidx.activity.z.b`, `androidx.activity.x.a`), not app code. These are library-level deprecations that Google's scanner attributes to your app; you can't fix them by changing app code, only by updating the library.
- The theme in `themes.xml` uses `Theme.AppCompat.DayNight.NoActionBar` — an older AppCompat base. For SDK 35 edge-to-edge, the recommended base is a Material3 theme; however, changing the theme base may cause visual regressions, so the safer fix is to verify no theme item re-sets status/nav bar colors.
- `androidx.core:core-ktx` version is `1.15.0` (declared in `Sources/Maxi80Services/Skip/skip.yml`). Updating this to 1.16.0+ would update the `androidx.activity` transitive dependency which contains the deprecated `z.b`/`x.a` shims.

**What needs to change:**
1. Bump `androidx.core:core-ktx` from `1.15.0` to `1.16.0` in `Sources/Maxi80Services/Skip/skip.yml` to pull in a newer `androidx.activity` that has removed the deprecated shims.
2. Confirm neither `themes.xml` file sets `statusBarColor` or `navigationBarColor` (they don't currently — this is a confirmation step).
3. Add `<item name="android:windowOptOutEdgeToEdgeEnforcement">false</item>` to the SDK 35+ theme override so the app explicitly opts in rather than relying on the default, making the intent clear to Google's scanner.

**Files:**
- Modify: `Sources/Maxi80Services/Skip/skip.yml`
- Modify: `Android/app/src/main/res/values-v31/themes.xml` (add SDK 35 override file)
- Create: `Android/app/src/main/res/values-v35/themes.xml`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: updated `core-ktx` version used in Task 2's build verification

- [ ] **Step 1: Confirm themes.xml doesn't set deprecated bar colors**

Read `Android/app/src/main/res/values/themes.xml` and `Android/app/src/main/res/values-v31/themes.xml`. Confirm neither contains `android:statusBarColor` or `android:navigationBarColor`. Both files currently only set `android:windowBackground` and `android:windowSplashScreenBackground` — that is correct. No change needed to these files.

Expected: neither file contains `statusBarColor` or `navigationBarColor`.

- [ ] **Step 2: Create a values-v35 theme override to declare edge-to-edge opt-in**

Create `Android/app/src/main/res/values-v35/themes.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Android 15 (API 35) enforces edge-to-edge by default. We call enableEdgeToEdge()
         in MainActivity.onCreate() and set transparent bar styles via SyncSystemBarsWithTheme(),
         so we opt in explicitly here rather than relying on the platform default. -->
    <style name="Theme.Maxi80" parent="Theme.AppCompat.DayNight.NoActionBar">
        <item name="android:windowBackground">@android:color/black</item>
        <item name="android:windowSplashScreenBackground">@android:color/black</item>
        <item name="android:windowOptOutEdgeToEdgeEnforcement">false</item>
    </style>
</resources>
```

- [ ] **Step 3: Bump core-ktx to 1.16.0 in skip.yml**

In `Sources/Maxi80Services/Skip/skip.yml`, change the `core-ktx` version:

Before:
```yaml
        - 'implementation("androidx.core:core-ktx:1.15.0")'
```

After:
```yaml
        - 'implementation("androidx.core:core-ktx:1.16.0")'
```

- [ ] **Step 4: Verify the debug build still compiles**

```bash
cd /Users/sst/code/maxi80/maxi80-2026/Maxi80/Android && ./gradlew assembleDebug 2>&1 | tail -40
```

Expected: `BUILD SUCCESSFUL`. If there is a version conflict between `core-ktx:1.16.0` and another dependency, check `./gradlew dependencies --configuration releaseRuntimeClasspath 2>&1 | grep androidx.core` and resolve.

- [ ] **Step 5: Commit**

```bash
git add Sources/Maxi80Services/Skip/skip.yml \
        Android/app/src/main/res/values-v35/themes.xml
git commit -m "fix(android): declare edge-to-edge opt-in for SDK 35 and bump core-ktx to 1.16.0"
```

---

## Task 2: Tighten R8 keep rules to raise optimization/obfuscation/shrinking rates

**Context:**
The current `Android/app/proguard-rules.pro` contains:

```
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
```

This blanket rule instructs R8 to keep the **entire media3 library** (exoplayer, session, ui, extractor, common — roughly 2 MB of bytecode) exactly as-is. R8 cannot rename, inline, or remove any of it. This alone likely explains the low optimization/obfuscation/shrinking rates Google reported.

**Why the broad keep was added:** The comment in the existing rule explains it: "the by-name bridge reflects on the CONCRETE runtime type returned by `SharedAudioPlayer.shared()`". The JNI bridge in the native Swift side looks up classes by name (e.g. `androidx.media3.exoplayer.ExoPlayerImpl`). However, media3 ships its own ProGuard consumer rules (inside the `.aar`) that already keep everything media3 needs for its own reflection. The overly broad app-level rule was added out of caution but is duplicating what media3's own rules already do.

**What needs to change:**
Replace the blanket `-keep class androidx.media3.** { *; }` with targeted keeps for only the specific class(es) the JNI bridge accesses by name, and then rely on media3's own consumer ProGuard rules for everything else.

The Swift bridge calls `SharedAudioPlayer.shared()` which returns the ExoPlayer instance. The concrete type is `ExoPlayerImpl`. The relevant lookup is in `Sources/Maxi80Services/Platform/Android/AudioStreamPlayer.kt` (or the transpiled Kotlin). We need to keep only that class.

Additionally, the current rule `-keeppackagenames **` prevents R8 from flattening package structure — this alone contributes to low obfuscation rate. Remove it (or scope it to only the packages that need it: `maxi80.**`, `skip.**`, `tools.skip.**`).

**Files:**
- Modify: `Android/app/proguard-rules.pro`

**Interfaces:**
- Consumes: nothing from other tasks (independent)
- Produces: optimized release APK

- [ ] **Step 1: Find the exact media3 class the JNI bridge touches by name**

```bash
grep -r "ExoPlayer\|media3\|androidx\.media3" \
  /Users/sst/code/maxi80/maxi80-2026/Maxi80/Sources/Maxi80Services/ \
  --include="*.kt" --include="*.swift" -l
```

Then for each file found:
```bash
grep "ExoPlayer\|media3\." <file>
```

This tells you which class names the bridge uses. The expected finding is that the bridge accesses `androidx.media3.exoplayer.ExoPlayer` (the interface, not `ExoPlayerImpl`) via the `SharedAudioPlayer` singleton, and that the `Maxi80MediaService` Kotlin file references `ExoPlayer` directly — but `Maxi80MediaService` is a Kotlin file R8 can trace statically, so it doesn't need a `-keep` for that reference.

- [ ] **Step 2: Verify media3's own consumer rules already cover what's needed**

```bash
cd /Users/sst/code/maxi80/maxi80-2026/Maxi80/Android
./gradlew :app:printConfiguration --variant release 2>&1 | grep -A2 "media3" | head -60
```

Alternatively, inspect the AAR's embedded rules:
```bash
find ~/.gradle/caches -name "*.aar" -path "*media3*exoplayer*" 2>/dev/null | head -3 | xargs -I{} unzip -p {} proguard.txt 2>/dev/null | head -40
```

Expected: media3's own rules keep `ExoPlayer`, `MediaController`, `MediaSession`, and related public API. If they do, the app-level blanket rule is entirely redundant.

- [ ] **Step 3: Replace the blanket media3 keep with a targeted one**

Edit `Android/app/proguard-rules.pro`. Replace:

```
-keeppackagenames **
-keep class skip.** { *; }
-keep class tools.skip.** { *; }
-keep class kotlin.jvm.functions.** {*;}
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
-keep class * implements com.sun.jna.** { *; }
-keep class * implements skip.bridge.** { *; }
-keep class **._ModuleBundleAccessor_* { *; }
-keep class maxi80.module.** { *; }
# Transpiled Maxi80Services classes are reached only via JNI-by-name from the native Swift bridge,
# so R8 can't see the reference and would strip/rename them — causing ClassNotFoundException at launch.
-keep class maxi80.services.** { *; }

# Media3 (ExoPlayer) surface used by the now-playing writeback. Deliberately broad (whole
# androidx.media3.**) rather than relying on Media3's own consumer ProGuard rules: the by-name
# bridge reflects on the CONCRETE runtime type returned by SharedAudioPlayer.shared() — an
# ExoPlayerImpl whose implementation lives in androidx.media3.exoplayer, not .common.
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
```

With:

```
# Skip framework packages must be kept verbatim — JNI looks them up by name.
-keeppackagenames maxi80.**
-keeppackagenames skip.**
-keeppackagenames tools.skip.**
-keep class skip.** { *; }
-keep class tools.skip.** { *; }
-keep class kotlin.jvm.functions.** { *; }
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
-keep class * implements com.sun.jna.** { *; }
-keep class * implements skip.bridge.** { *; }
-keep class **._ModuleBundleAccessor_* { *; }
-keep class maxi80.module.** { *; }
# Transpiled Maxi80Services classes are reached only via JNI-by-name from the native Swift bridge.
-keep class maxi80.services.** { *; }

# ExoPlayerImpl is the concrete class the JNI bridge receives from SharedAudioPlayer.shared().
# Media3's own consumer ProGuard rules keep the rest of the public API.
-keep class androidx.media3.exoplayer.ExoPlayerImpl { *; }
-dontwarn androidx.media3.**
```

Key changes:
- `-keeppackagenames **` → scoped to only `maxi80.**`, `skip.**`, `tools.skip.**` (lets R8 flatten all other packages)
- Blanket `-keep class androidx.media3.** { *; }` → single targeted keep for `ExoPlayerImpl`

- [ ] **Step 4: Build a release APK and check it doesn't crash at launch**

```bash
cd /Users/sst/code/maxi80/maxi80-2026/Maxi80/Android && ./gradlew assembleRelease 2>&1 | tail -40
```

Expected: `BUILD SUCCESSFUL`. If R8 reports a missing class warning for a media3 class, add a targeted keep for that class (not a blanket keep) and re-run.

- [ ] **Step 5: Install the release APK on an emulator and verify the app launches**

```bash
# Start an emulator if not running:
# emulator -avd <avd-name> &

# Install:
adb install -r Android/app/build/outputs/apk/release/app-release.apk

# Launch:
adb shell am start -n maxi80.module/.MainActivity

# Check logcat for crash signals:
adb logcat -s "maxi80.module" "AndroidRuntime" "ExoPlayerImpl" --line-count 40
```

Expected: app launches, plays audio, no `ClassNotFoundException` or `NoSuchMethodException` in logcat. If a `ClassNotFoundException` appears for an `androidx.media3.*` class, add a `-keep class <that-class> { *; }` line.

- [ ] **Step 6: Check shrinking/obfuscation improvement with R8 mapping output**

```bash
# The mapping file is written during release build:
wc -l Android/app/build/outputs/mapping/release/mapping.txt
head -100 Android/app/build/outputs/mapping/release/mapping.txt
```

Expected: the mapping file now contains many more renamed class/method entries than before. If `androidx.media3` entries are mostly absent, that means R8 successfully processed them using media3's own keep rules.

- [ ] **Step 7: Commit**

```bash
git add Android/app/proguard-rules.pro
git commit -m "fix(android): tighten R8 keeps — scope keeppackagenames, replace blanket media3 keep with targeted ExoPlayerImpl keep"
```

---

## Self-Review

**Spec coverage:**

| Google Issue | Plan Task | Coverage |
|---|---|---|
| 1. Edge-to-edge for SDK 35 | Task 1, Steps 1–3 | `values-v35/themes.xml` opt-in + `enableEdgeToEdge()` already in code |
| 2. Deprecated `setStatusBarColor`, `setNavigationBarColor`, `LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES` | Task 1, Step 3 | Bumping `core-ktx` updates the `androidx.activity` transitive dep that contains these shims |
| 3. Low R8 optimization/obfuscation/shrinking | Task 2 | Scoped `keeppackagenames`, targeted `media3` keep |

**Scope note on Issues 1 & 2:** The deprecated API calls trace to `androidx.activity.z.b` and `androidx.activity.x.a` — these are ProGuard-obfuscated names for internal ActivityCompat shim methods, not app code. The app's `Main.kt` already uses the modern `enableEdgeToEdge()` + `SystemBarStyle` API correctly. Updating `core-ktx` (which pulls in `androidx.activity:activity-ktx:1.10+`) removes the legacy shim path from the dependency tree.

**Placeholder scan:** No TBDs or "implement later" present.

**Type consistency:** No cross-task type references.
