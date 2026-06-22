import argparse
import asyncio
import json
import sys
from typing import Any

import httpx
import websockets


DEFAULT_API = "http://127.0.0.1:8787"


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "doctor":
        from cli.doctor import main as doctor_main

        sys.exit(asyncio.run(doctor_main()))

    parser = argparse.ArgumentParser(description="Run a klo desktop-agent prompt.")
    parser.add_argument("prompt", help="What klo should do on your Mac, or 'doctor' to diagnose the setup.")
    parser.add_argument("--api", default=DEFAULT_API, help="FastAPI sidecar base URL.")
    parser.add_argument(
        "--prior-message",
        action="append",
        default=[],
        help="Optional prior conversation message as role:content.",
    )
    args = parser.parse_args()
    asyncio.run(_run(args.prompt, args.api.rstrip("/"), args.prior_message))


async def _run(prompt: str, api_base: str, prior_messages_raw: list[str]) -> None:
    prior_messages = [_parse_prior(value) for value in prior_messages_raw]
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            f"{api_base}/runs",
            json={"prompt": prompt, "prior_messages": prior_messages or None},
        )
        response.raise_for_status()
        body = response.json()
        run_id = body.get("id") or body.get("run_id")
        if not run_id:
            raise RuntimeError(f"sidecar did not return a run id: {body}")

    print(f"klo run {run_id}")
    ws_url = api_base.replace("http://", "ws://").replace("https://", "wss://")
    async with websockets.connect(f"{ws_url}/ws/runs/{run_id}") as websocket:
        async for raw in websocket:
            event = json.loads(raw)
            _print_event(event)
            if event["type"] == "status_change" and event["payload"].get("status") in {
                "completed",
                "failed",
                "paused",
            }:
                return


def _parse_prior(value: str) -> dict[str, Any]:
    role, _, content = value.partition(":")
    if role not in {"user", "assistant"} or not content:
        raise SystemExit("--prior-message must look like user:hello or assistant:done")
    return {"role": role, "content": content}


def _print_event(event: dict[str, Any]) -> None:
    event_type = event["type"]
    payload = event["payload"]
    if event_type == "status_change":
        status = payload["status"]
        detail = payload.get("failure_detail") or payload.get("failure_reason")
        if status == "failed" and detail:
            print(f"[status] failed — {detail}")
        elif status == "paused" and (payload.get("pause_reason") or payload.get("reason")):
            print(f"[status] paused — {payload.get('pause_reason') or payload.get('reason')}")
        else:
            print(f"[status] {status}")
    elif event_type == "tool_call":
        action = payload.get("input", {}).get("action") or payload.get("name")
        print(f"[tool] {action}")
    elif event_type == "tool_result":
        suffix = " + screenshot" if payload.get("has_screenshot") else ""
        text = (payload.get("text") or "ok").splitlines()[0][:200]
        print(f"[result] {text}{suffix}")
    elif event_type == "agent_thought":
        print(f"[thought] {payload['text']}")
    elif event_type == "plan":
        ids = [s.get("id") for s in payload.get("subtasks", [])]
        print(f"[plan] subtasks: {ids}")
    elif event_type == "plan_failed":
        print(f"[plan-failed] {payload.get('reason', '')}")
    elif event_type == "plan_revised":
        ids = [s.get("id") for s in payload.get("appended", [])]
        print(f"[plan-revised] +{ids}")
    elif event_type == "evidence_satisfied":
        print(f"[evidence] {payload.get('subtask_id')}")
    elif event_type == "subtask_commit":
        print(f"[committed] {payload.get('subtask_id')}")
    elif event_type == "subtask_abandoned":
        print(f"[abandoned] {payload.get('subtask_id')} — {payload.get('reason', '')}")
    elif event_type == "verification_required":
        pending = payload.get("pending_subtasks") or []
        print(f"[verify] pending: {pending}")
    elif event_type == "escalate":
        print(f"[escalate] {payload.get('subtask_id')} → {payload.get('new_surface')}")
    elif event_type == "workspace":
        print(
            f"[workspace] dedicated_space={payload['dedicated_space_enabled']} "
            f"active_app={payload.get('active_app')}"
        )
    elif event_type == "final_message":
        print(f"[final] {payload['text']}")
    elif event_type == "error":
        print(f"[error] {payload.get('text', '')}")
    else:
        # Fallback for events we don't yet pretty-print — still terse.
        print(f"[{event_type}]")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
