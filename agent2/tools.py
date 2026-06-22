"""Tool definitions and dispatch for agent2.

Six tools, each clear about its purpose and intent. The system prompt tells
the model to pick the cheapest one — there's no router below; the model
routes itself.
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any, Awaitable, Callable


# ----------------------------------------------------------------- safety

_BLOCKED_SHELL = re.compile(
    r"\b(rm\s+-rf?|sudo|dd\s+if=|mkfs|kill\s+-9|shutdown|reboot|tccutil\s+reset|"
    r"defaults\s+write|launchctl\s+(?:unload|load|bootstrap|bootout)|"
    r"chflags|chown\s+-R|killall\s+-9|pmset|networksetup\s+-set|"
    r"git\s+push\s+-f|git\s+reset\s+--hard|git\s+clean\s+-f)",
    re.IGNORECASE,
)
def _is_safe_write_path(path: Path) -> bool:
    """Allow writes only to /tmp, /private/tmp, /var/folders (resolved /tmp), or cwd subtree."""
    try:
        abs_p = path.expanduser().resolve()
    except Exception:
        return False
    cwd = Path.cwd().resolve()
    for prefix in ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"):
        if str(abs_p).startswith(prefix):
            return True
    try:
        abs_p.relative_to(cwd)
        return True
    except ValueError:
        return False


# ----------------------------------------------------------------- tool impls

async def _run_subprocess(argv: list[str], timeout: float) -> tuple[int, str, str]:
    """Run a subprocess with a timeout; returns (rc, stdout, stderr) text."""
    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.communicate()
        raise
    return proc.returncode, stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")


async def _tool_shell(cmd: str, intent: str = "read", verify: str | None = None, timeout: float = 15) -> str:
    if intent not in {"read", "write"}:
        return json.dumps({"ok": False, "error": "intent must be 'read' or 'write'"})
    if intent == "write" and not (verify and verify.strip()):
        return json.dumps({"ok": False, "error": (
            "intent='write' requires a 'verify' shell clause that reads the resulting state back "
            "(e.g. after `echo X > /tmp/f.txt` verify with `cat /tmp/f.txt`; after `git commit -m X` "
            "verify with `git log -1 --pretty=%s`). The verify output is the ground truth — "
            "without it you cannot tell whether your write actually landed where the user expects."
        )})
    if _BLOCKED_SHELL.search(cmd):
        return json.dumps({"ok": False, "error": "blocked by safety policy: destructive command pattern"})
    if verify and _BLOCKED_SHELL.search(verify):
        return json.dumps({"ok": False, "error": "blocked by safety policy: verify clause must be read-only"})
    timeout = max(0.5, min(float(timeout), 30.0))
    try:
        rc, out, err = await _run_subprocess(["/bin/zsh", "-lc", cmd], timeout)
    except asyncio.TimeoutError:
        return json.dumps({"ok": False, "error": f"timed out after {timeout}s"})
    result: dict[str, Any] = {
        "ok": rc == 0,
        "intent": intent,
        "returncode": rc,
        "stdout": out[:8000],
        "stderr": err[:2000],
    }
    if intent == "write" and rc == 0 and verify:
        try:
            v_rc, v_out, v_err = await _run_subprocess(["/bin/zsh", "-lc", verify], min(timeout, 10.0))
            result["verified"] = v_out.strip()[:4000]
            result["verify_returncode"] = v_rc
            if v_rc != 0:
                result["verify_stderr"] = v_err.strip()[:1000]
        except asyncio.TimeoutError:
            result["verified"] = None
            result["verify_error"] = "verify clause timed out"
    return json.dumps(result, ensure_ascii=False)


async def _tool_applescript(script: str, intent: str = "read", timeout: float = 15) -> str:
    """Read-only AppleScript queries against scriptable apps. Writes are
    disabled at the tool layer — they previously produced phantom-success
    bugs (object created in a hidden account/folder, agent reports done,
    user can't see it). Native-app mutations go through the `computer` tool
    where the agent actually sees the user's screen before and after."""
    if intent != "read":
        return json.dumps({"ok": False, "error": "applescript_writes_disabled", "hint": (
            "AppleScript intent='write' is disabled. Native-app mutations go through the "
            "`computer` tool: take a screenshot, reason about what's visible, click coordinates, "
            "type. The after-screenshot is automatically returned so you can see whether the "
            "change actually landed."
        )})
    timeout = max(0.5, min(float(timeout), 30.0))
    try:
        rc, out, err = await _run_subprocess(["/usr/bin/osascript", "-e", script], timeout)
    except asyncio.TimeoutError:
        return json.dumps({"ok": False, "error": f"timed out after {timeout}s"})
    return json.dumps({
        "ok": rc == 0,
        "intent": intent,
        "returncode": rc,
        "stdout": out.strip()[:6000],
        "stderr": err.strip()[:1500],
    }, ensure_ascii=False)


async def _tool_read_file(path: str, max_bytes: int = 50_000) -> str:
    p = Path(path).expanduser()
    if not p.exists():
        return json.dumps({"ok": False, "error": f"not found: {p}"})
    if not p.is_file():
        return json.dumps({"ok": False, "error": f"not a regular file: {p}"})
    try:
        data = p.read_bytes()[:max_bytes]
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
    text = data.decode("utf-8", errors="replace")
    return json.dumps({
        "ok": True,
        "path": str(p),
        "bytes_read": len(data),
        "size": p.stat().st_size,
        "content": text,
    }, ensure_ascii=False)


async def _tool_write_file(path: str, content: str) -> str:
    p = Path(path).expanduser()
    if not _is_safe_write_path(p):
        return json.dumps({"ok": False, "error": f"path outside allowed write zones (/tmp/* or cwd subtree): {p}"})
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
    try:
        actual = p.read_text(errors="replace")
    except Exception as exc:
        return json.dumps({"ok": False, "path": str(p), "error": f"wrote but could not verify: {exc}"})
    head = actual[:1000]
    return json.dumps({
        "ok": True,
        "path": str(p),
        "bytes_written": len(content),
        "verified": head,
        "verified_full_match": actual == content,
        "verified_size": len(actual),
    }, ensure_ascii=False)


# ----------------------------------------------------------- browser-use bridge

def _find_chromium_binary() -> str | None:
    """Locate a Chromium-family executable Playwright already installed, so
    browser-use doesn't try to download Chrome at runtime (which needs sudo)."""
    cache = Path.home() / "Library" / "Caches" / "ms-playwright"
    if not cache.exists():
        return None
    # Prefer the highest-numbered chromium-N install (newest)
    candidates = sorted(
        [p for p in cache.glob("chromium-*") if p.is_dir() and not p.name.endswith("headless_shell-1217") and not p.name.endswith("headless_shell-1208")],
        reverse=True,
    )
    for c in candidates:
        for exe in c.rglob("Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"):
            return str(exe)
        for exe in c.rglob("Chromium.app/Contents/MacOS/Chromium"):
            return str(exe)
    return None


async def _tool_browser_task(task: str, max_steps: int = 25) -> str:
    """Delegate a browser-only task to a specialist browser-use Agent.

    Spawns its own LLM-driven loop with vision. Returns the final result text
    from the inner agent.
    """
    try:
        from browser_use import Agent, Browser
        from browser_use.llm.openai.chat import ChatOpenAI
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"browser-use import failed: {exc}"})

    try:
        # Find the Chromium binary playwright already installed.
        chromium_exe = _find_chromium_binary()
        kwargs = {"headless": False}
        if chromium_exe:
            kwargs["executable_path"] = chromium_exe
        browser = Browser(**kwargs)
        model_name = os.environ.get("BROWSER_USE_MODEL") or os.environ.get("OPENAI_MODEL", "gpt-5.1")
        llm = ChatOpenAI(model=model_name, api_key=os.environ.get("OPENAI_API_KEY", ""))
        agent = Agent(task=task, llm=llm, browser_session=browser, use_vision=True)
        history = await agent.run(max_steps=int(max_steps))
        # Browser-use's history exposes a final result string via different APIs
        # depending on version. Try a few defensively.
        result_text = ""
        for attr in ("final_result", "extracted_content"):
            getter = getattr(history, attr, None)
            try:
                if callable(getter):
                    val = getter()
                    if val:
                        result_text = str(val)
                        break
                elif isinstance(getter, str) and getter:
                    result_text = getter
                    break
            except Exception:
                continue
        if not result_text:
            try:
                result_text = str(history.final_result()) if callable(getattr(history, "final_result", None)) else str(history)
            except Exception:
                result_text = "(browser-use returned no extractable text)"
        return json.dumps({"ok": True, "result": result_text[:8000]}, ensure_ascii=False)
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


# ----------------------------------------------------------- registry

ToolFn = Callable[..., Awaitable[str]]

