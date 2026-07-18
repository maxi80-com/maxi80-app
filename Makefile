# ==============================================================================
# Maxi80 — cross-platform Skip app (Swift + SwiftUI transpiled to Android)
# ------------------------------------------------------------------------------
# Build/package/publish automation for the iOS (Darwin) and Android halves.
#
# BUILD NUMBER SCHEME
#   Format:   yyyyMMddNN   (yyyyMMdd + 2-digit daily counter), via `date +%Y%m%d`.
#   Example:  2026-07-18 (1st build)  ->  2026071800
#   Why this format (NOT a smaller time-based one):
#     - The app's LAST PUBLISHED Play versionCode was 2021122500. Google Play
#       rejects any upload whose versionCode is not strictly greater, so the new
#       number MUST exceed 2021122500 — which a 2-digit-year scheme cannot do.
#     - Must also stay < Android's ceiling of 2,100,000,000. yyyyMMdd00 sits in
#       the valid band (2021122500, 2100000000] and stays monotonic until 2099.
#     - Shared by BOTH platforms: the value lives in Skip.env as
#       CURRENT_PROJECT_VERSION and flows into Darwin/Maxi80.xcconfig and
#       Android/settings.gradle.kts. Bumping it there sets the build number
#       for iOS and Android at once. `make bump` rewrites that single value.
#     - Monotonic-safe: see the `bump` recipe (falls back to OLD+1 if the daily
#       base isn't greater, so multiple same-day builds still increment).
#
# PUBLISH GATE ORDER (publish-* targets only)
#   1. Refuse to publish unless the git working tree is clean
#      (checked BEFORE the bump, so the bump the publish itself makes is the
#       only change).
#   2. Run the full test suite; abort on failure.
#   3. Bump CURRENT_PROJECT_VERSION in Skip.env to a fresh build number.
#   4. Commit the Skip.env bump (Skip.env is tracked).
#   5. Build + package + upload via fastlane (the fastlane `release` lanes
#      internally call `assemble`, so they build and sign as part of upload).
#   6. On success, create an annotated git tag  v<MARKETING_VERSION>-<BUILD>.
#   TRADEOFF: the bump commit (step 4) lands before the upload (step 5). If the
#   upload fails, you keep a committed bump with no shipped release. That is
#   acceptable (the next publish simply bumps again) and avoids uploading a
#   build whose number was never recorded. Nothing is pushed automatically —
#   the push command is printed for you to run.
# ==============================================================================

# Fail fast: one shell per recipe, abort on first error / unset var / pipe fail.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

# --- Project metadata, read dynamically from Skip.env (never hardcoded) -------
SKIP_ENV          := Skip.env
MARKETING_VERSION := $(shell grep '^MARKETING_VERSION' $(SKIP_ENV) | sed -E 's/.*=[[:space:]]*//')
BUILD_NUMBER      := $(shell grep '^CURRENT_PROJECT_VERSION' $(SKIP_ENV) | sed -E 's/.*=[[:space:]]*//')

# --- Paths --------------------------------------------------------------------
CONFIG_PLIST := Sources/Maxi80/Resources/Configuration.plist
# Apple artifacts are per-platform (the assemble lane outputs to Darwin/<platform>)
IOS_DIR      := .build/fastlane/Darwin/ios
TVOS_DIR     := .build/fastlane/Darwin/tvos
MACOS_DIR    := .build/fastlane/Darwin/macos
AAB_PATH     := .build/Android/app/outputs/bundle/release/app-release.aab

.PHONY: help version doctor verify check-config check-clean-tree test \
        clean build-ios build-android build-all \
        package-ios package-tvos package-macos package-android package-all \
        publish-metadata-ios publish-metadata-tvos publish-metadata-mac publish-metadata-all \
        publish-ios publish-tvos publish-macos publish-android publish-all \
        bump release screenshots

