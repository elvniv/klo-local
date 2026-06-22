from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx
import websockets

from api.core import input as mac_input
from api.core.contract import TrustedHandles
from api.core.macos import (
    _activate_app_by_name,
    _browser_tab,
    _browser_tabs,
    _focus_browser_tab,
)
from api.core.os_context import get_os_context


BROWSER_TOOL = {
    "name": "browser",
    "description": (
        "Generic browser control. Use it for browser tab inventory and tab focusing "
        "before falling back to visual tab-strip clicks. It verifies the active tab. "
        "playback_state and javascript run via the controlled-CDP browser; call "
        "ensure_controlled and controlled_open_url first."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": [
                    "active_tab",
                    "list_tabs",
                    "focus_tab",
                    "diagnose_capabilities",
                    "ensure_controlled",
                    "controlled_list_tabs",
                    "controlled_open_url",
                    "controlled_focus_tab",
                    "playback_state",
                    "javascript",
                ],
            },
            "query": {
                "type": "string",
                "description": "Text to match against tab title or URL.",
            },
            "window": {
                "type": "integer",
                "description": "Browser window number from list_tabs.",
            },
            "index": {
                "type": "integer",
                "description": "Browser tab index from list_tabs.",
            },
            "url": {
                "type": "string",
                "description": "URL for controlled_open_url.",
            },
            "expression": {
                "type": "string",
                "description": "JavaScript expression to evaluate via Runtime.evaluate (CDP).",
            },
            "intent": {
                "type": "string",
                "enum": ["read", "write"],
                "description": "For javascript, declare whether the expression reads state or mutates state.",
            },
            "tab_id": {
                "type": "string",
                "description": "Optional CDP target id; defaults to first non-blank page in the controlled browser.",
            },
        },
        "required": ["action"],
        "additionalProperties": False,
    },
}


class BrowserControlExecutor:
    def __init__(self, trusted: TrustedHandles | None = None) -> None:
        self.trusted = trusted

    async def execute(self, tool_input: dict[str, Any]) -> str:
        action = tool_input.get("action")
        if action == "active_tab":
            payload = await _browser_tab()
            self._record_urls([payload])
            return json.dumps(payload, ensure_ascii=False)
        if action == "list_tabs":
            payload = await _browser_tabs()
            self._record_urls(payload.get("tabs", []))
            return json.dumps(payload, ensure_ascii=False)
        if action == "diagnose_capabilities":
            return json.dumps(await diagnose_capabilities(), ensure_ascii=False)
        if action == "ensure_controlled":
            return json.dumps(await ensure_controlled_browser(), ensure_ascii=False)
        if action == "controlled_list_tabs":
            payload = await _cdp_tabs((CONTROLLED_CDP_PORT,))
            self._record_urls(payload.get("tabs", []))
            return json.dumps(payload, ensure_ascii=False)
        if action == "controlled_open_url":
            url = str(tool_input.get("url") or "about:blank")
            payload = await controlled_open_url(url)
            target = payload.get("target") or {}
            self._record_urls([target])
            return json.dumps(payload, ensure_ascii=False)
        if action == "controlled_focus_tab":
            return json.dumps(await controlled_focus_tab(str(tool_input.get("query") or "")), ensure_ascii=False)
        if action == "playback_state":
            payload = await playback_state(
                tab_id=tool_input.get("tab_id") or None,
                query=str(tool_input.get("query") or "") or None,
            )
            return json.dumps(payload, ensure_ascii=False)
        if action == "javascript":
            payload = await cdp_javascript(
                expression=str(tool_input.get("expression") or ""),
                tab_id=tool_input.get("tab_id") or None,
                query=str(tool_input.get("query") or "") or None,
            )
            return json.dumps(payload, ensure_ascii=False)
        if action == "focus_tab":
            target = await _target_tab(tool_input)
            if not target:
                return json.dumps(
                    {"ok": False, "error": "No matching tab found.", "query": tool_input.get("query")},
                    ensure_ascii=False,
                )
            result = await focus_tab_ladder(target)
            result["matched_tab"] = target
            return json.dumps(result, ensure_ascii=False)
        raise ValueError(f"Unsupported browser action: {action!r}")

    def _record_urls(self, items: list[dict[str, Any]]) -> None:
        if self.trusted is None:
            return
        for item in items:
            url = item.get("url") if isinstance(item, dict) else None
            if isinstance(url, str):
                self.trusted.add_url(url)