TOOLS: list[dict[str, Any]] = [
    {
        "name": "shell",
        "description": (
            "Run a zsh command and return its stdout/stderr/exit code. intent='read' for "
            "inspect/list/grep/curl/version-print, intent='write' for anything that mutates "
            "state. When intent='write' you MUST also pass a 'verify' clause — a read-only "
            "shell command that reads back the resulting state (e.g. write `echo X > /tmp/f` "
            "→ verify `cat /tmp/f`; write `git commit -m X` → verify `git log -1 --pretty=%s`). "
            "The verify output is returned as the 'verified' field and is the ground truth — "
            "do not claim success based on returncode alone. Destructive patterns (rm -rf, "
            "sudo, mkfs, force-push, hard-reset) are blocked. Default timeout 15s, max 30s. "
            "macOS TCC NOTE: reading ~/Documents, ~/Downloads, ~/Desktop, ~/Movies, "
            "~/Music, ~/Pictures, /Volumes/* triggers a separate Apple consent dialog per "
            "folder. For unscoped 'what's using my storage' questions prefer "
            "`system_profiler SPStorageDataType -json` or `df -h /` — they read at the "
            "volume layer with zero TCC prompts. Only scope `du`/`ls` into a user folder "
            "when the user named that folder explicitly."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "cmd": {"type": "string"},
                "intent": {"type": "string", "enum": ["read", "write"]},
                "verify": {"type": "string", "description": "Required when intent='write'. Read-only shell command that re-reads the state your write changed."},
                "timeout": {"type": "number", "description": "Seconds, max 30."},
            },
            "required": ["cmd", "intent"],
        },
    },
    {
        "name": "applescript",
        "description": (
            "Read-only queries against scriptable macOS apps via /usr/bin/osascript. "
            "intent='read' is the only supported value. Use this for fast structured "
            "queries that don't mutate state — e.g. 'what's playing in Music', "
            "'list calendar events for today', 'list folder names in Notes'. "
            "Writes are disabled at the tool layer; for any native-app mutation use "
            "the `computer` tool (screenshot → click → type → after-screenshot)."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "script": {"type": "string"},
                "intent": {"type": "string", "enum": ["read"]},
                "timeout": {"type": "number"},
            },
            "required": ["script", "intent"],
        },
    },
    {
        "name": "read_file",
        "description": "Read a UTF-8 text file. Returns {ok, path, content, size, bytes_read}.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "max_bytes": {"type": "integer"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "write_file",
        "description": (
            "Write text to a file. Allowed write zones: /tmp/* or under the current "
            "working directory. Other paths are refused."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["path", "content"],
        },
    },
    {
        "name": "web",
        "description": (
            "PRIMARY tool for any website task. Drives the USER'S OWN Chrome "
            "browser through the klo Chrome extension (localhost bridge). "
            "There is NO embedded web pane — pages load in the user's real "
            "Chrome window, in a visible tab that klo brings to the front. "
            "The user watches klo work inside their own browser.\n"
            "\n"
            "Because this is the user's Chrome: their sessions already exist "
            "(Gmail, Notion, Linear — already signed in), and clicks fire "
            "real DOM events that React/SPA handlers accept. (The "
            "`computer.left_click` path produces `isTrusted=false` events "
            "those handlers ignore.)\n"
            "\n"
            "Use `web.*` for EVERY website task. Only fall back to `computer` "
            "for native macOS apps, the Finder, system dialogs, or canvas / "
            "game UIs.\n"
            "\n"
            "IF THE EXTENSION IS NOT CONNECTED: `web.open` opens the URL in "
            "the user's DEFAULT browser instead and returns "
            "`opened_in_default_browser: true`. The page IS visible to the "
            "user, but you CANNOT read or interact with it — no snapshot, no "
            "press, no text. Tell the user exactly what you opened, answer "
            "only from information you actually have, and mention that "
            "installing the klo Chrome extension lets you work inside the "
            "page. All other `web.*` actions fail with "
            "`error_code: extension_not_connected`. NEVER claim you read or "
            "verified a page you could not see.\n"
            "\n"
            "Actions (snapshot-first workflow is the FAST path):\n"
            "  - open(url)               navigate. Returns {target: {url, title}, "
            "text_excerpt: first ~1200 chars}. Auto-waits for the page to settle.\n"
            "  - snapshot()              capture an INDEXED list of every visible "
            "interactive element with its ARIA role + accessible name (Playwright-"
            "style). PRIMARY tool for any web interaction — use BEFORE clicking. "
            "Returns {snapshot_id, items: [{idx, role, name, value?, x, y}, ...]}. "
            "Auto-settles the DOM. Items are roughly in document order. Cap 300.\n"
            "  - press(idx, snapshot_id?)  click the item at this idx in the most "
            "recent snapshot. Real isTrusted=true click. Returns state_changed. "
            "If snapshot is stale (DOM changed), returns ok:false with stale:true.\n"
            "  - fill(idx, text, submit=false, clear_first=true, snapshot_id?)  "
            "focus item idx + insertText. submit=true presses Enter after.\n"
            "  - screenshot(max_width=1280)  capture the visible viewport as PNG. "
            "USE THIS alongside snapshot for ANY visual SPA. The image gives spatial "
            "structure; the snapshot gives semantic structure. Together they cover "
            "everything. Real image content block sent to you.\n"
            "  - click(selector)          CSS-selector click. SHORTCUT for when you "
            "already know a unique selector — most of the time, prefer snapshot+press.\n"
            "  - click(text)              click first clickable element whose "
            "innerText/aria-label/title contains `text`. FALLBACK for simple sites "
            "— on heavy SPAs (Google Flights, Booking, Notion, anything Material/MUI), "
            "snapshot+press is far more reliable.\n"
            "  - type(selector, text, submit=false, clear_first=true)  focus + "
            "insertText. Same as fill() but selector-based. Prefer fill(idx) when "
            "you have a fresh snapshot.\n"
            "  - text(selector?)          innerText of element or whole page. "
            "Auto-waits for settle.\n"
            "  - scroll(direction='top'|'bottom'  |  idx=N  |  selector='...'  |  "
            "text='...')  scroll the page. For long pages where the snapshot "
            "didn't include content below the fold: call scroll(direction='bottom') "
            "or scroll(idx=N) to bring more content into view, then re-snapshot. "
            "For canvas-content apps (Google Docs/Sheets/Slides, Figma) where "
            "the page text isn't in the DOM at all, scroll won't help — see the "
            "Canvas-content escape hatch below.\n"
            "  - wait_for(selector, timeout=8)  block until selector appears.\n"
            "  - wait_settled(timeout=4)  block until DOM is settled (readyState=complete, "
            "fetch+XHR idle for 2 polls). Call BEFORE click/text on freshly-loaded "
            "SPA routes that hydrate after first paint.\n"
            "  - autofill(host?)           no-op in Chrome: the user's own "
            "browser autofill / password manager handles credentials. "
            "Returns a note saying so — don't retry, just let the user "
            "fill the form themselves (use wait_for_login).\n"
            "  - wait_for_login(timeout=90)  block while user signs in to a "
            "known service. Call after web.open if the URL is a login page "
            "(accounts.google.com, instagram.com/accounts/login, etc.). "
            "Returns when URL leaves the login flow.\n"
            "  - evaluate(expression)     escape hatch: run JS in the page "
            "via the extension. Returns JSON-serialisable result.\n"
            "  - url()                    current url + title (cheap state check).\n"
            "\n"
            "After every click, the result includes before_url/after_url + "
            "state_changed. If state_changed=false after a click that was "
            "supposed to navigate, the click landed but didn't activate — try "
            "a different selector or text query before retrying.\n"
            "\n"
            "First-time sign-in is just-in-time: navigate, hit the login page, "
            "call wait_for_login, the user signs in inside their own Chrome "
            "tab, you continue. Most services are already signed in because "
            "this is the user's everyday browser."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["open", "snapshot", "press", "fill", "click", "type", "text", "screenshot", "evaluate", "scroll", "wait_for", "wait_for_login", "wait_settled", "autofill", "url"],
                },
                "url": {"type": "string", "description": "URL for open."},
                "host": {"type": "string", "description": "autofill only — hostname to look up. Defaults to current page host."},
                "idx": {"type": "integer", "description": "press/fill — index into the items[] array returned by the last web.snapshot()."},
                "snapshot_id": {"type": "string", "description": "press/fill — optional snapshot_id from web.snapshot(); validates the snapshot is still fresh."},
                "selector": {"type": "string", "description": "CSS selector."},
                "text": {
                    "type": "string",
                    "description": (
                        "For click: visible text to search for (when selector is omitted). "
                        "For type: the literal text to insert."
                    ),
                },
                "submit": {"type": "boolean", "default": False, "description": "type only — press Enter after typing."},
                "clear_first": {"type": "boolean", "default": True, "description": "type only — select-all + delete first."},
                "nth": {"type": "integer", "default": 0, "description": "click only — which match (0-indexed)."},
                "expression": {"type": "string", "description": "evaluate only — JS expression."},
                "direction": {
                    "type": "string",
                    "enum": ["top", "bottom"],
                    "description": "scroll only — 'top' or 'bottom' of page. Omit and provide idx/selector/text to scroll a specific element into view.",
                },
                "max": {"type": "integer", "default": 4000, "description": "text only — character limit."},
                "timeout": {"type": "number", "default": 8, "description": "wait_for / wait_for_login — seconds."},
            },
            "required": ["action"],
            "additionalProperties": False,
        },
    },
    {
        "name": "computer",
        "description": (
            "Native macOS desktop interaction — the channel for mutating "
            "native-app state when no higher tier covers it. Uses in-process "
            "Quartz events + ScreenCaptureKit screenshots.\n\n"
            "RAW PIXEL CLICKS ARE NOT IN THIS TOOL. They were removed because "
            "models can't reliably pick small targets visually — `left_click "
            "(coordinate=[x,y])` repeatedly landed on the wrong icon. Click "
            "by IDENTITY:\n"
            "  • `click_element(description='the + button')` — uses Anthropic "
            "    Computer Use's vision model with bounded scope + correct "
            "    resize math to find pixel-precise coords for the named "
            "    element. The model emits a DESCRIPTION; the system finds "
            "    the pixel. PRIMARY way to click from this tool.\n"
            "  • `accessibility.window_state` + `press_indexed` — identity-"
            "    based AX press, NO pixel guess at all. Strongly preferred "
            "    for Electron / web-app targets (Cursor, VS Code, Slack, "
            "    Notion, Linear, Gmail).\n"
            "  • `web.snapshot` + `web.press(idx)` — same identity model for "
            "    web pages (the user's Chrome via the klo extension).\n"
            "  • `applescript` — name-based menu bar items, scriptable apps.\n\n"
            "STANDARD FLOW:\n"
            "  1. open_app(name) — deterministic launch via `open -a`. "
            "Returns the after-screenshot. NEVER use Spotlight (cmd+space + "
            "type) for opening apps; that wastes 5+ vision turns.\n"
            "  2. KEYBOARD FIRST. If the target has a global shortcut, use "
            "key('cmd+shift+p') (Cursor/VS Code Cmd Palette), key('cmd+t') "
            "(new tab), key('cmd+k') (Linear/Notion/Slack quick switcher), "
            "key('cmd+,') (Settings). Skip the screenshot, skip the click.\n"
            "  3. For CLICKS, prefer `accessibility.window_state(mode='som')` "
            "+ `accessibility.press_indexed` — the screenshot comes back "
            "with numbered [N] labels on every button so you pick from a "
            "visible index, and the click acts on the cached AX node "
            "(identity-based, never misses a small target). "
            "`computer.click_element(description='...')` is a LAST RESORT "
            "for genuinely canvas-rendered surfaces; on Cocoa / Electron "
            "apps the agent loop will redirect it back to `accessibility.window_state`.\n"
            "  4. Every mutating action automatically returns a fresh "
            "after-screenshot. The image is ground truth.\n"
            "  5. After 3 attempts at the same thing without progress, "
            "call i_couldnt_do_this honestly.\n\n"
            "Actions (high-trust first, vision-fallback last):\n"
            "  - open_app(name)                              launch/activate via `open -a`; returns screenshot\n"
            "  - key(text)                                   press a key combo, e.g. 'cmd+n', 'esc', 'return'\n"
            "  - hold_key(text, duration)                    hold a key for N seconds\n"
            "  - type(text)                                  type literal text\n"
            "  - paste_text(text)                            paste text via clipboard (faster for >12 chars; preserves Markdown formatting — use REAL newlines between sections, never embed `## ` mid-string)\n"
            "  - scroll(coordinate=[x,y], scroll_x, scroll_y)\n"
            "  - screenshot                                  capture full primary display\n"
            "  - get_cursor_position                         {x, y}\n"
            "  - mouse_move(coordinate=[x,y])                move cursor only (no click)\n"
            "  - wait(duration)                              sleep N seconds (max 5)\n"
            "  - find_element(description)                   LAST RESORT — vision returns coords without clicking\n"
            "  - click_element(description)                  LAST RESORT — vision click on canvas / non-AX surfaces. Auto-redirects to accessibility.window_state on native apps.\n\n"
            "SAFETY: refuse anything that would send messages, make "
            "purchases, or delete data — those are constitutional bans. "
            "Destructive key combos (logout, lock, empty trash) and "
            "dangerous type patterns (curl|bash, rm -rf /) are hard-"
            "blocked at the dispatcher — you'll get a structured error."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": [
                        "open_app",
                        "key", "hold_key",
                        "type", "paste_text",
                        "scroll", "screenshot", "get_cursor_position",
                        "mouse_move", "wait",
                        "find_element",   # last-resort vision
                        "click_element",  # last-resort vision (auto-redirects on native apps)
                    ],
                },
                "name": {
                    "type": "string",
                    "description": "For open_app: the app name as it appears in /Applications (e.g. 'Reminders', 'Notes', 'System Settings').",
                },
                "description": {
                    "type": "string",
                    "description": "For click_element / find_element: a 1-5 word description of the UI element to click (e.g. 'the + button', 'New Reminder', 'the search field'). The system uses Anthropic Computer Use to find pixel coordinates.",
                },
                "coordinate": {
                    "type": "array",
                    "items": {"type": "number"},
                    "description": "[x, y] in IMAGE-space pixels from a recent screenshot.",
                },
                "capture_after": {
                    "type": "boolean",
                    "default": True,
                    "description": "After a mutating action (click/type/key/scroll/drag/paste), automatically attach a fresh window-scoped screenshot to the response. Default True — gives you ground truth on what the action did. Set to false ONLY when chaining several mutations where you don't need to verify intermediate state (e.g. typing 5 lines of code, only verify after the last). Skipping the after-screenshot saves ~1500 tokens + 200ms per action. Has no effect on observe actions (screenshot, get_cursor_position) or on actions where state-change is unlikely (mouse_move, wait).",
                },
                "start_coordinate": {
                    "type": "array",
                    "items": {"type": "number"},
                    "description": "Drag origin for left_click_drag.",
                },
                "text": {
                    "type": "string",
                    "description": "For type/paste_text/key: the text or key combo. With paste_text on multi-section content, you MUST include real newline characters between sections — a heading like '## Section' must start on its own line, never appear mid-string. Emitting '# Title ## Section body ## Other' as one flat string makes the destination render literal `##` characters as a wall of text instead of styled headings.",
                },
                "duration": {"type": "number"},
                "scroll_x": {"type": "integer"},
                "scroll_y": {"type": "integer"},
            },
            "required": ["action"],
        },
    },
    {
        "name": "memory_remember",
        "description": (
            "Persist a durable fact about the user across runs. Use SPARINGLY — "
            "only for stable preferences, identity, recurring context. NOT for "
            "transient task state.\n"
            "\n"
            "WRITE AS DECLARATIVE FACTS, NOT IMPERATIVE INSTRUCTIONS. Memory is "
            "re-injected into the system prompt every session, so an imperative "
            "phrasing gets re-read as a directive klo must follow on every "
            "future request — even when irrelevant to what the user is asking. "
            "Fact-shaped storage avoids that.\n"
            "  ✓ 'User prefers Notes app for jotting things down'\n"
            "  ✓ 'User has Sony WH-1000XM6 headphones'\n"
            "  ✓ 'User is planning an SF trip 2026-05-21 to 2026-05-25'\n"
            "  ✗ 'Always use Notes app, never Reminders'  (imperative — bad)\n"
            "  ✗ 'Never auto-confirm sends'  (imperative — bad)\n"
            "\n"
            "DO NOT save: task progress, completed-work logs, PR numbers, "
            "commit SHAs, 'fixed bug X', session outcomes, or anything that "
            "will be stale in 7 days. If a fact will be irrelevant in a week, "
            "it does not belong in memory. type: identity|preference|context|"
            "fact|todo|note."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "type": {"type": "string", "enum": ["identity", "preference", "context", "fact", "todo", "note"]},
            },
            "required": ["text"],
        },
    },
    {
        "name": "memory_recall",
        "description": (
            "Search stored facts by substring/word match. Useful when the system-"
            "prompt-injected memory might have been truncated or you need a specific "
            "fact. Returns up to `limit` facts ordered by recency."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Words to match against fact text (case-insensitive). Omit to list all."},
                "limit": {"type": "integer"},
                "type": {"type": "string", "description": "Filter by type."},
            },
        },
    },
    {
        "name": "memory_forget",
        "description": "Delete a fact by id or by substring match. Use when a fact is wrong or outdated.",
        "input_schema": {
            "type": "object",
            "properties": {
                "fact_id": {"type": "integer"},
                "text_match": {"type": "string"},
            },
        },
    },
    {
        "name": "accessibility",
        "description": (
            "macOS Accessibility surface — PRIMARY native-app tool, prefer over "
            "`computer` for everything except canvas/game apps. Targets elements by "
            "AX identity, not screen coordinates, so it doesn't drift when the UI "
            "shifts and works on Retina displays without coordinate math.\n\n"
            "STANDARD FLOW for any native-app interaction:\n"
            "  1. `actionable_index` → returns {snapshot_id, items: [{idx, role, "
            "label, actions, bounds, ...}], menu: {File: [...], Edit: [...], ...}}. "
            "Read this BEFORE clicking — it tells you exactly what's clickable and "
            "by what index.\n"
            "  2. `press` (idx) — AXPress on the element. Use for buttons.\n"
            "  3. `fill` (idx, text) — focus + AXValue set. Use for text fields.\n"
            "  4. `focus` (idx) — set AXFocused, useful before keyboard shortcuts.\n"
            "  5. `confirm` (idx) — AXConfirm, for search fields / fields that submit on Enter.\n"
            "  6. `menu_select` (path=[\"File\",\"Save\"]) — walks the menu bar deterministically. "
            "Use this INSTEAD of clicking a menu by coordinate. Works on Electron apps "
            "(Cursor, VS Code, Slack, Discord) where the window interior is barren but "
            "the menu bar is always reachable.\n"
            "Plus read actions: focused_snapshot, visible_text, screen_text, "
            "screen_text_locations — use these as evidence after a write to verify "
            "the UI state changed as expected (cheaper + more reliable than another "
            "screenshot).\n\n"
            "ELECTRON / WEB-APP MODE (Gmail, Notion, Linear, Slack, VS Code, "
            "Cursor): prefer `window_state` (returns a markdown AX tree dump for "
            "the target window) followed by `press_indexed` (AXPerformAction on "
            "the cached element handle). This path caches AXUIElement refs by "
            "(pid, window_id), so press_indexed lands on the exact element that "
            "window_state described — immune to re-enumeration drift between "
            "calls. The legacy `actionable_index` + `press` flow still works "
            "but re-resolves by index each call and can mis-click after a UI "
            "render. `ax_action` is the AX action name (default 'AXPress'; use "
            "'AXShowMenu' to open a context menu, etc.)."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": [
                        "focused_snapshot",
                        "visible_text",
                        "screen_text",
                        "screen_text_locations",
                        "actionable_index",
                        "press",
                        "fill",
                        "focus",
                        "confirm",
                        "menu_select",
                        "window_state",
                        "press_indexed",
                        "set_value_indexed",
                        "ax_dump_tree",
                        "ax_set_value",
                        "ax_press",
                    ],
                    "description": (
                        "BEST DEFAULT for any 'type X into App Y' task: ax_dump_tree "
                        "→ inspect items[] → ax_set_value with snapshot_id+idx. "
                        "Walks the FULL AX tree of every window of the named app via "
                        "Python directly (no MacOps, no frontmost requirement, no "
                        "coordinate scaling). Each item has role/label/value/editable/"
                        "focused/depth — pick the one with editable=true and a role "
                        "of AXTextArea/AXTextField/AXComboBox or whatever matches "
                        "the visible compose box."
                    ),
                },
                "max_depth": {"type": "integer", "minimum": 1, "maximum": 8, "default": 4},
                "max_nodes": {"type": "integer", "minimum": 20, "maximum": 600, "default": 180},
                "snapshot_id": {"type": "string", "description": "From a prior actionable_index call. Required for press/fill/focus/confirm."},
                "idx": {"type": "integer", "minimum": 0, "description": "Element index from the snapshot. Required for press/fill/focus/confirm."},
                "text": {"type": "string", "description": "Text to write into the field. Required for fill."},
                "path": {"type": "array", "items": {"type": "string"}, "description": "Menu title path, e.g. [\"File\",\"Open\"]. Required for menu_select."},
                "app_name": {"type": "string", "description": "Target app for window_state / press_indexed. Defaults to frontmost app if omitted."},
                "window_id": {"type": "integer", "description": "CGWindowID for window_state / press_indexed. Defaults to the app's frontmost window if omitted."},
                "element_index": {"type": "integer", "minimum": 0, "description": "Element index from a prior window_state call. Required for press_indexed."},
                "ax_action": {"type": "string", "description": "AX action name for press_indexed (default 'AXPress'). Options: AXPress, AXShowMenu, AXConfirm, AXCancel, AXIncrement, AXDecrement, AXPick, AXRaise."},
                "value": {"type": "string", "description": "For set_value_indexed: the value to write. For AXPopUpButton / select dropdowns, pass the option's display label (e.g. 'Blue'). For sliders, pass a numeric string. For checkboxes, '1' or '0'. For contenteditable text, the full new text. AVOIDS opening native pickers (no focus steal) and AVOIDS visual targeting."},
                "ax_attribute": {"type": "string", "description": "For set_value_indexed: AX attribute to write. Default 'AXValue' covers ~90% of cases (popups, sliders, checkboxes, text fields). Use 'AXSelectedText' to set text-field selection or 'AXStringValue' on edge-case readers."},
                "mode": {"type": "string", "enum": ["som", "text"], "default": "som", "description": "For window_state: 'som' (DEFAULT) returns a screenshot with numbered [N] labels drawn on every actionable element + the AX tree — the model picks elements off the annotated image. 'text' is the cheaper follow-up read that returns the AX tree markdown only (no screenshot). Always use 'som' on the first call for a new window so you can SEE which numbered button is which. Use 'text' for tight follow-up reads where you already know the layout."},
                "max_elements": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 100, "description": "For window_state: cap on returned actionable elements. Default 100, max 1000. Electron apps (Cursor, VS Code, Slack, Discord, Notion) publish 500+ AX nodes per window — capping prevents one call from blowing context. When the cap trims the tree the response carries `truncated: true` and `total_elements` so you can either narrow via app_name= or raise max_elements."},
            },
            "required": ["action"],
        },
    },
    {
        "name": "wait",
        "description": (
            "Idle-sleep for N seconds without consuming a model turn for "
            "every check. Use when you need to wait for an external "
            "process — a deploy to finish on Render, a build to complete, "
            "a long page to load fully, a backup job to settle. After the "
            "sleep returns, take a fresh `web.snapshot()` / `computer.screenshot` "
            "to inspect the new state.\n\n"
            "Hard cap: 180 seconds per call. For longer waits, loop — "
            "but consider whether the task is better handed off via "
            "`schedule_task` or `handoff_to_user`.\n\n"
            "DO NOT use this to pad timing inside a UI interaction "
            "(typing, clicking) — use `computer.wait` (max 5s) for those. "
            "This tool is for genuine external-process waits where 30–180s "
            "of polling is appropriate."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "seconds": {
                    "type": "number",
                    "minimum": 1,
                    "maximum": 180,
                    "description": "How many seconds to sleep. 1–180.",
                },
                "reason": {
                    "type": "string",
                    "description": "Short why-string surfaced to the user in the notch so they know what we're waiting on, e.g. 'waiting for Render deploy'.",
                },
            },
            "required": ["seconds"],
        },
    },
    {
        "name": "request_permission",
        "description": (
            "Surface a TCC permission grant flow to the user. Call this "
            "when you literally cannot complete the user's task without "
            "a macOS permission you don't have — INSTEAD of writing a "
            "prose refusal explaining how the user could grant it.\n\n"
            "When you call this, the Mac app opens the right Privacy "
            "pane in System Settings, shows a drag-island affordance, "
            "and AUTO-RETRIES the user's original query as soon as the "
            "grant lands. The user gets a hand-held flow; you get a "
            "successful completion on the retry.\n\n"
            "Anti-pattern (the user has flagged this multiple times): "
            "responding with 'I'm not able to see your screen because "
            "screen recording isn't granted, you can enable it in...'. "
            "That text reply is useless — call this tool instead.\n\n"
            "Services:\n"
            "  - accessibility    — needed for clicks / keystrokes (computer.click, computer.type)\n"
            "  - screen_recording — needed for screenshots (computer.screenshot, every after-screenshot)\n"
            "  - apple_events     — needed for scriptable apps (applescript)\n\n"
            "ONE call per missing permission. Do NOT loop — after you "
            "call this, the agent run terminates and the Mac app drives "
            "the grant flow."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "service": {
                    "type": "string",
                    "enum": ["accessibility", "screen_recording", "apple_events"],
                    "description": "Which TCC permission you need.",
                },
                "reason": {
                    "type": "string",
                    "description": "Brief context about what you were trying to do (one sentence). Optional but helps the user understand why klo is asking.",
                },
            },
            "required": ["service"],
        },
    },
    {
        "name": "confirm_action",
        "description": (
            "Ask the user to confirm an action BEFORE you do it. Use for "
            "anything irreversible, anything visible to other people, or "
            "anything that changes system / billing / personal state.\n\n"
            "CONFIRM-FIRST list:\n"
            "  - Sending: messages, emails, DMs, comments, posts, tweets — "
            "any outbound communication\n"
            "  - Money: purchases, orders, transfers, subscriptions\n"
            "  - Destructive: rm outside /tmp/, dropping tables, force-"
            "pushing, deleting notes/events, anything you can't undo\n"
            "  - System changes: Bluetooth pair/unpair, audio device "
            "switch, network/DNS, login items\n"
            "  - Outbound personal data: posting private info publicly, "
            "sharing files externally, copying credentials\n"
            "  - Mutating third-party services: clicking Save / Submit / "
            "Deploy / Add on any external dashboard (Render, Vercel, "
            "Stripe, AWS, GitHub, Cloudflare, registrar, etc.). These "
            "trigger deploys, charges, or live config changes that take "
            "minutes to revert. Confirm BEFORE the final submit click, "
            "even if the user described the form fields in detail — they "
            "want to verify the assistant got them right.\n\n"
            "NOT confirm-first (just do these): lookups, reads, summaries, "
            "navigation, opening apps, fetching webpages, web search, "
            "filling form fields (only the final submit click needs a "
            "confirm — fill all fields first, then confirm, then submit).\n\n"
            "EXCEPTION — if the user already fully specified the action in "
            "their prompt (\"send john@x.com saying 'meeting at 4'\"), you "
            "have authorization. Skip the confirm and just do it. This "
            "EXCEPTION DOES NOT APPLY to the third-party-service-submit "
            "case above — always confirm those, even when fully specified.\n\n"
            "The Mac app shows the user an inline confirm bar. The user "
            "either accepts (⌘+Enter) or cancels (Esc). The tool returns "
            "{\"approved\": true|false}. If approved:false, abandon the "
            "action cleanly — don't retry or argue. NEVER ask in prose "
            "and end the turn; that pattern doesn't surface a UI."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "summary": {
                    "type": "string",
                    "description": (
                        "One concise sentence describing EXACTLY what you're "
                        "about to do. Include recipient, content snippet, "
                        "amounts. Example: \"Send 'meeting moved to 4pm' to "
                        "john@example.com\"."
                    ),
                },
                "irreversible": {
                    "type": "boolean",
                    "description": "True if the action cannot be undone with one click (sends, purchases, deletes).",
                    "default": True,
                },
                "danger": {
                    "type": "string",
                    "description": "Optional callout for high-impact actions, e.g. \"deletes 12 notes\" or \"$200 charge\".",
                },
            },
            "required": ["summary"],
        },
    },
    {
        "name": "i_couldnt_do_this",
        "description": (
            "Call this instead of looping or fabricating when you've genuinely "
            "tried and can't complete the task. Triggers a terminal honest failure "
            "with a structured payload. Use when:\n"
            "  - You've tried 3+ different approaches and none worked\n"
            "  - The task requires capability the tool surface doesn't have\n"
            "  - Auth/captcha/2FA blocks you and you can't ask the user\n"
            "  - The data the user asked for genuinely doesn't exist anywhere reachable\n"
            "Don't use for tasks where you're just confused — try a different tool first."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "reason": {"type": "string", "description": "One sentence on why you can't do it."},
                "what_i_tried": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "List of approaches you tried before giving up.",
                },
                "blocker": {"type": "string", "description": "The specific blocker (auth, missing tool, captcha, page error, etc.)."},
            },
            "required": ["reason"],
        },
    },
    {
        "name": "handoff_to_user",
        "description": (
            "Call this when you've done what the user asked and now need to tell "
            "them something or hand control back. Use AT THE END of every task "
            "whose deliverable is 'take me to X and tell me Y' — after navigating, "
            "call handoff_to_user with the answer/guidance instead of taking "
            "another action. Also call when the user has wandered off (e.g. you "
            "see a tool result with error_code: \"user_has_focus\") and your "
            "remaining steps would be intrusive. After this call, the run ends "
            "cleanly and your message is shown to the user. Do NOT keep calling "
            "tools after this. For honest failures, use i_couldnt_do_this instead."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "message": {
                    "type": "string",
                    "description": (
                        "Plain prose to show the user. 1-3 sentences. Tell them "
                        "what's done and what to do next. Concrete — quote the "
                        "menu item / setting name / element label they should click."
                    ),
                },
                "next_steps": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional ordered list of explicit click/type steps the user should perform themselves.",
                },
            },
            "required": ["message"],
        },
    },
    # browser_extension intentionally removed from the TOOLS list — the
    # product promise is "no install required." All web tasks go through
    # the `accessibility` tool which auto-enriches Chromium AX trees via
    # AXManualAccessibility. The tool implementation below stays in the
    # file for the future opt-in path (KLO_ENABLE_BROWSER_EXTENSION=1)
    # but is unreachable by the model.

    # ─── Composio (third-party integrations) ────────────────────────────
    # Single meta-tool pair instead of one tool per Composio action — keeps
    # the model's tool list stable regardless of which services the user
    # has connected (so prompt cache stays warm across users).
    # Both tools proxy through klo-cloud's /api/integrations/composio/*
    # which holds the Composio API key + checks the user's subscription.
    {
        "name": "composio_list_actions",
        "description": (
            "List the available actions for a service the user has connected via "
            "Composio (e.g. gmail, notion, slack, linear, github, asana, gcalendar). "
            "Returns JSON schemas so you know what parameters each action takes. "
            "Use BEFORE composio_execute when you don't already know the action's "
            "exact slug + parameter shape. The connected services for the current "
            "user are listed in CONNECTED SERVICES — only those are usable.\n\n"
            "If the user asks about a service NOT in CONNECTED SERVICES, tell them "
            "they need to connect it in Settings → Connected Apps first."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "toolkit": {
                    "type": "string",
                    "description": "Toolkit slug, e.g. 'gmail', 'notion', 'slack'.",
                },
            },
            "required": ["toolkit"],
        },
    },
    {
        "name": "composio_execute",
        "description": (
            "Execute a Composio action on a service the user has connected. "
            "Composio handles OAuth and API plumbing; you just need the action "
            "slug + parameters (get these from composio_list_actions first if "
            "you don't already know them).\n\n"
            "Prefer composio_execute over web.* when the toolkit is connected — "
            "API-direct is faster and more reliable than UI clicks. Examples:\n"
            "  - 'send email to bob@x.com' → composio_execute(toolkit='gmail', "
            "action='GMAIL_SEND_EMAIL', params={...})\n"
            "  - 'add to Notion DB' → composio_execute(toolkit='notion', "
            "action='NOTION_INSERT_ROW_DATABASE', params={...})\n"
            "  - 'create Linear issue' → composio_execute(toolkit='linear', "
            "action='LINEAR_CREATE_ISSUE', params={...})\n\n"
            "Large responses get auto-truncated at 16 KB with a hint to refine — "
            "if you see _truncated:true in the result, add filters/limits to your "
            "next call."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "toolkit": {"type": "string", "description": "Toolkit slug from CONNECTED SERVICES."},
                "action": {
                    "type": "string",
                    "description": "Exact action slug from composio_list_actions, e.g. 'GMAIL_SEND_EMAIL'.",
                },
                "params": {
                    "type": "object",
                    "description": "Action parameters matching the action's schema.",
                },
            },
            "required": ["toolkit", "action", "params"],
        },
    },
    {
        "name": "delegate_task",
        "description": (
            "Fork ONE or MORE child agents to work in parallel on independent "
            "subtasks. Each child runs to completion against a fresh conversation "
            "with a restricted tool set (no memory writes, no further delegation, "
            "no scheduling). Parent only sees each child's final summary text — "
            "tool-call traces aren't bubbled up.\n\n"
            "Use ONLY when the user's task decomposes into 2+ truly independent "
            "subtasks (e.g. 'brief me from gmail AND linear AND calendar' — three "
            "independent fetches that don't depend on each other). For sequential "
            "workflows (gather then act), do not delegate — just call tools "
            "yourself in order.\n\n"
            "Each `tasks` entry: prompt (required), scoped_service (optional "
            "Composio toolkit slug), worker_kind (optional: 'quick'=6 turns / "
            "'research'=20 turns / 'deep'=40 turns — picks model + budget). "
            "Children run concurrently; this call blocks the parent until all "
            "settle. Cap is 4 parallel children.\n\n"
            "If a campaign workspace is bound to this run, children inherit it "
            "(via ContextVar) and can read campaign.md / write evidence."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tasks": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 4,
                    "items": {
                        "type": "object",
                        "properties": {
                            "prompt": {"type": "string"},
                            "scoped_service": {"type": "string"},
                            "worker_kind": {
                                "type": "string",
                                "enum": ["quick", "research", "deep"],
                                "description": "quick=Haiku/6 turns (default), research=Sonnet/20 turns, deep=Sonnet/40 turns.",
                            },
                        },
                        "required": ["prompt"],
                    },
                },
            },
            "required": ["tasks"],
        },
    },
    {
        "name": "schedule_task",
        "description": (
            "DRAFT a recurring schedule that the user must confirm in the notch "
            "before it goes live. As of klo 2.0.0 this tool no longer activates "
            "schedules silently — it queues a pending row and pops a confirm "
            "card on the user's Mac.\n\n"
            "Use when the user asks to be pinged on a schedule about something: "
            "'every morning at 8 brief me on linear', 'every hour check if anything's "
            "blocked', 'remind me at the end of the day to journal'.\n\n"
            "After calling this tool, your reply to the user must say the schedule "
            "is DRAFTED and waiting for confirmation — never claim it's already "
            "running. Example reply: \"I drafted a schedule to check Linear every "
            "hour. Tap Confirm on the notch card to activate it.\"\n\n"
            "Once activated, the cloud reruns `prompt` on the cadence. When the "
            "model's reply equals the literal string `[SILENT]` (case-insensitive), "
            "klo swallows the run — no notification, no chat noise. So 'every hour, "
            "check linear; if nothing's blocked, reply [SILENT]' becomes a real-time "
            "monitor that only pings when there's something.\n\n"
            "Cadence supports: 'every Nm/Nh/Nd' (e.g. 'every 30m', 'every 4h', "
            "'every 2d'), 'hourly', 'daily', AND wall-clock forms "
            "'at 9am' / 'at 9:30am' / 'at 14:00' (fires daily at that time), "
            "'weekdays at 9am', 'weekends at 10am', 'every monday at 8am' "
            "(any weekday name). Wall-clock times are interpreted in the "
            "user's local timezone. Minimum interval cadence is 2 minutes.\n\n"
            "scoped_service is optional — pass the lowercase Composio slug "
            "(gmail/notion/linear/etc) when the scheduled prompt is scoped to "
            "one toolkit."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "user_phrase": {
                    "type": "string",
                    "description": "Cadence phrase the user used (e.g. 'every hour', 'daily', 'every 30 min').",
                },
                "prompt": {
                    "type": "string",
                    "description": "The prompt klo runs at cadence. Include the [SILENT] convention if relevant.",
                },
                "scoped_service": {
                    "type": "string",
                    "description": "Optional Composio toolkit slug (lowercase): 'gmail', 'notion', 'linear', etc.",
                },
            },
            "required": ["user_phrase", "prompt"],
        },
    },
    # ─── Long-horizon workspace tools ──────────────────────────────────
    #
    # The workspace primitive lets klo own a durable, on-disk handle to
    # an initiative that spans hours/days/weeks. It is INTENTIONALLY
    # domain-neutral: marketing campaigns, fundraises, product launches,
    # KPI watches, ship-date orchestration — all use the same files
    # (brief.md / plan.md / log.md / decisions.md / pending.json) under
    # ~/Library/Application Support/com.klorah.klo/workspaces/{slug}/.
    #
    # Workspaces are bound via ContextVar (workspace.set_current_workspace).
    # Once bound, workspace_* tools read/write the active workspace, AND
    # delegate_task children inherit it automatically. Outside a bound
    # workspace, write/read tools return a structured "no workspace" error
    # so the model gets a clear signal.
    #
    # When klo decides a task warrants long-horizon treatment (the user is
    # asking it to track something, manage something, hit a multi-day goal),
    # it calls workspace_init to create one and switches into the
    # long-horizon posture for the rest of the run.
    {
        "name": "workspace_init",
        "description": (
            "Create a fresh long-horizon workspace and bind it to this run. "
            "Use when the user's ask is non-trivial AND will require either "
            "(a) work spanning multiple sessions/days, (b) recurring scheduled "
            "check-ins (KPI watches, weekly reviews), (c) tracking decisions "
            "and state over time, or (d) delegating to multiple parallel "
            "workers with shared context.\n\n"
            "Signals that a workspace is warranted: 'be my CMO/CTO/COO/X for "
            "Y', 'track this for me', 'manage this project', 'run my "
            "fundraise', 'plan and execute X', 'help me hit KPI Z by date W', "
            "anything that begins with 'over the next N weeks…'.\n\n"
            "Signals that a workspace is OVERKILL: any one-shot task ('open "
            "Notes', 'send this email', 'what's playing'), anything finishable "
            "in this single turn.\n\n"
            "After init succeeds, you have access to workspace_read, "
            "workspace_write, workspace_append_log, workspace_append_decision, "
            "workspace_save_evidence, workspace_request_human, and you can "
            "spawn workers via delegate_task that will inherit the workspace. "
            "You should also call schedule_task with the prompts you want "
            "yourself to be re-invoked with on a cadence (e.g. weekly KPI "
            "review, daily morning sync). brief.md is seeded from the brief "
            "you pass; the rest are empty templates you fill in."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Short human-friendly slug-base, e.g. 'meal-tracking-launch', 'series-a-raise', 'api-ship-sept'. Today's date is appended automatically.",
                },
                "brief": {
                    "type": "string",
                    "description": "The user's full ask captured verbatim — the anchor klo re-reads to stay grounded. Don't paraphrase; use the user's words.",
                },
            },
            "required": ["name", "brief"],
        },
    },
    {
        "name": "workspace_load",
        "description": (
            "Load an existing workspace by slug and bind it to this run. "
            "Use when the user references prior long-horizon work ('continue "
            "the meal tracking campaign', 'what's the state of the raise', "
            "'check on the API ship') and you want to pick up where you "
            "left off. Call workspace_list first if you're not sure of the "
            "slug."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "slug": {"type": "string"},
            },
            "required": ["slug"],
        },
    },
    {
        "name": "workspace_list",
        "description": (
            "Enumerate every workspace on disk (newest-first). Returns slug + "
            "brief + created_at for each. Use this to (a) help the user pick "
            "between multiple active initiatives, (b) find the right slug for "
            "workspace_load, (c) decide whether the user's current ask is a "
            "new initiative or a continuation of an existing one."
        ),
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "workspace_read",
        "description": (
            "Read one file from the active workspace. Always call this before "
            "writing or planning — it's how you ground in the existing state "
            "across sessions and across delegated workers.\n\n"
            "Valid names:\n"
            "  - 'brief'     — the user's anchor ask (immutable; re-read to stay grounded)\n"
            "  - 'plan'      — your current decomposition with [ ]/[x]/[?]/[!] status flags\n"
            "  - 'log'       — human-readable history of what you've done (markdown)\n"
            "  - 'decisions' — user-approved choices to honor (semantic memory)\n"
            "  - 'recent'    — last N internal audit events (machine-readable); pass limit"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "enum": ["brief", "plan", "log", "decisions", "recent"],
                },
                "limit": {
                    "type": "integer",
                    "description": "For 'recent' only: max events to return.",
                },
            },
            "required": ["name"],
        },
    },
    {
        "name": "workspace_write",
        "description": (
            "Overwrite brief.md or plan.md in the active workspace.\n\n"
            "  - 'plan'  — your current decomposition. Update freely as the "
            "initiative evolves. Use [ ]/[x]/[?]/[!] status flags so progress "
            "is scannable.\n"
            "  - 'brief' — overwrite ONLY when the user materially clarifies "
            "scope (e.g. 'actually, I want to focus on Reels, not Shorts'). "
            "Don't paraphrase — preserve the user's words.\n\n"
            "log/decisions are append-only via their dedicated tools — don't "
            "rewrite them here."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "enum": ["brief", "plan"]},
                "content": {"type": "string"},
            },
            "required": ["name", "content"],
        },
    },
    {
        "name": "workspace_append_log",
        "description": (
            "Append one human-readable line to log.md. Use for substantive "
            "events the USER would want to see on opening the file: 'wrote "
            "first draft of the plan', 'scheduled weekly KPI review for "
            "Mondays 8am', 'delegated TikTok research to a worker, 12 "
            "creators surveyed', 'pending publish approval on YouTube Short "
            "#1'. One line per call. Skip for chatter — log.md is what the "
            "user reads to catch up, not a debug trace."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "message": {"type": "string"},
            },
            "required": ["message"],
        },
    },
    {
        "name": "workspace_append_decision",
        "description": (
            "Append one user-approved choice to decisions.md. Use when the "
            "user explicitly picks between options ('go with Shorts not "
            "long-form') or sets a constraint ('cap spend at $200/mo'). One "
            "decision per call. Don't use for general notes — that's plan.md "
            "or log.md."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
            },
            "required": ["text"],
        },
    },
    {
        "name": "workspace_save_evidence",
        "description": (
            "Save a raw artifact (research dump, draft, scraped data, SVG, "
            "screenshot path) under the workspace's evidence/ folder. Workers "
            "save dense findings here rather than stuffing them into their "
            "return summary — keeps the summary tight and gives the parent a "
            "path to grep later. For Phase 2, completion gates will require "
            "evidence paths."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Filename including extension."},
                "content": {"type": "string"},
            },
            "required": ["name", "content"],
        },
    },
    {
        "name": "workspace_request_human",
        "description": (
            "Queue an item for human approval before an external side-effect "
            "(publish, send, post, irreversible change). Returns a clearance_id "
            "the caller MUST pass back when the approved action executes — the "
            "publish gate refuses without it.\n\n"
            "Use whenever you're about to do something the user can't easily "
            "undo: send a cold email, publish a YT video, post to social, "
            "create a calendar event, spend > $20. The desktop UI surfaces "
            "the queue as approval cards. After enqueuing, either poll "
            "workspace_check_clearance or hand off and let the user resume "
            "the initiative later."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "reason": {"type": "string"},
                "ask": {"type": "string"},
                "payload": {"type": "object"},
            },
            "required": ["reason", "ask"],
        },
    },
    {
        "name": "workspace_check_clearance",
        "description": (
            "Check whether a previously queued pending item has been approved. "
            "Returns {status: 'pending'|'approved'|'rejected', ...}."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "clearance_id": {"type": "string"},
            },
            "required": ["clearance_id"],
        },
    },
]