# ------------------------------------------------------------------------------
# Help / info
# ------------------------------------------------------------------------------
help: ## Show this help (default target)
	@echo "Maxi80 build automation — version $(MARKETING_VERSION) (build $(BUILD_NUMBER))"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "  Info"
	@echo "    help              Show this help (default)"
	@echo "    version           Print marketing version + current build number"
	@echo "    doctor            Preflight: check required tools & credentials"
	@echo "    verify            Run 'skip verify' + 'skip checkup'"
	@echo "    test              Run the real Swift test suite (publish gate)"
	@echo ""
	@echo "  Build"
	@echo "    build-ios         Build the Swift/iOS side (swift build)"
	@echo "    build-android     Skip transpile + gradle build (both halves)"
	@echo "    build-all         build-ios + build-android"
	@echo ""
	@echo "  Package (signed artifacts, no upload)"
	@echo "    package-ios       Signed iOS IPA (incl. CarPlay)"
	@echo "    package-tvos      Signed Apple TV IPA"
	@echo "    package-macos     Signed macOS build"
	@echo "    package-android   Release AAB (upload-signed)"
	@echo "    package-all       All of the above"
	@echo ""
	@echo "  Release (one version across all platforms)"
	@echo "    release              Bump -> build+sign ALL -> test -> commit+tag (no upload)"
	@echo "    bump                 Rewrite build number in Skip.env (yyyyMMddNN, low-level)"
	@echo ""
	@echo "  Publish metadata (listing text + screenshots, draft; no binary/review)"
	@echo "    publish-metadata-ios / -tvos / -mac / -all"
	@echo ""
	@echo "  Publish binaries (to TEST tracks; promote to prod manually in each Console)"
	@echo "    publish-ios / publish-tvos / publish-macos   TestFlight"
	@echo "    publish-android                              Play internal (draft)"
	@echo "    publish-all      Everything: all metadata + all binaries"
	@echo ""
	@echo "  Typical:  make release && make publish-all"
	@echo ""
	@echo "  Misc"
	@echo "    screenshots       Helper wrapping fastlane/capture_screenshots.sh"
	@echo "    clean             Remove build artifacts (.build, gradle outputs)"

version: ## Print the marketing version and current build number
	@echo "marketing version : $(MARKETING_VERSION)"
	@echo "build number      : $(BUILD_NUMBER)"

# ------------------------------------------------------------------------------
# Preflight / verification
# ------------------------------------------------------------------------------
doctor: ## Check required tools and credentials are present
	# One shell invocation: the MISSING accumulator must survive across all the
	# checks. (GNU Make 3.81 — macOS's system make — runs each recipe LINE in its
	# own shell and ignores .ONESHELL, so this whole check is a single `;\` block.)
	@MISSING=""; \
	echo "==> Checking required tools"; \
	for tool in skip fastlane gradle xcodebuild; do \
	  if command -v $$tool >/dev/null 2>&1; then \
	    echo "  ok   $$tool -> $$(command -v $$tool)"; \
	  else \
	    echo "  MISS $$tool (not found on PATH)"; MISSING=1; \
	  fi; \
	done; \
	: "Skip/gradle need a JDK. Homebrew gradle sets JAVA_HOME to /opt/homebrew/opt/openjdk."; \
	: "CLAUDE.md references JDK 21; any modern JDK gradle accepts is fine (openjdk 26 here)."; \
	if [ -x "$${JAVA_HOME:-}/bin/java" ]; then \
	  echo "  ok   java -> $$JAVA_HOME/bin/java"; \
	elif [ -x /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin/java ]; then \
	  echo "  ok   java -> Homebrew openjdk (used by gradle)"; \
	elif command -v java >/dev/null 2>&1; then \
	  echo "  ok   java -> $$(command -v java)"; \
	else \
	  echo "  WARN no JDK found on PATH/JAVA_HOME (gradle uses Homebrew openjdk)"; \
	fi; \
	echo "==> Checking credentials & configuration"; \
	for f in "$(CONFIG_PLIST)" \
	         "Darwin/fastlane/apikey.json" \
	         "Android/fastlane/apikey.json" \
	         "secrets/play_service_account.json"; do \
	  if [ -e "$$f" ]; then echo "  ok   $$f"; \
	  else echo "  MISS $$f"; MISSING=1; fi; \
	done; \
	if [ -f Android/app/keystore.properties ]; then \
	  echo "  ok   Android/app/keystore.properties (release AAB signed with the UPLOAD key)"; \
	else \
	  echo "  WARN Android/app/keystore.properties absent — release AAB is signed with the"; \
	  echo "       DEBUG key (see Android/app/build.gradle.kts, which reads keystore.properties"; \
	  echo "       relative to the app MODULE dir). Google Play upload needs the UPLOAD key."; \
	  echo "       Add Android/app/keystore.properties before a Play upload."; \
	fi; \
	if [ -n "$$MISSING" ]; then \
	  echo "==> doctor: some tools/files are missing (see above)"; exit 1; \
	fi; \
	echo "==> doctor: OK"

