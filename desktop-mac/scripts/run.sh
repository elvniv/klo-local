#!/usr/bin/env bash
#
# run.sh — regenerate the Xcode project, build, and (re)launch KLO.app.
#
# Why this exists: `xcodegen generate` reshuffles project UUIDs, which
# Xcode hashes into a fresh DerivedData folder. If you `pkill` + `open`
# from a hardcoded path, you can easily relaunch a stale binary from a
# previous DerivedData slot. This script asks xcodebuild itself for the
# current BUILT_PRODUCTS_DIR and launches THAT, so it survives any
# future regen.
#
# Usage:
#   ./scripts/run.sh        # rebuild + relaunch
#
# (Inside Xcode, ⌘R does the same thing natively — this is for the
# terminal workflow.)

set -euo pipefail

cd "$(dirname "$0")/.."

# Regenerate project from project.yml so any source-file additions land
# in the build. xcodegen is idempotent — no-op when nothing changed.
xcodegen generate >/dev/null

# Ask the project itself where it builds. Survives any DerivedData
# reshuffle since the project's UUID drives the hash.
APP_DIR=$(xcodebuild -project KLO.xcodeproj -scheme KLO -showBuildSettings 2>/dev/null \
          | awk '/^[[:space:]]*BUILT_PRODUCTS_DIR/ { print $3 }')

if [[ -z "${APP_DIR:-}" ]]; then
  echo "✗ Couldn't read BUILT_PRODUCTS_DIR from xcodebuild." >&2
  exit 1
fi

echo "→ Building (target: $APP_DIR)"
xcodebuild -project KLO.xcodeproj -scheme KLO -configuration Debug \
           -destination "platform=macOS" -quiet build

# Kill any running instance + sidecar so the new binary boots clean.
osascript -e 'tell application "KLO" to quit' 2>/dev/null || true
sleep 0.4
pkill -f "KLO.app/Contents/MacOS/KLO" 2>/dev/null || true
pkill -f "klo-sidecar/klo-sidecar" 2>/dev/null || true
sleep 0.4

echo "→ Launching $APP_DIR/KLO.app"
open "$APP_DIR/KLO.app"
sleep 1
pgrep -lf "KLO.app/Contents/MacOS/KLO" | head -3
