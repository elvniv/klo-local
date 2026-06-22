import json

from api.core import browser
from api.core.browser import (
    BrowserControlExecutor,
    _cdp_tab_from_target,
    best_tab_match,
    cdp_javascript,
    controlled_focus_tab,
    diagnose_capabilities,
    focus_tab_ladder,
    playback_state,
)
from api.core.contract import TrustedHandles


def test_best_tab_match_scores_title_and_url():
    tabs = [
        {"title": "OpenAI API", "url": "https://platform.openai.com", "index": 1},
        {"title": "D'Aaron Fox EPIC 50PT GAME! - YouTube", "url": "https://youtube.com/watch?v=x", "index": 2},
    ]

    match = best_tab_match("D'Aaron Fox YouTube", tabs)

    assert match is not None
    assert match["index"] == 2


def test_best_tab_match_returns_none_without_signal():
    assert best_tab_match("cursor", [{"title": "OpenAI", "url": "https://openai.com"}]) is None


async def test_focus_ladder_does_not_open_duplicate_url(monkeypatch):
    calls = []

    async def fake_native(window, index):
        return {"ok": False, "error": "native failed"}

    async def fake_cdp(target):
        return {"ok": False, "error": "no cdp"}

    async def fake_search(target):
        calls.append(("search", target["url"]))
        return {
            "ok": True,
            "active_url": target["url"],
            "target_url": target["url"],
        }

    async def fake_ax(target):
        calls.append(("ax", target["url"]))
        return {"ok": False}

    monkeypatch.setattr("api.core.browser._focus_browser_tab", fake_native)
    monkeypatch.setattr("api.core.browser._focus_tab_cdp", fake_cdp)
    monkeypatch.setattr("api.core.browser._focus_tab_with_search", fake_search)
    monkeypatch.setattr("api.core.browser._focus_tab_with_accessibility", fake_ax)

    result = await focus_tab_ladder({"window": 1, "index": 2, "url": "https://example.com"})

    assert result["ok"] is True
    assert result["method"] == "tab_search"
    assert calls == [("search", "https://example.com")]


async def test_diagnose_capabilities_reports_methods(monkeypatch):
    async def fake_browser_tabs():
        return {"browser": "Dia", "tabs": [{"title": "A", "url": "https://a.test"}]}

    async def fake_cdp_tabs(*args):
        return {"ok": False, "tabs": []}

    async def fake_cdp_available(port):
        return {"ok": True, "port": port}

    monkeypatch.setattr("api.core.browser._browser_tabs", fake_browser_tabs)
    monkeypatch.setattr("api.core.browser._cdp_tabs", fake_cdp_tabs)
    monkeypatch.setattr("api.core.browser._cdp_available", fake_cdp_available)

    result = await diagnose_capabilities()

    assert result["browser"] == "Dia"
    assert result["apple_script_tabs"] is True
    assert result["cdp"] is False
    assert result["controlled_browser"] is True
    assert result["controlled_browser_usable"] is False


def test_cdp_tab_from_target_normalizes_target():
    tab = _cdp_tab_from_target(
        9333,
        {"id": "abc", "title": "Example", "url": "https://example.com", "type": "page"},
    )

    assert tab == {
        "port": 9333,
        "id": "abc",
        "title": "Example",
        "url": "https://example.com",
    }


class _FakeWebSocket:
    def __init__(self, response: dict, sent: list[str]):
        self._response = response
        self._sent = sent

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def send(self, message: str) -> None:
        self._sent.append(message)

    async def recv(self) -> str:
        return json.dumps(self._response)


def _fake_connect(response: dict, sent: list[str]):
    def factory(*args, **kwargs):
        return _FakeWebSocket(response, sent)

    return factory


async def test_playback_state_returns_video_metadata(monkeypatch):
    target = {
        "id": "T1",
        "url": "https://www.youtube.com/watch?v=abc",
        "title": "video",
        "webSocketDebuggerUrl": "ws://localhost:9333/devtools/page/T1",
    }

    async def fake_resolve(tab_id=None, query=None):
        return target

    monkeypatch.setattr(browser, "_resolve_cdp_target", fake_resolve)
    sent: list[str] = []
    monkeypatch.setattr(
        browser.websockets,
        "connect",
        _fake_connect(
            {"id": 1, "result": {"result": {"value": {"paused": False, "fullscreen": True, "title": "video"}, "type": "object"}}},
            sent,
        ),
    )

    result = await playback_state()

    assert result["ok"] is True
    assert result["value"]["paused"] is False
    assert result["value"]["fullscreen"] is True
    assert sent
    sent_payload = json.loads(sent[0])
    assert sent_payload["method"] == "Runtime.evaluate"
    assert "document.querySelector('video')" in sent_payload["params"]["expression"]


async def test_cdp_javascript_propagates_runtime_exception(monkeypatch):
    target = {
        "id": "T1",
        "url": "https://example.com",
        "title": "x",
        "webSocketDebuggerUrl": "ws://localhost:9333/devtools/page/T1",
    }

    async def fake_resolve(tab_id=None, query=None):
        return target

    monkeypatch.setattr(browser, "_resolve_cdp_target", fake_resolve)
    sent: list[str] = []
    monkeypatch.setattr(
        browser.websockets,
        "connect",
        _fake_connect(
            {
                "id": 1,
                "result": {
                    "exceptionDetails": {"text": "ReferenceError: foo is not defined"}
                },
            },
            sent,
        ),
    )

    result = await cdp_javascript(expression="foo()")

    assert result["ok"] is False
    assert "ReferenceError" in result["error"]


async def test_cdp_javascript_no_target(monkeypatch):
    async def fake_resolve(tab_id=None, query=None):
        return None

    monkeypatch.setattr(browser, "_resolve_cdp_target", fake_resolve)

    result = await cdp_javascript(expression="1+1")

    assert result["ok"] is False
    assert "controllable" in result["error"]


async def test_browser_executor_records_urls_in_trusted_handles(monkeypatch):
    async def fake_browser_tabs():
        return {"browser": "Chrome", "tabs": [{"title": "X", "url": "https://x.test", "window": 1, "index": 1}]}

    monkeypatch.setattr(browser, "_browser_tabs", fake_browser_tabs)
    trusted = TrustedHandles()
    executor = BrowserControlExecutor(trusted=trusted)

    await executor.execute({"action": "list_tabs"})

    assert trusted.has_url("https://x.test")


async def test_controlled_focus_tab_reports_missing_match(monkeypatch):
    async def fake_ready():
        return {"ok": True}

    async def fake_cdp_tabs(ports):
        return {"ok": True, "tabs": [{"title": "OpenAI", "url": "https://openai.com", "id": "1", "port": 9333}]}

    monkeypatch.setattr("api.core.browser.ensure_controlled_browser", fake_ready)
    monkeypatch.setattr("api.core.browser._cdp_tabs", fake_cdp_tabs)

    result = await controlled_focus_tab("Notion")

    assert result["ok"] is False
    assert "No matching controlled tab" in result["error"]
