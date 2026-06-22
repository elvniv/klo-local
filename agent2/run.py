"""CLI entry: `python -m agent2.run "<task>"`."""
from __future__ import annotations

import asyncio
import json
import sys
import uuid

from dotenv import load_dotenv

from .agent import Agent


async def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: python -m agent2.run \"<task>\"", file=sys.stderr)
        return 2
    task = " ".join(argv[1:]).strip()
    load_dotenv()

    run_id = uuid.uuid4().hex[:12]

    async def on_run_start(payload: dict) -> None:
        # Best-effort push of task.begin so the extension's focus-takeover
        # detection arms. If the bridge_server isn't running (or no
        # extension is connected) this silently no-ops — the agent loop
        # still works, the user just won't get the "user wandered off"
        # auto-handoff behavior. Same shape used by desktop_api.
        try:
            from .bridge import call_via_server
            await call_via_server("_internal.push_event", {
                "name": "task.begin",
                "payload": {"run_id": run_id, "task": task[:200]},
            }, timeout=2)
        except Exception:
            pass

    async def on_run_end(payload: dict) -> None:
        try:
            from .bridge import call_via_server
            data = dict(payload or {})
            data["run_id"] = run_id
            await call_via_server("_internal.push_event", {
                "name": "task.end",
                "payload": data,
            }, timeout=2)
        except Exception:
            pass

    agent = Agent(on_run_start=on_run_start, on_run_end=on_run_end)
    result = await agent.run(task)
    print()
    print("==========")
    print(f"final: {result.final!r}")
    print(f"turns: {result.turns}  elapsed: {result.elapsed_s:.1f}s")
    print(f"tokens: in={result.input_tokens} out={result.output_tokens} cached={result.cached_input_tokens}")
    if result.handoff:
        print(f"handoff: {result.handoff_message!r}")
    if result.error:
        print(f"ERROR: {result.error}")
    return 0 if result.error is None else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv)))