CONTROLLED_CDP_PORT = 9333
CONTROLLED_PROFILE = Path(".klo/controlled-browser").resolve()


async def _target_tab(tool_input: dict[str, Any]) -> dict[str, Any] | None:
    if tool_input.get("window") and tool_input.get("index"):
        return {"window": int(tool_input["window"]), "index": int(tool_input["index"])}

    query = str(tool_input.get("query") or "").strip()
    if not query:
        raise ValueError("focus_tab requires query or window/index")
    tabs_result = await _browser_tabs()
    tabs = tabs_result.get("tabs", [])
    return best_tab_match(query, tabs)


def best_tab_match(query: str, tabs: list[dict[str, Any]]) -> dict[str, Any] | None:
    terms = [term for term in query.lower().replace("'", "").split() if term]
    best = None
    best_score = 0
    for tab in tabs:
        haystack = f"{tab.get('title', '')} {tab.get('url', '')}".lower().replace("'", "")
        score = sum(1 for term in terms if term in haystack)
        if query.lower() in haystack:
            score += len(terms) + 2
        if score > best_score:
            best = tab
            best_score = score
    return best if best_score > 0 else None


async def focus_tab_ladder(target: dict[str, Any]) -> dict[str, Any]:
    attempts = []

    native = await _focus_browser_tab(int(target["window"]), int(target["index"]))
    attempts.append({"method": "native_script", "ok": native.get("ok"), "detail": native})
    if _focused_expected_tab(native, target):
        native["method"] = "native_script"
        native["attempts"] = attempts
        return native

    cdp = await _focus_tab_cdp(target)
    attempts.append({"method": "cdp", "ok": cdp.get("ok"), "detail": cdp})
    if _focused_expected_tab(cdp, target):
        cdp["method"] = "cdp"
        cdp["attempts"] = attempts
        return cdp

    tab_search = await _focus_tab_with_search(target)
    attempts.append({"method": "tab_search", "ok": tab_search.get("ok"), "detail": tab_search})
    if _focused_expected_tab(tab_search, target):
        tab_search["method"] = "tab_search"
        tab_search["attempts"] = attempts
        return tab_search

    ax = await _focus_tab_with_accessibility(target)
    attempts.append({"method": "accessibility", "ok": ax.get("ok"), "detail": ax})
    if _focused_expected_tab(ax, target):
        ax["method"] = "accessibility"
        ax["attempts"] = attempts
        return ax

    return {
        "ok": False,
        "error": "Could not focus existing tab without opening a duplicate URL.",
        "target_title": target.get("title", ""),
        "target_url": target.get("url", ""),
        "attempts": attempts,
    }


async def diagnose_capabilities() -> dict[str, Any]:
    tabs = await _browser_tabs()
    cdp = await _cdp_tabs()
    controlled = await _cdp_available(CONTROLLED_CDP_PORT)
    controlled_tabs = await _cdp_tabs((CONTROLLED_CDP_PORT,))
    return {
        "browser": tabs.get("browser"),
        "apple_script_tabs": bool(tabs.get("tabs")),
        "apple_script_focus": "unknown_until_focus_attempt",
        "tab_search": True,
        "accessibility_tab_strip": "best_effort",
        "cdp": bool(cdp.get("ok")),
        "cdp_targets": len(cdp.get("tabs", [])),
        "controlled_browser": bool(controlled.get("ok")),
        "controlled_browser_page_targets": len(controlled_tabs.get("tabs", [])),
        "controlled_browser_usable": bool(controlled.get("ok") and controlled_tabs.get("tabs")),
        "controlled_port": CONTROLLED_CDP_PORT,
    }