async def _tool_browser_extension(action: str, **params: Any) -> str:
    """Drive the user's daily browser via the agent2 chrome extension.

    Available actions (params after the dash):
      - tabs_list                          (no params; lists every tab everywhere)
      - tabs_active                        (the current foreground tab)
      - tabs_navigate          — url, [tab_id]
      - tabs_create            — url, [active=true]
      - tabs_read_text         — [tab_id], [max=12000]
      - tabs_read_html         — [tab_id], [max=30000]
      - tabs_click             — selector, [tab_id]
      - tabs_fill              — selector, text, [tab_id], [submit=false]
      - tabs_evaluate          — code, [tab_id]
      - tabs_screenshot        — (active tab only)
    """
    from .bridge import bridge

    method_map = {
        "tabs_list": "tabs.list",
        "tabs_active": "tabs.active",
        "tabs_navigate": "tabs.navigate",
        "tabs_create": "tabs.create",
        "tabs_read_text": "tabs.read_text",
        "tabs_read_html": "tabs.read_html",
        "tabs_click": "tabs.click",
        "tabs_click_text": "tabs.click_text",
        "tabs_click_idx": "tabs.click_idx",
        "tabs_fill": "tabs.fill",
        "tabs_fill_text": "tabs.fill_text",
        "tabs_evaluate": "tabs.evaluate",
        "tabs_screenshot": "tabs.screenshot",
        "tabs_dom_snapshot": "tabs.dom_snapshot",
        "tabs_wait_for": "tabs.wait_for",
    }
    method = method_map.get(action)
    if method is None:
        return json.dumps({
            "ok": False,
            "error": f"unknown action {action!r}; valid actions: {sorted(method_map.keys())}",
        })

    # Reject hallucinated empty calls before they hit the bridge — the bridge
    # eventually errors anyway but with a less actionable message, costing
    # the model another turn.
    if action == "tabs_wait_for" and not params.get("selector") and not params.get("text"):
        return json.dumps({
            "ok": False,
            "error": (
                "tabs_wait_for requires either `selector` or `text`. "
                "Use `text` for visible content (e.g. text=\"Uganda\") or "
                "`selector` for a CSS hook (e.g. selector=\"input[aria-label='Where to?']\")."
            ),
        })

    # Agent2 runs in a different process from bridge_server, so we connect
    # to the bridge over its /rpc route and proxy the call.
    from .bridge import call_via_server, BridgeNotConnectedError

    try:
        result = await call_via_server(method, params, timeout=30)
        return json.dumps({"ok": True, "result": result}, ensure_ascii=False, default=str)
    except BridgeNotConnectedError as exc:
        # Tagged so the desktop_api can lift this into the run's
        # `error_code` field, which the Mac app routes to a branded
        # "install the Chrome extension" card instead of a salmon
        # RuntimeError string.
        return json.dumps({
            "ok": False,
            "error": str(exc),
            "error_code": BridgeNotConnectedError.code,
        })
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


# ---------------------------------------------------------------- native computer

# Lazy singleton — caches display geometry across calls in one run so we
# don't re-screenshot on every click.
_action_executor = None


def _get_action_executor():
    """Return the singleton MacOpsExecutor. This proxies all TCC-gated
    operations (screenshot, click, type, key, scroll, ...) over HTTP to
    the Mac app's MacOpsServer (port 8788), which executes them with
    the Mac app's TCC trust. The sidecar binary's own (empty) trust
    state is no longer in the path — that was the cross-process gap
    causing the perpetual permission-denied loop."""
    global _action_executor
    if _action_executor is None:
        from .mac_ops_client import MacOpsExecutor
        _action_executor = MacOpsExecutor()
    return _action_executor


# Import lazily-but-eagerly so the symbol is available for the
# top-level except clause in _tool_computer. The Mac app server is
# only reachable when the sidecar runs as a child of klo.app — in
# unit tests where that isn't true, calls hit the executor and raise
# a network error, which we surface as a normal tool error. The
# import itself is cheap (no network, just module load).
from .mac_ops_client import PermissionDeniedError  # noqa: E402


_COMPUTER_MUTATING_ACTIONS = {
    "left_click", "right_click", "double_click", "triple_click",
    "left_click_drag", "type", "paste_text", "key", "hold_key", "scroll",
    "click_element", "find_element",
}


def _permission_denied_payload(service: str) -> str:
    """Structured signal the Mac app reads from `status_change` events
    via the desktop_api error_code capture hook. `permission_service`
    drives the Privacy-pane the user is sent to."""
    pretty = {
        "accessibility": "Accessibility",
        "screen_recording": "Screen Recording",
        "apple_events": "Automation",
    }.get(service, service)
    return json.dumps({
        "ok": False,
        "error": f"{pretty} access is required for this action.",
        "error_code": "permission_denied",
        "permission_service": service,
    })


