"""End-to-end browser-control smoke against the user's daily browser.

Exercises the new dom_snapshot / click_text / click_idx / wait_for / vision
pipeline. Requires:
  - bridge_server running:  uv run python -m agent2.bridge_server
  - extension installed and CONNECTED with the latest background.js
    (reload after pulling the latest commit)

Usage:
    uv run python -m agent2._smoke_browser
    uv run python -m agent2._smoke_browser 1 3      # only listed task numbers
"""
from __future__ import annotations

import asyncio
import sys
import time

from dotenv import load_dotenv

from .agent import Agent
from .bridge import call_via_server


TASKS = [
    # 1. Pure inventory — tests dom_snapshot
    (
        "snapshot_active_tab",
        "Take a DOM snapshot of my currently active browser tab. Tell me the total interactive element count and list the visible text of the first 5 elements.",
    ),
    # 2. Multi-step navigation + content extraction
    (
        "navigate_and_read",
        "Open https://news.ycombinator.com in a new tab, wait for the story list to load, "
        "then tell me the title and points of the top 3 stories.",
    ),
    # 3. Click interaction by visible text
    (
        "click_by_text",
        "Open https://news.ycombinator.com in a new tab. Wait for it to load. Then click "
        "the link in the top navigation labeled 'new' and tell me the URL of the resulting page.",
    ),
    # 4. Vision — only kicks in if the model decides to call screenshot
    (
        "screenshot_describe",
        "Open https://example.com in a new tab. Wait for it to load. Take a screenshot. "
        "Then tell me, based on the image, what color scheme the page uses and what the H1 says.",
    ),
]


async def _check_ready() -> bool:
    try:
        r = await call_via_server("tabs.dom_snapshot", {"max": 3}, timeout=3)
        return isinstance(r, dict) and "elements" in r
    except Exception:
        return False


async def main(argv: list[str]) -> int:
    load_dotenv()
    print("checking bridge + new RPCs...", flush=True)
    if not await _check_ready():
        print("✗ extension is not running the latest background.js")
        print("  reload it at chrome://extensions (or dia://extensions) and rerun this script.")
        return 2
    print("✓ extension reachable; new methods available\n")

    selected = set()
    for arg in argv[1:]:
        try:
            selected.add(int(arg) - 1)
        except ValueError:
            pass

    agent = Agent(verbose=True)
    pass_count = 0
    fail_count = 0
    for i, (label, prompt) in enumerate(TASKS):
        if selected and i not in selected:
            continue
        print(f"\n=== task {i+1}: {label} ===")
        print(f"prompt: {prompt}")
        t0 = time.perf_counter()
        try:
            result = await asyncio.wait_for(agent.run(prompt), timeout=240)
        except asyncio.TimeoutError:
            print(f"  TIMEOUT after 240s")
            fail_count += 1
            continue
        elapsed = time.perf_counter() - t0
        if result.error:
            print(f"  FAIL — {result.error}")
            fail_count += 1
        else:
            print(f"  ok  ({elapsed:.1f}s, {result.turns} turns, in/out/cached={result.input_tokens}/{result.output_tokens}/{result.cached_input_tokens})")
            print(f"  final: {result.final}")
            pass_count += 1

    print(f"\n=========\nresult: {pass_count} ok / {fail_count} fail")
    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv)))
