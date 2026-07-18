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
# The captured PNGs land in the exact directories `deliver` (Apple) and
# `supply` (Android) read from, named with a numeric prefix that controls
# display order in the store.
#
# USAGE
#   ./fastlane/capture_screenshots.sh ios   <locale> <order> <name>
#   ./fastlane/capture_screenshots.sh tvos  <locale> <order> <name>
#   ./fastlane/capture_screenshots.sh mac   <locale> <order> <name>
#   ./fastlane/capture_screenshots.sh droid <locale> <order> <name> [phone|seven|ten|tv]
#
#   locale : en-US | fr-FR | fr-CA
#   order  : 1..10  (display order in the store)
#   name   : short slug, e.g. "now-playing", "cover-flow", "carplay"
#
# PLATFORMS
#   ios   → iPhone/iPad shot, from a booted iOS simulator.
#   tvos  → Apple TV shot, from a booted tvOS simulator. deliver auto-classifies
#           App Store screenshots by pixel size, so tvOS shots land in the same
#           locale folder as iOS ones but get a "tv-" filename prefix to avoid
#           colliding with an iPhone shot of the same order.
#   droid → Android shot; pick the form factor with the 5th arg (default phone).
#           "tv" targets the Android TV screenshot set in the Play listing.
#
# EXAMPLES
#   # iOS: capture the booted simulator's current screen as en-US shot #1
#   ./fastlane/capture_screenshots.sh ios en-US 1 now-playing
#
#   # Apple TV: capture the booted tvOS simulator as en-US shot #1
#   ./fastlane/capture_screenshots.sh tvos en-US 1 now-playing
#
#   # Android: capture the running emulator as a French phone shot #2
#   ./fastlane/capture_screenshots.sh droid fr-FR 2 cover-flow phone
#
#   # Android TV: capture the running TV emulator as en-US shot #1
#   ./fastlane/capture_screenshots.sh droid en-US 1 now-playing tv
#
# REQUIREMENTS
#   ios/tvos : a booted simulator (xcrun simctl). If more than one simulator is
#              booted, `booted` is ambiguous — boot only the one you want, or
#              take the shot in the Simulator (⌘S) and drop it in the folder
#              this prints. For the exact required pixel sizes, capture from a
#              matching device (e.g. iPhone 16 Pro Max, Apple TV 4K).
#   droid    : `adb` on PATH and one running emulator/device (`adb devices`).
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
  || die "usage: $0 <ios|tvos|mac|droid> <locale> <order> <name> [phone|seven|ten|tv]"

case "$LOCALE" in en-US|fr-FR|fr-CA) ;; *) die "locale must be en-US, fr-FR or fr-CA" ;; esac

FILE="$(printf '%02d' "$ORDER")-${NAME}.png"

case "$PLATFORM" in
  ios|tvos)
    command -v xcrun >/dev/null || die "xcrun not found (install Xcode)"
    # deliver runs one platform per lane with a per-platform screenshots_path,
    # so each platform has its OWN folder tree (see Darwin/fastlane/Fastfile).
    case "$PLATFORM" in
      ios)  SUBDIR=ios ;;
      tvos) SUBDIR=appletv ;;
    esac
    OUT_DIR="$REPO_ROOT/Darwin/fastlane/screenshots/$SUBDIR/$LOCALE"
    mkdir -p "$OUT_DIR"
    xcrun simctl io booted screenshot "$OUT_DIR/$FILE" \
      || die "no booted simulator — boot one (only one) and open Maxi 80 first"
    echo "saved ${PLATFORM} screenshot: $OUT_DIR/$FILE"
    ;;
  mac)
    # macOS has no simulator: capture the REAL Maxi 80 window on this Mac, then
    # normalize to an App-Store-accepted size. deliver requires an EXACT size —
    # one of 1280x800, 1440x900, 2560x1600, 2880x1800. We capture the window and
    # scale-to-fit onto a 2560x1600 black canvas (Retina; downscaled by ASC as
    # needed). Uses `screencapture -l <windowID>` to grab just the app window.
    command -v screencapture >/dev/null || die "screencapture not found (macOS only)"
    OUT_DIR="$REPO_ROOT/Darwin/fastlane/screenshots/mac/$LOCALE"
    mkdir -p "$OUT_DIR"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    # Region-capture the Maxi 80 window by its position+size (System Events window
    # ids are NOT CoreGraphics ids, so `screencapture -l` doesn't work; -R with the
    # window rect does, and needs no interaction). On a Retina display the PNG comes
    # out at 2x the point size.
    GEO="$(osascript -e 'tell application "System Events" to tell (first process whose name contains "Maxi80")
      set frontmost to true
      set p to position of window 1
      set s to size of window 1
      set x to item 1 of p
      set y to item 2 of p
      set w to item 1 of s
      set h to item 2 of s
      return ("" & x & " " & y & " " & w & " " & h)
    end tell' 2>/dev/null || true)"
    [[ -n "$GEO" ]] || die "Maxi80 window not found — run the macOS app first"
    read -r X Y W H <<< "$GEO"
    screencapture -x -o -R"${X},${Y},${W},${H}" "$TMP/raw.png" \
      || die "capture failed (grant your terminal Screen Recording in System Settings → Privacy)"
    # Normalize to an exact App-Store-accepted macOS size (2560x1600, 16:10) by
    # scaling-to-fit onto a black canvas. mkasset upsizes small captures cleanly.
    if [[ -x /tmp/mkasset ]]; then
      /tmp/mkasset "$TMP/raw.png" 2560 1600 "$OUT_DIR/$FILE" 1.0 || die "normalize failed"
    else
      cp "$TMP/raw.png" "$OUT_DIR/$FILE"
      echo "warning: /tmp/mkasset not present — $FILE is $(sips -g pixelWidth -g pixelHeight "$OUT_DIR/$FILE" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w\"x\"h}'), not normalized to 2560x1600"
    fi
    echo "saved mac screenshot: $OUT_DIR/$FILE"
    ;;
  droid)
    case "$FORM" in
      phone) KIND=phoneScreenshots ;;
      seven) KIND=sevenInchScreenshots ;;
      ten)   KIND=tenInchScreenshots ;;
      tv)    KIND=tvScreenshots ;;
      *) die "form must be phone, seven, ten or tv" ;;
    esac
    OUT_DIR="$REPO_ROOT/Android/fastlane/metadata/android/$LOCALE/images/$KIND"
    mkdir -p "$OUT_DIR"
    command -v adb >/dev/null || die "adb not found (install Android platform-tools)"
    adb exec-out screencap -p > "$OUT_DIR/$FILE" \
      || die "no running emulator/device — start one and open Maxi 80 first"
    echo "saved Android ($FORM) screenshot: $OUT_DIR/$FILE"
    ;;
  *)
    die "first arg must be 'ios', 'tvos', 'mac' or 'droid'"
    ;;
esac