# Anthropic Computer Use sub-call usage accumulator. agent.py reads and
# resets this around each run() so the run's RunResult includes both
# the orchestrator's tokens and the coord-finder's tokens.
_anthropic_usage_total: dict[str, int] = {"input_tokens": 0, "output_tokens": 0, "calls": 0}


def _record_anthropic_usage(usage: dict[str, int]) -> None:
    _anthropic_usage_total["input_tokens"] += int(usage.get("input_tokens", 0) or 0)
    _anthropic_usage_total["output_tokens"] += int(usage.get("output_tokens", 0) or 0)
    _anthropic_usage_total["calls"] += 1


def consume_anthropic_usage() -> dict[str, int]:
    """Snapshot and reset the accumulated Anthropic usage. Called by the
    agent loop before/after each run() so the totals attribute to the
    correct run."""
    snap = dict(_anthropic_usage_total)
    _anthropic_usage_total["input_tokens"] = 0
    _anthropic_usage_total["output_tokens"] = 0
    _anthropic_usage_total["calls"] = 0
    return snap


# Anthropic Computer Use API gives pixel-precise coordinates because the
# model is specifically trained for screen UIs. We use it as a
# coordinate-finding co-processor: agent describes element ("the +
# button"), Anthropic returns coordinates, we click. Way more reliable
# than asking a generic vision model to guess pixels itself.
_ANTHROPIC_COMPUTER_USE_RESOLUTIONS: list[tuple[int, int, float]] = [
    (1024, 768, 1024 / 768),    # 4:3
    (1280, 800, 1280 / 800),    # 16:10 (most Macs)
    (1366, 768, 1366 / 768),    # 16:9
]


def _best_anthropic_resolution(width_px: int, height_px: int) -> tuple[int, int]:
    """Pick the Anthropic-recommended Computer Use resolution closest to
    the actual display's aspect ratio. Avoids distorting the image (which
    degrades coordinate accuracy)."""
    aspect = width_px / max(1, height_px)
    best = min(_ANTHROPIC_COMPUTER_USE_RESOLUTIONS, key=lambda r: abs(aspect - r[2]))
    return (best[0], best[1])


def _resize_png_for_anthropic(png_bytes: bytes, target_w: int, target_h: int) -> bytes:
    from PIL import Image
    img = Image.open(io.BytesIO(png_bytes))
    if img.mode != "RGB":
        img = img.convert("RGB")
    img = img.resize((target_w, target_h), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    img.save(out, format="PNG", optimize=True)
    return out.getvalue()


# ─── Native-Cocoa AX redirect ───────────────────────────────────────────
#
# Apps where AccessibilityServices publishes a dense, identity-based tree.
# For these, `accessibility.window_state` + `accessibility.press_indexed`
# is dramatically more accurate than vision targeting — the AX path acts
# on the actual button by its AX identity, not by guessing pixels in a
# downsampled screenshot. Pre-redirecting click_element to AX for these
# bundle IDs eliminates the most common visual-fallback failure mode.
#
# Electron/Chromium apps and canvas-rendered apps are intentionally
# omitted — their AX trees are sparse and vision is sometimes the right
# call there.
_NATIVE_COCOA_BUNDLES = frozenset({
    "com.apple.Notes",
    "com.apple.iCal",
    "com.apple.reminders",
    "com.apple.Music",
    "com.apple.systempreferences",
    "com.apple.finder",
    "com.apple.mail",
    "com.apple.MobileSMS",
    "com.apple.TextEdit",
    "com.apple.AddressBook",
    "com.apple.calculator",
    "com.apple.dictionary",
    "com.apple.Preview",
    "com.apple.Maps",
    "com.apple.Stocks",
    "com.apple.weather",
    "com.apple.Voice-Memos",
    "com.apple.FaceTime",
    "com.apple.Photos",
    "com.apple.Home",
    "com.apple.podcasts",
    "com.apple.iWork.Pages",
    "com.apple.iWork.Numbers",
    "com.apple.iWork.Keynote",
})

# Cues that signal "this target genuinely needs vision" — pictorial
# content, custom-rendered surfaces, anything where AX won't have an
# identity-rich representation. When the description matches one of
# these patterns, skip the AX redirect even on a native app.
_VISION_ONLY_CUES = (
    "image of",
    "photo of",
    "picture of",
    "icon at",
    "the red",
    "the blue",
    "the green",
    "the yellow",
    "the orange",
    "canvas",
    "the dot",
    "the circle",
)


def _maybe_redirect_to_accessibility(description: str, action: str) -> str | None:
    """Return a JSON redirect response when click_element is called on a
    native Cocoa app where accessibility.window_state would be more
    reliable. Return None to let the vision path proceed normally.

    Reads NSWorkspace.frontmostApplication directly — NOT the
    active-apps tracker — because the tracker polls every 500ms and a
    common failure mode is `computer.open_app("Notes")` immediately
    followed by `computer.click_element(...)` where Notes is frontmost
    by the time the click fires but the tracker hasn't logged the
    activation yet, so the redirect misses and the agent clicks blind
    against a downsampled screenshot. AppKit's `frontmostApplication()`
    is synchronous and reflects the current state.
    """
    desc_lower = description.lower()
    for cue in _VISION_ONLY_CUES:
        if cue in desc_lower:
            return None
    bid = ""
    name = ""
    try:
        import AppKit  # type: ignore
        ws = AppKit.NSWorkspace.sharedWorkspace()
        front = ws.frontmostApplication()
        if front is not None:
            bid = str(front.bundleIdentifier() or "").strip()
            name = str(front.localizedName() or "").strip()
    except Exception:  # noqa: BLE001
        return None
    # Fall back to the tracker if NSWorkspace gave us nothing useful
    # (extremely rare — sandbox / launchd edge cases).
    if not bid:
        try:
            from .active_apps import tracker as get_tracker
            t = get_tracker()
            rec = t.most_recent_non_klo() if t is not None else None
            if rec is not None:
                bid = (rec.bundle_id or "").strip()
                name = (rec.name or "").strip()
        except Exception:  # noqa: BLE001
            return None
    # Skip when klo's own UI is frontmost — the agent doesn't drive klo.
    if bid.startswith("com.klo") or bid == "com.klorah.klo":
        return None
    if bid not in _NATIVE_COCOA_BUNDLES:
        return None
    return json.dumps({
        "ok": False,
        "redirect": "accessibility",
        "frontmost_bundle_id": bid,
        "frontmost_app_name": name,
        "guidance": (
            f"{name or bid} is a native Cocoa app with a reliable "
            f"accessibility tree. Vision targeting (computer.{action}) "
            f"misses small controls in apps like this. Call "
            f"accessibility.window_state(target_app='{name}', mode='som') "
            f"to get the indexed element tree PLUS an annotated screenshot "
            f"with numbered [N] labels on every actionable control. Pick "
            f"the matching element by the visible [N] index, then call "
            f"accessibility.press_indexed(element_index=N) to act on the "
            f"button by its AX identity — no pixel guess, no Retina "
            f"translation, no downsampling artifacts. Do NOT retry "
            f"computer.{action} on this app."
        ),
        "next_step": "accessibility.window_state(target_app=..., mode='som')",
    }, ensure_ascii=False)


async def _find_element_via_openai(
    screenshot_png: bytes,
    description: str,
    image_w: int,
    image_h: int,
    model: str | None = None,
) -> dict[str, Any]:
    """Fallback coordinate-finder using OpenAI vision + structured JSON
    output. Less accurate than Anthropic Computer Use (which has
    specialized pixel-precision training) but works without an Anthropic
    balance. Acceptable for clearly-labeled UI elements; dense or
    canvas-rendered UIs may miss.
    """
    from .cloud_auth import KLO_CLOUD_URL, get_session_token
    session_token = get_session_token()
    if not session_token:
        return {"ok": False, "error": "klo not signed in"}
    model = model or os.environ.get("OPENAI_COORD_MODEL") or os.environ.get("OPENAI_MODEL", "gpt-5.1")

    base64_img = base64.b64encode(screenshot_png).decode("ascii")
    data_url = f"data:image/png;base64,{base64_img}"

    system_msg = (
        f"You are a UI element locator. Given a screenshot and a description, "
        f"return the pixel coordinates of the element's center.\n\n"
        f"The screenshot is {image_w} x {image_h} pixels. Origin (0,0) is top-left. "
        f"X increases rightward, Y increases downward.\n\n"
        f"Respond with ONLY a JSON object using exactly this shape:\n"
        f"  {{\"found\": true, \"x\": <int>, \"y\": <int>, \"label\": \"<short description>\"}}\n"
        f"or, if you cannot confidently identify the element:\n"
        f"  {{\"found\": false, \"reason\": \"<short explanation>\"}}"
    )

    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_msg},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": data_url}},
                    {"type": "text", "text": f"Find this element: {description}"},
                ],
            },
        ],
        "response_format": {"type": "json_object"},
    }

    import httpx
    from .cloud_auth import SIDECAR_UA
    try:
        async with httpx.AsyncClient(timeout=25.0) as client:
            resp = await client.post(
                f"{KLO_CLOUD_URL}/v1/openai/chat/completions",
                headers={
                    "Authorization": f"Bearer {session_token}",
                    "Content-Type": "application/json",
                    "User-Agent": SIDECAR_UA,
                },
                json=body,
            )
    except httpx.HTTPError as exc:
        return {"ok": False, "error": f"klo-cloud openai proxy network: {type(exc).__name__}"}

    if resp.status_code >= 400:
        # Don't pass through resp.text — could be a Render WAF HTML
        # block page. Tool result strings flow into the agent's
        # context window AND eventually surface in error UI.
        return {"ok": False, "error": f"openai_proxy_{resp.status_code}"}

    try:
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        parsed = json.loads(content)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"openai response parse: {exc}"}

    if parsed.get("found") is False:
        return {"ok": False, "error": f"openai-coord-finder: not found ({parsed.get('reason','')})"}

    x = parsed.get("x")
    y = parsed.get("y")
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        return {"ok": False, "error": f"openai returned malformed coords: {parsed}"}

    cx = max(0, min(int(x), image_w))
    cy = max(0, min(int(y), image_h))

    return {
        "ok": True,
        "coordinate": [cx, cy],
        "raw_coordinate": [int(x), int(y)],
        "target_resolution": [image_w, image_h],
        "image_resolution": [image_w, image_h],
        "label": parsed.get("label"),
        "model": model,
        "provider": "openai",
    }


async def _find_element(
    screenshot_png: bytes,
    description: str,
    image_w: int,
    image_h: int,
) -> dict[str, Any]:
    """Try Anthropic Computer Use first (specialized pixel-precision
    training); fall back to OpenAI structured-JSON if Anthropic isn't
    available (no key, no credits, transient error). Either way returns
    the same shape: {ok, coordinate, ...}.

    Override the order with KLO_COORD_PROVIDER=anthropic|openai|both
    (default: both).
    """
    provider_pref = os.environ.get("KLO_COORD_PROVIDER", "both").lower()
    last_err: dict[str, Any] | None = None

    # In hosted mode both providers are always available IF the user is
    # signed in (klo-cloud holds the upstream keys; we just need the
    # Supabase session token). The individual providers handle the
    # not-signed-in case themselves with a clean error.
    if provider_pref in {"anthropic", "both"}:
        anth = await _find_element_via_anthropic(screenshot_png, description, image_w, image_h)
        if anth.get("ok"):
            return {**anth, "provider": "anthropic"}
        last_err = anth
        if provider_pref == "anthropic":
            return last_err

    if provider_pref in {"openai", "both"}:
        oai = await _find_element_via_openai(screenshot_png, description, image_w, image_h)
        if oai.get("ok"):
            return oai
        last_err = oai

    return last_err or {"ok": False, "error": "no coordinate provider available — sign in to klo first"}


async def _find_element_via_anthropic(
    screenshot_png: bytes,
    description: str,
    image_w: int,
    image_h: int,
    model: str | None = None,
) -> dict[str, Any]:
    """Call Anthropic Computer Use to locate a UI element. Returns
    coordinates in the original image's pixel space (0..image_w, 0..image_h).
    """
    model = model or os.environ.get("ANTHROPIC_COORD_MODEL", "claude-sonnet-4-6")
    # Hosted mode: Anthropic Computer Use traffic flows through klo-cloud's
    # /v1/anthropic proxy with the user's Supabase session token.
    from .cloud_auth import KLO_CLOUD_URL, get_session_token
    session_token = get_session_token()
    if not session_token:
        return {"ok": False, "error": "klo not signed in"}

    target_w, target_h = _best_anthropic_resolution(image_w, image_h)
    try:
        resized_png = _resize_png_for_anthropic(screenshot_png, target_w, target_h)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"image resize failed: {type(exc).__name__}: {exc}"}

    base64_img = base64.b64encode(resized_png).decode("ascii")

    body = {
        "model": model,
        "max_tokens": 256,
        "tools": [
            {
                "type": "computer_20251124",
                "name": "computer",
                "display_width_px": target_w,
                "display_height_px": target_h,
            }
        ],
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/png",
                            "data": base64_img,
                        },
                    },
                    {
                        "type": "text",
                        "text": (
                            f"The user is looking at the screen above. They want to interact "
                            f"with: {description}\n\n"
                            f"Look at the screenshot. If the element is visible, click on it "
                            f"using the computer tool's left_click action with the element's "
                            f"center pixel coordinates. The image is your current view — do "
                            f"NOT call the screenshot action; you already have the screen.\n\n"
                            f"If the element is not clearly visible or cannot be identified, "
                            f"respond with text saying 'not found' (no tool use)."
                        ),
                    },
                ],
            }
        ],
    }

    import httpx
    from .cloud_auth import SIDECAR_UA
    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            resp = await client.post(
                f"{KLO_CLOUD_URL}/v1/anthropic/messages",
                headers={
                    "Authorization": f"Bearer {session_token}",
                    "anthropic-version": "2023-06-01",
                    "anthropic-beta": "computer-use-2025-11-24",
                    "content-type": "application/json",
                    "User-Agent": SIDECAR_UA,
                },
                json=body,
            )
    except httpx.HTTPError as exc:
        return {"ok": False, "error": f"klo-cloud anthropic proxy network: {type(exc).__name__}"}

    if resp.status_code >= 400:
        # Don't pass through resp.text — could be a Render WAF HTML
        # block page (same risk as the openai proxy path above).
        return {"ok": False, "error": f"anthropic_proxy_{resp.status_code}"}

    try:
        data = resp.json()
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"anthropic response not json: {exc}"}

    usage = data.get("usage", {}) or {}
    usage_record = {
        "input_tokens": int(usage.get("input_tokens", 0) or 0),
        "output_tokens": int(usage.get("output_tokens", 0) or 0),
    }
    _record_anthropic_usage(usage_record)

    text_chunks: list[str] = []
    non_click_actions: list[str] = []
    for block in data.get("content", []):
        btype = block.get("type")
        if btype == "tool_use" and block.get("name") == "computer":
            input_args = block.get("input", {}) or {}
            anth_action = input_args.get("action")
            coord = input_args.get("coordinate")
            if anth_action not in {"left_click", "double_click", "triple_click", "mouse_move"}:
                non_click_actions.append(str(anth_action))
                continue
            if isinstance(coord, list) and len(coord) == 2:
                rx, ry = float(coord[0]), float(coord[1])
                # Clamp to declared resolution.
                rx = max(0.0, min(rx, float(target_w)))
                ry = max(0.0, min(ry, float(target_h)))
                # Scale back to original image-pixel space.
                ix = int((rx / target_w) * image_w)
                iy = int((ry / target_h) * image_h)
                return {
                    "ok": True,
                    "coordinate": [ix, iy],
                    "raw_coordinate": [int(rx), int(ry)],
                    "target_resolution": [target_w, target_h],
                    "image_resolution": [image_w, image_h],
                    "anthropic_action": anth_action,
                    "model": model,
                    "_anthropic_usage": usage_record,
                }
        elif btype == "text":
            text_chunks.append(block.get("text", ""))

    msg = "anthropic returned no coordinates"
    if non_click_actions:
        msg = f"{msg} — model called non-click action(s): {', '.join(non_click_actions)}"
    if text_chunks:
        msg = f"{msg} — model said: {' '.join(text_chunks)[:300]}"
    return {"ok": False, "error": msg, "_anthropic_usage": usage_record}


async def _open_app_via_shell(name: str, settle_s: float = 1.0) -> dict[str, Any]:
    """Launch / activate a Mac app by name using `open -a`. Deterministic,
    fast, no vision tokens — way better than driving Spotlight. Pairs with
    an automatic after-screenshot so the agent sees the app once it's up.
    """
    if not name or not name.strip():
        return {"ok": False, "error": "app name required"}
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/open", "-a", name.strip(),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        _, stderr = await asyncio.wait_for(proc.communicate(), timeout=8)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.communicate()
        return {"ok": False, "error": f"open -a {name!r} timed out"}
    if proc.returncode != 0:
        return {"ok": False, "error": stderr.decode("utf-8", errors="replace").strip()
                or f"open -a {name!r} failed (rc={proc.returncode})"}
    if settle_s > 0:
        await asyncio.sleep(settle_s)
    return {"ok": True, "app": name.strip()}


# Tool-level enforcement state. The model often re-issues identical
# click_element calls because its perception of the after-screenshot
# misreads "panel opened" as "panel still not open." Prompt discipline
# alone hasn't fixed it (see the Gmail Compose double-click trace).
# Block identical click_element calls within a short window at the
# dispatcher so the suppression doesn't depend on the model remembering
# the rule. The synthetic error tells the model what to do instead.
_RECENT_CLICK_WINDOW_S = 30.0
_recent_click_at: dict[str, float] = {}

# Track the most recent action's "kind" so we can refuse redundant
# observations. After a screenshot, the model often re-screenshots a
# few seconds later — that's wasted tokens (~1MB shipped to the model)
# and worse, it makes the model compare two near-identical screens and
# decide neither is "fresh enough." Block back-to-back observations:
# a screenshot is only useful after a mutation has happened.
_last_action_kind: str = ""  # "observe" | "mutate" | ""


def _normalize_click_desc(description: Any) -> str:
    """Stable key for duplicate-click detection — case+whitespace folded.

    Empty / non-string descriptions return "" so callers without a
    description (raw left_click by coords) don't share a key.
    """
    if not isinstance(description, str):
        return ""
    return " ".join(description.lower().split())


def _reset_recent_clicks() -> None:
    """Clear the duplicate-click guard. Called by the agent loop at the
    start of each run so guard state doesn't leak across user turns."""
    global _last_action_kind
    _recent_click_at.clear()
    _last_action_kind = ""


# Computer actions that are pure observations — they don't change state,
# so back-to-back observations are redundant and we block the second.
# NOTE: `wait` is intentionally NOT here — it's a passive delay so the
# UI can settle, and `screenshot → wait → screenshot` is a legitimate
# "let the page load before re-observing" pattern. Wait is classified
# as transparent below (doesn't update _last_action_kind).
_OBSERVE_ACTIONS = frozenset({"screenshot", "get_cursor_position"})
_TRANSPARENT_ACTIONS = frozenset({"wait"})


