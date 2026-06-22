"""High-level web-task operations.

Routes through the Mac app's MacOpsServer (port 8788) which owns the
embedded WKWebView. Everything you see here is a thin HTTP client; all
the actual web driving lives in `desktop-mac/KLO/Web/WebViewManager.swift`.

Why this architecture (replacing the previous CDP-against-bundled-Chromium
approach):

  - WKWebView gives `isTrusted=true` mouse + key events from synthesized
    NSEvent, verified empirically on macOS Sequoia. Same trust gate
    React/Instagram/Gmail check.
  - Native WebKit means no 344MB Chromium bundle inside KLO.app — the
    app stays ~124MB.
  - The WKWebView lives INSIDE klo's window (not a separate app), so the
    user doesn't see "two browsers" — just klo doing its thing in a
    big embedded pane.
  - Cookie + localStorage persistence via WKWebsiteDataStore survives
    process restart and app updates — sign in to Gmail in klo once,
    klo stays signed in to Gmail forever.

Public function names + return shapes are identical to the prior CDP
implementation, so `agent2/tools.py` and the system prompt don't need
to change with the architecture swap.
"""
from __future__ import annotations

import asyncio
from typing import Any

import httpx


# MacOpsServer (Swift) listens on this port. Same port the screenshot /
# click / type endpoints use today.
_MAC_OPS_BASE = "http://127.0.0.1:8788"

# Generous default — the actual ops have their own internal timeouts;
# this just keeps the HTTP transport from hanging the whole sidecar if
# the Mac app crashed mid-call.
_HTTP_TIMEOUT = 60.0


async def _post(path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    """Generic POST helper. Returns the parsed JSON response from the
    Mac app or a structured error if the Mac app is unreachable."""
    body = body or {}
    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT) as client:
            resp = await client.post(f"{_MAC_OPS_BASE}{path}", json=body)
    except httpx.HTTPError as exc:
        return {
            "ok": False,
            "error": (
                f"klo's embedded browser unreachable at {_MAC_OPS_BASE}{path}: "
                f"{type(exc).__name__}: {exc}. Is KLO.app running?"
            ),
        }
    try:
        return resp.json()
    except Exception as exc:  # noqa: BLE001
        return {
            "ok": False,
            "error": f"klo's browser returned non-JSON for {path}: {resp.text[:200]}",
        }


# ─── Public ops ──────────────────────────────────────────────────────────


async def web_open(url: str, *, timeout: float = 20.0, **_: Any) -> dict[str, Any]:
    """Navigate the embedded WKWebView to `url`. Klo's overlay
    auto-expands into the web pane mode so the user sees the page.
    Returns the post-navigation URL + title + text excerpt.

    Default timeout bumped from 12s → 20s because heavy SPAs (Google
    Flights, Booking, Expedia) routinely take 8-15s for first paint
    when the network is anything less than excellent.
    """
    if not url:
        return {"ok": False, "error": "url required"}
    result = await _post("/v1/web/open", {"url": url, "timeout": timeout})
    if not result.get("ok"):
        return result
    # Settle wait BEFORE reading text — SPA hydration commonly happens
    # 1-3s after didFinish navigation. Without this, the excerpt is the
    # pre-hydration skeleton ("Loading..." etc.) and the model wastes
    # turns thinking the page is still loading.
    await _post("/v1/web/wait_settled", {"timeout": 4.0})
    # The /v1/web/open response is the urlSummary shape. Add the text
    # excerpt by calling /v1/web/text so the agent has immediate
    # grounding without a separate request from the model.
    text_resp = await _post("/v1/web/text", {"max": 1200})
    excerpt = text_resp.get("text", "") if text_resp.get("ok") else ""
    return {
        "ok": True,
        "target": {
            "url": result.get("url"),
            "title": result.get("title"),
        },
        "text_excerpt": excerpt,
    }


async def web_click(
    selector: str | None = None,
    text: str | None = None,
    *,
    nth: int = 0,
    **_: Any,
) -> dict[str, Any]:
    """Click an element via NSEvent → WKWebView. Produces an
    `isTrusted=true` DOM click — fires React handlers.

    `selector` = CSS selector; `text` = visible-text/aria-label match.
    Returns before/after URL + title so the caller can detect state
    changes.
    """
    if not selector and not text:
        return {"ok": False, "error": "selector or text required"}
    body: dict[str, Any] = {"nth": nth}
    if selector is not None:
        body["selector"] = selector
    if text is not None:
        body["text"] = text
    return await _post("/v1/web/click", body)


async def web_type(
    selector: str,
    text: str,
    *,
    submit: bool = False,
    clear_first: bool = True,
    **_: Any,
) -> dict[str, Any]:
    """Focus `selector` and type `text` via WKWebView's text input
    pipeline (insertText for bulk → trusted `input` event; per-key
    NSEvent for the optional Enter/clear path)."""
    if not selector:
        return {"ok": False, "error": "selector required"}
    return await _post(
        "/v1/web/type",
        {"selector": selector, "text": text, "submit": submit, "clear_first": clear_first},
    )


