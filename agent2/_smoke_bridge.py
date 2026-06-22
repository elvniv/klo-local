"""Internal smoke test: run the bridge server, connect a fake-extension client
that handles RPC the way the real extension would, and exercise every tool.

Usage:
    uv run python -m agent2._smoke_bridge

Validates:
  - Bridge server starts cleanly.
  - Extension connects, sends hello, becomes "connected".
  - bridge.call() round-trips for ping, tabs.list, tabs.read_text.
  - "extension not connected" path fires correctly when the fake disconnects.
"""
from __future__ import annotations

import asyncio
import json
import sys

import websockets

from .bridge import HOST, PATH, PORT, bridge, serve


# ----- fake extension that responds to a known set of RPCs ------------------

FAKE_TABS = [
    {"id": 1, "title": "Hacker News", "url": "https://news.ycombinator.com", "active": True, "windowId": 100},
    {"id": 2, "title": "Wikipedia: Penguin", "url": "https://en.wikipedia.org/wiki/Penguin", "active": False, "windowId": 100},
]


async def _fake_extension(stop_event: asyncio.Event) -> None:
    async with websockets.connect(f"ws://{HOST}:{PORT}{PATH}") as ws:
        await ws.send(json.dumps({"kind": "hello", "version": "fake-0.0.1", "ua": "smoke-test"}))
        async def reader():
            async for raw in ws:
                msg = json.loads(raw)
                req_id = msg.get("id")
                method = msg.get("method")
                params = msg.get("params") or {}
                if method == "ping":
                    await ws.send(json.dumps({"id": req_id, "result": {"ok": True, "version": "fake-0.0.1", "ts": 0}}))
                elif method == "tabs.list":
                    await ws.send(json.dumps({"id": req_id, "result": FAKE_TABS}))
                elif method == "tabs.active":
                    await ws.send(json.dumps({"id": req_id, "result": FAKE_TABS[0]}))
                elif method == "tabs.read_text":
                    text = "Penguins are a group of flightless semi-aquatic sea birds…"
                    await ws.send(json.dumps({"id": req_id, "result": {
                        "url": FAKE_TABS[1]["url"],
                        "title": FAKE_TABS[1]["title"],
                        "text": text,
                        "chars": len(text),
                        "truncated": False,
                    }}))
                else:
                    await ws.send(json.dumps({"id": req_id, "error": f"unsupported in smoke: {method}"}))
        reader_task = asyncio.create_task(reader())
        await stop_event.wait()
        reader_task.cancel()


async def main() -> int:
    server_task = asyncio.create_task(serve())
    # Give the server a moment to bind.
    await asyncio.sleep(0.4)

    print("✓ bridge server up on ws://%s:%d%s" % (HOST, PORT, PATH))
    print("  testing connection state pre-extension…")
    if bridge.connected:
        print("  ! unexpectedly already connected")
        return 1
    print("  bridge.connected = False (expected)")

    stop_event = asyncio.Event()
    fake_task = asyncio.create_task(_fake_extension(stop_event))
    # Wait for the fake to connect + hello to land.
    for _ in range(30):
        await asyncio.sleep(0.1)
        if bridge.connected:
            break
    if not bridge.connected:
        print("  ✗ fake extension never registered")
        stop_event.set()
        await fake_task
        return 1
    print(f"  ✓ fake extension connected: {bridge.client_meta}")

    # ---- exercise three RPCs ----
    pong = await bridge.call("ping")
    assert pong["ok"] is True, pong
    print(f"  ✓ ping → {pong}")

    tabs = await bridge.call("tabs.list")
    assert isinstance(tabs, list) and len(tabs) == 2
    print(f"  ✓ tabs.list → {len(tabs)} tabs")

    page = await bridge.call("tabs.read_text", {"tab_id": 2})
    assert "Penguins" in page["text"]
    print(f"  ✓ tabs.read_text → {page['title']!r}, {page['chars']} chars")

    # ---- error path: disconnect the fake and confirm the next call errors cleanly ----
    stop_event.set()
    await fake_task
    # Allow the bridge to notice the disconnect.
    for _ in range(20):
        await asyncio.sleep(0.1)
        if not bridge.connected:
            break
    if bridge.connected:
        print("  ✗ bridge still claims connected after fake hung up")
        return 1
    print("  ✓ bridge.connected = False after fake disconnect")
    try:
        await bridge.call("ping", timeout=2)
        print("  ✗ ping should have errored after disconnect")
        return 1
    except RuntimeError as exc:
        print(f"  ✓ post-disconnect call errored as expected: {exc}")

    print("\nSMOKE PASSED")
    server_task.cancel()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