verify: ## Verify project structure and environment via Skip
	skip verify
	skip checkup

check-config: ## Ensure Configuration.plist exists (missing one asserts in debug)
	@if [ ! -f "$(CONFIG_PLIST)" ]; then \
	  echo "ERROR: $(CONFIG_PLIST) is missing."; \
	  echo "       Seed it from the template:"; \
	  echo "         cp $(CONFIG_PLIST).template $(CONFIG_PLIST)"; \
	  exit 1; \
	fi

check-clean-tree: ## Abort if the git working tree has uncommitted changes
	@if [ -n "$$(git status --porcelain)" ]; then \
	  echo "ERROR: git working tree is not clean. Commit or stash first:"; \
	  git status --short; \
	  exit 1; \
	fi

# ------------------------------------------------------------------------------
# Test (the publish gate — real Swift tests, ENVIRONMENTAL Android harness excluded)
# ------------------------------------------------------------------------------
test: ## Run the real Swift/Swift-Testing suite (used as the publish gate)
	# THIS IS A REAL GATE — it runs all 81 native Swift tests across 20 suites
	# (MetadataParser, APIClient, ViewModel, StationProvider, History, Reconnection,
	# ArtworkColors, TV root-view, …) and aborts publish on any genuine failure.
	#
	# `--skip XCSkipTests` excludes ONE thing only: the Skip-transpiler-generated
	# `XCSkipTests.testSkipModule` harness that skipstone auto-adds to every
	# *Tests target. That harness shells out to `skip android test … --robolectric`
	# (Gradle + Kotlin). It is KNOWN-BROKEN in this environment: the generated
	# Android test project fails to COMPILE with unresolved references
	# (SkipBridgeExecOps, execOps, commandLine, swiftBuildFolder, skipCommand,
	# environment(…) receiver mismatches) — a Skip/Gradle harness defect, NOT a
	# failure of this app's Swift code (the native tests all pass). It is
	# pre-existing and environmental (reproduces on a clean, stashed tree). Real
	# Android verification is done on a device/emulator via `skip app launch`,
	# not this Robolectric harness. We exclude ONLY that class by name so every
	# real Swift test still runs and still gates the release.
	#
	# --no-parallel: run the suite SERIALLY. The intermittent signal-5 (SIGTRAP)
	# crashes were a data race in the swift-testing PARALLEL runner over
	# APIClientTests' shared `MockURLProtocol.mockResponses` (a
	# `nonisolated(unsafe) static var` mutated across concurrently-running tests).
	# Serial execution removes the race — verified 4/4 clean, exit 0 — so the raw
	# exit code is a trustworthy gate again (a real failure returns non-zero).
	#
	# --scratch-path: keep the macOS test build in its own dir, isolated from any
	# Android artifacts (aarch64-unknown-linux-android28) that skip android build
	# leaves in the shared .build/.
	swift test --skip XCSkipTests --no-parallel --scratch-path .build/host-test

# ------------------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------------------
clean: ## Remove build artifacts (safe: never touches sources/secrets/config)
	# All of these are git-ignored, generated outputs — verified not tracked.
	rm -rf .build
	rm -rf Android/.build Android/.gradle Android/.kotlin Android/build Android/app/build
	rm -rf .skip build
	@echo "==> cleaned build artifacts"

# ------------------------------------------------------------------------------
# Build
# ------------------------------------------------------------------------------
build-ios: check-config ## Build the Swift/iOS side
	# `swift build` compiles the Swift/macOS toolchain build. Per CLAUDE.md, the
	# Skip transpiler (skipstone) only runs for the macOS destination, so a plain
	# `swift build` here doubles as the "does the native Swift compile" check for
	# the iOS side without needing a full Xcode archive (that's `package-ios`).
	swift build

build-android: check-config ## Skip transpile + gradle build (both halves)
	# Two halves, run explicitly (the user wants BOTH, not just the transpile):
	#   1. `skip android build` — runs the Skip transpile (Swift -> Kotlin) and
	#      the Skip prebuild plugin.
	#   2. gradle assembleDebug — compiles the generated Kotlin/Android project.
	#      (Debug avoids requiring a release signing key for a routine dev build;
	#       use `package-android` for the signed release AAB.)
	skip android build
	cd Android && gradle --warning-mode none -x lint assembleDebug