async def ensure_controlled_browser(url: str = "about:blank") -> dict[str, Any]:
    existing = await _cdp_available(CONTROLLED_CDP_PORT)
    if existing.get("ok"):
        tabs = await _cdp_tabs((CONTROLLED_CDP_PORT,))
        return {
            "ok": True,
            "already_running": True,
            "port": CONTROLLED_CDP_PORT,
            "usable": bool(tabs.get("tabs")),
            "tabs": tabs.get("tabs", []),
        }

    browser = get_os_context().default_browser_name
    if not browser:
        return {"ok": False, "error": "Default browser unknown."}
    CONTROLLED_PROFILE.mkdir(parents=True, exist_ok=True)
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/open",
        "-n",
        "-a",
        browser,
        "--args",
        f"--remote-debugging-port={CONTROLLED_CDP_PORT}",
        f"--user-data-dir={CONTROLLED_PROFILE}",
        url,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    await proc.communicate()
    for _ in range(20):
        available = await _cdp_available(CONTROLLED_CDP_PORT)
        if available.get("ok"):
            tabs = await _cdp_tabs((CONTROLLED_CDP_PORT,))
            return {
                "ok": True,
                "already_running": False,
                "browser": browser,
                "port": CONTROLLED_CDP_PORT,
                "profile": str(CONTROLLED_PROFILE),
                "usable": bool(tabs.get("tabs")),
                "tabs": tabs.get("tabs", []),
            }
        await asyncio.sleep(0.5)
    return {
        "ok": False,
        "browser": browser,
        "port": CONTROLLED_CDP_PORT,
        "profile": str(CONTROLLED_PROFILE),
        "error": "Controlled browser did not expose CDP after launch.",
    }


async def controlled_open_url(url: str) -> dict[str, Any]:
    ready = await ensure_controlled_browser()
    if not ready.get("ok"):
        return ready
    async with httpx.AsyncClient(timeout=5) as client:
        response = await client.put(f"http://127.0.0.1:{CONTROLLED_CDP_PORT}/json/new?{quote(url, safe=':/?&=%')}")
        if response.status_code not in {200, 201}:
            return {"ok": False, "error": response.text, "status": response.status_code}
        target = response.json()
    # Some Chromium-based browsers expose /json/version and /json/new but never
    # publish page targets in /json/list. Treat that as non-usable for control.
    await asyncio.sleep(0.5)
    tabs = await _cdp_tabs((CONTROLLED_CDP_PORT,))
    normalized = _cdp_tab_from_target(CONTROLLED_CDP_PORT, target)
    visible = any(tab.get("id") == normalized.get("id") for tab in tabs.get("tabs", []))
    return {"ok": visible, "target": normalized, "tabs": tabs.get("tabs", []), "error": None if visible else "Controlled browser did not expose a controllable page target."}


async def controlled_focus_tab(query: str) -> dict[str, Any]:
    ready = await ensure_controlled_browser()
    if not ready.get("ok"):
        return ready
    tabs = (await _cdp_tabs((CONTROLLED_CDP_PORT,))).get("tabs", [])
    target = best_tab_match(query, tabs)
    if not target:
        return {"ok": False, "error": "No matching controlled tab.", "query": query, "tabs": tabs}
    async with httpx.AsyncClient(timeout=5) as client:
        response = await client.get(f"http://127.0.0.1:{CONTROLLED_CDP_PORT}/json/activate/{target['id']}")
        if response.status_code != 200:
            return {"ok": False, "error": response.text, "target": target}
    return {"ok": True, "target": target}


async def _focus_tab_with_search(target: dict[str, Any]) -> dict[str, Any]:
    browser = get_os_context().default_browser_name
    if not browser:
        return {"ok": False, "error": "Default browser unknown."}
    await _activate_app_by_name(browser)
    await mac_input.key_press("cmd+shift+a")
    await asyncio.sleep(0.2)
    query = str(target.get("title") or target.get("url") or "")
    await mac_input.paste_text(query)
    await asyncio.sleep(0.2)
    await mac_input.key_press("return")
    await asyncio.sleep(1.2)
    await mac_input.key_press("esc")
    await asyncio.sleep(0.2)
    active = await _browser_tab_with_retries()
    target_url = str(target.get("url") or "")
    return {
        "ok": bool(target_url and active.get("url") == target_url),
        "browser": browser,
        "window": target.get("window"),
        "index": target.get("index"),
        "target_title": target.get("title", ""),
        "target_url": target_url,
        "active_title": active.get("title", ""),
        "active_url": active.get("url", ""),
        "error": None if active.get("url") == target_url else "Tab search did not focus target tab.",
    }