async def web_text(
    selector: str | None = None,
    *,
    max: int = 4000,
    settle: bool = True,
    **_: Any,
) -> dict[str, Any]:
    """Return `innerText` of `selector` (or whole page if omitted),
    truncated to `max` chars.

    Settles the DOM before reading (readyState complete + fetch/XHR
    idle, max 4s) unless `settle=False`. Pass `settle=False` for
    rapid-fire polling reads where you've already settled.
    """
    if settle:
        await _post("/v1/web/wait_settled", {"timeout": 4.0})
    body: dict[str, Any] = {"max": max}
    if selector is not None:
        body["selector"] = selector
    return await _post("/v1/web/text", body)


async def web_evaluate(
    expression: str,
    *,
    await_promise: bool = True,  # accepted for API parity; WKWebView handles promises natively
    **_: Any,
) -> dict[str, Any]:
    """Run a JS expression in the page's main world via
    `WKWebView.evaluateJavaScript(_:)`. Returns the JSON-serialisable
    result value. `await_promise` is accepted for parity with the old
    CDP API but is a no-op — WKWebView's evaluator handles promises
    transparently."""
    if not expression:
        return {"ok": False, "error": "expression required"}
    return await _post("/v1/web/evaluate", {"expression": expression})


async def web_wait_for(
    selector: str,
    *,
    timeout: float = 8.0,
    **_: Any,
) -> dict[str, Any]:
    """Block until `selector` is present (or `timeout` elapses).
    Implementation polls every 250ms via Runtime.evaluate."""
    if not selector:
        return {"ok": False, "error": "selector required"}
    return await _post("/v1/web/wait_for", {"selector": selector, "timeout": timeout})


async def web_url(**_: Any) -> dict[str, Any]:
    """Current URL + title. Cheap state check after a click that
    should have navigated."""
    return await _post("/v1/web/url")


async def web_snapshot(**_: Any) -> dict[str, Any]:
    """Capture an indexed AX-tree snapshot of every visible interactive
    element on the current page. THE PRIMARY tool for any web
    interaction — use this BEFORE clicking instead of guessing
    selectors or text.

    Returns:
      {
        ok: True,
        snapshot_id: "snap_abcd1234",
        url, title, viewport, scroll,
        items: [
          {idx: 0, role: "tab",      name: "Round trip", selected: False, x, y},
          {idx: 1, role: "tab",      name: "One way",    x, y},
          {idx: 2, role: "combobox", name: "From",       value: "Atlanta", x, y},
          {idx: 3, role: "combobox", name: "To",         value: "",        x, y},
          {idx: 4, role: "button",   name: "Search flights", x, y},
          ...
        ]
      }

    Pick the target idx from `items` and call `web.press(idx)` or
    `web.fill(idx, text)`. The list is auto-truncated at 300 items
    (typical pages have 30-80). Auto-settles the DOM first.

    Why this is better than `web.click(text=...)` for ANY non-trivial
    site: text-matching against innerText collides on heavy MUI/Material
    pages (multiple elements contain "Round trip" as a substring).
    Accessibility names + roles uniquely identify each interactive
    element the way a screen reader does.
    """
    return await _post("/v1/web/snapshot")


async def web_press(idx: int, snapshot_id: str | None = None, **_: Any) -> dict[str, Any]:
    """Click the element at `idx` in the most recent snapshot. If
    `snapshot_id` is passed and doesn't match the last one issued by
    web.snapshot, returns `{ok: false, stale: true, error}` — take a
    new snapshot.

    Real isTrusted=true click via NSEvent. Returns before/after url
    + state_changed so the caller can detect if the click landed.
    """
    body: dict[str, Any] = {"idx": int(idx)}
    if snapshot_id:
        body["snapshot_id"] = snapshot_id
    return await _post("/v1/web/press", body)


async def web_fill(
    idx: int,
    text: str,
    *,
    submit: bool = False,
    clear_first: bool = True,
    snapshot_id: str | None = None,
    **_: Any,
) -> dict[str, Any]:
    """Focus the element at `idx` in the most recent snapshot and type
    `text` (trusted insertText). Pass submit=true to press Enter after.

    Falls back to a stale-snapshot error if `idx` no longer resolves
    in the live page (DOM was rebuilt since the snapshot).
    """
    body: dict[str, Any] = {
        "idx": int(idx),
        "text": text,
        "submit": bool(submit),
        "clear_first": bool(clear_first),
    }
    if snapshot_id:
        body["snapshot_id"] = snapshot_id
    return await _post("/v1/web/fill", body)


async def web_screenshot(max_width: int = 1280, **_: Any) -> dict[str, Any]:
    """Snapshot the WKWebView's visible viewport as a PNG. Returns
    a payload with `{ok, media_type, data, width, height, ...}` where
    `data` is a base64 PNG. agent2/tools.py wraps the response so the
    image lands as a real image content block to the model.

    Use this for visual grounding on heavy SPAs (Google Flights,
    Booking, Notion, etc.) where `web.text` returns shells without
    the rendered structure. Cheap — ~100-300ms per capture.
    """
    return await _post("/v1/web/screenshot", {"max_width": max_width})


