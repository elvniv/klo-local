import asyncio
from datetime import datetime
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

from api.config import Settings, get_settings
from api.core.loop import ComputerUseLoop
from api.core.loop_core import pop_pause_state
from api.core.openai_loop import OpenAIAXLoop
from api.deps import get_store
from api.store.bus import bus
from api.store.persist import RunStore


router = APIRouter()


class CreateRunRequest(BaseModel):
    prompt: str = Field(min_length=1)
    prior_messages: list[dict[str, Any]] | None = None


class CreateRunResponse(BaseModel):
    run_id: str


class RunSummary(BaseModel):
    id: str
    prompt: str
    status: str
    created_at: str
    updated_at: str
    duration_ms: int | None = None
    tool_calls: int = 0
    screenshots: int = 0
    final_message: str | None = None
    model_turns: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cached_input_tokens: int = 0
    failure_reason: str | None = None
    failure_detail: str | None = None
    pause_reason: str | None = None


@router.post("/runs", response_model=CreateRunResponse)
async def create_run(
    body: CreateRunRequest,
    settings: Settings = Depends(get_settings),
    store: RunStore = Depends(get_store),
) -> CreateRunResponse:
    if settings.model_provider == "anthropic" and not settings.anthropic_api_key:
        raise HTTPException(status_code=400, detail="Set ANTHROPIC_API_KEY in .env first.")
    if settings.model_provider == "openai" and not settings.openai_api_key:
        raise HTTPException(status_code=400, detail="Set OPENAI_API_KEY in .env first.")

    run_id = str(uuid4())
    await store.create_run(run_id, body.prompt)

    loop = _loop_for_provider(settings, store)
    asyncio.create_task(loop.run(run_id, body.prompt, body.prior_messages))
    return CreateRunResponse(run_id=run_id)


@router.post("/runs/{run_id}/resume", response_model=CreateRunResponse)
async def resume_run(
    run_id: str,
    settings: Settings = Depends(get_settings),
    store: RunStore = Depends(get_store),
) -> CreateRunResponse:
    run = await store.get_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="Run not found.")
    if run["status"] != "paused":
        raise HTTPException(status_code=409, detail=f"Run is {run['status']!r}, not paused.")
    state = pop_pause_state(run_id)
    if state is None:
        raise HTTPException(
            status_code=409,
            detail="Pause state unavailable (sidecar restarted?). Start a new run.",
        )
    loop = _loop_for_provider(settings, store)
    asyncio.create_task(loop.run(run_id, run["prompt"], resume_state=state))
    return CreateRunResponse(run_id=run_id)


@router.get("/runs", response_model=list[RunSummary])
async def list_runs(limit: int = 50, store: RunStore = Depends(get_store)) -> list[RunSummary]:
    runs = await store.list_runs(limit=max(1, min(limit, 200)))
    summaries = []
    for run in runs:
        events = await store.events(run["id"])
        summaries.append(_summarize_run(run, events))
    return summaries


@router.get("/runs/{run_id}")
async def get_run(run_id: str, store: RunStore = Depends(get_store)) -> dict[str, Any]:
    run = await store.get_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="Run not found.")
    events = await store.events(run_id)
    return {
        "run": _summarize_run(run, events).model_dump(),
        "events": events,
    }


@router.websocket("/ws/runs/{run_id}")
async def run_events(websocket: WebSocket, run_id: str, store: RunStore = Depends(get_store)):
    await websocket.accept()
    for event in await store.events(run_id):
        await websocket.send_json(event)

    try:
        async for event in bus.subscribe(run_id):
            await websocket.send_json(event)
            if event["type"] == "status_change" and event["payload"].get("status") in {
                "completed",
                "failed",
                "paused",
            }:
                break
    except WebSocketDisconnect:
        return


def _summarize_run(run: dict[str, Any], events: list[dict[str, Any]]) -> RunSummary:
    final_message = None
    usage_total: dict[str, int] = {}
    model_turns = 0
    failure_reason = failure_detail = pause_reason = None
    for event in events:
        et = event["type"]
        if et == "status_change":
            payload = event["payload"] or {}
            if payload.get("status") == "failed":
                failure_reason = payload.get("failure_reason")
                failure_detail = payload.get("failure_detail") or payload.get("reason")
            elif payload.get("status") == "paused":
                pause_reason = payload.get("pause_reason") or payload.get("reason")
        if et == "final_message":
            final_message = event["payload"].get("text")
        elif et == "usage_total":
            usage_total = event["payload"] or {}
        elif et == "model_usage":
            model_turns += 1
            # Fallback: if no usage_total event was emitted (e.g. status_change
            # arrived before the totals), reconstruct from the last delta total.
            if not usage_total:
                usage_total = event["payload"].get("total") or {}
            else:
                usage_total = event["payload"].get("total") or usage_total

    screenshots = sum(
        1
        for event in events
        if event["type"] == "tool_result" and event["payload"].get("has_screenshot")
    )
    tool_calls = sum(1 for event in events if event["type"] == "tool_call")
    return RunSummary(
        **run,
        duration_ms=_duration_ms(run["created_at"], run["updated_at"]),
        tool_calls=tool_calls,
        screenshots=screenshots,
        final_message=final_message,
        model_turns=model_turns,
        input_tokens=int(usage_total.get("input_tokens", 0) or 0),
        output_tokens=int(usage_total.get("output_tokens", 0) or 0),
        cached_input_tokens=int(usage_total.get("cached_input_tokens", 0) or 0),
        failure_reason=failure_reason if run["status"] == "failed" else None,
        failure_detail=failure_detail if run["status"] == "failed" else None,
        pause_reason=pause_reason if run["status"] == "paused" else None,
    )


def _duration_ms(start: str, end: str) -> int | None:
    try:
        started = datetime.fromisoformat(start)
        ended = datetime.fromisoformat(end)
    except ValueError:
        return None
    return round((ended - started).total_seconds() * 1000)


def _loop_for_provider(settings: Settings, store: RunStore):
    if settings.model_provider == "openai":
        return OpenAIAXLoop(settings=settings, store=store)
    if settings.model_provider == "anthropic":
        return ComputerUseLoop(settings=settings, store=store)
    raise HTTPException(status_code=400, detail=f"Unknown MODEL_PROVIDER={settings.model_provider!r}.")
