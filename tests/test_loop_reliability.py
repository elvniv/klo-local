"""Reliability fixes: display-geometry derivation, wall-time enforcement,
structured failure reasons, and the fast path for simple read-only prompts."""
from dataclasses import dataclass
from pathlib import Path

from api.config import Settings
from api.core.actions import ActionExecutor
from api.core.coords import ScreenGeometry
from api.core.loop import ComputerUseLoop
from api.core.loop_core import _is_simple_prompt
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
        self.all_kwargs = []

    async def create(self, **kwargs):
        self.last_kwargs = kwargs
        self.all_kwargs.append(kwargs)
        return self.scripted.pop(0)


class _StubClient:
    def __init__(self, scripted):
        self.messages = _Messages(scripted)
        self.beta = type("Beta", (), {"messages": self.messages})()


def _settings(tmp_path: Path, **overrides) -> Settings:
    base = dict(anthropic_api_key="test", database_path=tmp_path / "runs.sqlite3")
    base.update(overrides)
    return Settings(**base)


async def _store(settings: Settings) -> RunStore:
    store = RunStore(settings.database_path)
    await store.create_run("r", "do it")
    return store


def _last_status(events):
    return [e for e in events if e["type"] == "status_change"][-1]["payload"]


# ----------------------------------------------------------- display geometry

async def test_computer_tool_uses_real_screenshot_geometry(tmp_path, monkeypatch):
    async def fake_geometry(self):
        return ScreenGeometry(
            image_width_px=1512, image_height_px=982,
            logical_width_px=1512.0, logical_height_px=982.0,
        )

    monkeypatch.setattr(ActionExecutor, "ensure_geometry", fake_geometry)

    settings = _settings(tmp_path, max_turns=1)
    store = await _store(settings)
    client = _StubClient([_Response([_text("nope")])])
    await ComputerUseLoop(settings, store, client=client).run("r", "do it")

    computer = next(t for t in client.messages.last_kwargs["tools"] if t.get("name") == "computer")
    assert computer["display_width_px"] == 1512
    assert computer["display_height_px"] == 982


async def test_computer_tool_falls_back_when_geometry_unavailable(tmp_path, monkeypatch):
    async def broken_geometry(self):
        raise RuntimeError("no screen")

    monkeypatch.setattr(ActionExecutor, "ensure_geometry", broken_geometry)

    settings = _settings(tmp_path, max_turns=1)
    store = await _store(settings)
    client = _StubClient([_Response([_text("nope")])])
    await ComputerUseLoop(settings, store, client=client).run("r", "do it")

    computer = next(t for t in client.messages.last_kwargs["tools"] if t.get("name") == "computer")
    assert computer["display_width_px"] == 1440
    assert computer["display_height_px"] == 900


# ----------------------------------------------------------------- wall time

async def test_wall_time_exceeded_fails_with_structured_reason(tmp_path, monkeypatch):
    class _FakeTime:
        def __init__(self):
            self.now = 0.0

        def monotonic(self):
            self.now += 200.0
            return self.now

    monkeypatch.setattr("api.core.loop_core.time", _FakeTime())

    settings = _settings(tmp_path, max_turns=5, max_wall_time_seconds=100)
    store = await _store(settings)
    client = _StubClient([])
    await ComputerUseLoop(settings, store, client=client).run("r", "do it")

    payload = _last_status(await store.events("r"))
    assert payload["status"] == "failed"
    assert payload["failure_reason"] == "wall_time"
    assert "100" in payload["failure_detail"]
    assert client.messages.last_kwargs is None


# ----------------------------------------------------------- failure reasons

async def test_max_turns_failure_reason(tmp_path):
    settings = _settings(tmp_path, max_turns=2)
    store = await _store(settings)
    client = _StubClient([
        _Response([_text("no plan")]),
        _Response([_text("still no plan")]),
    ])
    await ComputerUseLoop(settings, store, client=client).run("r", "do it")

    payload = _last_status(await store.events("r"))
    assert payload["status"] == "failed"
    assert payload["failure_reason"] == "max_turns"
    assert payload["failure_detail"]


async def test_model_error_failure_reason(tmp_path):
    class _ExplodingMessages:
        async def create(self, **kwargs):
            raise RuntimeError("boom")

    class _ExplodingClient:
        def __init__(self):
            self.messages = _ExplodingMessages()
            self.beta = type("Beta", (), {"messages": self.messages})()

    settings = _settings(tmp_path, max_turns=2)
    store = await _store(settings)
    await ComputerUseLoop(settings, store, client=_ExplodingClient()).run("r", "do it")

    payload = _last_status(await store.events("r"))
    assert payload["status"] == "failed"
    assert payload["failure_reason"] == "model_error"
    assert "boom" in payload["failure_detail"]