async def _browser_tab_with_retries(attempts: int = 3) -> dict[str, str | None]:
    last = None
    for _ in range(attempts):
        last = await _browser_tab()
        if last.get("url") or last.get("title"):
            return last
        await asyncio.sleep(0.4)
    return last or {"title": None, "url": None}


async def _focus_tab_cdp(target: dict[str, Any]) -> dict[str, Any]:
    targets = await _cdp_tabs()
    if not targets.get("ok"):
        return targets
    target_url = str(target.get("url") or "")
    match = next((tab for tab in targets["tabs"] if tab.get("url") == target_url), None)
    if not match:
        return {"ok": False, "error": "No matching CDP target.", "cdp_available": True}
    port = match["port"]
    async with httpx.AsyncClient(timeout=3) as client:
        response = await client.get(f"http://127.0.0.1:{port}/json/activate/{match['id']}")
        if response.status_code != 200:
            return {"ok": False, "error": response.text, "cdp_available": True}
    active = await _browser_tab_with_retries()
    return {
        "ok": active.get("url") == target_url,
        "target_title": target.get("title", ""),
        "target_url": target_url,
        "active_title": active.get("title", ""),
        "active_url": active.get("url", ""),
        "cdp_target": match,
    }


PLAYBACK_EXPRESSION = """
(() => {
  const v = document.querySelector('video');
  return {
    url: location.href,
    title: document.title,
    paused: v ? v.paused : null,
    currentTime: v ? v.currentTime : null,
    duration: v && isFinite(v.duration) ? v.duration : null,
    fullscreen: !!document.fullscreenElement,
    videoCount: document.querySelectorAll('video').length,
    muted: v ? v.muted : null,
  };
})()
"""


async def playback_state(
    tab_id: str | None = None,
    query: str | None = None,
) -> dict[str, Any]:
    return await cdp_javascript(expression=PLAYBACK_EXPRESSION, tab_id=tab_id, query=query)


async def cdp_javascript(
    expression: str,
    tab_id: str | None = None,
    query: str | None = None,
) -> dict[str, Any]:
    if not expression.strip():
        return {"ok": False, "error": "expression is required"}
    target = await _resolve_cdp_target(tab_id=tab_id, query=query)
    if not target:
        return {
            "ok": False,
            "error": (
                "No controllable CDP page target available. Call browser/ensure_controlled "
                "and browser/controlled_open_url first."
            ),
        }
    ws_url = target.get("webSocketDebuggerUrl")
    if not ws_url:
        return {"ok": False, "error": "Target has no webSocketDebuggerUrl", "target": target}
    try:
        async with websockets.connect(
            ws_url, open_timeout=3, close_timeout=3, max_size=2_000_000
        ) as ws:
            await ws.send(
                json.dumps(
                    {
                        "id": 1,
                        "method": "Runtime.evaluate",
                        "params": {
                            "expression": expression,
                            "returnByValue": True,
                            "awaitPromise": True,
                        },
                    }
                )
            )
            raw = await asyncio.wait_for(ws.recv(), timeout=5)
    except (asyncio.TimeoutError, OSError) as exc:
        return {"ok": False, "error": f"CDP connection failed: {exc}", "target": _public_target(target)}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"CDP error: {exc}", "target": _public_target(target)}

    try:
        response = json.loads(raw)
    except json.JSONDecodeError as exc:
        return {"ok": False, "error": f"Could not parse CDP response: {exc}"}

    if "error" in response:
        return {
            "ok": False,
            "error": response["error"].get("message", "CDP error"),
            "target": _public_target(target),
        }

    result = response.get("result", {}).get("result", {})
    exception = response.get("result", {}).get("exceptionDetails")
    if exception:
        return {
            "ok": False,
            "error": exception.get("text") or "JS exception",
            "details": exception,
            "target": _public_target(target),
        }
    return {
        "ok": True,
        "value": result.get("value"),
        "type": result.get("type"),
        "target": _public_target(target),
    }


def _public_target(target: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": target.get("id"),
        "url": target.get("url"),
        "title": target.get("title"),
    }