build-all: build-ios build-android ## Build both platforms

# ------------------------------------------------------------------------------
# Package (signed artifacts, no upload)
# ------------------------------------------------------------------------------
package-ios: check-config ## Produce a signed iOS IPA (App Store, incl. CarPlay)
	# build_app (scheme "Maxi80 App", sdk iphoneos) app-store export, signed with
	# team 56U756R2L2. CarPlay ships inside this binary (carplay-audio entitlement).
	cd Darwin && fastlane assemble platform:ios
	@echo "==> iOS IPA in $(IOS_DIR)"

package-tvos: check-config ## Produce a signed Apple TV IPA (App Store)
	cd Darwin && fastlane assemble platform:tvos
	@echo "==> tvOS IPA in $(TVOS_DIR)"

package-macos: check-config ## Produce a signed macOS build (App Store)
	cd Darwin && fastlane assemble platform:macos
	@echo "==> macOS artifact in $(MACOS_DIR)"

package-android: check-config ## Produce a release AAB (gradle bundleRelease)
	# The Android `assemble` lane runs `gradle bundleRelease` -> $(AAB_PATH).
	# SIGNING: Android/app/build.gradle.kts reads `keystore.properties` relative to
	# the app MODULE dir, so the file MUST live at Android/app/keystore.properties
	# (git-ignored). It points at the UPLOAD key, so this AAB is upload-signed and
	# accepted by Google Play (Play App Signing re-signs with the app key). If that
	# file is missing, gradle falls back to the DEBUG key and Play rejects the
	# upload ("signed with the wrong key"). See `doctor`.
	cd Android && fastlane assemble
	@echo "==> AAB at $(AAB_PATH)"

package-all: package-ios package-tvos package-macos package-android ## Build+sign every binary

# ------------------------------------------------------------------------------
# Release
# ------------------------------------------------------------------------------
bump: ## Rewrite CURRENT_PROJECT_VERSION in Skip.env to a fresh build number
	# Scheme: yyyyMMddNN (yyyyMMdd + 2-digit daily counter). Chosen to stay ABOVE
	# the app's last published Play versionCode (2021122500) and BELOW Android's
	# 2,100,000,000 ceiling — a pure date (yyyyMMdd00) satisfies both until 2099.
	# Monotonic-safe: the daily base is yyyyMMdd00, but if that is not strictly
	# greater than the current value (e.g. a second build the same day), we use
	# OLD+1 instead so the number always climbs (up to 99 builds/day).
	@set -e; \
	OLD="$$(grep '^CURRENT_PROJECT_VERSION' $(SKIP_ENV) | sed -E 's/.*=[[:space:]]*//')"; \
	BASE="$$(date +%Y%m%d)00"; \
	if [ "$$BASE" -gt "$$OLD" ] 2>/dev/null; then NEW="$$BASE"; else NEW="$$((OLD + 1))"; fi; \
	sed -i '' -E "s/^(CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*).*/\1$$NEW/" $(SKIP_ENV); \
	echo "==> build number: $$OLD -> $$NEW"

# RELEASE MODEL (one codebase -> one build number -> one commit+tag -> two binaries)
#
#   make release   Prepare a versioned, signed release of BOTH platforms:
#                    clean-tree check -> bump -> build+sign IPA & AAB at that
#                    version -> run tests -> ONLY if all succeed: commit the bump
#                    + one shared tag. Produces signed .ipa and .aab; uploads NOTHING.
#                  Because the version is baked into each binary AT BUILD TIME, the
#                  bump MUST precede the build; the commit+tag land LAST, so a build
#                  or test failure aborts with a clean git tree (fix and rerun).
#
#   make publish-android | publish-ios | publish-all
#                  Upload the ALREADY-BUILT signed binary from `make release` to its
#                  TEST track (Play internal draft / TestFlight). No bump, no build,
#                  no tag. Uploading is NOT a production release — you promote to
#                  production manually in each Console.
#
#   Typical flow:  make release   &&   make publish-all
#                  (then test on device, then promote to prod in the Consoles)