async def _tool_computer(action: str, **params: Any) -> str:
    """Same dispatcher as before; PermissionDeniedError raised by the
    MacOpsExecutor proxy is caught at the outer try/except in
    `_tool_computer_dispatch` and converted to the structured payload."""
    global _last_action_kind

    # Redundant-observation suppression. Two screenshots back-to-back
    # (with no mutation between) is the canonical wander pattern: the
    # model second-guesses its first observation, takes another
    # screenshot, then compares two near-identical screens and gets
    # confused. Block.
    if action in _OBSERVE_ACTIONS and _last_action_kind == "observe":
        return json.dumps({
            "ok": False,
            "error": (
                f"redundant {action} — your previous tool call was already "
                f"an observation. Two observations in a row with no mutation "
                f"between them just compares two near-identical screens and "
                f"wastes tokens. Look at the screenshot/snapshot you already "
                f"have, decide what action to take, and call a MUTATING tool "
                f"(left_click / key / type / accessibility.press / "
                f"accessibility.fill / browser_extension.tabs_click_idx / "
                f"shell / applescript). If you genuinely have nothing to do, "
                f"return a final text response — don't keep observing."
            ),
            "suppressed_because": "redundant observation",
        })

    # Duplicate-click suppression — see _RECENT_CLICK_WINDOW_S note.
    if action == "click_element":
        desc_key = _normalize_click_desc(params.get("description"))
        if desc_key:
            now = time.monotonic()
            prior_ts = _recent_click_at.get(desc_key)
            if prior_ts is not None and (now - prior_ts) < _RECENT_CLICK_WINDOW_S:
                age = now - prior_ts
                return json.dumps({
                    "ok": False,
                    "error": (
                        f"duplicate click suppressed — you clicked "
                        f"'{params.get('description')}' {age:.0f}s ago. The "
                        f"first click already fired and almost certainly worked; "
                        f"your perception of the after-screenshot is wrong. DO "
                        f"NOT click the same target again. Instead: take a "
                        f"fresh screenshot or call accessibility.actionable_index "
                        f"to see what's now on screen, then act on the new state "
                        f"(type into the focused field, click a DIFFERENT target, "
                        f"or read the result)."
                    ),
                    "suppressed_because": "identical click_element within 30s",
                    "previous_click_age_s": round(age, 1),
                })
            _recent_click_at[desc_key] = now

    # Record the action's "kind" so the next call's guards can compare.
    # Done BEFORE dispatch so that even if dispatch errors we don't think
    # the screen is fresh. Observe = pure read, mutate = changes state.
    _last_action_kind = "observe" if action in _OBSERVE_ACTIONS else "mutate"

    try:
        return await _tool_computer_dispatch(action, **params)
    except PermissionDeniedError as exc:
        return _permission_denied_payload(exc.service)


async def _tool_computer_dispatch(action: str, **params: Any) -> str:
    """Native desktop interaction. Same dispatch shape as before; the
    underlying ActionExecutor is now a thin proxy over HTTP to the Mac
    app's MacOpsServer (port 8788), which executes the operation in
    the Mac app's process — the one that holds TCC trust.

    Actions:
      - open_app(name) — launch/activate a Mac app via `open -a`.
        Deterministic, fast, returns the after-screenshot. ALWAYS use this
        instead of Spotlight (cmd+space + type) for opening apps.
      - screenshot — full-display PNG.
      - left_click / right_click / double_click / triple_click(coordinate=[x,y])
      - mouse_move / left_click_drag — pointer ops.
      - type(text) / paste_text(text) — typing.
      - key(text) / hold_key(text, duration) — keystrokes; modifier-aware
        (e.g. text='cmd+s').
      - scroll(coordinate, scroll_x, scroll_y) — pixel deltas.
      - wait(duration) — sleep up to 5s.
      - get_cursor_position — sanity probe.

    Coordinates are in IMAGE space; the executor handles Retina translation.

    Mutating actions automatically return a fresh after-screenshot in the
    payload's `data_url` field. The agent loop forwards it to the model
    as a real image_url block — so every click/keystroke ships its
    consequences as visible ground truth. This is the verify-by-vision
    contract: ok=True is informational, the image is the truth.
    """
    # No sidecar-side TCC preflight — we proxy to the Mac app, which
    # has its OWN preflight against its OWN trust (the trust that
    # actually matters, since it's the one the user grants). Mac app
    # returns `error_code: permission_denied` in the JSON envelope when
    # trust is missing; the executor converts that to a
    # PermissionDeniedError below, which we catch and re-emit as the
    # standard permission_denied tool result.

    # Special action: click_element — describe the target ("the + button")
    # and we use Anthropic Computer Use to find pixel-precise coordinates,
    # then click them. Way more reliable than asking a generic vision model
    # to guess pixels itself. Returns the after-screenshot.
    if action in {"click_element", "find_element"}:
        description = str(params.get("description", "")).strip()
        if not description:
            return json.dumps({"ok": False, "error": f"{action} requires 'description' (e.g. 'the + button')"})

        # Pre-flight: for native Cocoa apps the accessibility tree is
        # rich + reliable + identity-based — drastically more accurate
        # than vision targeting on small UI controls. Redirect the model
        # to the AX path BEFORE spending the vision turn that's
        # statistically likely to miss.
        #
        # Visual-only descriptions ("the red dot", "the icon at top
        # left", "the image of a dog") still pass through to vision —
        # AX can't see those.
        try:
            redirect = _maybe_redirect_to_accessibility(description, action)
        except Exception:  # noqa: BLE001
            redirect = None
        if redirect is not None:
            return redirect
        try:
            executor = _get_action_executor()
            # Window-scoped: focuses Anthropic Computer Use on the
            # frontmost app instead of letting it pick targets in
            # background windows.
            ss = await executor.execute({"action": "screenshot", "scope": "window"})
        except Exception as exc:  # noqa: BLE001
            return json.dumps({"ok": False, "error": f"screenshot for {action} failed: {exc}"})
        shot = getattr(ss, "screenshot", None)
        if shot is None:
            return json.dumps({"ok": False, "error": f"no screenshot from executor for {action}"})
        try:
            png_bytes = base64.b64decode(shot.base64_png)
        except Exception as exc:  # noqa: BLE001
            return json.dumps({"ok": False, "error": f"could not decode screenshot: {exc}"})
        image_w = shot.geometry.image_width_px
        image_h = shot.geometry.image_height_px
        find_res = await _find_element(png_bytes, description, image_w, image_h)
        if not find_res.get("ok"):
            # Vision missed. Don't make the model guess what to try next
            # — surface a structured pivot recommendation. If the
            # frontmost app has a usable AX tree, point straight at
            # accessibility.window_state. Otherwise, suggest a
            # description refinement or web.snapshot if Chrome is front.
            front_name = ""
            front_bid = ""
            try:
                from .active_apps import tracker as get_tracker
                t = get_tracker()
                rec = t.most_recent_non_klo() if t is not None else None
                if rec is not None:
                    front_name = rec.name or ""
                    front_bid = rec.bundle_id or ""
            except Exception:  # noqa: BLE001
                pass
            ax_likely = front_bid in _NATIVE_COCOA_BUNDLES
            chrome_front = front_bid in {"com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"}
            if ax_likely:
                pivot = (
                    f"Vision couldn't find '{description}' in the {front_name or 'frontmost'} "
                    f"window. {front_name or 'This app'} has a reliable accessibility "
                    f"tree — call accessibility.window_state(target_app='{front_name}') "
                    f"and find the matching element by role+name, then press_indexed. "
                    f"DO NOT call computer.{action} again with a slightly different "
                    f"description; vision misses don't typically recover via rephrasing."
                )
                pivot_to = "accessibility.window_state"
            elif chrome_front:
                pivot = (
                    f"Vision couldn't find '{description}'. Chrome is frontmost — "
                    f"web.snapshot() is the right tool here. It returns indexed "
                    f"interactive elements by AX role+name; press them by idx. "
                    f"Don't retry computer.{action}."
                )
                pivot_to = "web.snapshot"
            else:
                pivot = (
                    f"Vision couldn't find '{description}'. Before retrying, try: "
                    f"(1) accessibility.window_state(target_app='{front_name or '<app>'}') "
                    f"if it's a native app; (2) a more specific description (label "
                    f"text, position relative to a known element); (3) scroll the "
                    f"window first if the target may be off-screen. Don't loop on "
                    f"the same description."
                )
                pivot_to = "accessibility.window_state | computer scroll | refine description"
            payload: dict[str, Any] = {
                "ok": False,
                "method": "computer",
                "action": action,
                "description": description,
                "frontmost_bundle_id": front_bid,
                "frontmost_app_name": front_name,
                "pivot": pivot,
                "pivot_to": pivot_to,
                **find_res,
                "data_url": f"data:image/png;base64,{shot.base64_png}",
                "geometry": {
                    "image_w": shot.geometry.image_width_px,
                    "image_h": shot.geometry.image_height_px,
                    "logical_w": shot.geometry.logical_width_px,
                    "logical_h": shot.geometry.logical_height_px,
                },
            }
            return json.dumps(payload, ensure_ascii=False)
        coord = find_res["coordinate"]

        if action == "find_element":
            # Just return coords + the original screenshot; no click.
            payload = {
                "ok": True,
                "method": "computer",
                "action": action,
                "description": description,
                "coordinate": coord,
                "anthropic_resolution": find_res["target_resolution"],
                "data_url": f"data:image/png;base64,{shot.base64_png}",
                "geometry": {
                    "image_w": shot.geometry.image_width_px,
                    "image_h": shot.geometry.image_height_px,
                    "logical_w": shot.geometry.logical_width_px,
                    "logical_h": shot.geometry.logical_height_px,
                },
            }
            return json.dumps(payload, ensure_ascii=False)

        # action == "click_element": do the click
        try:
            await executor.execute({"action": "left_click", "coordinate": coord})
        except Exception as exc:  # noqa: BLE001
            return json.dumps({"ok": False, "error": f"click at {coord} failed: {exc}"})

        # After-screenshot — window-scoped to the new frontmost app, so
        # the model sees what's actually in focus after the click.
        try:
            after_ss = await executor.execute({"action": "screenshot", "scope": "window"})
        except Exception as exc:  # noqa: BLE001
            return json.dumps({"ok": True, "method": "computer", "action": action,
                                "description": description, "clicked_at": coord,
                                "screenshot_error": f"{exc}"})
        after_shot = getattr(after_ss, "screenshot", None)
        payload = {
            "ok": True,
            "method": "computer",
            "action": action,
            "description": description,
            "clicked_at": coord,
            "anthropic_resolution": find_res["target_resolution"],
            "after_screenshot": True,
            "targeting_method": "vision_anthropic",
        }
        if after_shot is not None:
            payload["data_url"] = f"data:image/png;base64,{after_shot.base64_png}"
            payload["geometry"] = {
                "image_w": after_shot.geometry.image_width_px,
                "image_h": after_shot.geometry.image_height_px,
                "logical_w": after_shot.geometry.logical_width_px,
                "logical_h": after_shot.geometry.logical_height_px,
            }
            # State-change detection. If the after-screenshot is pixel-
            # identical to the before, the click landed on a no-op
            # (disabled control, captured by an invisible overlay, or
            # the UI updated faster than ScreenCaptureKit could
            # capture). Hint the model to verify via AX instead of
            # blindly clicking again — that's the most common
            # loop-on-failure pattern.
            try:
                import hashlib as _hashlib
                before_hash = _hashlib.md5(png_bytes).hexdigest()
                after_hash = _hashlib.md5(
                    base64.b64decode(after_shot.base64_png)
                ).hexdigest()
                if before_hash == after_hash:
                    payload["state_changed"] = False
                    payload["state_change_warning"] = (
                        f"Click at {coord} returned ok=true but the after-"
                        f"screenshot is pixel-identical to the before. Either "
                        f"the target was disabled, the click was eaten by an "
                        f"invisible overlay, or vision picked the wrong "
                        f"coordinate. DO NOT click the same description "
                        f"again — verify the target's actual state via "
                        f"accessibility.window_state and act via "
                        f"press_indexed instead."
                    )
                else:
                    payload["state_changed"] = True
            except Exception:  # noqa: BLE001
                pass
        return json.dumps(payload, ensure_ascii=False)

    # Special action: open_app — handled here so we can run `open -a` via
    # subprocess, then take an after-screenshot. Doesn't go through the
    # ActionExecutor because the executor only knows pixel/keyboard ops.
    if action == "open_app":
        launch = await _open_app_via_shell(params.get("name", ""))
        if not launch.get("ok"):
            return json.dumps({"ok": False, "method": "computer", "action": action, **launch})
        try:
            executor = _get_action_executor()
            # Window-scoped — we just opened this app, focus the model
            # on its window without distraction from the rest of the
            # desktop.
            after = await executor.execute({"action": "screenshot", "scope": "window", "app_name": launch["app"]})
        except Exception as exc:  # noqa: BLE001
            return json.dumps({"ok": True, "method": "computer", "action": action,
                                "app": launch["app"], "screenshot_error": f"{type(exc).__name__}: {exc}"})
        payload: dict[str, Any] = {"ok": True, "method": "computer", "action": action,
                                    "app": launch["app"], "after_screenshot": True}
        after_shot = getattr(after, "screenshot", None)
        if after_shot is not None:
            payload["data_url"] = f"data:image/png;base64,{after_shot.base64_png}"
            payload["geometry"] = {
                "image_w": after_shot.geometry.image_width_px,
                "image_h": after_shot.geometry.image_height_px,
                "logical_w": after_shot.geometry.logical_width_px,
                "logical_h": after_shot.geometry.logical_height_px,
            }
        return json.dumps(payload, ensure_ascii=False)

    # Hermes-style opt-out: callers chaining mutations can pass
    # capture_after=false to skip the verify-by-vision screenshot. Default
    # is True (preserve klo's existing always-screenshot-after behavior,
    # which prevents "I clicked X" hallucinations). Pop from params so
    # it isn't forwarded to the executor as a bogus param.
    capture_after_opt = params.pop("capture_after", True)
    # Skip auto-capture for actions where it's almost always wasteful:
    #   mouse_move:    no state change, the cursor moved 50px
    #   wait:          we just slept N seconds, nothing changed visually
    #   get_cursor_*:  pure read
    _AUTO_CAPTURE_SKIP = {"mouse_move", "wait", "get_cursor_position"}

    tool_input: dict[str, Any] = {"action": action, **params}
    try:
        executor = _get_action_executor()
        result = await executor.execute(tool_input)
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})

    payload: dict[str, Any] = {"ok": True, "method": "computer", "action": action}
    if getattr(result, "screenshot", None) is not None:
        shot = result.screenshot
        payload["data_url"] = f"data:image/png;base64,{shot.base64_png}"
        payload["geometry"] = {
            "image_w": shot.geometry.image_width_px,
            "image_h": shot.geometry.image_height_px,
            "logical_w": shot.geometry.logical_width_px,
            "logical_h": shot.geometry.logical_height_px,
        }
    if getattr(result, "text", None):
        payload["text"] = result.text

    # Verify-by-vision: for any mutating action, take an after-screenshot
    # automatically and attach it. The agent's next turn sees the consequence
    # as a real image — closes the channel for "I clicked successfully" lies.
    # Caller can opt out via capture_after=false (Hermes-style chain). Always
    # skip for actions where state-change is unlikely (mouse_move/wait).
    should_capture_after = (
        capture_after_opt
        and action in _COMPUTER_MUTATING_ACTIONS
        and action not in _AUTO_CAPTURE_SKIP
        and "data_url" not in payload
    )
    if should_capture_after:
        try:
            # Re-scope the follow-up to the app the executor was last
            # operating against. Prevents focus-drift from causing the
            # follow-up screenshot to capture the wrong window (e.g. user
            # clicked into Chrome while klo was working in Notion — without
            # this, the after-screenshot shows Chrome, model gets confused).
            after_input: dict[str, Any] = {"action": "screenshot", "scope": "window"}
            if getattr(executor, "last_app_name", None):
                after_input["app_name"] = executor.last_app_name
            after = await executor.execute(after_input)
            after_shot = getattr(after, "screenshot", None)
            if after_shot is not None:
                payload["data_url"] = f"data:image/png;base64,{after_shot.base64_png}"
                payload["geometry"] = {
                    "image_w": after_shot.geometry.image_width_px,
                    "image_h": after_shot.geometry.image_height_px,
                    "logical_w": after_shot.geometry.logical_width_px,
                    "logical_h": after_shot.geometry.logical_height_px,
                }
                payload["after_screenshot"] = True
        except Exception as exc:  # noqa: BLE001
            payload["after_screenshot_error"] = f"{type(exc).__name__}: {exc}"

    return json.dumps(payload, ensure_ascii=False)


async def _tool_memory_remember(text: str, type: str = "fact") -> str:
    from . import memory
    res = await memory.remember(text=text, type_=type, source="agent2.run")
    return json.dumps(res, ensure_ascii=False)


async def _tool_memory_recall(query: str | None = None, limit: int = 10, type: str | None = None) -> str:
    from . import memory
    facts = await memory.recall(query=query, limit=int(limit), type_=type)
    return json.dumps({"ok": True, "facts": facts, "count": len(facts)}, ensure_ascii=False)


async def _tool_memory_forget(fact_id: int | None = None, text_match: str | None = None) -> str:
    from . import memory
    res = await memory.forget(fact_id=fact_id, text_match=text_match)
    return json.dumps(res, ensure_ascii=False)


async def _tool_i_couldnt_do_this(reason: str, what_i_tried: list | str | None = None,
                                   blocker: str | None = None) -> str:
    """Structured failure: agent reports it can't complete the task. The agent
    loop treats this as a terminal final-message and stops.
    """
    payload = {
        "ok": True,
        "honest_failure": True,
        "reason": str(reason or "no reason given"),
        "what_i_tried": what_i_tried,
        "blocker": blocker,
    }
    return json.dumps(payload, ensure_ascii=False)


async def _tool_wait(seconds: float, reason: str | None = None) -> str:
    """Idle-sleep without spending a model turn for the check loop.

    Used for external-process waits — Render deploys, builds, long page
    loads. Capped at 180s per call so the agent never wedges; for longer
    polls, the model loops the call.
    """
    try:
        n = float(seconds)
    except (TypeError, ValueError):
        return json.dumps({"ok": False, "error": "seconds must be a number"})
    n = max(0.1, min(n, 180.0))
    await asyncio.sleep(n)
    return json.dumps({
        "ok": True,
        "slept": n,
        "reason": (reason or "").strip() or None,
    }, ensure_ascii=False)


async def _tool_handoff_to_user(message: str, next_steps: list | None = None) -> str:
    """Explicit "I'm done — over to you" terminator. The agent loop
    intercepts this tool name in agent.py and sets result.final to
    `message`, then ends the run cleanly. This real handler exists so
    `dispatch()` is honest for code paths that bypass the loop's
    special-case (e.g. eval harness, smoke tests).
    """
    payload = {
        "ok": True,
        "handed_off": True,
        "message": str(message or "(handoff)"),
        "next_steps": next_steps or [],
    }
    return json.dumps(payload, ensure_ascii=False)


