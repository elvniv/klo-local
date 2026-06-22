"""macOS scripting surface — AppleScript, app activation, URL opens, browser
tab queries via osascript. The MacOSAssistExecutor handles the `macos` generic
tool; the underscored helpers are reused by `browser.py` for tab lookups.

Avoids synthetic input (cliclick) wherever possible — these calls go through
Apple Events, which need Automation permission for the launching app rather
than Accessibility.
"""
from __future__ import annotations

import asyncio
import json
from typing import Any


MACOS_TOOL = {
    "name": "macos",
    "description": (
        "macOS app & system scripting. Activate apps, open URLs in the default "
        "browser, run AppleScript with intent='read'|'write', paste text, switch "
        "Spaces, capture a desktop inventory. Prefer this over the generic "
        "computer tool whenever the task can be expressed as a script."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": [
                    "activate_app",
                    "open_url",
                    "run_applescript",
                    "paste_text",
                    "switch_space",
                    "desktop_inventory",
                ],
            },
            "name": {"type": "string", "description": "App name for activate_app."},
            "url": {"type": "string", "description": "URL for open_url. Must have been observed earlier this run for sensitive destinations."},
            "script": {"type": "string", "description": "AppleScript source for run_applescript."},
            "intent": {
                "type": "string",
                "enum": ["read", "write"],
                "description": "Whether the AppleScript reads state or mutates state.",
            },
            "text": {"type": "string", "description": "Text to paste."},
            "key": {
                "type": "string",
                "description": "Key combo for switch_space (default: ctrl+right).",
            },
        },
        "required": ["action"],
        "additionalProperties": False,
    },
}


class MacOSAssistExecutor:
    async def execute(self, tool_input: dict[str, Any]) -> str:
        action = tool_input.get("action")

        if action == "activate_app":
            return json.dumps(
                await _activate_app_by_name(str(tool_input.get("name") or "")),
                ensure_ascii=False,
            )

        if action == "open_url":
            return json.dumps(
                await _open_url(str(tool_input.get("url") or "")),
                ensure_ascii=False,
            )

        if action == "run_applescript":
            script = str(tool_input.get("script") or "")
            intent = str(tool_input.get("intent") or "read")
            return await _run_applescript_tool(script, intent)

        if action == "paste_text":
            from api.core import input as mac_input

            text = str(tool_input.get("text") or "")
            try:
                await mac_input.paste_text(text)
            except Exception as exc:
                return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)
            return json.dumps({"ok": True, "pasted_chars": len(text)}, ensure_ascii=False)

        if action == "switch_space":
            from api.core import input as mac_input

            key = str(tool_input.get("key") or "ctrl+right")
            try:
                await mac_input.key_press(key)
            except Exception as exc:
                return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)
            return json.dumps({"ok": True, "switched_with": key}, ensure_ascii=False)

        if action == "desktop_inventory":
            from api.core.os_context import get_os_context

            return json.dumps(get_os_context().to_dict(), ensure_ascii=False)

        raise ValueError(f"Unsupported macos action: {action!r}")


# --------------------------------------------------------------------- helpers

async def _osascript(script: str, timeout: float = 8) -> tuple[int, str, str]:
    """Run a single AppleScript; return (returncode, stdout, stderr)."""
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/osascript",
        "-e",
        script,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.communicate()
        return -1, "", f"osascript timed out after {timeout:g}s"
    return (
        proc.returncode or 0,
        stdout.decode("utf-8", errors="replace").strip(),
        stderr.decode("utf-8", errors="replace").strip(),
    )


async def _run_applescript_tool(script: str, intent: str) -> str:
    if not script.strip():
        return json.dumps({"ok": False, "error": "empty script"}, ensure_ascii=False)
    rc, out, err = await _osascript(script, timeout=15)
    payload: dict[str, Any] = {
        "ok": rc == 0,
        "intent": intent,
        "returncode": rc,
        "stdout": out[:8000],
    }
    if err:
        payload["stderr"] = err[:2000]
    return json.dumps(payload, ensure_ascii=False)


async def _activate_app_by_name(name: str) -> dict[str, Any]:
    name = name.strip()
    if not name:
        return {"ok": False, "error": "empty app name"}
    safe = name.replace('"', '\\"')
    rc, _, err = await _osascript(f'tell application "{safe}" to activate', timeout=4)
    return {
        "ok": rc == 0,
        "app": name,
        "error": err if rc != 0 else None,
    }


