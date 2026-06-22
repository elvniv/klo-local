"""Run the agent2 ↔ extension WebSocket bridge as a long-running process.

Usage:
    uv run python -m agent2.bridge_server

Once running, install the extension/ directory in your browser as an unpacked
extension; it will auto-connect within ~3 seconds.
"""
from __future__ import annotations

import asyncio
import logging
import sys

from .bridge import bridge, serve


async def _status_loop() -> None:
    last = None
    while True:
        state = bridge.connected
        if state != last:
            mark = "✓ connected" if state else "… waiting for extension"
            print(f"  [bridge] {mark}  client_meta={bridge.client_meta}", flush=True)
            last = state
        await asyncio.sleep(1)


async def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    print("agent2 bridge starting on ws://127.0.0.1:8767/extension")
    print("  load the repo's extension/ directory as an unpacked extension")
    print("  Ctrl-C to stop")
    await asyncio.gather(serve(), _status_loop())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        print("\nstopped")
        sys.exit(0)
