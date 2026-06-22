#!/bin/bash
# notarize.sh — build, sign, notarize, staple, and DMG-package KLO.app.
#
# One-shot pipeline that takes the Swift project and produces a
# notarized, stapled `dist/KLO.dmg` ready to ship.
#
# Required setup before first run:
#   1. Apple Developer account + Developer ID Application certificate
#      installed in your login keychain (open Keychain Access to verify).
#   2. App-specific password for notarytool. Create one at
#      appleid.apple.com → Sign-In and Security → App-Specific Passwords.
#   3. Store credentials in keychain so notarytool can read them:
#        xcrun notarytool store-credentials klo-notary \
#          --apple-id you@example.com \
#          --team-id TEAMID123 \
#          --password APP-SPECIFIC-PASSWORD
#   4. Replace TEAMID123 below with your actual team ID.
#   5. Install create-dmg + librsvg (one-time):
#        brew install create-dmg librsvg
#      librsvg ships rsvg-convert, which rasterizes the DMG background
#      SVG (Distribution/dmg-background.svg) into the 1x/2x PNGs that
#      create-dmg picks up via --background.
#
# Usage:
#   cd desktop-mac
#   ./Distribution/notarize.sh
#
# Output: ./dist/KLO.dmg

set -euo pipefail

cd "$(dirname "$0")/.."

# ---- configurable ----
# Public builds provide signing values via env.
# SIGNING_IDENTITY is the SHA-1 of the Developer ID Application cert rather
# than the friendly name — codesign errors out as "ambiguous identity" when
# multiple identically-named certs exist in the keychain.
TEAM_ID="${KLO_TEAM_ID:-}"
NOTARY_PROFILE="${KLO_NOTARY_PROFILE:-klo-notary}"
SIGNING_IDENTITY="${KLO_SIGNING_IDENTITY:-}"

if [[ -z "$TEAM_ID" || -z "$SIGNING_IDENTITY" ]]; then
  echo "error: set KLO_TEAM_ID and KLO_SIGNING_IDENTITY before notarizing." >&2
  echo "public KLO Local builds use ad-hoc/debug signing; notarization requires your own Apple Developer identity." >&2
  exit 1
fi
SCHEME="KLO"
PROJECT="KLO.xcodeproj"

# ---- paths ----
BUILD_DIR="$(mktemp -d -t klo-build)"
ARCHIVE_PATH="$BUILD_DIR/KLO.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/KLO.app"
DIST_DIR="./dist"
ZIP_PATH="$BUILD_DIR/KLO.zip"
DMG_PATH="$DIST_DIR/KLO.dmg"

mkdir -p "$DIST_DIR"

# ---- codesign wrapper with --timestamp retry ----
# Apple's timestamp server (timestamp.apple.com) is occasionally
# unreachable for ~seconds at a time. A bare `codesign --timestamp` call
# during that window fails the entire release with a network error.
# Single retry with 5s backoff covers it without papering over real
# auth/signing issues (which fail consistently, not transiently).
codesign_with_retry() {
  local attempt=1
  while true; do
    if codesign "$@"; then
      return 0
    fi
    if [ $attempt -ge 2 ]; then
      echo "✗ codesign failed twice — aborting" >&2
      return 1
    fi
    echo "⚠ codesign attempt $attempt failed (likely Apple timestamp server) — retrying in 5s" >&2
    sleep 5
    attempt=$((attempt + 1))
  done
}

# ---- 1. Ensure project is up to date ----
if command -v xcodegen >/dev/null 2>&1; then
  echo "▶︎ regenerating Xcode project from project.yml"
  xcodegen generate
fi

# ---- 2. Build Release ----
echo "▶︎ building Release archive"
# -skipMacroValidation bypasses the "Macro from package X must be
# enabled" prompt for vendored Swift macros (MetaCodable's MacroPlugin
# is in this graph). Required because `xcodebuild archive` doesn't
# inherit the trust state from interactive Xcode sessions, and a
# release script can't sit at an approval prompt forever.
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

