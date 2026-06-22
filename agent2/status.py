"""Quick status command:
    uv run python -m agent2.status

Reports whether the bridge port is up. To verify the extension is actually
connected, watch the live log of `agent2.bridge_server` or check the side
panel in your browser.
"""
from __future__ import annotations

import asyncio
import sys

from .bridge import HOST, PATH, PORT, detect


async def main() -> int:
    listening = await detect()
    if listening:
        print(f"agent2 bridge: listening on ws://{HOST}:{PORT}{PATH}")
        print("  to confirm the extension is actually connected, look at the bridge_server log")
        print("  or open the agent2 side panel in your browser (it shows a green dot when connected).")
        return 0
    print(f"agent2 bridge: NOT running on ws://{HOST}:{PORT}{PATH}")
    print("  start it: uv run python -m agent2.bridge_server")
    return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