async def _tool_request_permission(service: str, reason: str | None = None) -> str:
    """Agent-driven TCC permission request. Returns the same structured
    `permission_denied` envelope the in-process preflight emits — so the
    existing capture hook in `desktop_api` plucks `error_code` +
    `permission_service` from the tool result and the Mac app's
    `status_change` handler routes it to `PermissionGrantOrchestrator`
    (Settings deep-link + drag island + auto-retry on grant).

    Use this when the agent KNOWS it can't complete the user's task
    without a permission it doesn't have — instead of writing a prose
    refusal ("I can't see your screen because SR isn't granted, here's
    how to enable it"). The user wants the grant flow, not an
    explanation.
    """
    s = (service or "").strip().lower().replace("-", "_").replace(" ", "_")
    valid = {"accessibility", "screen_recording", "apple_events"}
    if s not in valid:
        return json.dumps({
            "ok": False,
            "error": f"unknown permission service: {service!r}; valid: {sorted(valid)}",
        })
    return _permission_denied_payload(s)


async def _tool_web(action: str, **params: Any) -> str:
    """Dispatch web.* actions to the user's real Chrome via the klo
    extension over the ws://127.0.0.1:8767/extension bridge.

    Previously this routed to an embedded WKWebView (api.core.web_drive)
    which had its own session, no autofill, and routinely got stuck on
    login pages because the user wasn't signed in inside the pane. The
    extension drives the user's actual Chrome — Notion / Gmail / Linear
    are already signed in, persistent across tabs, and the user can SEE
    what klo is doing inside their normal browser.

    Action surface mirrors the old `web_drive` API one-for-one so the
    agent's prompts don't need any changes. Most actions map 1:1 to a
    `tabs.*` RPC on background.js (extension/background.js); a few wrap
    polling logic (`wait_for_login`, `wait_settled`).

    Bridge unavailable → returns a typed `extension_not_connected` error
    that KLOState picks up and surfaces as the install card (Phase E
    of the canonical-browser refactor).
    """
    from . import bridge as bridge_module

    try:
        return await _web_dispatch(bridge_module.bridge, action, params)
    except bridge_module.BridgeNotConnectedError as exc:
        # Bridge down. For `open` we can still give the user something
        # visible: hand the URL to the default browser. Everything else
        # is a typed error so the model knows the page is unreadable.
        if action == "open":
            fallback = await _open_in_default_browser(params.get("url"))
            if fallback is not None:
                return fallback
        return json.dumps({
            "ok": False,
            "error_code": "extension_not_connected",
            "error": str(exc),
            "speak": (
                "klo's Chrome extension isn't connected, so I can't see or "
                "interact with web pages right now. Install or enable the "
                "klo extension in Chrome and I'll continue."
            ),
        })
    except TypeError as exc:
        return json.dumps({"ok": False, "error": f"bad arguments to web.{action}: {exc}"})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"web.{action} failed: {type(exc).__name__}: {exc}"})


async def _open_in_default_browser(url: Any) -> str | None:
    """Bridge-down fallback for `web.open`: hand the URL to the user's
    default browser so the navigation is at least visible. Returns None
    when the URL isn't an openable http(s) link (caller falls through to
    the typed extension_not_connected error)."""
    candidate = str(url or "").strip()
    if not candidate.lower().startswith(("http://", "https://")):
        return None
    code, _out, err = await _run_subprocess(["/usr/bin/open", candidate], timeout=10)
    if code != 0:
        return json.dumps({
            "ok": False,
            "error_code": "extension_not_connected",
            "error": f"extension bridge down and default-browser open failed: {err.strip() or code}",
        })
    return json.dumps({
        "ok": True,
        "opened_in_default_browser": True,
        # Typed code rides along even though ok=true: desktop_api's
        # first-error capture forwards it on the terminal status_change
        # so the Mac app can show the extension install card. Without
        # this, a run whose ONLY web call is `open` ends with no signal
        # and the user never learns the extension exists.
        "error_code": "extension_not_connected",
        "url": candidate,
        "note": (
            "klo's Chrome extension isn't connected, so the page was opened "
            "in the user's DEFAULT browser instead (this open SUCCEEDED — "
            "the error_code field is only a UI hint for the Mac app). The "
            "user can see the page, but you CANNOT read, snapshot, click, "
            "or verify anything on it. Tell the user what you opened, answer "
            "only from information you actually have, and suggest connecting "
            "the klo Chrome extension for full web control. Do not claim you "
            "read this page."
        ),
    })


async def _web_dispatch(bridge_singleton: Any, action: str, params: dict[str, Any]) -> str:
    """Core action router. Each branch builds the right tabs.* RPC
    payload and shapes the response back into the legacy web_drive
    return contract so the agent prompts + downstream parsers don't
    need to change.
    """
    if action == "open":
        url = params.get("url")
        if not url:
            return json.dumps({"ok": False, "error": "url required"})
        # tabs.navigate updates the active tab to the URL; the extension
        # creates one if there's no active tab yet.
        nav = await bridge_singleton.call("tabs.navigate", {"url": url})
        # Best-effort settle + grounding excerpt. Match the old shape
        # (`target.url`/`target.title` + `text_excerpt`) the model knows.
        try:
            text_resp = await bridge_singleton.call(
                "tabs.read_text",
                {"max": 1200},
                timeout=10,
            )
            excerpt = text_resp.get("text", "") if isinstance(text_resp, dict) else ""
        except Exception:  # noqa: BLE001
            excerpt = ""
        out = {
            "ok": True,
            "target": {
                "url": (nav or {}).get("url") if isinstance(nav, dict) else None,
                "title": (nav or {}).get("title") if isinstance(nav, dict) else None,
            },
            "text_excerpt": excerpt,
        }
        return json.dumps(out, ensure_ascii=False)

    if action == "snapshot":
        snap = await bridge_singleton.call("tabs.dom_snapshot", params or {})
        # Canvas-content escape hatch: Google Docs/Sheets/Slides and Figma
        # render their content into a <canvas>, not the DOM, so the
        # snapshot returns toolbar buttons only. Without a typed signal
        # the model loops on web.snapshot / web.screenshot and never
        # makes progress. Attach a hint pointing at the clipboard recipe
        # (cmd+a → cmd+c → pbpaste) which works for any app with a
        # native copy handler.
        if isinstance(snap, dict):
            items = snap.get("items") or []
            url = ""
            try:
                cur = await bridge_singleton.call("tabs.active", {})
                if isinstance(cur, dict):
                    url = str(cur.get("url") or "")
            except Exception:  # noqa: BLE001
                pass
            host = ""
            try:
                from urllib.parse import urlparse
                host = (urlparse(url).hostname or "").lower()
            except Exception:  # noqa: BLE001
                pass
            is_canvas_host = (
                host.endswith("docs.google.com")
                or host.endswith("figma.com")
                or host.endswith("sheets.google.com")
                or host.endswith("slides.google.com")
            )
            if is_canvas_host and len(items) < 5:
                snap = dict(snap)
                snap["error_code"] = "canvas_content_not_exposed"
                snap["hint"] = (
                    "This page renders its content in a <canvas> — the DOM "
                    "snapshot only sees the toolbar. To read the document "
                    "text: focus the canvas area (one web.press into the "
                    "doc, or web.click(text='<a known phrase>')), then "
                    "computer key(text='cmd+a'), computer key(text='cmd+c'), "
                    "shell pbpaste. To read visually: web.screenshot(). "
                    "Do NOT loop on web.snapshot / web.text — the content "
                    "is not in the DOM."
                )
        return json.dumps(snap if isinstance(snap, dict) else {"ok": True, "result": snap}, ensure_ascii=False)

    if action == "press":
        idx = params.get("idx")
        if idx is None:
            return json.dumps({"ok": False, "error": "idx required"})
        rpc_params: dict[str, Any] = {"idx": idx}
        if "snapshot_id" in params and params["snapshot_id"] is not None:
            rpc_params["snapshot_id"] = params["snapshot_id"]
        result = await bridge_singleton.call("tabs.click_idx", rpc_params)
        out = result if isinstance(result, dict) else {"ok": True, "result": result}
        out["targeting_method"] = "web_extension"
        return json.dumps(out, ensure_ascii=False)

    if action == "fill":
        idx = params.get("idx")
        text = params.get("text")
        if idx is None or text is None:
            return json.dumps({"ok": False, "error": "idx and text required"})
        rpc_params = {"idx": idx, "text": text}
        for opt in ("submit", "clear_first", "snapshot_id"):
            if opt in params and params[opt] is not None:
                rpc_params[opt] = params[opt]
        result = await bridge_singleton.call("tabs.fill", rpc_params)
        return json.dumps(result if isinstance(result, dict) else {"ok": True, "result": result}, ensure_ascii=False)

    if action == "click":
        # Either CSS selector or visible-text click. The extension splits
        # these into two RPC paths.
        selector = params.get("selector")
        text = params.get("text")
        if text and not selector:
            result = await bridge_singleton.call("tabs.click_text", {"text": text, "nth": params.get("nth", 0)})
        elif selector:
            result = await bridge_singleton.call("tabs.click", {"selector": selector, "nth": params.get("nth", 0)})
        else:
            return json.dumps({"ok": False, "error": "selector or text required"})
        return json.dumps(result if isinstance(result, dict) else {"ok": True, "result": result}, ensure_ascii=False)

    if action == "type":
        selector = params.get("selector")
        text = params.get("text")
        if not selector or text is None:
            return json.dumps({"ok": False, "error": "selector and text required"})
        rpc_params = {"selector": selector, "text": text}
        for opt in ("submit", "clear_first"):
            if opt in params and params[opt] is not None:
                rpc_params[opt] = params[opt]
        result = await bridge_singleton.call("tabs.fill_text", rpc_params)
        return json.dumps(result if isinstance(result, dict) else {"ok": True, "result": result}, ensure_ascii=False)

    if action == "text":
        rpc_params = {"max": params.get("max", 4000)}
        if "selector" in params and params["selector"] is not None:
            rpc_params["selector"] = params["selector"]
        result = await bridge_singleton.call("tabs.read_text", rpc_params)
        return json.dumps(result if isinstance(result, dict) else {"ok": True, "text": str(result)}, ensure_ascii=False)

    if action == "evaluate":
        expression = params.get("expression")
        if not expression:
            return json.dumps({"ok": False, "error": "expression required"})
        result = await bridge_singleton.call("tabs.evaluate", {"expression": expression})
        return json.dumps(result if isinstance(result, dict) else {"ok": True, "value": result}, ensure_ascii=False)

    if action == "scroll":
        # Scroll the active tab. Three modes, matching tabs.scroll in the
        # extension:
        #   direction="bottom" or "top" — page extremes
        #   idx=N — scroll an indexed actionable element into view
        #   selector / text — scroll a CSS selector or text-matched
        #                     element into view
        # Use this BEFORE re-snapshotting on long pages — the snapshot
        # only includes elements within the rendered viewport scope, so
        # content below the fold won't appear in the index list until
        # you've scrolled it into view.
        rpc_params: dict[str, Any] = {}
        if "direction" in params and params["direction"] is not None:
            d = str(params["direction"]).lower()
            if d not in ("top", "bottom"):
                return json.dumps({"ok": False, "error": "direction must be 'top' or 'bottom'"})
            rpc_params["direction"] = d
        if "idx" in params and params["idx"] is not None:
            rpc_params["idx"] = int(params["idx"])
        if "selector" in params and params["selector"]:
            rpc_params["selector"] = str(params["selector"])
        if "text" in params and params["text"]:
            rpc_params["text"] = str(params["text"])
        if not rpc_params:
            return json.dumps({
                "ok": False,
                "error": "scroll requires one of: direction='top'|'bottom', idx=N, selector='...', text='...'",
            })
        result = await bridge_singleton.call("tabs.scroll", rpc_params)
        return json.dumps(result if isinstance(result, dict) else {"ok": True}, ensure_ascii=False)

    if action == "wait_for":
        selector = params.get("selector")
        if not selector:
            return json.dumps({"ok": False, "error": "selector required"})
        result = await bridge_singleton.call(
            "tabs.wait_for",
            {"selector": selector, "timeout": params.get("timeout", 10)},
            timeout=max(15, float(params.get("timeout", 10)) + 5),
        )
        return json.dumps(result if isinstance(result, dict) else {"ok": True}, ensure_ascii=False)

    if action == "wait_settled":
        # No direct bridge method — the extension's CDP path settles per
        # navigation. Approximate with a small polling loop on document
        # readyState via tabs.evaluate.
        timeout = float(params.get("timeout", 4.0))
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            try:
                resp = await bridge_singleton.call(
                    "tabs.evaluate",
                    {"expression": "document.readyState"},
                    timeout=3,
                )
                state = (resp or {}).get("value") if isinstance(resp, dict) else None
                if state == "complete":
                    return json.dumps({"ok": True, "settled": True})
            except Exception:  # noqa: BLE001
                pass
            await asyncio.sleep(0.4)
        return json.dumps({"ok": True, "settled": False, "note": "timed out"})

    if action == "screenshot":
        # Returns { ok, data (base64 png), media_type, width, height }.
        max_width = params.get("max_width", 1280)
        result = await bridge_singleton.call("tabs.screenshot", {"max_width": max_width})
        if isinstance(result, dict) and result.get("ok"):
            media_type = result.get("media_type", "image/png")
            b64 = result.get("data", "")
            out = {k: v for k, v in result.items() if k != "data"}
            out["data_url"] = f"data:{media_type};base64,{b64}"
            return json.dumps(out, ensure_ascii=False)
        return json.dumps(result if isinstance(result, dict) else {"ok": False}, ensure_ascii=False)

    if action == "url":
        result = await bridge_singleton.call("tabs.active", {})
        return json.dumps(result if isinstance(result, dict) else {"ok": True, "result": result}, ensure_ascii=False)

    if action == "autofill":
        # The user's real Chrome has its own autofill; klo doesn't need
        # to drive it. Return a friendly no-op so the model doesn't
        # trip over the missing handler.
        return json.dumps({
            "ok": True,
            "note": "Chrome handles autofill natively — ask the user to use their own password manager.",
        })

    if action == "wait_for_login":
        # Watch the URL until it leaves the login route. Polls active
        # tab URL until it changes or `timeout` elapses.
        timeout = float(params.get("timeout", 120))
        login_marker = (params.get("login_marker") or "login").lower()
        start_resp = await bridge_singleton.call("tabs.active", {})
        start_url = (start_resp or {}).get("url", "") if isinstance(start_resp, dict) else ""
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            try:
                cur = await bridge_singleton.call("tabs.active", {}, timeout=5)
                url = (cur or {}).get("url", "") if isinstance(cur, dict) else ""
                if url and url != start_url and login_marker not in url.lower():
                    return json.dumps({"ok": True, "url": url})
            except Exception:  # noqa: BLE001
                pass
            await asyncio.sleep(1.0)
        return json.dumps({"ok": False, "error": "wait_for_login timed out"})

    return json.dumps({"ok": False, "error": f"unknown web action: {action!r}"})


# ─── Python-side AX walker (2.1.3) ───────────────────────────────────────────
#
# Bypasses MacOps's frontmost-window requirement by walking the AX tree
# directly via pyobjc. The sidecar (codesigned) has Accessibility trust;
# we use it. Tree results live in a process-local cache keyed by
# snapshot_id so follow-up set_value / press calls can resolve back to
# the live AXUIElement reference without re-walking.

_AX_SNAPSHOTS: dict[str, dict[int, Any]] = {}
_AX_SNAPSHOT_TTL_S = 60.0  # snapshots stay valid for 1 minute
_AX_SNAPSHOT_META: dict[str, float] = {}  # snapshot_id → created_at


def _ax_snapshot_gc() -> None:
    """Evict snapshots older than TTL. Cheap — runs on every dump call."""
    import time as _time
    now = _time.monotonic()
    expired = [sid for sid, ts in _AX_SNAPSHOT_META.items() if now - ts > _AX_SNAPSHOT_TTL_S]
    for sid in expired:
        _AX_SNAPSHOTS.pop(sid, None)
        _AX_SNAPSHOT_META.pop(sid, None)


async def _ax_dump_tree(app_name: str, max_depth: int = 8, max_elements: int = 250) -> str:
    """Walk every window of `app_name` and return a flat numbered list of
    AX elements. The model picks which element to act on by index.

    Each element entry includes:
      - idx
      - role (AXButton, AXTextField, AXScrollArea, AXGroup, …)
      - subrole (where present)
      - label (AXTitle or AXDescription or AXValue snippet)
      - value (truncated to 80 chars)
      - editable (True if AXValue is settable)
      - focused (True if currently focused)
      - depth (nesting level under the window)
      - parent_idx (-1 for window roots)

    Returns JSON: {ok, snapshot_id, app, windows: [...], items: [...]}
    """
    try:
        import AppKit  # type: ignore
        import HIServices  # type: ignore
        from ApplicationServices import (  # type: ignore
            AXUIElementCreateApplication,
            AXUIElementCopyAttributeValue,
            AXUIElementCopyAttributeNames,
            AXUIElementIsAttributeSettable,
        )
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"ax_dump_tree import failed: {exc}"})

    if not HIServices.AXIsProcessTrusted():
        return json.dumps({
            "ok": False,
            "error": "Accessibility not granted to this process — bundled klo-sidecar should have it.",
        })

    # Find the running app by localizedName match. CRITICAL: filter to
    # activationPolicy == regular FIRST (NSApplicationActivationPolicyRegular = 0).
    # Without this, "Messages" matches both com.apple.MobileSMS (the real
    # app) AND com.apple.messages.AssistantExtension (a background XPC
    # helper with no windows). The extension would win on iteration order
    # → we'd return windows:[], items:[] and look broken.
    ws = AppKit.NSWorkspace.sharedWorkspace()
    target_app = None
    name_lower = app_name.lower()
    for app in ws.runningApplications():
        try:
            if app.activationPolicy() != 0:  # 0 = NSApplicationActivationPolicyRegular
                continue
        except Exception:  # noqa: BLE001
            continue
        name = str(app.localizedName() or "").strip()
        if name.lower() == name_lower:
            target_app = app
            break
    # Fallback: bundle-id contains the search string (handles "messages" →
    # com.apple.MobileSMS even though that doesn't appear in localizedName).
    if target_app is None:
        for app in ws.runningApplications():
            try:
                if app.activationPolicy() != 0:
                    continue
            except Exception:  # noqa: BLE001
                continue
            bid = str(app.bundleIdentifier() or "").lower()
            if name_lower in bid:
                target_app = app
                break
    if target_app is None:
        return json.dumps({"ok": False, "error": f"app not found: {app_name!r} (filtered to regular apps)"})

    # Activate (brief) so windows are reachable. Some apps' AX trees only
    # populate after activation; activating costs ~50ms of focus flicker
    # but is necessary for first-walk reliability.
    try:
        target_app.activateWithOptions_(0)  # NSApplicationActivateIgnoringOtherApps = 0
        import asyncio as _aio
        await _aio.sleep(0.15)  # let AX tree settle
    except Exception:  # noqa: BLE001
        pass

    pid = int(target_app.processIdentifier())
    ax_app = AXUIElementCreateApplication(pid)

    def _get(elem: Any, attr: str) -> Any:
        try:
            err, val = AXUIElementCopyAttributeValue(elem, attr, None)
            if err != 0:
                return None
            return val
        except Exception:  # noqa: BLE001
            return None

    def _settable(elem: Any, attr: str) -> bool:
        try:
            err, val = AXUIElementIsAttributeSettable(elem, attr, None)
            return err == 0 and bool(val)
        except Exception:  # noqa: BLE001
            return False

    # Walk: BFS-ish — each window root + all descendants up to max_depth.
    items: list[dict[str, Any]] = []
    elem_cache: dict[int, Any] = {}  # idx → live element
    windows_summary: list[dict[str, Any]] = []

    windows = _get(ax_app, "AXWindows") or []
    for w_idx, window in enumerate(windows):
        w_title = _get(window, "AXTitle") or ""
        w_main = bool(_get(window, "AXMain"))
        w_minimized = bool(_get(window, "AXMinimized"))
        if w_minimized:
            continue

        # Walk recursively
        stack: list[tuple[Any, int, int]] = [(window, 0, -1)]  # (elem, depth, parent_idx)
        while stack and len(items) < max_elements:
            elem, depth, parent_idx = stack.pop(0)
            if depth > max_depth:
                continue
            role = _get(elem, "AXRole") or "?"
            sub = _get(elem, "AXSubrole")
            label = (_get(elem, "AXTitle")
                     or _get(elem, "AXDescription")
                     or _get(elem, "AXPlaceholderValue")
                     or "")
            raw_value = _get(elem, "AXValue")
            value_str = ""
            if raw_value is not None:
                try:
                    value_str = str(raw_value)[:80]
                except Exception:  # noqa: BLE001
                    value_str = ""
            editable = _settable(elem, "AXValue")
            focused = bool(_get(elem, "AXFocused"))
            idx = len(items)
            elem_cache[idx] = elem
            items.append({
                "idx": idx,
                "role": str(role),
                "sub": str(sub) if sub else None,
                "label": str(label)[:80],
                "value": value_str,
                "editable": editable,
                "focused": focused,
                "depth": depth,
                "parent_idx": parent_idx,
                "window_idx": w_idx,
            })
            # Children
            children = _get(elem, "AXChildren") or []
            for child in children:
                stack.append((child, depth + 1, idx))

        windows_summary.append({
            "window_idx": w_idx,
            "title": str(w_title),
            "main": w_main,
        })

    # Cache the snapshot
    import time as _time
    snapshot_id = f"ax{int(_time.time()*1000)}"
    _AX_SNAPSHOTS[snapshot_id] = elem_cache
    _AX_SNAPSHOT_META[snapshot_id] = _time.monotonic()
    _ax_snapshot_gc()

    return json.dumps({
        "ok": True,
        "snapshot_id": snapshot_id,
        "app": str(target_app.localizedName() or app_name),
        "bundle_id": str(target_app.bundleIdentifier() or ""),
        "windows": windows_summary,
        "items": items,
        "tip": (
            "Pick the item whose role+label matches what you want to type into "
            "(typically AXTextArea / AXTextField / AXComboBox, or anything with "
            "editable=true). Then call accessibility.ax_set_value with "
            f"snapshot_id='{snapshot_id}' and idx=N."
        ),
    }, ensure_ascii=False)