async def _resolve_cdp_target(
    tab_id: str | None = None,
    query: str | None = None,
) -> dict[str, Any] | None:
    targets = await _cdp_full_targets(CONTROLLED_CDP_PORT)
    if not targets:
        return None
    if tab_id:
        for target in targets:
            if target.get("id") == tab_id:
                return target
        return None
    if query:
        match = best_tab_match(query, targets)
        if match:
            return match
        return None
    for target in targets:
        url = target.get("url") or ""
        if url and url != "about:blank":
            return target
    return targets[0] if targets else None


async def _cdp_full_targets(port: int) -> list[dict[str, Any]]:
    async with httpx.AsyncClient(timeout=2) as client:
        try:
            response = await client.get(f"http://127.0.0.1:{port}/json/list")
        except httpx.HTTPError:
            return []
    if response.status_code != 200:
        return []
    return [item for item in response.json() if item.get("type") == "page"]


async def _cdp_tabs(ports: tuple[int, ...] = (9222, 9223, 9224, 9229)) -> dict[str, Any]:
    tabs = []
    async with httpx.AsyncClient(timeout=0.5) as client:
        for port in ports:
            try:
                response = await client.get(f"http://127.0.0.1:{port}/json/list")
                if response.status_code != 200:
                    continue
                for item in response.json():
                    if item.get("type") == "page":
                        tabs.append(_cdp_tab_from_target(port, item))
            except Exception:
                continue
    return {"ok": bool(tabs), "tabs": tabs}


async def _cdp_available(port: int) -> dict[str, Any]:
    try:
        async with httpx.AsyncClient(timeout=1) as client:
            response = await client.get(f"http://127.0.0.1:{port}/json/version")
            if response.status_code != 200:
                return {"ok": False, "port": port, "status": response.status_code}
            data = response.json()
            return {"ok": True, "port": port, "browser": data.get("Browser")}
    except Exception as exc:
        return {"ok": False, "port": port, "error": str(exc)}


def _cdp_tab_from_target(port: int, item: dict[str, Any]) -> dict[str, Any]:
    return {
        "port": port,
        "id": item.get("id"),
        "title": item.get("title", ""),
        "url": item.get("url", ""),
    }


async def _focus_tab_with_accessibility(target: dict[str, Any]) -> dict[str, Any]:
    try:
        import ApplicationServices as AS
        import AppKit
    except Exception as exc:
        return {"ok": False, "error": f"Accessibility unavailable: {exc}"}

    browser = get_os_context().default_browser_name
    if not browser:
        return {"ok": False, "error": "Default browser unknown."}
    apps = AppKit.NSRunningApplication.runningApplicationsWithBundleIdentifier_(
        get_os_context().default_browser_bundle_id
    )
    if not apps:
        return {"ok": False, "error": "Browser process not found."}
    app = AS.AXUIElementCreateApplication(apps[0].processIdentifier())
    windows = _copy_attr(AS, app, "AXWindows") or []
    needle = str(target.get("title") or "").lower()
    for window in windows:
        match = _find_ax_tab(AS, window, needle)
        if match is not None:
            AS.AXUIElementPerformAction(match, "AXPress")
            await asyncio.sleep(0.6)
            active = await _browser_tab_with_retries()
            return {
                "ok": active.get("url") == target.get("url"),
                "target_title": target.get("title", ""),
                "target_url": target.get("url", ""),
                "active_title": active.get("title", ""),
                "active_url": active.get("url", ""),
            }
    return {"ok": False, "error": "No matching AX tab element found."}


def _find_ax_tab(AS, element, needle: str):
    title = str(_copy_attr(AS, element, "AXTitle") or "").lower()
    role = str(_copy_attr(AS, element, "AXRole") or "")
    if needle and needle in title and role in {"AXRadioButton", "AXButton", "AXStaticText"}:
        return element
    children = _copy_attr(AS, element, "AXChildren") or []
    if not isinstance(children, (list, tuple)):
        return None
    for child in children:
        found = _find_ax_tab(AS, child, needle)
        if found is not None:
            return found
    return None


def _copy_attr(AS, element, attr: str):
    try:
        err, value = AS.AXUIElementCopyAttributeValue(element, attr, None)
        if err == 0:
            return value
    except Exception:
        return None
    return None


def _focused_expected_tab(result: dict[str, Any], target: dict[str, Any]) -> bool:
    return bool(result.get("ok") and result.get("active_url", result.get("url")) == target.get("url"))