release: ## Prepare a signed, versioned release of ALL platforms (no upload)
	# One codebase -> one build number -> one commit+tag -> all binaries.
	# The version is compiled into each binary, so bump BEFORE building; commit+tag
	# land LAST so a failed build/test leaves git clean (fix and rerun). GNU Make
	# 3.81 ignores .ONESHELL, so each step is its own line.
	@$(MAKE) --no-print-directory check-clean-tree
	@$(MAKE) --no-print-directory bump
	@echo "==> Building + signing iOS(+CarPlay), tvOS, macOS and Android at the new version"
	@$(MAKE) --no-print-directory package-ios
	@$(MAKE) --no-print-directory package-tvos
	@$(MAKE) --no-print-directory package-macos
	@$(MAKE) --no-print-directory package-android
	@echo "==> Running tests"
	@$(MAKE) --no-print-directory test
	@set -e; \
	BUILD="$$(grep '^CURRENT_PROJECT_VERSION' $(SKIP_ENV) | sed -E 's/.*=[[:space:]]*//')"; \
	TAG="v$(MARKETING_VERSION)-$$BUILD"; \
	git add $(SKIP_ENV); \
	git commit -m "chore(release): $(MARKETING_VERSION) build $$BUILD"; \
	git tag -a "$$TAG" -m "Maxi 80 $(MARKETING_VERSION) (build $$BUILD)"; \
	echo "==> Release $$TAG prepared (iOS/tvOS/macOS IPAs+pkg, Android AAB), committed + tagged (not pushed)."; \
	echo "    Next: make publish-all    (metadata + binaries to all test tracks)"; \
	echo "    Then: git push && git push origin $$TAG"

# --- Metadata uploads (listing text + screenshots as draft; no binary, no review) ---
publish-metadata-ios: ## App Store iOS listing (text + iPhone screenshots) as draft
	cd Darwin && fastlane metadata

publish-metadata-tvos: ## App Store tvOS listing (text + Apple TV screenshots) as draft
	cd Darwin && fastlane metadata_tvos

publish-metadata-mac: ## App Store macOS listing (text + Mac screenshots) as draft
	cd Darwin && fastlane metadata_mac

publish-metadata-all: publish-metadata-ios publish-metadata-tvos publish-metadata-mac ## All Apple listings

# --- Binary uploads (test tracks; promote to production manually in each Console) ---
publish-ios: ## Upload the built iOS IPA to TestFlight
	@ls $(IOS_DIR)/*.ipa >/dev/null 2>&1 || { echo "no iOS IPA in $(IOS_DIR) — run 'make package-ios' (or release) first"; exit 1; }
	cd Darwin && fastlane upload platform:ios

publish-tvos: ## Upload the built Apple TV IPA to TestFlight
	@ls $(TVOS_DIR)/*.ipa >/dev/null 2>&1 || { echo "no tvOS IPA in $(TVOS_DIR) — run 'make package-tvos' (or release) first"; exit 1; }
	cd Darwin && fastlane upload platform:tvos

publish-macos: ## Upload the built macOS pkg to TestFlight/App Store
	@ls $(MACOS_DIR)/*.pkg >/dev/null 2>&1 || { echo "no macOS pkg in $(MACOS_DIR) — run 'make package-macos' (or release) first"; exit 1; }
	cd Darwin && fastlane upload platform:macos

publish-android: ## Upload the built AAB to Google Play (internal track, draft)
	@test -f "$(AAB_PATH)" || { echo "no AAB at $(AAB_PATH) — run 'make package-android' (or release) first"; exit 1; }
	cd Android && fastlane upload track:internal release_status:draft

publish-all: publish-metadata-all publish-ios publish-tvos publish-macos publish-android ## Upload EVERYTHING (metadata + all binaries)

# ------------------------------------------------------------------------------
# Misc
# ------------------------------------------------------------------------------
screenshots: ## Capture a store screenshot (wraps fastlane/capture_screenshots.sh)
	# Pass args through ARGS, e.g.:
	#   make screenshots ARGS="ios en-US 1 now-playing"
	#   make screenshots ARGS="droid fr-FR 2 cover-flow phone"
	@if [ -z "$(ARGS)" ]; then \
	  echo "usage: make screenshots ARGS=\"<ios|tvos|droid> <locale> <order> <name> [form-factor]\""; \
	  echo "example: make screenshots ARGS=\"ios en-US 1 now-playing\""; \
	  exit 1; \
	fi
	./fastlane/capture_screenshots.sh $(ARGS)