async def _ax_set_value_on_indexed(snapshot_id: str, idx: int, value: str) -> str:
    """Set AXValue on the element at `idx` in the cached snapshot. The
    target app gets brief focus first (some apps reject AXValueSet when
    they're not focused)."""
    try:
        from ApplicationServices import AXUIElementSetAttributeValue  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"ax_set_value import failed: {exc}"})
    cache = _AX_SNAPSHOTS.get(snapshot_id)
    if cache is None:
        return json.dumps({"ok": False, "error": "snapshot expired or unknown — call ax_dump_tree again"})
    elem = cache.get(idx)
    if elem is None:
        return json.dumps({"ok": False, "error": f"idx {idx} not in snapshot"})
    try:
        err = AXUIElementSetAttributeValue(elem, "AXValue", value)
        if err != 0:
            return json.dumps({"ok": False, "error": f"AXUIElementSetAttributeValue returned err={err}"})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"set raised: {exc}"})
    return json.dumps({"ok": True, "method": "ax_set_value", "idx": idx, "snapshot_id": snapshot_id})


async def _ax_press_on_indexed(snapshot_id: str, idx: int) -> str:
    """Perform AXPress on the element at `idx`."""
    try:
        from ApplicationServices import AXUIElementPerformAction  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"ax_press import failed: {exc}"})
    cache = _AX_SNAPSHOTS.get(snapshot_id)
    if cache is None:
        return json.dumps({"ok": False, "error": "snapshot expired or unknown"})
    elem = cache.get(idx)
    if elem is None:
        return json.dumps({"ok": False, "error": f"idx {idx} not in snapshot"})
    try:
        err = AXUIElementPerformAction(elem, "AXPress")
        if err != 0:
            return json.dumps({"ok": False, "error": f"AXUIElementPerformAction err={err}"})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"press raised: {exc}"})
    return json.dumps({"ok": True, "method": "ax_press", "idx": idx, "snapshot_id": snapshot_id})


async def _tool_accessibility(**kwargs: Any) -> str:
    """Delegate to the upgraded AccessibilityExecutor in api.core.

    This is the precedence-1 native-app surface: indexed AX targeting +
    menu walking. Beats `computer` for every action that AX can express
    (which is most non-canvas controls) because it acts by element
    identity, not by screen coordinates.

    BUT: refuses if klo's embedded web pane is the active surface. The
    AX walker reads the user's frontmost app (Cursor, Safari, whatever)
    — it CANNOT see inside klo's WKWebView (different process boundary
    inside the panel). When the model calls accessibility.* in web mode
    it always returns the wrong app's tree. Return a typed redirect so
    the model fixes the next call instead of debugging the tree it got.
    """
    if await _web_pane_active():
        return json.dumps({
            "ok": False,
            "error": (
                "klo's embedded web pane is active. The accessibility tool "
                "reads the user's frontmost app, NOT klo's WKWebView — using "
                "it here always returns the wrong app's tree. Use web.* "
                "tools for everything inside the web pane: web.screenshot "
                "for visual grounding, web.click for trusted clicks, "
                "web.text for content reads, web.evaluate for custom JS."
            ),
            "redirect_to": "web",
        })

    action = kwargs.get("action")

    # NEW (2.1.3): Python-side AX walker that returns the FULL recursive
    # tree of every window of an app, flat-numbered. Bypasses MacOps
    # entirely (no frontmost-window requirement, no coordinate scaling).
    # Pairs with `ax_set_value` to type into ANY element the model picks.
    # Use case: "type X in chat with emily" → inventory picks Messages →
    # model calls ax_dump_tree(app_name='Messages') → sees every element
    # in the window (AXGroup, AXScrollArea, AXTextArea, AXButton, etc.)
    # with editable/focused flags → calls ax_set_value with the index of
    # whatever's actually editable. Model reasons instead of klo guessing.
    if action == "ax_dump_tree":
        app_name = (kwargs.get("app_name") or "").strip()
        if not app_name:
            return json.dumps({"ok": False, "error": "ax_dump_tree requires app_name"})
        max_depth = int(kwargs.get("max_depth", 8))
        max_elements = int(kwargs.get("max_elements", 250))
        return await _ax_dump_tree(app_name, max_depth=max_depth, max_elements=max_elements)
    if action == "ax_set_value":
        snapshot_id = (kwargs.get("snapshot_id") or "").strip()
        idx = kwargs.get("idx")
        value = kwargs.get("value")
        if not snapshot_id:
            return json.dumps({"ok": False, "error": "ax_set_value requires snapshot_id from a prior ax_dump_tree"})
        if idx is None:
            return json.dumps({"ok": False, "error": "ax_set_value requires idx"})
        if value is None:
            return json.dumps({"ok": False, "error": "ax_set_value requires value"})
        return await _ax_set_value_on_indexed(snapshot_id, int(idx), str(value))
    if action == "ax_press":
        snapshot_id = (kwargs.get("snapshot_id") or "").strip()
        idx = kwargs.get("idx")
        if not snapshot_id or idx is None:
            return json.dumps({"ok": False, "error": "ax_press requires snapshot_id + idx"})
        return await _ax_press_on_indexed(snapshot_id, int(idx))

    # cua-driver AX path: identity-cached AXUIElement handles per
    # (pid, window_id). Routes via MacOps HTTP at 127.0.0.1:8788.
    if action in ("window_state", "press_indexed", "set_value_indexed"):
        import httpx
        body: dict[str, Any] = {}
        if kwargs.get("app_name"):
            body["app_name"] = kwargs["app_name"]
        if kwargs.get("window_id") is not None:
            body["window_id"] = int(kwargs["window_id"])
        if action == "window_state":
            path = "/v1/ax/window_state"
            # Default to SOM (numbered overlays on the screenshot) when
            # the caller didn't specify — matches the schema's `default`
            # and Hermes' canonical capture mode. The model can opt down
            # to `mode='text'` for follow-up reads on a known layout.
            mode = (kwargs.get("mode") or "som")
            if mode not in ("som", "text"):
                mode = "som"
            body["mode"] = mode
            if kwargs.get("max_elements") is not None:
                body["max_elements"] = int(kwargs["max_elements"])
        elif action == "press_indexed":
            path = "/v1/ax/click_element"
            if kwargs.get("element_index") is None:
                return json.dumps({"ok": False, "error": "press_indexed requires element_index"})
            body["element_index"] = int(kwargs["element_index"])
            if kwargs.get("ax_action"):
                body["action"] = kwargs["ax_action"]
        else:  # set_value_indexed
            path = "/v1/ax/set_value"
            if kwargs.get("element_index") is None:
                return json.dumps({"ok": False, "error": "set_value_indexed requires element_index"})
            if kwargs.get("value") is None:
                return json.dumps({"ok": False, "error": "set_value_indexed requires value"})
            body["element_index"] = int(kwargs["element_index"])
            body["value"] = str(kwargs["value"])
            if kwargs.get("ax_attribute"):
                body["attribute"] = kwargs["ax_attribute"]
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                resp = await client.post(f"http://127.0.0.1:8788{path}", json=body)
        except httpx.HTTPError as e:
            return json.dumps({"ok": False, "error": f"mac_ops unreachable: {e}"})

        # TRANSPARENT FALLBACK (2.1.3): when MacOps's window_state /
        # press_indexed / set_value_indexed fails with "no frontmost
        # window" — which happens whenever klo's panel grabs focus from
        # the target app — automatically retry via the Python AX walker.
        # The Python path (ax_dump_tree / ax_set_value) bypasses MacOps's
        # frontmost requirement entirely; it walks via NSRunningApplication
        # → AXUIElementCreateApplication directly. Model never needs to
        # learn a new action.
        try:
            _peek = resp.json() if resp.status_code == 200 else {}
        except Exception:  # noqa: BLE001
            _peek = {}
        if isinstance(_peek, dict) and (
            "no frontmost window" in str(_peek.get("error") or "").lower()
            or "frontmost" in str(_peek.get("error") or "").lower()
        ):
            app_name = body.get("app_name") or ""
            if action == "window_state" and app_name:
                # Re-dump via Python AX walker (cached for follow-up
                # press_indexed / set_value_indexed calls).
                py_result = await _ax_dump_tree(app_name, max_depth=8, max_elements=250)
                return py_result
            if action in ("press_indexed", "set_value_indexed") and app_name:
                # No cached element from previous window_state. Re-walk
                # via Python so we can act on the index.
                py_result = await _ax_dump_tree(app_name, max_depth=8, max_elements=250)
                try:
                    py = json.loads(py_result)
                except Exception:  # noqa: BLE001
                    py = {}
                snap = py.get("snapshot_id")
                idx = body.get("element_index")
                if snap and idx is not None:
                    if action == "press_indexed":
                        return await _ax_press_on_indexed(snap, int(idx))
                    if action == "set_value_indexed":
                        return await _ax_set_value_on_indexed(snap, int(idx), str(body.get("value", "")))
                return py_result

        # For mode=som, lift base64_png into a data_url field so the
        # agent loop's _split_tool_output() will attach it as a real
        # multimodal image block to the model. Without this the PNG
        # sits as inert JSON text and the model can't actually see it.
        if action == "window_state" and body.get("mode") == "som":
            try:
                parsed = resp.json()
                b64 = parsed.pop("base64_png", None)
                if b64:
                    parsed["data_url"] = f"data:image/png;base64,{b64}"
                parsed["targeting_method"] = "accessibility"
                return json.dumps(parsed, ensure_ascii=False)
            except Exception:
                return resp.text
        # Tag all AX paths with targeting_method so the Mac app can
        # tint the wisp / fire indicator accordingly. The model also
        # benefits from the signal: a chain of accessibility.press_indexed
        # calls implicitly reports "I'm in the high-trust path."
        try:
            parsed = resp.json()
            if isinstance(parsed, dict):
                parsed["targeting_method"] = "accessibility"
                return json.dumps(parsed, ensure_ascii=False)
        except Exception:  # noqa: BLE001
            pass
        return resp.text

    from api.core.accessibility import AccessibilityExecutor
    executor = AccessibilityExecutor()
    return await executor.execute(kwargs)


_WEB_PANE_PROBE_CACHE: dict[str, Any] = {"ts": 0.0, "active": False}


async def _web_pane_active() -> bool:
    """Cheap probe: is klo's embedded WKWebView currently displaying a
    real page (not about:blank)? Caches the answer for 500ms so back-
    to-back AX calls don't each pay the HTTP roundtrip.

    Implementation: POST /v1/web/url and check for a non-blank URL.
    The Mac app returns ok=true with url=null if the WKWebView was
    never navigated (klo started, web pane never opened).
    """
    import time as _time
    import httpx
    now = _time.monotonic()
    if now - _WEB_PANE_PROBE_CACHE["ts"] < 0.5:
        return bool(_WEB_PANE_PROBE_CACHE["active"])
    active = False
    try:
        async with httpx.AsyncClient(timeout=0.5) as client:
            resp = await client.post("http://127.0.0.1:8788/v1/web/url", json={})
        if resp.status_code == 200:
            data = resp.json()
            url = data.get("url") or ""
            # about:blank / empty / null all mean "no real page yet"
            active = bool(url) and url != "about:blank"
    except Exception:
        active = False
    _WEB_PANE_PROBE_CACHE["ts"] = now
    _WEB_PANE_PROBE_CACHE["active"] = active
    return active


async def _tool_composio_list_actions(toolkit: str) -> str:
    """Proxy to klo-cloud's /api/integrations/composio/list_actions.

    Sidecar-side handler for the `composio_list_actions` tool. We never
    talk to Composio directly from the sidecar — the API key lives only
    on klo-cloud, so all per-user dispatch routes through the cloud
    proxy with the user's Supabase JWT as the bearer.
    """
    import httpx
    from .cloud_auth import KLO_CLOUD_URL, SIDECAR_UA, require_session_token, NotSignedIn
    try:
        token = require_session_token()
    except NotSignedIn as exc:
        return json.dumps({"ok": False, "error": "not_signed_in", "message": str(exc)})
    url = f"{KLO_CLOUD_URL}/api/integrations/composio/list_actions"
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                url,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                    "User-Agent": SIDECAR_UA,
                },
                json={"toolkit": toolkit},
            )
    except httpx.HTTPError as exc:
        return json.dumps({"ok": False, "error": "network", "message": str(exc)})
    if resp.status_code == 402:
        return json.dumps({
            "ok": False,
            "error": "subscription_required",
            "message": "Composio integrations are a Pro feature. Open Settings to subscribe.",
        })
    if resp.status_code >= 400:
        try:
            err = resp.json()
        except Exception:
            err = {"raw": resp.text[:400]}
        return json.dumps({"ok": False, "error": "upstream", "status": resp.status_code, "detail": err})
    return resp.text


# klo 2.1 Track D — scheduled-run pre-auth gate.
#
# When the agent is running INSIDE a scheduled routine (state.source
# starts with "scheduled"), every composio_execute call goes through
# an allowlist check against `state.allowed_actions`. Anything outside
# the allowlist DRAFTS the action — the model gets a "drafted" tool
# result it should mention to the user, and the actual side-effect
# (sending the email / posting the message / etc) does NOT happen.
#
# Allowlist entry shape:
#   {"toolkit": "gmail", "action": "send_email", "to": ["alice@x.com"]}
#   {"toolkit": "slack", "action": "post_message", "channels": ["#my-team"]}
#   {"toolkit": "googlecalendar", "action": "create_event"}      # unconstrained
#
# Constraint matching is per-toolkit:
#   - gmail send_email: params["to"] (str or list) must be a subset of
#     the allowlist entry's "to" list
#   - slack post_message: params["channel"] must be in entry's "channels"
#   - everything else: entry without a constraint key means "allowed
#     unconditionally for this (toolkit, action) pair"
#
# Defaults to ALLOW for non-scheduled runs so user-driven interactive
# work isn't affected.

_SCHEDULED_RUN_SOURCES = {"scheduled", "scheduled_routine", "scheduled_preview"}


def _composio_action_allowed(
    toolkit: str,
    action: str,
    params: dict[str, Any],
    allowed_actions: list[dict[str, Any]],
) -> tuple[bool, str | None]:
    """Returns (allowed, denial_reason). denial_reason is None on
    allow, otherwise a one-line user-facing string explaining why
    this action was drafted instead of executed."""
    tk = (toolkit or "").lower().strip()
    act = (action or "").lower().strip()
    matching_entries = [
        e for e in (allowed_actions or [])
        if (e.get("toolkit") or "").lower() == tk
        and (e.get("action") or "").lower() == act
    ]
    if not matching_entries:
        return False, f"this routine isn't authorized to run {tk}/{act}"

    # Check constraints — if ANY matching entry permits it, allow.
    for entry in matching_entries:
        if tk == "gmail" and act == "send_email":
            allowed_to = [a.lower() for a in (entry.get("to") or [])]
            if not allowed_to:
                return True, None       # unconstrained = any recipient ok
            requested = params.get("to") or params.get("recipient_email") or params.get("recipients")
            if isinstance(requested, str):
                requested_list = [requested]
            elif isinstance(requested, list):
                requested_list = [str(x) for x in requested]
            else:
                requested_list = []
            requested_lower = [r.lower() for r in requested_list]
            if requested_lower and all(r in allowed_to for r in requested_lower):
                return True, None
            return False, (
                f"this routine can email {', '.join(allowed_to) or 'no one'} "
                f"but tried to email {', '.join(requested_list) or '(unknown)'}"
            )
        if tk == "slack" and act in ("post_message", "send_message"):
            allowed_ch = [c.lower() for c in (entry.get("channels") or [])]
            if not allowed_ch:
                return True, None
            requested = params.get("channel") or params.get("channel_id") or ""
            if str(requested).lower() in allowed_ch:
                return True, None
            return False, (
                f"this routine can post to {', '.join(allowed_ch) or 'no channel'} "
                f"but tried to post to {requested or '(unknown)'}"
            )
        # Unconstrained entry for any other toolkit/action pair.
        return True, None
    return False, "no matching allowlist entry"