async def _open_url(url: str) -> dict[str, Any]:
    url = url.strip()
    if not url:
        return {"ok": False, "error": "empty url"}
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/open",
        url,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    err = stderr.decode("utf-8", errors="replace").strip()
    return {
        "ok": proc.returncode == 0,
        "url": url,
        "error": err if proc.returncode != 0 else None,
    }


_CHROMIUM_TAB_QUERY = """
tell application "{app}"
  if (count of windows) > 0 then
    set t to active tab of front window
    return (URL of t) & "<KLO_SEP>" & (title of t)
  end if
end tell
"""

_SAFARI_TAB_QUERY = """
tell application "{app}"
  if (count of windows) > 0 then
    set t to current tab of front window
    return (URL of t) & "<KLO_SEP>" & (name of t)
  end if
end tell
"""


async def _browser_tab() -> dict[str, str | None]:
    """Return the active tab of the default browser as {title, url}.

    Falls through Chromium-style → Safari-style queries; returns nulls if both fail.
    """
    from api.core.os_context import get_os_context

    browser = get_os_context().default_browser_name
    if not browser:
        return {"title": None, "url": None}
    safe = browser.replace('"', '\\"')

    for template in (_CHROMIUM_TAB_QUERY, _SAFARI_TAB_QUERY):
        rc, out, _ = await _osascript(template.format(app=safe), timeout=4)
        if rc == 0 and "<KLO_SEP>" in out:
            url, _, title = out.partition("<KLO_SEP>")
            return {"title": title.strip() or None, "url": url.strip() or None}
    return {"title": None, "url": None}


_CHROMIUM_TABS_QUERY = """
tell application "{app}"
  set output to ""
  set winNum to 0
  repeat with w in windows
    set winNum to winNum + 1
    set tabNum to 0
    try
      repeat with t in tabs of w
        set tabNum to tabNum + 1
        set output to output & winNum & "<F1>" & tabNum & "<F1>" & (URL of t) & "<F1>" & (title of t) & "<F2>"
      end repeat
    end try
  end repeat
  return output
end tell
"""


async def _browser_tabs() -> dict[str, Any]:
    """Return all tabs of the default browser as {browser, tabs:[{window,index,url,title}]}.

    Best-effort across Chromium-derived browsers; returns an empty list on Safari/Firefox.
    """
    from api.core.os_context import get_os_context

    browser = get_os_context().default_browser_name
    if not browser:
        return {"browser": None, "tabs": []}
    safe = browser.replace('"', '\\"')

    rc, out, _ = await _osascript(_CHROMIUM_TABS_QUERY.format(app=safe), timeout=8)
    tabs: list[dict[str, Any]] = []
    if rc == 0 and out:
        for record in out.split("<F2>"):
            if not record.strip():
                continue
            parts = record.split("<F1>")
            if len(parts) < 4:
                continue
            try:
                tabs.append(
                    {
                        "window": int(parts[0]),
                        "index": int(parts[1]),
                        "url": parts[2],
                        "title": parts[3],
                    }
                )
            except ValueError:
                continue
    return {"browser": browser, "tabs": tabs}


async def _focus_browser_tab(window: int, index: int) -> dict[str, Any]:
    """Activate a specific tab in the default browser by window/index."""
    from api.core.os_context import get_os_context

    browser = get_os_context().default_browser_name
    if not browser:
        return {"ok": False, "error": "default browser unknown"}
    safe = browser.replace('"', '\\"')
    script = f"""
        tell application "{safe}"
          activate
          if (count of windows) >= {window} then
            set targetWin to window {window}
            try
              if (count of tabs of targetWin) >= {index} then
                set active tab index of targetWin to {index}
                set frontmost to true
                return "ok"
              end if
            on error errMsg
              return "error:" & errMsg
            end try
          end if
          return "missing"
        end tell
    """
    rc, out, err = await _osascript(script, timeout=4)
    return {
        "ok": rc == 0 and out.strip() == "ok",
        "browser": browser,
        "window": window,
        "index": index,
        "error": err or (out if out.startswith("error:") else None) if rc != 0 or out != "ok" else None,
    }
