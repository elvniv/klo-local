"""Verify both screenshot paths land:
  1. Native chrome.tabs.captureVisibleTab (fast)
  2. html2canvas DOM render (slower fallback, works without user click)

Saves the resulting PNGs to /tmp so we can eyeball them.
"""
from __future__ import annotations

import asyncio
import base64
import sys
import time
from pathlib import Path

from agent2.bridge import call_via_server


OUT = Path("/tmp/agent2-screenshots")


async def main() -> int:
    OUT.mkdir(exist_ok=True)

    # Find a regular http tab (not chrome://) to target.
    tabs = await call_via_server("tabs.list", {"current_window": True}, timeout=3)
    target = next((t for t in tabs if t["url"].startswith(("http://", "https://"))), None)
    if not target:
        print("✗ no http(s) tab open in current window")
        return 1
    print(f"target tab: {target['title']!r} — {target['url']}")

    print("\ncalling tabs.screenshot...")
    t0 = time.perf_counter()
    try:
        result = await call_via_server("tabs.screenshot", {"tab_id": target["id"]}, timeout=15)
    except Exception as exc:
        print(f"✗ {exc}")
        return 1
    elapsed = time.perf_counter() - t0
    method = result.get("method", "?")
    data_url = result.get("data_url", "")
    if not data_url.startswith("data:image/"):
        print(f"✗ no data_url returned: {result}")
        return 1

    # Decode and save
    header, _, b64 = data_url.partition(",")
    raw = base64.b64decode(b64)
    fname = OUT / f"screenshot-{int(time.time())}-{method}.png"
    fname.write_bytes(raw)

    print(f"✓ {method}, {len(raw):,} bytes, {elapsed:.2f}s → {fname}")
    if "width" in result:
        print(f"  dimensions: {result['width']}x{result['height']}")

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
