"""Smoke tests for the Anthropic adapter wiring through LoopCore.

These verify the public ComputerUseLoop entry point still works and that the
adapter correctly drives the loop through plan -> readback -> commit -> finalize.
"""
import json
from dataclasses import dataclass
from pathlib import Path

from api.config import Settings
from api.core.loop import ComputerUseLoop
from api.store.persist import RunStore


@dataclass
class _Block:
    type: str
    text: str = ""
    id: str = ""
    name: str = ""
    input: dict | None = None


def _text(text):
    return _Block(type="text", text=text)


def _tool_use(id, name, input):
    return _Block(type="tool_use", id=id, name=name, input=input or {})


class _Response:
    def __init__(self, blocks):
        self.content = blocks


class _Messages:
    def __init__(self, scripted):
        self.scripted = list(scripted)
        self.last_kwargs = None

    async def create(self, **kwargs):
        self.last_kwargs = kwargs
        return self.scripted.pop(0)


class _StubClient:
    def __init__(self, scripted):
        self.messages = _Messages(scripted)
        self.beta = type("Beta", (), {"messages": self.messages})()


PLAN_INPUT = {
    "subtasks": [
        {
            "id": "s1",
            "goal": "demo",
            "surface": "macos",
            "evidence": [
                {
                    "from_tool": "macos",
                    "from_action": "run_applescript",
                    "from_intent": "read",
                    "expectation": {"must_contain": "ready"},
                }
            ],
        }
    ]
}


async def test_loop_emits_plan_required_when_first_turn_skips_plan(tmp_path: Path):
    settings = Settings(
        anthropic_api_key="test",
        database_path=tmp_path / "runs.sqlite3",
        max_turns=2,
    )
    store = RunStore(settings.database_path)
    await store.create_run("r", "do it")

    scripted = [
        _Response([_text("hello no plan")]),
        _Response([_text("still no plan")]),
    ]
    loop = ComputerUseLoop(settings, store, client=_StubClient(scripted))

    await loop.run("r", "do it")

    events = await store.events("r")
    types = [event["type"] for event in events]
    assert "plan_required" in types
    assert types[-1] == "status_change"
    assert events[-1]["payload"]["status"] == "failed"


async def test_loop_runs_plan_then_finalizes(tmp_path: Path, monkeypatch):
    settings = Settings(
        anthropic_api_key="test",
        database_path=tmp_path / "runs.sqlite3",
        max_turns=6,
    )
    store = RunStore(settings.database_path)
    await store.create_run("r", "do it")

    async def fake_macos_execute(self, tool_input):
        return "player state is ready"

    from api.core.macos import MacOSAssistExecutor

    monkeypatch.setattr(MacOSAssistExecutor, "execute", fake_macos_execute)

    scripted = [
        _Response([_tool_use("c1", "plan", PLAN_INPUT)]),
        _Response(
            [
                _tool_use(
                    "c2",
                    "macos",
                    {"action": "run_applescript", "intent": "read", "script": "x"},
                )
            ]
        ),
        _Response([_tool_use("c3", "commit_subtask", {"subtask_id": "s1"})]),
        _Response([_text("done")]),
    ]
    loop = ComputerUseLoop(settings, store, client=_StubClient(scripted))

    await loop.run("r", "do it")

    events = await store.events("r")
    types = [event["type"] for event in events]
    assert "plan" in types
    assert "evidence_satisfied" in types
    assert "subtask_commit" in types
    assert types[-1] == "status_change"
    assert events[-1]["payload"]["status"] == "completed"


async def test_loop_blocks_finalize_until_evidence_satisfied(tmp_path: Path):
    settings = Settings(
        anthropic_api_key="test",
        database_path=tmp_path / "runs.sqlite3",
        max_turns=4,
    )
    store = RunStore(settings.database_path)
    await store.create_run("r", "do it")

    scripted = [
        _Response([_tool_use("c1", "plan", PLAN_INPUT)]),
        _Response([_text("done now")]),
        _Response([_text("still nothing")]),
        _Response([_text("still nothing")]),
    ]
    loop = ComputerUseLoop(settings, store, client=_StubClient(scripted))

    await loop.run("r", "do it")

    events = await store.events("r")
    types = [event["type"] for event in events]
    assert "verification_required" in types
    assert events[-1]["payload"]["status"] == "failed"


async def test_loop_exposes_contract_tools_alongside_surface_tools(tmp_path: Path):
    settings = Settings(
        anthropic_api_key="test",
        database_path=tmp_path / "runs.sqlite3",
        max_turns=1,
    )
    store = RunStore(settings.database_path)
    await store.create_run("r", "do it")

    client = _StubClient([_Response([_text("nope")])])
    loop = ComputerUseLoop(settings, store, client=client)
    await loop.run("r", "do it")

    tools = client.messages.last_kwargs["tools"]
    names = {tool.get("name") for tool in tools}
    expected = {
        "computer",
        "macos",
        "browser",
        "system",
        "web",
        "accessibility",
        "plan",
        "revise_plan",
        "escalate",
        "commit_subtask",
    }
    assert expected <= names
