#!/usr/bin/env bash
#
# capture_screenshots.sh — grab App Store / Play Store screenshots from a
# running simulator or emulator that you drive by hand.
#
# Maxi 80 is a single-screen radio app, so a full UITest/screengrab harness is
# overkill and doesn't fit Skip's module layout. Instead: get the app into the
# state you want to show (playing with metadata, cover-flow history open, etc.),
# then run this to capture the current frame into the right fastlane folder.
#
# The captured PNGs land in the exact directories `deliver` (iOS) and
# `supply` (Android) read from, named with a numeric prefix that controls
# display order in the store.
#
# USAGE
#   ./fastlane/capture_screenshots.sh ios   <locale> <order> <name>
#   ./fastlane/capture_screenshots.sh droid <locale> <order> <name> [phone|seven|ten]
#
#   locale : en-US | fr-FR | fr-CA
#   order  : 1..10  (display order in the store)
#   name   : short slug, e.g. "now-playing", "cover-flow", "carplay"
#
# EXAMPLES
#   # iOS: capture the booted simulator's current screen as en-US shot #1
#   ./fastlane/capture_screenshots.sh ios en-US 1 now-playing
#
#   # Android: capture the running emulator as a French phone shot #2
#   ./fastlane/capture_screenshots.sh droid fr-FR 2 cover-flow phone
#
# REQUIREMENTS
#   iOS     : a booted simulator (xcrun simctl). For a physical device or the
#             exact required pixel sizes, take the shot in the Simulator (⌘S)
#             or via Xcode Devices and drop it in the folder this prints.
#   Android : `adb` on PATH and one running emulator/device (`adb devices`).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-}"
LOCALE="${2:-}"
ORDER="${3:-}"
NAME="${4:-}"
FORM="${5:-phone}"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "$PLATFORM" && -n "$LOCALE" && -n "$ORDER" && -n "$NAME" ]] \
  || die "usage: $0 <ios|droid> <locale> <order> <name> [phone|seven|ten]"

case "$LOCALE" in en-US|fr-FR|fr-CA) ;; *) die "locale must be en-US, fr-FR or fr-CA" ;; esac

FILE="$(printf '%02d' "$ORDER")-${NAME}.png"

case "$PLATFORM" in
  ios)
    OUT_DIR="$REPO_ROOT/Darwin/fastlane/screenshots/$LOCALE"
    mkdir -p "$OUT_DIR"
    command -v xcrun >/dev/null || die "xcrun not found (install Xcode)"
    xcrun simctl io booted screenshot "$OUT_DIR/$FILE" \
      || die "no booted simulator — boot one and open Maxi 80 first"
    echo "saved iOS screenshot: $OUT_DIR/$FILE"
    ;;
  droid)
    case "$FORM" in
      phone) KIND=phoneScreenshots ;;
      seven) KIND=sevenInchScreenshots ;;
      ten)   KIND=tenInchScreenshots ;;
      *) die "form must be phone, seven or ten" ;;
    esac
    OUT_DIR="$REPO_ROOT/Android/fastlane/metadata/android/$LOCALE/images/$KIND"
    mkdir -p "$OUT_DIR"
    command -v adb >/dev/null || die "adb not found (install Android platform-tools)"
    adb exec-out screencap -p > "$OUT_DIR/$FILE" \
      || die "no running emulator/device — start one and open Maxi 80 first"
    echo "saved Android screenshot: $OUT_DIR/$FILE"
    ;;
  *)
    die "first arg must be 'ios' or 'droid'"
    ;;
esac