# ---- 3. Export the .app from the archive ----
cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

echo "▶︎ exporting .app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist"

# ---- 3.5 Hardened-runtime sign the embedded sidecar ----
# Apple notary fails if ANY embedded executable lacks hardened runtime.
# Xcode signs the outer .app and the Swift binary; it does NOT touch the
# PyInstaller bundle in Resources/. We deep-sign that here, inside-out:
#   1. Every .dylib / .so inside _internal/
#   2. The klo-sidecar entry binary (with Python-friendly entitlements)
#   3. Re-sign the outer .app to seal the new signatures
SIDECAR_DIR="$APP_PATH/Contents/Resources/klo-sidecar"
SIDECAR_BIN="$SIDECAR_DIR/klo-sidecar"
SIDECAR_ENT="./Distribution/sidecar.entitlements"
APP_ENT="./KLO/KLO.entitlements"

if [ -d "$SIDECAR_DIR" ]; then
  echo "▶︎ hardened-runtime signing all dylibs/so under $SIDECAR_DIR"
  # `find -print0` + xargs handles paths with spaces robustly. We sign
  # in dependency order (deepest first) so dylibs that import other
  # dylibs see signed dependencies. xargs -n1 keeps each codesign call
  # independent so one bad file doesn't abort the rest.
  find "$SIDECAR_DIR" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 | \
    while IFS= read -r -d '' lib; do
      codesign_with_retry \
        --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$lib"
    done

  echo "▶︎ signing klo-sidecar entry binary with Python entitlements"
  codesign_with_retry \
    --force --options runtime --timestamp \
    --entitlements "$SIDECAR_ENT" \
    --sign "$SIGNING_IDENTITY" \
    "$SIDECAR_BIN"

  echo "▶︎ re-signing outer KLO.app to seal embedded signatures"
  codesign_with_retry \
    --force --options runtime --timestamp \
    --entitlements "$APP_ENT" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH"

  echo "▶︎ verifying signature chain"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -5
else
  echo "○ no sidecar bundle at $SIDECAR_DIR — Mac app will need an external sidecar"
fi

# ---- 4. Zip for notarization ----
echo "▶︎ zipping for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# ---- 5. Submit to notary ----
echo "▶︎ submitting to Apple notary (this can take a few minutes)"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# ---- 6. Staple ticket ----
echo "▶︎ stapling notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# ---- 7. Build DMG ----
echo "▶︎ building DMG"
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "✗ create-dmg not installed. Run: brew install create-dmg" >&2
  exit 1
fi

# Re-rasterize the branded DMG background (cream paper + klo wordmark +
# olive wisp arrow). Source of truth is dmg-background.svg; PNGs are
# regenerated every release so a tweak to the SVG ships without anyone
# remembering to run the build script.
echo "▶︎ rasterizing DMG background"
./Distribution/build-dmg-bg.sh

rm -f "$DMG_PATH"
# `--background` points at the 1x PNG; create-dmg auto-picks the
# @2x.png sibling for Retina renders. `--hide-extension` drops the
# ".app" suffix under the icon so the user sees a bare "KLO" label
# that matches the wordmark above it.
# DO NOT add --skip-jenkins here. That flag disables the AppleScript
# step that applies --background and positions the icons, so the DMG
# would open as a default Finder window with no branding.
create-dmg \
  --volname "KLO" \
  --background "Distribution/dmg-background.png" \
  --window-size 540 380 \
  --window-pos 200 120 \
  --icon-size 100 \
  --icon "KLO.app" 140 200 \
  --hide-extension "KLO.app" \
  --app-drop-link 400 200 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_PATH"

# ---- 8. (optional) Notarize the DMG itself for Gatekeeper-on-DMG ----
echo "▶︎ notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG_PATH"

echo
echo "✓ done — $DMG_PATH"
echo "  size: $(du -h "$DMG_PATH" | cut -f1)"
