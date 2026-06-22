#!/bin/bash
# build-dmg-bg.sh — rasterize Distribution/dmg-background.svg into the
# 1x and 2x PNGs that create-dmg picks up via --background.
#
# Renders the SVG at 4x (2160x1520), then downsamples with PIL's
# Lanczos filter. The supersample + Lanczos pass gives the type and
# curves crisper edge anti-aliasing than rsvg-convert produces at
# native resolution — closer to the quality you'd get out of Sketch
# or Figma export.
#
# create-dmg auto-detects the @2x companion: passing dmg-background.png
# makes it look for dmg-background@2x.png next to it for Retina.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "✗ rsvg-convert not installed. Run: brew install librsvg" >&2
  exit 1
fi

# Pick an arm64 Python with PIL. /usr/bin/python3 ships an x86_64 PIL
# on Apple Silicon which fails to import; homebrew's 3.13 has the
# arm64 wheel.
PYTHON_BIN=""
for candidate in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3; do
  if [ -x "$candidate" ] && "$candidate" -c "from PIL import Image" 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
if [ -z "$PYTHON_BIN" ]; then
  echo "✗ No Python with Pillow found. Run: /opt/homebrew/bin/python3.13 -m pip install pillow" >&2
  exit 1
fi

TMP_4X="$(mktemp -t klo-dmg-bg-4x).png"
trap 'rm -f "$TMP_4X"' EXIT

echo "▶︎ rasterizing dmg-background.svg at 4x"
rsvg-convert -w 2160 -h 1520 dmg-background.svg -o "$TMP_4X"

echo "▶︎ downsampling to 1x and @2x with Lanczos"
"$PYTHON_BIN" - <<PYEOF
from PIL import Image
src = Image.open("$TMP_4X").convert("RGB")
src.resize((1080, 760), Image.LANCZOS).save("dmg-background@2x.png", "PNG", optimize=True)
src.resize((540, 380),  Image.LANCZOS).save("dmg-background.png",    "PNG", optimize=True)
PYEOF

echo "✓ wrote dmg-background.png + dmg-background@2x.png"