def _draft_composio_action(
    toolkit: str,
    action: str,
    params: dict[str, Any],
    reason: str | None,
) -> str:
    """The response the model gets when an action is drafted instead
    of executed. The model should include this in its final message
    so the user sees what klo wanted to do + why it didn't happen.
    The cloud's stitched-summary path will surface this in chat."""
    # Pull a short human summary of the params so the user can see
    # what the proposed action looked like at a glance.
    summary_bits = []
    for key in ("to", "recipient_email", "channel", "subject", "title", "body", "text", "message"):
        if key in params and params[key]:
            val = params[key]
            if isinstance(val, str) and len(val) > 200:
                val = val[:200] + "…"
            summary_bits.append(f"{key}: {val}")
    summary_blob = " | ".join(summary_bits) if summary_bits else "(no params summary)"
    return json.dumps({
        "ok": False,
        "drafted": True,
        "reason": reason or "not in routine allowlist",
        "toolkit": toolkit,
        "action": action,
        "params_summary": summary_blob,
        "_assistant_hint": (
            "This action was NOT executed because this scheduled routine "
            "doesn't have pre-authorization for it. In your final reply, "
            "mention that klo drafted this action and the user needs to "
            "either approve it manually or open Settings → Schedules to "
            "expand what this routine can do. Do NOT retry the action; "
            "the user must explicitly authorize first. Include the "
            "params_summary above so they can see what was drafted."
        ),
    })


async def _tool_composio_execute(toolkit: str, action: str, params: dict[str, Any]) -> str:
    """Proxy to klo-cloud's /api/integrations/composio/execute.

    Same JWT-bearer pattern as list_actions. Tool-result truncation is
    enforced server-side so a runaway action ('list_all_threads') can't
    burn the model's context window.

    klo 2.1 Track D: when running inside a scheduled routine, the
    (toolkit, action, params) tuple is gated against the routine's
    pre-authorization allowlist. Unauthorized actions are drafted
    (returned as a structured 'drafted' response) rather than
    executed. Interactive user-driven runs are unaffected.
    """
    # Scheduled-run pre-auth gate. Reads the current run's state via
    # the ContextVar set by desktop_api._run_agent. If we're inside a
    # scheduled routine and this action isn't in the allowlist, draft
    # the action and return without making the upstream call.
    try:
        from .run_context import current_run_state
        rs = current_run_state()
    except Exception:  # noqa: BLE001
        rs = None
    if rs is not None:
        src = (getattr(rs, "source", None) or "").lower()
        if src in _SCHEDULED_RUN_SOURCES:
            allowed = getattr(rs, "allowed_actions", []) or []
            ok, denial = _composio_action_allowed(toolkit, action, params or {}, allowed)
            if not ok:
                return _draft_composio_action(toolkit, action, params or {}, denial)

    import httpx
    from .cloud_auth import KLO_CLOUD_URL, SIDECAR_UA, require_session_token, NotSignedIn
    try:
        token = require_session_token()
    except NotSignedIn as exc:
        return json.dumps({"ok": False, "error": "not_signed_in", "message": str(exc)})
    url = f"{KLO_CLOUD_URL}/api/integrations/composio/execute"
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(
                url,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                    "User-Agent": SIDECAR_UA,
                },
                json={"toolkit": toolkit, "action": action, "params": params or {}},
            )
    except httpx.HTTPError as exc:
        return json.dumps({"ok": False, "error": "network", "message": str(exc)})
    if resp.status_code == 402:
        return json.dumps({
            "ok": False,
            "error": "subscription_required",
            "message": "Composio integrations are a Pro feature. Open Settings to subscribe.",
        })
    if resp.status_code >= 400:
        try:
            err = resp.json()
        except Exception:
            err = {"raw": resp.text[:400]}
        return json.dumps({"ok": False, "error": "upstream", "status": resp.status_code, "detail": err})
    return resp.text


async def _tool_delegate_task(tasks: list[dict[str, Any]]) -> str:
    """Spawn child agents in parallel via asyncio.gather. Each child
    gets a hard-blocked tool set (no memory writes, no further
    delegation, no scheduling, no user-handoff). Parent receives a
    JSON array of {prompt, summary, worker_kind} for each subtask.

    worker_kind picks the child's model + turn budget:
      - 'quick'    (default): Haiku, 6 turns. The original short-Composio-fetch pattern.
      - 'research': Sonnet, 20 turns. Multi-page social listening, deeper web crawls.
      - 'deep':    Sonnet, 40 turns. Heavy synthesis, multi-source consolidation.

    If a campaign workspace is bound to the parent run, children
    automatically inherit it via ContextVar — no extra wiring needed.
    """
    import asyncio
    from .agent import Agent, _MODEL_HAIKU, _MODEL_SONNET

    if not isinstance(tasks, list) or not tasks:
        return json.dumps({"ok": False, "error": "tasks must be a non-empty array"})
    if len(tasks) > 4:
        return json.dumps({"ok": False, "error": "max 4 parallel subtasks"})

    # Hard blocklist — children can't escape into shared state, recurse,
    # or contact the user behind the parent's back. workspace_write is
    # blocked too: only Strategist owns campaign.md / plan.md. Children
    # CAN call workspace_read and workspace_save_evidence — that's how
    # they pass findings back without bloating their summary string.
    CHILD_BLOCKED = {
        "memory_remember", "memory_forget",
        "delegate_task", "schedule_task",
        "handoff_to_user", "request_permission",
        "workspace_write",
    }

    # worker_kind → (model, max_turns). Defaults to quick to preserve
    # backwards-compatible behavior for callers that don't set it.
    _KINDS = {
        "quick":    (_MODEL_HAIKU, 6),
        "research": (_MODEL_SONNET, 20),
        "deep":     (_MODEL_SONNET, 40),
    }

    async def _run_child(spec: dict[str, Any]) -> dict[str, Any]:
        prompt = (spec.get("prompt") or "").strip()
        if not prompt:
            return {"prompt": "", "summary": "(empty prompt; skipped)", "worker_kind": "quick"}
        scope = spec.get("scoped_service")
        kind = (spec.get("worker_kind") or "quick").strip().lower()
        model, max_turns = _KINDS.get(kind, _KINDS["quick"])

        notes_parts: list[str] = []
        if isinstance(scope, str) and scope.strip():
            notes_parts.append(
                f"SCOPED TO COMPOSIO TOOLKIT: /{scope.strip().lower()} — "
                f"prefer composio_execute against this toolkit before reaching for "
                f"the broader tool set."
            )
        # If a workspace is bound to the parent, surface it to the child
        # explicitly. The ContextVar propagates automatically, but the
        # child needs to KNOW it's in a workspace to use the tools.
        from .workspace import current_workspace
        ws = current_workspace()
        if ws is not None:
            notes_parts.append(
                f"WORKSPACE: '{ws.slug}'. You're a child agent inside a long-horizon "
                f"initiative. Call `workspace_read(name='brief')` to see what the "
                f"user originally asked for, and `workspace_read(name='plan')` to "
                f"see the current plan. Save dense findings via "
                f"`workspace_save_evidence(name='...', content='...')` rather than "
                f"stuffing them into your return summary — your summary should be a "
                f"tight distillation, not the raw dump."
            )
        extra_notes = ("\n\n" + "\n\n".join(notes_parts)) if notes_parts else None

        child = Agent(
            model=model,
            max_turns=max_turns,
            verbose=False,
            disabled_tools=CHILD_BLOCKED,
        )
        try:
            result = await child.run(prompt, extra_system_notes=extra_notes)
            summary = (result.final or "").strip() or "(no answer)"
        except Exception as exc:  # noqa: BLE001
            summary = f"(child error: {exc})"
        return {"prompt": prompt, "summary": summary, "worker_kind": kind}

    results = await asyncio.gather(*[_run_child(t) for t in tasks], return_exceptions=False)
    return json.dumps({"ok": True, "results": results})


def _local_iana_timezone() -> str | None:
    """Best-effort IANA timezone identifier for the user's Mac.

    macOS keeps the active zoneinfo file as a symlink at
    /var/db/timezone/zoneinfo → /usr/share/zoneinfo/<Region>/<City>.
    Reading the symlink target gives us the canonical IANA name
    ("America/Los_Angeles", "Europe/London") without any new deps.

    Returns None on non-macOS or if the symlink isn't readable.
    klo-cloud falls back to UTC for the cron parser in that case.
    """
    try:
        import os
        target = os.readlink("/var/db/timezone/zoneinfo")
    except (OSError, AttributeError):
        try:
            import os
            target = os.readlink("/etc/localtime")
        except (OSError, AttributeError):
            return None
    parts = target.split("/zoneinfo/", 1)
    if len(parts) == 2:
        return parts[1]
    return None


async def _tool_schedule_task(user_phrase: str, prompt: str, scoped_service: str | None = None) -> str:
    """Proxy to klo-cloud's `/pending_schedules` POST.

    klo 2.0.0: when the model decides to schedule something from
    natural-language prose, the schedule does NOT go live immediately.
    It lands in `pending_schedules` and the cloud pushes a
    `pending_schedule_created` frame to the user's Mac. The notch
    surfaces a confirm card; only after the user taps Confirm does
    the row promote into the active scheduled_tasks table.

    This keeps the "always-confirm for indirect creates" trust
    guarantee — the user is never surprised by silent background
    scheduling.

    Returns a success payload telling the model that the schedule was
    DRAFTED (not activated). The model's reply to the user should
    reflect that: "I drafted a schedule, check the notch to confirm."
    """
    import httpx
    from .cloud_auth import KLO_CLOUD_URL, SIDECAR_UA, require_session_token, NotSignedIn
    try:
        token = require_session_token()
    except NotSignedIn as exc:
        return json.dumps({"ok": False, "error": "not_signed_in", "message": str(exc)})
    url = f"{KLO_CLOUD_URL}/pending_schedules"
    body: dict[str, Any] = {
        "user_phrase": user_phrase,
        "prompt": prompt,
        "kind": "single",
        "created_via": "agent_tool",
    }
    if scoped_service:
        body["scoped_service"] = scoped_service.strip().lower()
    # Wall-clock cadence ("at 9am", "weekdays at 8") gets interpreted
    # in the user's local timezone. Read it from the Mac's tzdb
    # symlink — Apple keeps the IANA identifier at /var/db/timezone.
    tz_name = _local_iana_timezone()
    if tz_name:
        body["tz_name"] = tz_name
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(
                url,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                    "User-Agent": SIDECAR_UA,
                },
                json=body,
            )
    except httpx.HTTPError as exc:
        return json.dumps({"ok": False, "error": "network", "message": str(exc)})
    if resp.status_code >= 400:
        try:
            err = resp.json()
        except Exception:
            err = {"raw": resp.text[:400]}
        return json.dumps({"ok": False, "error": "upstream", "status": resp.status_code, "detail": err})
    # Hint to the model that this is drafted-and-waiting, not active —
    # so its chat reply to the user matches the notch behavior.
    try:
        out = resp.json()
        return json.dumps({
            "ok": True,
            "drafted": True,
            "needs_confirmation": True,
            "pending_schedule": out,
            "_assistant_hint": (
                "Tell the user you drafted a schedule and they need to "
                "tap Confirm on the notch card to activate it. Do NOT "
                "claim the schedule is already running."
            ),
        })
    except Exception:
        return resp.text


# ─── Workspace tool handlers ──────────────────────────────────────────
#
# Long-horizon workspace primitives. Domain-neutral by design — klo
# decides what each workspace is for. The ContextVar binding propagates
# the active workspace to delegate_task children automatically.

NO_WORKSPACE_ERROR = (
    "no workspace bound to this run. call workspace_init first to start "
    "an initiative, or workspace_load to resume an existing one."
)


def _require_workspace() -> Any:
    from .workspace import current_workspace
    return current_workspace()


async def _tool_workspace_init(name: str, brief: str) -> str:
    from . import workspace as ws_mod
    name = (name or "").strip()
    brief = (brief or "").strip()
    if not name:
        return json.dumps({"ok": False, "error": "name required"})
    if not brief:
        return json.dumps({"ok": False, "error": "brief required"})
    try:
        ws = ws_mod.init(brief=brief, name=name)
        # Bind for the rest of this run. The token is intentionally not
        # tracked — the run's task wrapper resets workspace state on exit
        # via _RunState's finally block (desktop_api path) or the run
        # naturally ends (CLI path).
        ws_mod.set_current_workspace(ws)
        return json.dumps({
            "ok": True,
            "slug": ws.slug,
            "root": str(ws.root),
            "brief_path": str(ws.brief_path),
            "plan_path": str(ws.plan_path),
            "log_path": str(ws.log_path),
        })
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_load(slug: str) -> str:
    from . import workspace as ws_mod
    slug = (slug or "").strip()
    if not slug:
        return json.dumps({"ok": False, "error": "slug required"})
    try:
        ws = ws_mod.load(slug)
        ws_mod.set_current_workspace(ws)
        return json.dumps({
            "ok": True,
            "slug": ws.slug,
            "brief": ws.brief,
            "created_at": ws.created_at,
            "root": str(ws.root),
        })
    except FileNotFoundError:
        return json.dumps({"ok": False, "error": f"no workspace named {slug!r}"})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_list() -> str:
    from . import workspace as ws_mod
    try:
        workspaces = [
            {"slug": w.slug, "brief": w.brief, "created_at": w.created_at}
            for w in ws_mod.list_all()
        ]
        return json.dumps({"ok": True, "workspaces": workspaces})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_read(name: str, limit: int | None = None) -> str:
    ws = _require_workspace()
    if ws is None:
        return json.dumps({"ok": False, "error": NO_WORKSPACE_ERROR})
    try:
        if name == "brief":
            return json.dumps({"ok": True, "name": "brief", "content": ws.read_brief()})
        if name == "plan":
            return json.dumps({"ok": True, "name": "plan", "content": ws.read_plan()})
        if name == "log":
            return json.dumps({"ok": True, "name": "log", "content": ws.read_log()})
        if name == "decisions":
            return json.dumps({"ok": True, "name": "decisions", "content": ws.read_decisions()})
        if name == "recent":
            events = ws.recent_events(limit=limit or 30)
            return json.dumps({"ok": True, "name": "recent", "events": events})
        return json.dumps({"ok": False, "error": f"unknown workspace name: {name!r}"})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_write(name: str, content: str) -> str:
    ws = _require_workspace()
    if ws is None:
        return json.dumps({"ok": False, "error": NO_WORKSPACE_ERROR})
    if name not in ("brief", "plan"):
        return json.dumps({"ok": False, "error": f"workspace_write only accepts 'brief' or 'plan', got {name!r}"})
    content = (content or "").strip()
    if not content:
        return json.dumps({"ok": False, "error": "content required"})
    try:
        if name == "brief":
            ws.write_brief(content)
            return json.dumps({"ok": True, "name": "brief", "path": str(ws.brief_path), "chars": len(content)})
        ws.write_plan(content)
        return json.dumps({"ok": True, "name": "plan", "path": str(ws.plan_path), "chars": len(content)})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_append_log(message: str) -> str:
    ws = _require_workspace()
    if ws is None:
        return json.dumps({"ok": False, "error": NO_WORKSPACE_ERROR})
    message = (message or "").strip()
    if not message:
        return json.dumps({"ok": False, "error": "message required"})
    try:
        ws.append_log(message)
        return json.dumps({"ok": True, "appended": message[:200]})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_append_decision(text: str) -> str:
    ws = _require_workspace()
    if ws is None:
        return json.dumps({"ok": False, "error": NO_WORKSPACE_ERROR})
    text = (text or "").strip()
    if not text:
        return json.dumps({"ok": False, "error": "text required"})
    try:
        ws.add_decision(text)
        return json.dumps({"ok": True, "appended": text[:200]})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_save_evidence(name: str, content: str) -> str:
    ws = _require_workspace()
    if ws is None:
        return json.dumps({"ok": False, "error": NO_WORKSPACE_ERROR})
    name = (name or "").strip()
    if not name or "/" in name or ".." in name:
        return json.dumps({"ok": False, "error": "name must be a plain filename"})
    try:
        path = ws.write_evidence(name, content or "")
        return json.dumps({"ok": True, "path": str(path), "bytes": len(content or "")})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_request_human(reason: str, ask: str, payload: dict[str, Any] | None = None) -> str:
    ws = _require_workspace()
    if ws is None:
        return json.dumps({"ok": False, "error": NO_WORKSPACE_ERROR})
    reason = (reason or "").strip()
    ask = (ask or "").strip()
    if not reason or not ask:
        return json.dumps({"ok": False, "error": "reason and ask required"})
    try:
        cid = ws.add_pending(reason=reason, ask=ask, payload=payload or {})
        return json.dumps({"ok": True, "clearance_id": cid, "status": "pending"})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


async def _tool_workspace_check_clearance(clearance_id: str) -> str:
    ws = _require_workspace()
    if ws is None:
        return json.dumps({"ok": False, "error": NO_WORKSPACE_ERROR})
    cid = (clearance_id or "").strip()
    if not cid:
        return json.dumps({"ok": False, "error": "clearance_id required"})
    item = ws.get_pending(cid)
    if item is None:
        return json.dumps({"ok": False, "error": "clearance not found"})
    return json.dumps({"ok": True, **item})


_DISPATCH: dict[str, ToolFn] = {
    "shell": _tool_shell,
    "applescript": _tool_applescript,
    "read_file": _tool_read_file,
    "write_file": _tool_write_file,
    # "browser_extension" intentionally NOT registered — klo's product
    # promise is "no install required." The AX-on-Chromium path
    # (AXManualAccessibility auto-flip in api/core/accessibility.py)
    # already drives every browser. Set KLO_ENABLE_BROWSER_EXTENSION=1
    # at sidecar boot if you want to opt in (handled in TOOLS list
    # construction, not here).
    "web": _tool_web,
    "computer": _tool_computer,
    "accessibility": _tool_accessibility,
    "memory_remember": _tool_memory_remember,
    "memory_recall": _tool_memory_recall,
    "memory_forget": _tool_memory_forget,
    "i_couldnt_do_this": _tool_i_couldnt_do_this,
    "handoff_to_user": _tool_handoff_to_user,
    "request_permission": _tool_request_permission,
    # Composio meta-tools — proxy to klo-cloud's per-user Composio
    # surface. See the TOOLS list above for descriptions + the
    # CONNECTED SERVICES section of prompts.py for routing guidance.
    "composio_list_actions": _tool_composio_list_actions,
    "composio_execute": _tool_composio_execute,
    # Hermes-five M2 — schedule a recurring task via klo-cloud.
    "schedule_task": _tool_schedule_task,
    # Hermes-five M4 — fork parallel child agents.
    "delegate_task": _tool_delegate_task,
    # Idle wait — sleep N seconds without consuming a model turn for the
    # check loop. For deploy polling, build waits, settling on a long
    # page. Capped at 180s per call.
    "wait": _tool_wait,
    # ─── Long-horizon workspace tools (domain-neutral) ──────────────
    # klo calls workspace_init when the user's ask warrants persistent,
    # cross-session state. Once bound, delegate_task children inherit
    # the workspace via ContextVar. Outside a workspace, these tools
    # return a structured "no workspace" error.
    "workspace_init": _tool_workspace_init,
    "workspace_load": _tool_workspace_load,
    "workspace_list": _tool_workspace_list,
    "workspace_read": _tool_workspace_read,
    "workspace_write": _tool_workspace_write,
    "workspace_append_log": _tool_workspace_append_log,
    "workspace_append_decision": _tool_workspace_append_decision,
    "workspace_save_evidence": _tool_workspace_save_evidence,
    "workspace_request_human": _tool_workspace_request_human,
    "workspace_check_clearance": _tool_workspace_check_clearance,
}


async def dispatch(name: str, args: dict[str, Any]) -> str:
    fn = _DISPATCH.get(name)
    if fn is None:
        return json.dumps({"ok": False, "error": f"unknown tool: {name!r}"})
    try:
        return await fn(**args)
    except TypeError as exc:
        return json.dumps({"ok": False, "error": f"bad arguments: {exc}"})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