async def test_max_screenshots_failure_reason(tmp_path, monkeypatch):
    from api.core.actions import ActionResult
    from api.core.screenshot import Screenshot

    async def fake_execute(self, tool_input):
        return ActionResult(
            screenshot=Screenshot(
                png=b"x",
                geometry=ScreenGeometry(100, 100, 100.0, 100.0),
            )
        )

    monkeypatch.setattr(ActionExecutor, "execute", fake_execute)

    plan_input = {
        "subtasks": [
            {
                "id": "s1",
                "goal": "demo",
                "surface": "computer",
                "evidence": [
                    {"from_tool": "macos", "expectation": {"must_contain": "ready"}}
                ],
            }
        ]
    }
    settings = _settings(tmp_path, max_turns=3, max_screenshots=0)
    store = await _store(settings)
    client = _StubClient([
        _Response([_tool_use("c1", "plan", plan_input)]),
        _Response([_tool_use("c2", "computer", {"action": "screenshot"})]),
        _Response([_text("done?")]),
    ])
    await ComputerUseLoop(settings, store, client=client).run("r", "do it")

    payload = _last_status(await store.events("r"))
    assert payload["status"] == "failed"
    assert payload["failure_reason"] == "max_screenshots"


# ------------------------------------------------------------------ fast path

def test_simple_prompt_heuristic_is_conservative():
    assert _is_simple_prompt("what time is it?")
    assert _is_simple_prompt("list the open windows")
    assert not _is_simple_prompt("do it")
    assert not _is_simple_prompt("what should I write in this email?")
    assert not _is_simple_prompt("delete all my screenshots?")
    assert not _is_simple_prompt("x" * 300 + "?")


async def test_fast_path_allows_direct_final_answer(tmp_path):
    settings = _settings(tmp_path, max_turns=2)
    store = await _store(settings)
    client = _StubClient([_Response([_text("It is 5pm.")])])
    await ComputerUseLoop(settings, store, client=client).run("r", "what time is it?")

    events = await store.events("r")
    types = [e["type"] for e in events]
    assert "plan_required" not in types
    assert "final_message" in types
    assert _last_status(events)["status"] == "completed"


async def test_fast_path_allows_read_only_tool_without_plan(tmp_path, monkeypatch):
    async def fake_macos_execute(self, tool_input):
        return "frontmost app is Safari"

    from api.core.macos import MacOSAssistExecutor

    monkeypatch.setattr(MacOSAssistExecutor, "execute", fake_macos_execute)

    settings = _settings(tmp_path, max_turns=3)
    store = await _store(settings)
    client = _StubClient([
        _Response([
            _tool_use("c1", "macos", {"action": "run_applescript", "intent": "read", "script": "x"})
        ]),
        _Response([_text("Safari is frontmost.")]),
    ])
    await ComputerUseLoop(settings, store, client=client).run("r", "what app is frontmost?")

    events = await store.events("r")
    tool_results = [e for e in events if e["type"] == "tool_result"]
    assert tool_results and not tool_results[0]["payload"]["is_error"]
    assert _last_status(events)["status"] == "completed"


async def test_fast_path_still_blocks_writes_without_plan(tmp_path):
    settings = _settings(tmp_path, max_turns=2)
    store = await _store(settings)
    client = _StubClient([
        _Response([_tool_use("c1", "macos", {"action": "paste_text", "text": "hi"})]),
        _Response([_text("ok")]),
    ])
    await ComputerUseLoop(settings, store, client=client).run("r", "what time is it?")

    second_call_messages = client.messages.all_kwargs[1]["messages"]
    tool_results = [
        block
        for message in second_call_messages
        if isinstance(message, dict) and isinstance(message.get("content"), list)
        for block in message["content"]
        if isinstance(block, dict) and block.get("type") == "tool_result"
    ]
    assert any(
        block["is_error"]
        and "must call plan first" in block["content"][0]["text"]
        for block in tool_results
    )


async def test_fast_path_disabled_keeps_plan_contract(tmp_path):
    settings = _settings(tmp_path, max_turns=2, fast_path=False)
    store = await _store(settings)
    client = _StubClient([
        _Response([_text("It is 5pm.")]),
        _Response([_text("It is 5pm.")]),
    ])
    await ComputerUseLoop(settings, store, client=client).run("r", "what time is it?")

    events = await store.events("r")
    assert "plan_required" in [e["type"] for e in events]
    assert _last_status(events)["status"] == "failed"