async def web_wait_settled(timeout: float = 4.0, **_: Any) -> dict[str, Any]:
    """Block until the WKWebView's document.readyState is 'complete'
    AND in-flight fetch/XHR activity has been zero for 2 consecutive
    polls (or `timeout` elapses). Call after a web.open or web.click
    that triggered a SPA route change before doing web.text /
    web.click on the new state.
    """
    return await _post("/v1/web/wait_settled", {"timeout": timeout})


async def web_autofill(host: str | None = None, **_: Any) -> dict[str, Any]:
    """Try klo's own credential store for the current login form.
    Triggers Touch ID if a matching item exists. Klo NEVER auto-
    submits — fills the form + focuses the password field; the user
    presses Enter to authorize. Matches Safari's actual behavior.

    If `host` is omitted, the MacOpsServer uses the WKWebView's
    current URL host. Pass an explicit host to target a sub-domain
    that doesn't have a stored credential but a parent domain does
    (rare — most stored items match the visible host directly).

    Returns:
      - ok=true, filled=true, host, username     on success
      - ok=true, filled=false, reason="no_credential"  no saved item
      - ok=true, filled=false, reason="no_form"   no login form on page
      - ok=false, error="biometry_cancelled"     user cancelled Touch ID
      - ok=false, error="biometry_failed: <msg>" auth failed
    """
    body: dict[str, Any] = {}
    if host:
        body["host"] = host
    return await _post("/v1/web/autofill", body)


# ─── Just-in-time sign-in detection ──────────────────────────────────────

# URL substrings that identify a sign-in page for a known service. When
# `web.open` lands on one of these (and the model expected to be signed
# in), the model should call `web.wait_for_login` — that blocks while
# the user signs in inside the visible WKWebView pane. The pattern is
# minimal (substring contains) so it survives OAuth-domain shuffles.
_LOGIN_URL_PATTERNS: tuple[tuple[str, str], ...] = (
    ("accounts.google.com",            "Google"),
    ("login.microsoftonline.com",      "Microsoft"),
    ("login.live.com",                 "Microsoft Live"),
    ("appleid.apple.com",              "Apple ID"),
    ("login.yahoo.com",                "Yahoo"),
    ("instagram.com/accounts/login",   "Instagram"),
    ("facebook.com/login",             "Facebook"),
    ("github.com/login",               "GitHub"),
    ("x.com/i/flow/login",             "X"),
    ("twitter.com/login",              "Twitter"),
    ("linkedin.com/login",             "LinkedIn"),
    ("reddit.com/login",               "Reddit"),
    ("notion.so/login",                "Notion"),
    ("linear.app/login",               "Linear"),
    ("slack.com/signin",               "Slack"),
    ("openai.com/auth/login",          "OpenAI"),
    ("accounts.spotify.com",           "Spotify"),
)


def _detect_login_service(url: str | None) -> str | None:
    """Return the human-readable service name if `url` matches a known
    login page pattern, else None."""
    if not url:
        return None
    u = url.lower()
    for pattern, name in _LOGIN_URL_PATTERNS:
        if pattern in u:
            return name
    return None


async def web_wait_for_login(
    *,
    timeout: float = 90.0,
    **_: Any,
) -> dict[str, Any]:
    """Poll the WKWebView's URL every 500ms until it's no longer on a
    known sign-in page. Used by the model after `web.open` on a service
    that may require auth — gives the user time to sign in inside the
    visible klo web pane before the model continues.

    Default 90s timeout — long enough for typical sign-in including
    2FA challenges, short enough to not hang forever if the user walks
    away.

    Returns:
      - ok=True, already_signed_in=True if not on a login page at start
      - ok=True, service=<name>, elapsed_s=N if user finished sign-in
      - ok=False, error="timeout", service=<name> after `timeout` seconds
    """
    import time
    deadline = time.monotonic() + max(5.0, min(float(timeout), 600.0))

    initial = await web_url()
    if not initial.get("ok"):
        return {"ok": False, "error": "no active web view"}

    initial_service = _detect_login_service(initial.get("url"))
    if not initial_service:
        return {"ok": True, "already_signed_in": True, "url": initial.get("url")}

    start = time.monotonic()
    while time.monotonic() < deadline:
        await asyncio.sleep(0.5)
        cur = await web_url()
        if not cur.get("ok"):
            continue
        if _detect_login_service(cur.get("url")) is None:
            return {
                "ok": True,
                "service": initial_service,
                "url": cur.get("url"),
                "elapsed_s": round(time.monotonic() - start, 1),
            }
    return {
        "ok": False,
        "error": "timeout",
        "service": initial_service,
        "timeout_s": timeout,
    }
