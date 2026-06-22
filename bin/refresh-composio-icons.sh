#!/usr/bin/env bash
# bin/refresh-composio-icons.sh — fetch Composio's brand logos and bundle
# them into Assets.xcassets/Composio/<slug>.imageset/<slug>.png.
#
# Why this script exists:
#   1. Composio's logo CDN at logos.composio.dev only serves image/svg+xml.
#      macOS's NSImage doesn't decode SVG natively, so SwiftUI's
#      AsyncImage call on those URLs always falls through to the failure
#      case. Bundling the assets at build time bypasses the decode gap.
#   2. PNG (not PDF). Earlier this script wrote PDFs via rsvg-convert,
#      but SVGs that use <mask type="luminance"> with white-filled paths
#      (e.g. Asana's three circles) render white-on-white inside the PDF
#      page because PDF doesn't honor SVG mask compositing the way a
#      pixel-aware renderer does. PNG output keeps the alpha channel
#      from rsvg's raster path, so masked logos composite cleanly onto
#      whatever background SwiftUI gives them.
#
#   The icons live in the bundled app at fixed tile sizes (56-76pt),
#   so a single 256x256 PNG is more than enough resolution for @3x
#   retina. We use a "universal" imageset (one scale) and let SwiftUI
#   handle the downscale.
#
# Add a new slug:
#   1. Append it to SLUGS below
#   2. Also append it to BrandStyle.bundledSlugs in
#      desktop-mac/KLO/Views/ConnectionsView.swift
#   3. Run this script
#   4. git add desktop-mac/KLO/Assets.xcassets/Composio/
#
# Requires: curl, rsvg-convert (brew install librsvg).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/desktop-mac/KLO/Assets.xcassets/Composio"
CDN="https://logos.composio.dev/api"

SLUGS=(
  gmail googlecalendar googledrive googlesheets googledocs
  slack notion linear github gitlab asana jira trello
  hubspot salesforce discord zoom dropbox stripe twilio
)

# Pre-flight.
if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "✗ rsvg-convert missing — install with: brew install librsvg" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "✗ curl missing" >&2
  exit 1
fi

mkdir -p "$ASSETS"
cat > "$ASSETS/Contents.json" <<'EOF'
{
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "provides-namespace" : true }
}
EOF

ok=0
fail=0
for slug in "${SLUGS[@]}"; do
  imgset="$ASSETS/$slug.imageset"
  mkdir -p "$imgset"
  tmp_svg=$(mktemp -t "composio-$slug.XXXXXX.svg")

  if ! curl -fsSL "$CDN/$slug" -o "$tmp_svg" 2>/dev/null; then
    printf '  ✗ %-18s — fetch failed\n' "$slug"
    rm -rf "$imgset" "$tmp_svg"
    fail=$((fail + 1))
    continue
  fi
  if [ ! -s "$tmp_svg" ]; then
    printf '  ✗ %-18s — empty SVG\n' "$slug"
    rm -rf "$imgset" "$tmp_svg"
    fail=$((fail + 1))
    continue
  fi

  # --background-color=transparent ensures the PNG has an alpha channel
  # so masked logos (Asana's three circles, Trello, Jira) composite
  # cleanly onto whatever background SwiftUI gives them. PNG output
  # avoids the PDF page-background gotcha that swallowed white-fill
  # mask shapes in the previous PDF-based pipeline.
  png="$imgset/$slug.png"
  if ! rsvg-convert -f png -w 256 -h 256 --background-color=transparent \
       "$tmp_svg" > "$png" 2>/dev/null; then
    printf '  ✗ %-18s — rsvg-convert failed\n' "$slug"
    rm -rf "$imgset" "$tmp_svg"
    fail=$((fail + 1))
    continue
  fi
  if [ ! -s "$png" ]; then
    printf '  ✗ %-18s — empty PNG\n' "$slug"
    rm -rf "$imgset" "$tmp_svg"
    fail=$((fail + 1))
    continue
  fi

  cat > "$imgset/Contents.json" <<EOF
{
  "images" : [
    { "filename" : "$slug.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : {
    "template-rendering-intent" : "original"
  }
}
EOF

  printf '  ✓ %-18s (%s bytes png)\n' "$slug" "$(stat -f %z "$png")"
  rm -f "$tmp_svg"
  ok=$((ok + 1))
done

echo
echo "→ $ok ok, $fail failed"
[ "$fail" -eq 0 ]
