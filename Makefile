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
IPA_DIR      := .build/fastlane/Darwin
AAB_PATH     := .build/Android/app/outputs/bundle/release/app-release.aab

.PHONY: help version doctor verify check-config check-clean-tree \
        clean build-ios build-android build-all \
        package-ios package-android \
        bump publish-metadata-ios publish-ios publish-android publish-all screenshots

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
	@echo ""
	@echo "  Build"
	@echo "    build-ios         Build the Swift/iOS side (swift build)"
	@echo "    build-android     Skip transpile + gradle build (both halves)"
	@echo "    build-all         build-ios + build-android"
	@echo ""
	@echo "  Package (signed artifacts, no upload)"
	@echo "    package-ios       Signed IPA via fastlane (Darwin/assemble)"
	@echo "    package-android   Release AAB via fastlane (Android/assemble)"
	@echo ""
	@echo "  Release"
	@echo "    bump                 Rewrite build number in Skip.env (yyyyMMddNN)"
	@echo "    publish-metadata-ios Push App Store listing as draft (no binary/review)"
	@echo "    publish-ios          Gate -> bump -> commit -> TestFlight -> tag"
	@echo "    publish-android      Gate -> bump -> commit -> Play internal draft -> tag"
	@echo "    publish-all          publish-ios + publish-android"
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
	if [ -f Android/keystore.properties ]; then \
	  echo "  ok   Android/keystore.properties (release AAB signed with the UPLOAD key)"; \
	else \
	  echo "  WARN Android/keystore.properties absent — release AAB is signed with the"; \
	  echo "       DEBUG key (see Android/app/build.gradle.kts). Google Play upload"; \
	  echo "       needs a real UPLOAD key. Add Android/keystore.properties before"; \
	  echo "       a production Play submission (Play App Signing handles the rest)."; \
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
package-ios: check-config ## Produce a signed IPA (App Store codesigned)
	# The Darwin `assemble` lane runs build_app with scheme "Maxi80 App" and
	# fastlane/AppStore.xcconfig; it codesigns for the App Store. Output lands in
	# $(IPA_DIR).
	cd Darwin && fastlane assemble
	@echo "==> IPA in $(IPA_DIR)"

package-android: check-config ## Produce a release AAB (gradle bundleRelease)
	# The Android `assemble` lane runs `gradle bundleRelease` -> $(AAB_PATH).
	# SIGNING: Android/app/build.gradle.kts signs the release build with the
	# keystore named in Android/keystore.properties. That file is present here
	# (git-ignored) and points at the UPLOAD key, so this AAB is UPLOAD-signed and
	# ready for Google Play (Play App Signing re-signs with the app key on their
	# side). If keystore.properties is ever removed, the build falls back to the
	# DEBUG key — fine to inspect locally, but rejected by Play. See `doctor`.
	cd Android && fastlane assemble
	@echo "==> AAB at $(AAB_PATH)"

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

# publish-ios / publish-android compute the build number INSIDE the shell (by
# re-reading Skip.env AFTER `make bump`) rather than via the make $(BUILD_NUMBER)
# variable: that variable is expanded via $(shell ...) when the Makefile is read,
# i.e. BEFORE the bump runs, so it would hold the stale pre-bump number. The
# final block is one `set -e; ...` shell so a failed git commit or upload aborts
# the sequence instead of falling through to the tag (the installed GNU Make 3.81
# ignores .SHELLFLAGS/.ONESHELL, so we can't rely on those for fail-fast here).
publish-metadata-ios: ## Push the App Store listing (text + screenshots) as a DRAFT (no binary, no review)
	# Safe: uploads metadata/screenshots only, does not submit for review.
	cd Darwin && fastlane metadata

publish-ios: ## Gate -> bump -> commit -> upload to TestFlight (staging) -> tag
	# SAFE STAGING: uploads the build to TestFlight, NOT the App Store review queue.
	# Test it via TestFlight, then promote to the store manually in App Store Connect
	# (or run `cd Darwin && fastlane release` to submit for review from the CLI).
	@$(MAKE) --no-print-directory check-clean-tree
	@echo "==> Running tests (publish gate)"
	swift test
	@$(MAKE) --no-print-directory bump
	@set -e; \
	BUILD="$$(grep '^CURRENT_PROJECT_VERSION' $(SKIP_ENV) | sed -E 's/.*=[[:space:]]*//')"; \
	git add $(SKIP_ENV); \
	git commit -m "chore(release): bump build number to $$BUILD for iOS release $(MARKETING_VERSION)"; \
	echo "==> Building, signing and uploading to TestFlight"; \
	( cd Darwin && fastlane beta ); \
	TAG="v$(MARKETING_VERSION)-$$BUILD"; \
	git tag -a "$$TAG" -m "iOS release $(MARKETING_VERSION) (build $$BUILD) — TestFlight"; \
	echo "==> Tagged $$TAG (not pushed). To push:"; \
	echo "      git push && git push origin $$TAG"

publish-android: ## Gate -> bump -> commit -> Play internal draft -> tag
	@$(MAKE) --no-print-directory check-clean-tree
	@echo "==> Running tests (publish gate)"
	swift test
	@$(MAKE) --no-print-directory bump
	@set -e; \
	BUILD="$$(grep '^CURRENT_PROJECT_VERSION' $(SKIP_ENV) | sed -E 's/.*=[[:space:]]*//')"; \
	git add $(SKIP_ENV); \
	git commit -m "chore(release): bump build number to $$BUILD for Android release $(MARKETING_VERSION)"; \
	echo "==> Building, signing and uploading to Google Play (internal track, draft)"; \
	( cd Android && fastlane release track:internal release_status:draft ); \
	TAG="v$(MARKETING_VERSION)-$$BUILD-android"; \
	git tag -a "$$TAG" -m "Android release $(MARKETING_VERSION) (build $$BUILD)"; \
	echo "==> Tagged $$TAG (not pushed). To push:"; \
	echo "      git push && git push origin $$TAG"

publish-all: publish-ios publish-android ## Publish both platforms

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
