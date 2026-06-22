"""Agent loop. OpenAI tool use, no plan contract. Just: model picks tool,
tool runs, model observes, repeat until natural end.

OpenAI's prompt caching is automatic — keep the system prompt stable to hit it.
"""
from __future__ import annotations

import asyncio
import json
import re
import logging
import os
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any


log = logging.getLogger("agent2.agent")


def _classify_run_error(exc: BaseException) -> str:
    """Map an exception from the model-call loop to a stable code.

    Returns one of:
      - "auth_expired"         401 from klo-cloud — Supabase access
                               token has expired between session.json
                               read and the cloud reaching upstream.
                               Caller should rebuild the client (re-
                               reads session.json, which the Mac app
                               may have just rewritten) and retry once.
      - "upstream_overloaded"  Anthropic/OpenAI 429 / overloaded
      - "upstream_timeout"     network or SDK timeout
      - "upstream_billing"     credit / quota exhausted (klo-side issue,
                               user sees the same generic message)
      - "upstream_blocked"     403 / WAF / permission denied
                               (covers Render WAF blocks + revoked keys)
      - "upstream_error"       anything else (catch-all)

    Why this exists: the OpenAI SDK's exception __str__ includes the
    full upstream response body. When Render's WAF returns a 403
    HTML page, the entire HTML used to flow through `result.error`
    into desktop_api's status_change event into the Mac UI. Now
    `result.error` only ever holds a stable code; raw exception text
    stays in server logs via log.exception. Mirrors the same
    helper in klo_cloud/chat.py:_classify_upstream_error.
    """
    name = type(exc).__name__.lower()
    text = str(exc).lower()
    # ORDER MATTERS. Auth first — AuthenticationError / 401 is its own
    # recovery path (rebuild client + retry, see the run() loop). Must
    # be checked before "blocked" since both can match `permission`.
    if (
        "authentication" in name
        or " 401" in text
        or "status 401" in text
        or "http 401" in text
        or "missing bearer token" in text
        or "invalid jwt" in text
    ):
        return "auth_expired"
    # Check blocked BEFORE overloaded — Render's WAF 403 response body
    # embeds a base64-encoded WOFF2 font; that font's base64 just
    # happens to contain the literal substring "529", which used to
    # mis-classify every WAF block as "upstream_overloaded". The class
    # name (PermissionDeniedError) is a strong, unambiguous signal.
    if (
        "permission" in name
        or "forbidden" in name
        or " 403" in text
        or "forbidden" in text
        or "firewall" in text
        or "blocked by" in text  # Render WAF page title
    ):
        return "upstream_blocked"
    # Overloaded: prefer class-name match (RateLimitError) and
    # word-boundary text matches so base64 garbage in error bodies
    # can't false-positive.
    if (
        "ratelimit" in name
        or "overloaded" in text
        or " 529 " in text
        or "status 529" in text
        or "http 529" in text
    ):
        return "upstream_overloaded"
    if "timeout" in name or "timed out" in text:
        return "upstream_timeout"
    if "credit" in text or "billing" in text or "quota" in text or "insufficient" in text:
        return "upstream_billing"
    return "upstream_error"


# ─── Prose-refusal interception ───────────────────────────────────────
#
# The model has a stubborn prior toward "explain in prose that I can't do
# X because I don't have permission Y" when a task involves TCC-gated
# actions. The system prompt explicitly forbids this anti-pattern but
# gpt-5.1's training overrides it consistently. Code-level enforcement:
# when the natural-end text matches one of these specific refusal
# patterns AND the run never attempted the gated tool, we suppress the
# final and signal the Mac app's PermissionGrantOrchestrator instead.
#
# Patterns target user-facing refusal language, not internal phrasings.
# Each is anchored to verbs/subjects that can only appear in this anti-
# pattern shape (false positives essentially zero).

_PROSE_REFUSAL_RE = re.compile(
    r"""(?xi)
    \b(
        don'?t\s+(?:yet\s+)?have\s+(?:the\s+)?permission
      | don'?t\s+(?:yet\s+)?have\s+(?:the\s+)?(?:Accessibility|Screen\s+Recording)\s+(?:access|permission|control)
      | haven'?t\s+been\s+granted\s+(?:Accessibility|Screen\s+Recording|permission|access)
      | hasn'?t\s+granted\s+(?:me\s+)?(?:Accessibility|Screen\s+Recording|permission)
      | (?:macOS|the\s+OS|the\s+system)\s+hasn'?t\s+(?:granted|given)
      | (?:i\s+)?(?:can'?t|cannot)\s+(?:actually\s+)?(?:click|type|interact|control)
        \s+.*?\b(?:because|since|until|unless)\b.*?\b(?:permission|access|Accessibility|Screen\s+Recording)
      | i\s+would\s+need\s+(?:Accessibility|Screen\s+Recording|permission)
    )\b
    """,
)

# Map a refusal hit to the TCC service most likely needed, based on the
# verbs the model used. Conservative — defaults to accessibility when
# the verbs are ambiguous, since the user can change it later via the
# orchestrator's instruction card.
def _guess_refusal_service(text: str) -> str:
    t = text.lower()
    if "screen recording" in t or "see your screen" in t or "see what" in t or "screenshot" in t:
        return "screen_recording"
    if "control" in t and any(app in t for app in (" notes", " music", " calendar", " reminders", " mail", " messages", " safari")):
        return "apple_events"
    # Default to accessibility — covers "click", "type", "interact",
    # "drive", and most generic phrasings.
    return "accessibility"


# Preamble shapes — the model narrating intent without acting. These
# are the openings that consistently precede a no-tool bail when the
# task actually needed tools. Ported from klo_cloud/chat.py:140. Used
# by _detect_preamble_bail to decide whether to force a re-fire with
# tool_choice="required".
#
# Two clusters here:
#   1. Classic preamble openers ("let me", "i'll", "sure", "on it") —
#      the model verbalizing intent but not actually firing a tool.
#   2. Thread-loss / capability-pitch openers ("i can navigate",
#      "pretty smooth so far", "what would you like", "here's what i
#      can do") — the model drops the user's actual request and
#      reverts to talking about itself. User cdc57568 in our Jun 15
#      audit hit this on turn 4: asked klo to write a tweet, got back
#      "Pretty smooth so far! I can navigate, read pages, interact
#      with web apps, run commands, and a bunch more. What can I help
#      you with?" — zero tool calls. They asked once more, klo lied
#      with the tab-switch bail, they bounced.
_PREAMBLE_RE = re.compile(
    r"^\s*("
    # Cluster 1: classic intent-narration
    r"let me|i'?ll|i will|i'?m going to|i'?m about to|"
    r"sure|on it|first[,]?\s*i|okay,?\s*i'?ll|alright,?\s*i'?ll|"
    r"one moment|hang on|hold on|let'?s|"
    r"i can|i'?ll start|i'?ll begin|to do this|"
    # Cluster 2: thread-loss + capability-pitch openers (Jun 2026)
    r"what would you like|what would you want|"
    r"pretty smooth|pretty good|going well|going great|"
    r"i can navigate|i can browse|i can read|i can control|"
    r"i can help (you )?with|here'?s what i can do|"
    r"i'?m klo[,.]|i am klo[,.]|"
    r"based on (our|the) conversation|"
    r"as klo[,.]|as an assistant"
    r")\b",
    re.IGNORECASE,
)


def _detect_preamble_bail(text: str, trace: list, turn: int) -> bool:
    """True when the model narrated intent and stopped without acting.

    Triggers on:
      - text matches a known preamble opener ("I'll search…", "Let me…")
        OR a thread-loss pattern ("What would you like…", "Pretty smooth
        so far!", "I can navigate, read pages…")
      - trace contains zero tool_call events SINCE the most recent user
        message (model never actually tried anything for THIS ask)

    Caller responds by re-firing with `tool_choice="required"` so the
    model has to either call a tool this time or fail the structural
    check.

    History — June 2026: previously gated on `turn == 0` to avoid false
    positives on legitimate post-tool narration. Audit of 9 real users
    (Supabase messages table review) showed user cdc57568 hit this
    exact gap: on turn 4 the model emitted "Pretty smooth so far! I
    can navigate, read pages…" — pure thread-loss capability pitch with
    zero tool calls in that turn. User typed "can u write the tweet???"
    next turn and bounced. The gate now fires on ANY turn but uses the
    "no tool_call SINCE the last user message" check so post-action
    narration is still allowed.
    """
    if not text or len(text) > 4000:
        return False
    if not _PREAMBLE_RE.search(text):
        return False
    # Turn 0: classic gate — if no tool_call in trace at all, bail.
    if turn == 0:
        for ev in trace:
            if getattr(ev, "kind", "") == "tool_call":
                return False
        return True
    # Mid-conversation: walk trace backwards from the end. Stop at the
    # most recent assistant_text event — anything before that belongs
    # to PRIOR turns and doesn't tell us whether the model acted on the
    # CURRENT user message. If we see a tool_call in this slice,
    # treat the preamble as post-hoc narration; otherwise it's a bail.
    found_assistant_anchor = False
    for ev in reversed(trace):
        kind = getattr(ev, "kind", "")
        if kind == "tool_call":
            return False  # model acted this turn; legit narration
        if kind in ("assistant_text", "assistant_message"):
            if found_assistant_anchor:
                # Two assistant turns back; previous slice is closed.
                return True
            found_assistant_anchor = True
    return True


def _detect_prose_refusal(text: str, trace: list) -> str | None:
    """If `text` is shaped like a TCC-refusal AND the run never attempted
    the gated tool, return the service the orchestrator should request.
    Otherwise return None and let the natural-end text stand."""
    if not text or len(text) > 4000:
        # Real refusals are short. A long final is almost certainly a
        # legitimate completion of the task.
        return None
    if not _PROSE_REFUSAL_RE.search(text):
        return None
    # Did the run actually attempt a TCC-gated tool? If yes, the refusal
    # is honest reporting after a real attempt — let it through.
    attempted_gated_tool = False
    for ev in trace:
        if getattr(ev, "kind", "") != "tool_call":
            continue
        name = (getattr(ev, "payload", {}) or {}).get("name", "")
        if name in ("accessibility", "computer", "applescript"):
            attempted_gated_tool = True
            break
    if attempted_gated_tool:
        return None
    return _guess_refusal_service(text)


# Tool calls exempted from the stuck detector — repeating a read is fine and
# often productive (re-checking state, polling a slow load).
_STUCK_DETECTOR_EXEMPT = {
    "screenshot",  # not a tool name itself, but referenced via computer
    "tabs_active",
    "tabs_dom_snapshot",
    "list_apps",
    "memory_recall",
    # AppleScript repeats are usually a verify-then-write pattern, not
    # a wedge. Without this exemption, the verify-then-write loop
    # (write Note → screenshot lags → verify-read returns stale → write
    # again → fingerprint match) trips the 3-identical-call threshold
    # and ALSO duplicates the data the agent thought it was just
    # confirming. Observed in production as Notes/Reminders entries
    # appearing 3× from a single user prompt.
    "applescript",
}

# Volatile arg keys that shouldn't affect fingerprint identity (timeouts,
# settle delays, etc. — the agent might tweak these without changing intent).
_VOLATILE_FINGERPRINT_KEYS = {"timeout", "wait_after_s", "settle_s", "max_steps"}


def _fingerprint(name: str, args: dict[str, Any]) -> tuple[str, str]:
    """Normalize a tool call so the stuck detector can spot repeats.

    For `computer` mutating actions (clicks, key, type, etc.), we
    deliberately DROP fine-grained coordinates and key text — the model
    moving its click 50px over isn't a structurally different action,
    it's the same broken approach with a wiggle. Same goes for typing
    different text in the same field.

    Lowercase string values, drop volatile keys (timeouts, settle), sort.
    """
    if not isinstance(args, dict):
        args = {}

    # Reads: exempt from stuck detection entirely. `zoom` belongs here too —
    # it returns a cropped screenshot for closer inspection, doesn't mutate
    # the screen. Without this exemption, a model that alternates click+zoom
    # (looking, missing, looking closer, missing) never accumulates 3 identical
    # fingerprints in a row and the detector never fires — verified empirically
    # on a YouTube "subscribe" run that wedged for 5+ click attempts.
    if name == "computer" and args.get("action") in {"screenshot", "zoom", "get_cursor_position", "wait", "mouse_move"}:
        return ("__exempt__", "")
    if name in _STUCK_DETECTOR_EXEMPT:
        return ("__exempt__", "")

    # Computer mutating actions: fingerprint by (tool, action) only —
    # ignore coordinates, text, and key combos. This catches the "click
    # around the same region 5 times" pattern that the previous
    # coordinate-aware fingerprint missed.
    if name == "computer":
        action = args.get("action", "")
        return (name, json.dumps({"action": action}, sort_keys=True))

    canon = {}
    for k, v in args.items():
        if k in _VOLATILE_FINGERPRINT_KEYS:
            continue
        if isinstance(v, str):
            canon[k] = v.strip().lower()
        else:
            canon[k] = v
    return (name, json.dumps(canon, sort_keys=True, ensure_ascii=False))

from anthropic import AsyncAnthropic

from .cloud_auth import make_anthropic_client, make_openai_client  # openai kept for back-compat / voice path
from .prompts import SYSTEM_PROMPT
from .tools import TOOLS, dispatch


def _ae_permitted_for_system_events() -> bool:
    """Probe whether the current process has Apple Events permission to
    send events to System Events, WITHOUT triggering the macOS-native
    "klo wants to control System Events" prompt as a side effect.

    Implementation note: PyObjC's ApplicationServices binding does NOT
    expose AEDeterminePermissionToAutomateTarget (verified empirically:
    AttributeError at runtime), so we load the symbol directly via
    ctypes from /System/Library/Frameworks/ApplicationServices.framework.
    The Foundation-based version this used to be was a silent no-op
    that always returned False — the prompt was already suppressed,
    but the probe wasn't actually probing.

    Returns True ONLY when permission is already granted (errAEnoErr=0).
    Treats every other result as not-granted/unsafe, including:
      0      noErr                       — granted; safe to proceed
      -1743  errAEEventNotPermitted      — explicitly denied (silent)
      -1744  procNotFound (ish) /        — would prompt → DO NOT proceed
             errAEPermissionWouldRequireUserConsent
      -600   procNotFound                — System Events isn't running;
                                           starting it via osascript
                                           could trigger -1744 path
      anything else                      — unknown, treat as unsafe

    The user-facing AE prompt should ONLY ever fire from the cloud
    onboarding's optional-permissions card where klo's branded UI is
    visible to give the user context. Never as a surprise from typing
    "hey" into the panel.
    """
    try:
        import ctypes
        framework = ctypes.CDLL(
            "/System/Library/Frameworks/ApplicationServices.framework/"
            "ApplicationServices"
        )

        class _AEDesc(ctypes.Structure):
            _fields_ = [
                ("descriptorType", ctypes.c_uint32),
                ("dataHandle", ctypes.c_void_p),
            ]

        # AECreateDesc(DescType, const void* data, Size dataSize, AEDesc* out)
        AECreateDesc = framework.AECreateDesc
        AECreateDesc.restype = ctypes.c_int32
        AECreateDesc.argtypes = [
            ctypes.c_uint32, ctypes.c_char_p, ctypes.c_long,
            ctypes.POINTER(_AEDesc),
        ]
        AEDisposeDesc = framework.AEDisposeDesc
        AEDisposeDesc.argtypes = [ctypes.POINTER(_AEDesc)]

        # AEDeterminePermissionToAutomateTarget(
        #   const AEAddressDesc* target, AEEventClass cls,
        #   AEEventID evt, Boolean askUserIfNeeded) -> OSStatus
        Determine = framework.AEDeterminePermissionToAutomateTarget
        Determine.restype = ctypes.c_int32
        Determine.argtypes = [
            ctypes.POINTER(_AEDesc), ctypes.c_uint32,
            ctypes.c_uint32, ctypes.c_uint8,
        ]

        target = _AEDesc()
        bundle_id = b"com.apple.systemevents"
        # 'bund' = typeApplicationBundleID
        err = AECreateDesc(0x62756E64, bundle_id, len(bundle_id),
                            ctypes.byref(target))
        if err != 0:
            return False
        try:
            # '****' = typeWildCard for both class and id; askUserIfNeeded=False.
            result = Determine(ctypes.byref(target),
                                0x2A2A2A2A, 0x2A2A2A2A, 0)
        finally:
            AEDisposeDesc(ctypes.byref(target))
        return result == 0
    except Exception:
        return False


async def _format_connected_services() -> str:
    """Fetch the user's connected Composio toolkits from klo-cloud and
    format a system-prompt block listing them. Returns empty string if:
      - User isn't signed in
      - /auth/me is unreachable (network, cloud down)
      - User has no toolkits connected
      - Composio isn't configured server-side (503)

    Returning empty in all those cases keeps the system prompt byte-
    identical to "no integrations" — preserves prompt cache for the
    majority of users who haven't connected anything.
    """
    import httpx
    from .cloud_auth import KLO_CLOUD_URL, SIDECAR_UA, get_session_token
    token = get_session_token()
    if not token:
        return ""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(
                f"{KLO_CLOUD_URL}/auth/me",
                headers={
                    "Authorization": f"Bearer {token}",
                    "User-Agent": SIDECAR_UA,
                },
            )
        if resp.status_code != 200:
            return ""
        data = resp.json()
    except Exception:
        return ""
    composio = (data.get("integrations") or {}).get("composio") or {}
    toolkits = list(composio.get("connected_toolkits") or [])
    if not toolkits:
        return ""
    listing = ", ".join(sorted(toolkits))
    return (
        "\n\n# CONNECTED SERVICES (Composio-backed)\n\n"
        f"The user has connected: {listing}.\n\n"
        "When the user asks you to do something with one of these services "
        "(e.g. 'send Bob an email', 'add this to Notion', 'create a Linear issue'), "
        "use the Composio meta-tools:\n"
        "  1. `composio_list_actions(toolkit)` — get the action catalog with schemas\n"
        "  2. `composio_execute(toolkit, action, params)` — run a specific action\n\n"
        "Prefer Composio over web.* when the toolkit is in this list — API-direct "
        "is faster and more reliable than UI clicks. For services NOT in this list, "
        "fall back to web.*/applescript, or tell the user they need to connect that "
        "service first in Settings → Connected Apps.\n"
    )


async def _current_context() -> dict[str, str]:
    """Snapshot the user's current OS state — frontmost app, window
    title, AND default browser. Lets the agent ground its first action
    in what's actually on screen, AND know which browser to drive when
    a web task comes up (so it doesn't open Safari when the user lives
    in Chrome / Dia / Arc).

    Defensive: if AppleEvents permission isn't already granted, skip
    the System Events osascript entirely and return empty strings for
    the AE-derived fields. This prevents macOS from popping a
    "KLO wants to control System Events" prompt every time the user
    submits their first prompt — which felt like a scary surprise
    coming from a chat surface that just said "hey." The agent loses
    one piece of context (frontmost app + window title) but still
    runs. Default browser detection uses LaunchServices, NOT AE, so
    that part still works without the grant.
    """
    if _ae_permitted_for_system_events():
        # Frontmost app + window title (one osascript). Only run when
        # AE is granted — no prompt risk.
        script = (
            'tell application "System Events"\n'
            '  set fmName to name of first application process whose frontmost is true\n'
            '  set wTitle to ""\n'
            '  try\n'
            '    set wTitle to name of front window of first application process whose frontmost is true\n'
            '  end try\n'
            '  return fmName & "<<KLO>>" & wTitle\n'
            'end tell'
        )
        proc = await asyncio.create_subprocess_exec(
            "/usr/bin/osascript", "-e", script,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.communicate()
            out = b""
        parts = out.decode("utf-8", errors="replace").strip().split("<<KLO>>")
        frontmost = parts[0].strip() if parts and parts[0].strip() else ""
        window_title = parts[1].strip() if len(parts) > 1 and parts[1].strip() else ""
        # If klo's own panel was frontmost at snapshot time (common race —
        # the user just submitted via the notch UI, so KLO briefly owns
        # focus), the grounding block would misreport KLO as the user's
        # working context and the model would treat it as the target.
        # The AX path already filters klo everywhere via _SKIP_BUNDLE_IDS;
        # mirror that here. Fall back to the recent-app tracker which
        # never records klo activations. Window title can't transfer
        # cleanly (tracker has no window state), so we clear it rather
        # than carry the wrong one over.
        if frontmost.lower() == "klo":
            try:
                from .active_apps import tracker as _tracker  # noqa: WPS433
                recent = _tracker().history(limit=1)
                if recent and recent[0].get("name"):
                    frontmost = str(recent[0]["name"])
                    window_title = ""
                else:
                    frontmost = ""
                    window_title = ""
            except Exception:
                frontmost = ""
                window_title = ""
    else:
        frontmost = ""
        window_title = ""

    # Default browser — pull via LaunchServices so the agent knows
    # which browser is the user's daily driver. LaunchServices is NOT
    # an AppleEvents API — works regardless of the AE grant above.
    try:
        from . import system_info as _si
        browser = await _si.default_browser_async()
    except Exception:
        browser = {"bundle_id": None, "name": None}

    return {
        "frontmost_app": frontmost,
        "window_title": window_title,
        "default_browser_name": browser.get("name") or "",
        "default_browser_bundle_id": browser.get("bundle_id") or "",
    }


# ─── Ambient running-apps inventory (2.1.3) ──────────────────────────────────
#
# Users multitask. They're coding in Cursor while Messages is open with Emily,
# Mail with the inbox, Notes with a draft, browser on a research tab. When
# they say "text emily" they mean "use Messages, the one I have open." The
# focal-window-AX-tree architecture was the wrong primitive — it assumed the
# user was looking at the target app. They almost never are.
#
# Smarter primitive: inject an INVENTORY of every app the user has on-screen,
# with each app's window titles + a category hint. The model uses this to
# reason about which surface matches the user's task (text → messaging,
# email → email, etc.). Window titles often contain the answer directly —
# a Messages window titled "Emily Chen" tells you Emily's chat is open.
#
# Sidecar builds the inventory; klo-cloud proxy formats it and injects as a
# system block. No AX fetch up front — the model picks an app from the
# inventory and calls accessibility.window_state itself for the tree it
# wants. Cheap (~5-10ms to enumerate windows), no MacOps roundtrip required.

# Bundle-id → category mapping for the inventory's category hints. Used by
# the posture rule to teach the model "text → messaging app", etc.
_BUNDLE_CATEGORY: dict[str, str] = {
    # messaging
    "com.apple.MobileSMS": "messaging",
    "com.apple.iChat": "messaging",
    "com.tinyspeck.slackmacgap": "messaging",
    "com.hnc.Discord": "messaging",
    "com.discord.Discord": "messaging",
    "ru.keepcoder.Telegram": "messaging",
    "net.whatsapp.WhatsApp": "messaging",
    "com.linkedin.Messenger": "messaging",
    # email
    "com.apple.mail": "email",
    "com.readdle.smartemail-Mac": "email",
    "com.microsoft.Outlook": "email",
    "com.airmailapp.airmail2": "email",
    # browser
    "com.google.Chrome": "browser",
    "com.apple.Safari": "browser",
    "company.thebrowser.Browser": "browser",  # Arc
    "company.thebrowser.dia": "browser",  # Dia
    "com.brave.Browser": "browser",
    "com.microsoft.edgemac": "browser",
    "org.mozilla.firefox": "browser",
    "app.zen-browser.zen": "browser",
    "ai.perplexity.mac": "browser",
    # notes / docs
    "com.apple.Notes": "notes",
    "notion.id": "notes",
    "md.obsidian": "notes",
    "com.bear-writer": "notes",
    # calendar / reminders
    "com.apple.iCal": "calendar",
    "com.apple.reminders": "reminders",
    "com.flexibits.fantastical2.mac": "calendar",
    # music / media
    "com.apple.Music": "music",
    "com.spotify.client": "music",
    "com.apple.podcasts": "podcasts",
    # editors / IDE
    "com.todesktop.230313mzl4w4u92": "editor",  # Cursor
    "com.microsoft.VSCode": "editor",
    "com.microsoft.VSCodeInsiders": "editor",
    "com.apple.dt.Xcode": "editor",
    "com.jetbrains.intellij": "editor",
    "com.jetbrains.pycharm": "editor",
    "com.apple.TextEdit": "editor",
    "com.zedindustries.zed": "editor",
    # files
    "com.apple.finder": "files",
    # system
    "com.apple.systempreferences": "settings",
    "com.apple.calculator": "calculator",
    # documents
    "com.apple.iWork.Pages": "document",
    "com.apple.iWork.Numbers": "spreadsheet",
    "com.apple.iWork.Keynote": "presentation",
    "com.microsoft.Word": "document",
    "com.microsoft.Excel": "spreadsheet",
    "com.microsoft.Powerpoint": "presentation",
    # terminals
    "com.googlecode.iterm2": "terminal",
    "com.apple.Terminal": "terminal",
    "com.cmuxterm.app": "terminal",
    # design
    "com.figma.Desktop": "design",
    "com.bohemiancoding.sketch3": "design",
    # meetings
    "us.zoom.xos": "meetings",
    "com.tinyspeck.slackmacgap.huddle": "meetings",
}

# Apps to skip in the inventory: system pseudo-apps, klo itself.
_INVENTORY_SKIP_BIDS: frozenset[str] = frozenset({
    "com.apple.WindowManager",
    "com.apple.dock",
    "com.apple.controlcenter",
    "com.apple.systemuiserver",
    "com.apple.notificationcenterui",
    "com.apple.loginwindow",
    "com.apple.Spotlight",
    "com.apple.wallpaper.menu",
    "com.apple.PressAndHold",
})

_MAX_INVENTORY_APPS = 20      # cap so a 30-window mess doesn't blow tokens
_MAX_WINDOWS_PER_APP = 3      # most informative are top 3


def _build_running_apps_inventory() -> dict[str, Any] | None:
    """Enumerate running apps + their windows via NSWorkspace + AX.

    Architecture (from blog research, 2026-06-19): the right APIs for
    multi-app window inventory are:
      - `NSWorkspace.runningApplications` → list of every running app,
        filtered to `activationPolicy == .regular` (skips background
        agents, login items, helpers)
      - `AXUIElementCreateApplication(pid)` + `kAXWindowsAttribute` →
        every top-level window the app owns
      - `kAXTitleAttribute` → the human-meaningful title (conversation
        name for Messages, "Inbox (37)" for Mail, file path for editors)
      - `kAXMinimizedAttribute` → filter out minimized

    This path NEEDS Accessibility permission but NOT Screen Recording.
    The bundled klo-sidecar has it (codesigned, granted). Source-python
    inherits via terminal responsible-process (grant Terminal.app once,
    Python children of `uv run` inherit).

    Same shape as Hammerspoon, AltTab, Rectangle, macapptree,
    browser-use/macOS-use. Returns None if AX is denied (caller falls
    back to no inventory).
    """
    try:
        import AppKit  # type: ignore # noqa: WPS433
        import HIServices  # type: ignore # noqa: WPS433
        from ApplicationServices import (  # type: ignore # noqa: WPS433
            AXUIElementCreateApplication,
            AXUIElementCopyAttributeValue,
        )
    except Exception as exc:  # noqa: BLE001
        try:
            with open("/tmp/klo-ambient-debug.log", "a") as _f:
                _f.write(f"{time.time():.3f} inventory import failed: {exc}\n")
        except Exception:  # noqa: BLE001
            pass
        return None

    # Lazy import for category set
    from .tools import _NATIVE_COCOA_BUNDLES  # noqa: WPS433

    def _ax_get(elem: Any, attr: str) -> Any:
        """AXUIElementCopyAttributeValue with the error-tuple shape pyobjc
        returns: (error_code, value). 0 = kAXErrorSuccess."""
        try:
            err, value = AXUIElementCopyAttributeValue(elem, attr, None)
            if err != 0:
                return None
            return value
        except Exception:  # noqa: BLE001
            return None

    # Quick AX trust check — if AX is denied we return None immediately
    # rather than firing per-app failures.
    try:
        if not HIServices.AXIsProcessTrusted():
            try:
                with open("/tmp/klo-ambient-debug.log", "a") as _f:
                    _f.write(f"{time.time():.3f} inventory: AX not trusted for this process — terminal needs Accessibility grant\n")
            except Exception:  # noqa: BLE001
                pass
            return None
    except Exception:  # noqa: BLE001
        pass

    try:
        ws = AppKit.NSWorkspace.sharedWorkspace()
        running = ws.runningApplications()
    except Exception as exc:  # noqa: BLE001
        try:
            with open("/tmp/klo-ambient-debug.log", "a") as _f:
                _f.write(f"{time.time():.3f} inventory: runningApplications failed: {exc}\n")
        except Exception:  # noqa: BLE001
            pass
        return None

    NSApplicationActivationPolicyRegular = 0  # AppKit constant
    apps_out: list[dict[str, Any]] = []
    _counts = {"total": 0, "skipped_policy": 0, "skipped_klo": 0,
               "skipped_bid": 0, "no_ax_windows": 0, "kept": 0}

    for app in running:
        _counts["total"] += 1
        try:
            if app.activationPolicy() != NSApplicationActivationPolicyRegular:
                _counts["skipped_policy"] += 1
                continue
        except Exception:  # noqa: BLE001
            _counts["skipped_policy"] += 1
            continue
        bid = str(app.bundleIdentifier() or "").strip()
        if not bid:
            continue
        if bid.startswith("com.klo") or bid == "com.klorah.klo":
            _counts["skipped_klo"] += 1
            continue
        if bid in _INVENTORY_SKIP_BIDS:
            _counts["skipped_bid"] += 1
            continue
        name = str(app.localizedName() or "").strip()
        if not name:
            continue
        pid = int(app.processIdentifier())

        # Walk AX windows for this app
        try:
            ax_app = AXUIElementCreateApplication(pid)
        except Exception:  # noqa: BLE001
            ax_app = None
        windows_out: list[dict[str, Any]] = []
        if ax_app is not None:
            ax_windows = _ax_get(ax_app, "AXWindows") or []
            for w in ax_windows[:_MAX_WINDOWS_PER_APP * 2]:  # over-fetch, then filter
                minimized = _ax_get(w, "AXMinimized")
                if minimized:
                    continue
                title = _ax_get(w, "AXTitle")
                title_str = str(title or "").strip()
                # AXWindow doesn't expose CG window id directly. We can
                # leave window_id null — MacOps's window_state takes
                # app_name, which is enough.
                windows_out.append({"title": title_str, "window_id": None})
                if len(windows_out) >= _MAX_WINDOWS_PER_APP:
                    break
        if not windows_out:
            # Don't drop the app — it's still running, just no AX windows
            # (Electron apps, background agents, etc.). Emit with empty
            # windows so the model still sees the app is open.
            _counts["no_ax_windows"] += 1
        else:
            _counts["kept"] += 1
        apps_out.append({
            "bundle_id": bid,
            "name": name,
            "category": _BUNDLE_CATEGORY.get(bid),
            "ax_supported": bid in _NATIVE_COCOA_BUNDLES,
            "windows": windows_out,
        })
        if len(apps_out) >= _MAX_INVENTORY_APPS:
            break

    try:
        with open("/tmp/klo-ambient-debug.log", "a") as _f:
            _f.write(f"{time.time():.3f} inventory ax-walk: {_counts} → {len(apps_out)} apps\n")
    except Exception:  # noqa: BLE001
        pass

    if not apps_out:
        return None
    return {"apps": apps_out}


@dataclass
class TraceEvent:
    ts: float
    kind: str
    payload: dict[str, Any]


@dataclass
class RunResult:
    task: str
    final: str | None
    turns: int
    elapsed_s: float
    input_tokens: int = 0
    output_tokens: int = 0
    cached_input_tokens: int = 0
    # Anthropic Computer Use sub-call costs (each click_element / find_element
    # makes one). Tracked separately so users can see what the coord-finder
    # is costing them on top of the orchestrator.
    anthropic_input_tokens: int = 0
    anthropic_output_tokens: int = 0
    anthropic_calls: int = 0
    estimated_cost_usd: float = 0.0
    budget_warning: str | None = None
    error: str | None = None
    trace: list[TraceEvent] = field(default_factory=list)
    # Set by the prose-refusal interceptor when the model bails on a TCC-
    # gated task by writing "I can't / I don't have permission..." text
    # WITHOUT actually attempting the gated tool. desktop_api translates
    # this to state.error_code=permission_denied so the Mac app's
    # orchestrator routes to Settings + instruction card + auto-retry,
    # identical to the path taken when a real tool genuinely returned
    # permission_denied. None = no refusal detected.
    permission_refusal_service: str | None = None
    # True when the run ended via an explicit handoff_to_user tool call
    # OR a user-focus-takeover force-handoff. desktop_api uses this to
    # distinguish "model said its turn was over" from "loop exhausted
    # max_turns" — both populate `final` but the UX should differ
    # (handoff is a clean end, max_turns is a soft failure).
    handoff: bool = False
    handoff_message: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "task": self.task,
            "final": self.final,
            "turns": self.turns,
            "elapsed_s": round(self.elapsed_s, 2),
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cached_input_tokens": self.cached_input_tokens,
            "anthropic_input_tokens": self.anthropic_input_tokens,
            "anthropic_output_tokens": self.anthropic_output_tokens,
            "anthropic_calls": self.anthropic_calls,
            "estimated_cost_usd": round(self.estimated_cost_usd, 4),
            "budget_warning": self.budget_warning,
            "error": self.error,
            "handoff": self.handoff,
            "handoff_message": self.handoff_message,
            "trace": [{"ts": round(e.ts, 3), "kind": e.kind, **e.payload} for e in self.trace],
        }


# Claude models. The agent runs on Anthropic's native computer use
# (computer_20251124 schema-less tool + the perception-verification loop
# Anthropic recommends). Sonnet 4.6 is the default; a Haiku 4.5
# classifier upgrades to Opus 4.7 on COMPLEX prompts (Phase 2 router).
_MODEL_SONNET = "claude-sonnet-4-6"
_MODEL_OPUS = "claude-opus-4-7"
_MODEL_HAIKU = "claude-haiku-4-5"
MODEL_DEFAULT = os.environ.get("KLO_CU_MODEL", _MODEL_SONNET)
# Voice path historically rode the same model. Kept on a separate knob
# so we can tune voice latency independently.
VOICE_MODEL_DEFAULT = os.environ.get("KLO_VOICE_MODEL", _MODEL_SONNET)
COMPUTER_USE_BETA = "computer-use-2025-11-24"
MAX_TURNS_DEFAULT = 90  # Multi-click flows need turn budget; computer use steps can chain.
# Hermes-style budget pressure: nudge the model toward consolidation as it
# approaches the cap so it can wrap up gracefully instead of being cut off
# mid-action. Each threshold fires AT MOST ONCE per run. Tuneable via env
# for telemetry experiments on "how early is too early".
BUDGET_PRESSURE_SOFT_PCT = float(os.environ.get("KLO_BUDGET_PRESSURE_SOFT", "0.70"))
BUDGET_PRESSURE_HARD_PCT = float(os.environ.get("KLO_BUDGET_PRESSURE_HARD", "0.90"))


# Approximate $/1M tokens. Updated periodically — used for soft budgets.
# These are not contract; they're rough enough for the warning-band
# signal the user actually wants (".50 typical / $2 hard cap").
_PRICE_PER_M_TOKENS = {
    # Sonnet 4.6 ~ $3/Mtok in, $15/Mtok out. Cached input ~$0.30/Mtok.
    "sonnet_input": 3.00,
    "sonnet_cached_input": 0.30,
    "sonnet_output": 15.00,
    # Opus 4.7 ~ $15/Mtok in, $75/Mtok out. Cached input ~$1.50/Mtok.
    "opus_input": 15.00,
    "opus_cached_input": 1.50,
    "opus_output": 75.00,
    # Haiku 4.5 (router classifier) — cheap, negligible.
    "haiku_input": 1.00,
    "haiku_output": 5.00,
}

BUDGET_SOFT_WARN_USD = float(os.environ.get("KLO_BUDGET_SOFT_WARN", "0.50"))
BUDGET_HARD_STOP_USD = float(os.environ.get("KLO_BUDGET_HARD_STOP", "2.00"))


def _estimate_cost_usd(result: RunResult, model: str = _MODEL_SONNET) -> float:
    """Rough running cost across the model family. Sonnet is the default
    pricing tier; Opus is ~5× more expensive per token. The model arg
    lets us bill correctly when the router escalates a run to Opus.
    `anthropic_*` fields stay populated for back-compat with prior
    fingerprinting/eval tooling but the cost now folds into the unified
    Claude tier above."""
    fresh_input = max(0, result.input_tokens - result.cached_input_tokens)
    if model == _MODEL_OPUS:
        in_rate = _PRICE_PER_M_TOKENS["opus_input"]
        cached_rate = _PRICE_PER_M_TOKENS["opus_cached_input"]
        out_rate = _PRICE_PER_M_TOKENS["opus_output"]
    else:
        in_rate = _PRICE_PER_M_TOKENS["sonnet_input"]
        cached_rate = _PRICE_PER_M_TOKENS["sonnet_cached_input"]
        out_rate = _PRICE_PER_M_TOKENS["sonnet_output"]
    cost = 0.0
    cost += (fresh_input / 1_000_000) * in_rate
    cost += (result.cached_input_tokens / 1_000_000) * cached_rate
    cost += (result.output_tokens / 1_000_000) * out_rate
    # Haiku router cost (one cheap classifier call per run). Folded in.
    cost += (result.anthropic_input_tokens / 1_000_000) * _PRICE_PER_M_TOKENS["haiku_input"]
    cost += (result.anthropic_output_tokens / 1_000_000) * _PRICE_PER_M_TOKENS["haiku_output"]
    return cost


def _parse_data_url(data_url: str) -> tuple[str, str]:
    """Split `data:image/<mime>;base64,<data>` → (media_type, base64_data).
    Returns ("image/png", "") on malformed input — the caller can decide
    whether to skip the image block or surface an error.
    """
    if not data_url.startswith("data:"):
        return "image/png", ""
    head, _, b64 = data_url[5:].partition(",")
    mime, _, _flags = head.partition(";")
    return mime or "image/png", b64


def _split_tool_output(raw: str) -> tuple[str, str | None]:
    """If the tool returned an image data_url anywhere inside its JSON output,
    extract it and return a sanitized text + the data_url separately so the
    agent loop can attach it as a real image_url message.

    Returns (text_for_tool_message, data_url_or_none).
    """
    if "data:image/" not in raw:
        return raw, None
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return raw, None
    image_url = _find_data_url(parsed)
    if image_url is None:
        return raw, None
    sanitized = _replace_data_urls(parsed)
    return json.dumps(sanitized, ensure_ascii=False), image_url


def _find_data_url(node):
    if isinstance(node, str) and node.startswith("data:image/"):
        return node
    if isinstance(node, dict):
        for v in node.values():
            found = _find_data_url(v)
            if found is not None:
                return found
    if isinstance(node, list):
        for v in node:
            found = _find_data_url(v)
            if found is not None:
                return found
    return None


def _replace_data_urls(node):
    if isinstance(node, str):
        if node.startswith("data:image/"):
            return f"[image elided, {len(node)} chars; forwarded to model as image_url]"
        return node
    if isinstance(node, dict):
        return {k: _replace_data_urls(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_replace_data_urls(v) for v in node]
    return node


def _prune_old_screenshots(messages: list[dict[str, Any]], keep_last: int = 2) -> None:
    """Walk `messages` newest→oldest. For each tool_result block whose
    content list contains an image, keep the first `keep_last` intact;
    rewrite older ones so the image block is replaced with a tiny text
    stub. `tool_use_id` is preserved — Anthropic errors if a tool_use
    in a prior assistant message lacks a matching tool_result downstream.
    Idempotent: re-running on an already-pruned list is a no-op.

    Why: when the model has 4+ screenshots inline in conversation history
    it starts comparing "current state" across stale versions and
    misreads the world. Capping at 2 ensures only the freshest before/
    after pair is in attention. ~1MB → ~text-stub savings per pruned
    screenshot. Mutates `messages` in place.
    """
    seen = 0
    # Walk in reverse so we count from the newest screenshot back.
    for msg in reversed(messages):
        if msg.get("role") != "user":
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            inner = block.get("content")
            if not isinstance(inner, list):
                continue
            has_image = any(
                isinstance(c, dict) and c.get("type") == "image"
                for c in inner
            )
            if not has_image:
                continue
            seen += 1
            if seen <= keep_last:
                continue
            # Replace inner content with a text stub. Keep tool_use_id
            # by leaving the outer tool_result block intact.
            block["content"] = [{
                "type": "text",
                "text": "[screenshot omitted — older state, see newer screenshots]",
            }]


def _age_tool_result_text(
    messages: list[dict[str, Any]],
    keep_last_n_turns: int = 3,
    char_threshold: int = 4000,
) -> None:
    """Companion to _prune_old_screenshots: stub out large tool_result
    text from turns older than keep_last_n_turns. Preserves tool_use_id
    (Anthropic rejects orphans). Idempotent.
    """
    turn_index_for_msg: list[int] = [0] * len(messages)
    turns_back = 0
    for i in range(len(messages) - 1, -1, -1):
        turn_index_for_msg[i] = turns_back
        if messages[i].get("role") == "assistant":
            turns_back += 1

    for i, msg in enumerate(messages):
        if msg.get("role") != "user":
            continue
        if turn_index_for_msg[i] < keep_last_n_turns:
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            inner = block.get("content")
            # tool_result.content can be a list of typed blocks OR a string.
            if isinstance(inner, str):
                if len(inner) > char_threshold:
                    block["content"] = (
                        f"[tool result aged — {len(inner)} chars, see newer turns]"
                    )
                continue
            if not isinstance(inner, list):
                continue
            for j, c in enumerate(inner):
                if not isinstance(c, dict) or c.get("type") != "text":
                    continue
                text = c.get("text") or ""
                if len(text) <= char_threshold:
                    continue
                inner[j] = {
                    "type": "text",
                    "text": f"[tool result aged — {len(text)} chars, see newer turns]",
                }


def _strip_data_urls(raw: str) -> str:
    """Best-effort: collapse base64 image payloads in arbitrary string output
    so logs and traces aren't 200KB each."""
    if "data:image/" not in raw:
        return raw
    import re
    return re.sub(r"data:image/[^,\"\\]+,[A-Za-z0-9+/=]+", "[image elided]", raw)


# Match http(s) URLs minus typical sentence-end punctuation. Conservative —
# we'd rather miss an exotic URL than false-positive on prose.
import re as _re
_URL_PATTERN = _re.compile(r"https?://[^\s\)\]\}\"'<>,]+")


def _check_for_fabricated_urls(typed_text: str, messages: list[dict[str, Any]]) -> list[str]:
    """Return any URLs in `typed_text` that don't appear in the text of
    any recent tool-result message. Empty list = all URLs trace back to
    something the agent observed; non-empty = suspect fabrication.

    We scan up to the last ~12 tool messages — long enough to cover a
    multi-step browse-then-write flow, short enough to not burn forever
    on huge runs.
    """
    urls = _URL_PATTERN.findall(typed_text or "")
    if not urls:
        return []
    seen_blob_parts: list[str] = []
    tool_count = 0
    for m in reversed(messages):
        if m.get("role") == "tool":
            seen_blob_parts.append(str(m.get("content", "")))
            tool_count += 1
            if tool_count >= 12:
                break
    seen_blob = "\n".join(seen_blob_parts)
    return [u for u in urls if u not in seen_blob]


def _to_anthropic_tools(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Build the tool list Anthropic Messages API expects.

    Mix of two shapes:
      - Custom tools (shell, applescript, accessibility, browser_extension,
        memory_*, confirm_action, i_couldnt_do_this, ...) — each has
        `{name, description, input_schema}`.
      - Anthropic's native computer use tool — schema-less:
        `{type: "computer_20251124", name: "computer", display_width_px,
          display_height_px, display_number, enable_zoom}`. Claude owns the
        schema; we implement the action handlers in tools.py.

    The custom `computer` tool defined in TOOLS (tools.py) is REPLACED by
    the native schema-less version — Claude's computer use already knows
    every action (left_click, type, key, screenshot, scroll, zoom, etc.)
    and emits coordinates directly. No more `click_element(description)`
    indirection; Claude finds pixels itself.

    Display dimensions: 1280x800 matches a typical Mac viewport at the
    docs' recommended resolution band; the real Mac's native pixels
    (often 1710x1112 or 2560x1664) get downscaled before being shown to
    the model, then click coordinates are scaled back up by tools.py
    before reaching MacOpsExecutor.
    """
    # Anthropic's native computer_20251124 tool is OFF by default. Per
    # the trace analysis of the user's Cursor command-palette test — the
    # model defaulted to pixel-clicks via the native tool even with
    # strong prompt steering to prefer accessibility.window_state. The
    # native tool's RL training biases the model toward pixel paths;
    # the only reliable way to force the model down the tier ladder is
    # to remove the affordance entirely. Re-enable with
    # KLO_USE_NATIVE_COMPUTER=1 if a specific run needs it.
    use_native = os.environ.get("KLO_USE_NATIVE_COMPUTER", "0") == "1"
    out: list[dict[str, Any]] = []
    if use_native:
        out.append({
            "type": "computer_20251124",
            "name": "computer",
            "display_width_px": int(os.environ.get("KLO_CU_DISPLAY_WIDTH", "1280")),
            "display_height_px": int(os.environ.get("KLO_CU_DISPLAY_HEIGHT", "800")),
            "display_number": 1,
            "enable_zoom": os.environ.get("KLO_CU_ENABLE_ZOOM", "0") == "1",
        })
    for t in tools:
        # When native is on, klo's custom `computer` is skipped (Anthropic
        # owns that slot). When native is off (default), the custom one is
        # the only computer-tier path the model sees.
        if use_native and t.get("name") == "computer":
            continue
        out.append({
            "name": t["name"],
            "description": t["description"],
            "input_schema": t["input_schema"],
        })
    # Cache breakpoint on the LAST tool — Anthropic prompt caching is
    # positional. Cache covers everything before the breakpoint.
    if out and out[-1].get("type") != "computer_20251124":
        out[-1] = {**out[-1], "cache_control": {"type": "ephemeral"}}
    return out


class Agent:
    def __init__(
        self,
        model: str = MODEL_DEFAULT,
        max_turns: int = MAX_TURNS_DEFAULT,
        verbose: bool = True,
        on_event=None,  # async callable taking a TraceEvent — fires live as events happen
        on_request_confirm=None,  # async callable taking the confirm_action args dict, returning {approved: bool}
        on_user_interrupt=None,  # async callable () -> {"cancel": bool, "messages": [user-role dicts]} — polled at each turn boundary
        on_check_paused=None,    # async callable () -> bool — when True, the loop sleeps + polls instead of making a model call
        on_user_focus_taken=None,  # async callable () -> bool — when True, force handoff and end the run (user moved on)
        on_run_start=None,       # async callable (payload: dict) — fired once at run start. Used to push task.begin to extension.
        on_run_end=None,         # async callable (payload: dict) — fired once at run end (finally-guarded). Pushes task.end.
        disabled_tools: set[str] | None = None,  # M4 child agents pass a blocklist (memory writes, recursion, scheduling, etc.)
    ) -> None:
        # Anthropic Messages API via klo-cloud's /api/llm/anthropic proxy.
        # The Supabase access token authenticates each request; subscription
        # gating + upstream auth happen on the cloud side.
        self.client = make_anthropic_client()
        self.model = model
        self.max_turns = max_turns
        self.verbose = verbose
        self.on_event = on_event
        # confirm_action bridge — handle the tool call inline in the
        # agent loop (NOT in tools.py's _DISPATCH) so we can block on
        # an external event registered per-run by the desktop_api
        # layer. If None, confirm_action degrades to auto-approve so
        # CLI / test paths don't hang.
        self.on_request_confirm = on_request_confirm
        # Polled at each turn boundary (after a tool_result batch lands,
        # before the next model call). Returns a dict with:
        #   "cancel": bool          — user pressed Esc on the panel
        #   "messages": list[dict]  — user-role messages to inject
        # If both are absent/false, the loop continues normally. Keeping
        # this callback-shaped (rather than threading state through) means
        # CLI runs / tests don't need to know about the Mac app's inbox.
        self.on_user_interrupt = on_user_interrupt
        # Take-over hook. When True, the agent loop sleeps 250ms and re-
        # polls instead of making a model call. The user is driving the
        # WKWebView directly (sign-in, captcha, etc.); the run is paused
        # but NOT cancelled — when the user hits HAND BACK, the loop
        # resumes from the next turn boundary with full conversation
        # history intact.
        self.on_check_paused = on_check_paused
        # Distinct from on_check_paused: takeover here means the user
        # moved on (switched tab/window away from where the agent put
        # them). Returning True forces a clean handoff and ends the run
        # — we do NOT sleep+wait. The extension wires this via the
        # bridge's _user_focus_taken flag (set by chrome.tabs.onActivated
        # / windows.onFocusChanged in background.js).
        self.on_user_focus_taken = on_user_focus_taken
        # Run-lifecycle hooks. Fired once at start, once at end (the end
        # hook is wrapped in a finally so cancel/error still surface a
        # task.end). The agent stays oblivious to the bridge — wiring
        # lives in desktop_api (in-process singleton) and run.py (CLI
        # via call_via_server). Used by the extension to track whether
        # an agent task is in flight (replaces the prior 60s idle
        # heuristic so long-running tasks behave correctly).
        self.on_run_start = on_run_start
        self.on_run_end = on_run_end
        # Hermes-five M4: a child agent (spawned by `delegate_task`)
        # gets a curated `disabled_tools` blocklist so it can't write
        # to shared state (memory_remember/forget), spawn its own
        # children (delegate_task), or schedule recurring jobs. Parent
        # agents pass None and see the full TOOLS list.
        self._disabled_tools: set[str] = set(disabled_tools or set())
        filtered_tools = (
            [t for t in TOOLS if t.get("name") not in self._disabled_tools]
            if self._disabled_tools else TOOLS
        )
        self._tool_specs = _to_anthropic_tools(filtered_tools)
        # Stuck detector: track recent (tool_name, fingerprint) calls. If the
        # last 3 are identical, inject a user-role nudge to break the loop.
        self._recent_calls: deque[tuple[str, str]] = deque(maxlen=6)
        # How many times the stuck detector has fired this run. Drives the
        # escalation ladder: 1=text nudge, 2=force a tool + stronger message,
        # 3+=synthesize honest_failure_payload and terminate. Reset in run().
        self._stuck_fires_count = 0
        # Navigate-and-show guard state. _visited_urls tracks normalized
        # URLs the model has navigated to this run; _handoff_armed flips
        # true after the first navigate so a *second* navigate to a
        # previously-visited URL triggers a soft "call handoff_to_user"
        # nudge. Both reset per-run in run().
        self._visited_urls: set[str] = set()
        self._handoff_armed: bool = False

    async def _emit(self, event: TraceEvent) -> None:
        if self.on_event is not None:
            try:
                res = self.on_event(event)
                if asyncio.iscoroutine(res):
                    await res
            except Exception:
                pass

    async def run(
        self,
        task: str,
        prior_messages: list[dict[str, Any]] | None = None,
        extra_system_notes: str | None = None,
    ) -> RunResult:
        result = RunResult(task=task, final=None, turns=0, elapsed_s=0.0)
        t0 = time.perf_counter()

        # Fire the run-start hook so the extension (via desktop_api or
        # run.py wiring) knows a task is in flight. Best-effort — a
        # failure to push task.begin shouldn't block the run, just means
        # the extension falls back to its safety timer for focus
        # detection. Same shape as on_run_end below.
        if self.on_run_start is not None:
            try:
                await self.on_run_start({"task": task})
            except Exception as exc:  # noqa: BLE001
                log.warning("on_run_start hook failed: %s", exc)

        # Clear the per-process duplicate-click guard so prior runs don't
        # bleed into this one. The guard is in tools.py (module-level
        # state, intentionally process-scoped so concurrent runs in the
        # same sidecar share it — there's only ever one active run per
        # sidecar today).
        try:
            from .tools import _reset_recent_clicks  # noqa: WPS433
            _reset_recent_clicks()
        except Exception:
            pass
        # Reset stuck-detector state so a wedge in a prior run doesn't
        # half-poison this one. The deque has its own LRU, but if the last
        # 3 entries from the prior run were identical, the first qualifying
        # call this run would trip the detector incorrectly.
        self._recent_calls.clear()
        self._stuck_fires_count = 0
        # Web-specific stuck counter — reset per-run.
        self._web_noprogress_count = 0
        self._web_redirect_fired = False
        # Navigate-and-show guard state — reset per-run.
        self._visited_urls.clear()
        self._handoff_armed = False

        # Pull stored memory and append to the system prompt so the agent has
        # continuity across runs. After the first call this whole prefix is
        # cached, so the cost is essentially the memory size's first-use only.
        try:
            from . import memory as _mem
            mem_block = await _mem.format_for_system_prompt()
        except Exception:
            mem_block = ""

        # Pull the user's Composio connected_toolkits from klo-cloud's
        # /auth/me cache. We inject a CONNECTED SERVICES block only when
        # the user has connected at least one toolkit — so the system
        # prompt stays byte-identical (and therefore prompt-cache-warm)
        # for the majority of users who haven't connected anything yet.
        try:
            connected_block = await _format_connected_services()
        except Exception:
            connected_block = ""

        # Hermes-five M3 — append the user's curated skills (markdown
        # files at ~/.agent2/skills/*.md, mirrored to klo-cloud). Empty
        # string when there are no skills, keeping prompt cache warm
        # for users who haven't accumulated any yet.
        try:
            from . import skills as _skills
            skills_block = _skills.format_for_system_prompt()
        except Exception:
            skills_block = ""

        # Hermes-five M5 — append klo-cloud's derived user_model
        # ("# Things klo knows about you"). Cached for 5min so we
        # don't hit /user_model on every turn within a session.
        try:
            from . import cloud_user_model as _cum
            user_model = await _cum.fetch_user_model()
            user_model_block = _cum.format_for_system_prompt(user_model)
        except Exception:
            user_model_block = ""

        # Today's date, in the user's local timezone (this process runs
        # on the user's Mac). Without this anchor the model falls back
        # to its training cutoff for time-relative reasoning, so "what's
        # the next tennis match" returns events from weeks ago — they
        # look "upcoming" from the cutoff's vantage. Appended after the
        # static SYSTEM_PROMPT so we don't have to rewrite prompts.py
        # to inject a value; positioned ahead of mem/skills/etc. so the
        # model sees it before any user-shaped context that might
        # mention dates.
        from datetime import datetime as _dt  # noqa: WPS433
        _now = _dt.now().astimezone()
        date_block = (
            f"\n\nCURRENT DATE: {_now.strftime('%A, %B %-d, %Y')}. "
            f"LOCAL TIME: {_now.strftime('%H:%M %Z')}.\n"
            "Anchor every time-relative reference (\"today\", \"this week\", "
            "\"upcoming\", \"next\", \"recent\") on this date. Your training "
            "cutoff is NOT the current date — trust this value over anything "
            "you remember about \"recent\" events.\n"
        )

        # Two-tier system prompt: SYSTEM_PROMPT is the stable tier and
        # gets its own cached block. Everything user/session/turn-
        # specific (date, memory, connected services, skills, derived
        # user model, current-context snapshot, per-call notes) goes
        # into a SECOND, uncached block so it can change every turn
        # without invalidating the 40k-token cached prefix.
        # Pre-refactor: ALL of these were concatenated into one cached
        # string, so the cache survived only for users with empty
        # memory + no services + no skills — i.e., never, past turn 1.
        volatile_text = (
            date_block
            + (mem_block if mem_block else "")
            + (connected_block if connected_block else "")
            + (("\n\n" + skills_block) if skills_block else "")
            + (("\n\n" + user_model_block) if user_model_block else "")
        )
        if extra_system_notes:
            volatile_text += extra_system_notes

        # Snapshot current OS focus so the agent grounds its first action
        # in what the user is actually looking at.
        try:
            ctx = await _current_context()
        except Exception:
            ctx = {}
        # Augment with runtime-discovered defaults (no hardcoding):
        #   - the user's actual default browser, via LaunchServices
        #   - the user's recent-app history, via ActiveAppTracker
        # Both are user-agnostic: they ask the OS what's true on THIS Mac.
        try:
            from api.core.defaults import default_browser_info  # noqa: WPS433
            default_browser = default_browser_info() or {}
        except Exception:
            default_browser = {}
        try:
            from .active_apps import tracker as _tracker  # noqa: WPS433
            recent_apps = _tracker().history(limit=5)
        except Exception:
            recent_apps = []
        # Probe the in-process Chrome-extension bridge so the model knows
        # whether to reach for the fast DOM path (browser_extension) or
        # the universal AX path (accessibility) on the first turn. The
        # KLO_FORCE_NO_EXTENSION env var lets devs verify the AX-only
        # behaviour without unplugging the actual extension.
        extension_connected = False
        try:
            from .bridge import bridge as _bridge_singleton  # noqa: WPS433
            extension_connected = bool(_bridge_singleton.connected)
        except Exception:
            extension_connected = False
        if os.environ.get("KLO_FORCE_NO_EXTENSION", "0") == "1":
            extension_connected = False

        if ctx.get("frontmost_app") or default_browser or recent_apps:
            ctx_lines: list[str] = []
            if ctx.get("frontmost_app"):
                ctx_lines.append(f"  - frontmost app: {ctx['frontmost_app']}")
            if ctx.get("window_title"):
                ctx_lines.append(f"  - window title: {ctx['window_title']}")
            if default_browser.get("name"):
                bid = default_browser.get("bundle_id") or ""
                ctx_lines.append(
                    f"  - default browser: {default_browser['name']}"
                    + (f" (bundle {bid})" if bid else "")
                )
            if recent_apps:
                summary = ", ".join(
                    f"{r['name']}" for r in recent_apps if r.get("name")
                )
                ctx_lines.append(f"  - recent apps (most-recent first): {summary}")
            # Extension status drives the web-task tier hierarchy below.
            # The prompt teaches: connected → prefer browser_extension;
            # not connected → use accessibility for the same browser.
            ctx_lines.append(
                f"  - chrome extension: {'connected' if extension_connected else 'NOT CONNECTED'}"
            )
            ctx_lines.append(
                "  - drive web tasks via the BROWSER + WEB SURFACE tiers — "
                "`shell open -a \"<default browser name>\" \"<url>\"` for "
                "navigation, accessibility tool for DOM interaction. The "
                "accessibility walker auto-targets your most-recent non-klo "
                "app and auto-enriches the AX tree, so you typically don't "
                "need to pass target_app — but you CAN to be deterministic."
            )
            volatile_text += (
                "\n\nCURRENT CONTEXT (the user's screen state right now, "
                "for grounding your actions):\n" + "\n".join(ctx_lines)
            )

        # Ambient running-apps inventory. The model needs to know what
        # the user has on their screen RIGHT NOW so it can route the
        # task to the right app. Users multitask — they're coding in
        # Cursor while Messages has Emily's chat open and Mail shows
        # the inbox. "Text emily" means "use Messages, the one I have
        # open." Without this, the model treats every prompt as if the
        # user was looking at one app and asks for clarification.
        #
        # The inventory is rebuilt every turn (cheap — CGWindowList
        # call is microseconds). klo-cloud's proxy parses the marker
        # and replaces with a formatted CURRENT CONTEXT block. The
        # sidecar stays dumb; format/filter rules iterate server-side.
        ambient_block_text: str | None = None
        # TEMP DEBUG (remove after diagnosing): file-based trace that
        # bypasses the logger entirely, so we can see what's happening
        # in this code path without relying on syslog routing.
        def _ambient_debug(msg: str) -> None:
            try:
                with open("/tmp/klo-ambient-debug.log", "a") as _f:
                    _f.write(f"{time.time():.3f} {msg}\n")
            except Exception:  # noqa: BLE001
                pass
        _ambient_debug("ENTER ambient block")
        try:
            inventory = _build_running_apps_inventory()
            if inventory and inventory.get("apps"):
                _ambient_debug(
                    f"inventory built: {len(inventory['apps'])} apps "
                    + ", ".join(f"{a['name']}({a.get('category') or '?'})" for a in inventory['apps'][:8])
                )
                ambient_block_text = (
                    "<klo-ambient-context>\n"
                    + json.dumps(inventory, ensure_ascii=False)
                    + "\n</klo-ambient-context>"
                )
            else:
                _ambient_debug("inventory empty — no on-screen non-klo windows")
        except Exception as _amb_exc:  # noqa: BLE001
            _ambient_debug(f"inventory error: {_amb_exc}")
            log.warning("ambient: inventory build failed (%s); proceeding without it", _amb_exc)
            ambient_block_text = None

        # System is a TOP-LEVEL parameter in Anthropic Messages, not a
        # message. Two blocks:
        #   1. SYSTEM_PROMPT — stable across all turns + all users with
        #      the same prompt version. cache_control: ephemeral makes
        #      Anthropic cache it and serve cache_read on every
        #      subsequent turn (and every user that follows).
        #   2. volatile_text — date, memory, connected services, skills,
        #      derived user model, current-context snapshot, per-call
        #      notes. No cache_control: changes per turn and per user,
        #      and importantly doesn't invalidate block 1's cache.
        #   3. ambient_block_text (optional) — tagged AX-tree payload.
        #      klo-cloud rewrites this into a curated CURRENT CONTEXT
        #      block before forwarding to Anthropic. Sits AFTER block 1
        #      so its presence/absence per turn doesn't invalidate the
        #      block 0 cache.
        system_blocks: list[dict[str, Any]] = [{
            "type": "text",
            "text": SYSTEM_PROMPT,
            "cache_control": {"type": "ephemeral"},
        }]
        if volatile_text.strip():
            system_blocks.append({
                "type": "text",
                "text": volatile_text,
            })
        if ambient_block_text:
            system_blocks.append({
                "type": "text",
                "text": ambient_block_text,
            })

        # Messages list: user + assistant only. Tool results live INSIDE
        # user content as `tool_result` blocks (typed-block content).
        messages: list[dict[str, Any]] = []
        if prior_messages:
            cleaned = [
                {"role": m["role"], "content": m["content"].strip()}
                for m in prior_messages[-12:]
                if m.get("role") in ("user", "assistant")
                and isinstance(m.get("content"), str)
                and m["content"].strip()
            ]
            # Seal unanswered prior user turns. A run that hung or got
            # force-quit leaves a user message with no assistant reply;
            # shipped as-is the model reads it as a still-open request
            # and re-executes it INSTEAD of the new task (observed:
            # an interrupted YouTube lookup re-ran on every subsequent
            # prompt until the app restarted). A synthetic assistant
            # turn marks those exchanges closed.
            interrupted_note = (
                "(That request was interrupted and is NO longer pending. "
                "Do not attempt it again unless the user asks again.)"
            )
            for i, m in enumerate(cleaned):
                messages.append(m)
                next_role = cleaned[i + 1]["role"] if i + 1 < len(cleaned) else "user"
                if m["role"] == "user" and next_role == "user":
                    messages.append({"role": "assistant", "content": interrupted_note})
        messages.append({"role": "user", "content": task})

        # Preamble-bail guard state. When `force_tool_use` is set, the
        # NEXT model call passes tool_choice={"type":"any"} — forcing
        # the model to call a tool after a turn-0 narration bail.
        # One-shot per run.
        force_tool_use: bool = False
        forced_retry_used = False
        # Budget-pressure one-shot flags (see BUDGET_PRESSURE_*_PCT).
        budget_pressure_soft_fired = False
        budget_pressure_hard_fired = False
        for turn in range(self.max_turns):
            tool_choice = {"type": "any"} if force_tool_use else {"type": "auto"}
            force_tool_use = False  # consume single-use override
            # Retry transient 429 / 529 / overloaded / timeout once with a
            # short backoff before surfacing an error. Same pattern as
            # before; classifier handles both OpenAI and Anthropic shapes.
            attempt_exc: BaseException | None = None
            resp = None
            # ── LIVE TRACE DUMP ─────────────────────────────────────────────
            # Per-turn request snapshot to /tmp/klo-live-trace.log so we can
            # tail it during dev and see exactly what the model gets. No-op
            # in prod — just keeps a rolling local file. Remove this block
            # when we're done debugging ambient context.
            try:
                _trace_lines = []
                _trace_lines.append(f"\n===== TURN {turn} @ {time.time():.3f} =====")
                _trace_lines.append(f"system_blocks: {len(system_blocks)} blocks")
                for _i, _b in enumerate(system_blocks):
                    _t = _b.get("text", "") if isinstance(_b, dict) else str(_b)
                    _cc = _b.get("cache_control") if isinstance(_b, dict) else None
                    _trace_lines.append(f"  [{_i}] cache={_cc} len={len(_t)} preview={_t[:160]!r}")
                _tool_names = [
                    (t.get("name") or t.get("type") or "?") if isinstance(t, dict) else "?"
                    for t in (self._tool_specs or [])
                ]
                _trace_lines.append(f"tools: {_tool_names}")
                if messages:
                    _last = messages[-1]
                    _trace_lines.append(f"last_msg: role={_last.get('role')} content_preview={str(_last.get('content'))[:300]!r}")
                with open("/tmp/klo-live-trace.log", "a") as _tf:
                    _tf.write("\n".join(_trace_lines) + "\n")
            except Exception:  # noqa: BLE001
                pass
            for attempt in range(3):
                try:
                    resp = await self.client.beta.messages.create(
                        model=self.model,
                        max_tokens=4096,
                        system=system_blocks,
                        messages=messages,
                        tools=self._tool_specs,
                        tool_choice=tool_choice,
                        betas=[COMPUTER_USE_BETA],
                    )
                    # Also log the response shape (tool calls vs text)
                    try:
                        _content = getattr(resp, "content", None) or []
                        _resp_lines = [f"--- RESP @ {time.time():.3f} stop={getattr(resp, 'stop_reason', '?')} ---"]
                        for _block in _content:
                            _kind = getattr(_block, "type", "?")
                            if _kind == "tool_use":
                                _tn = getattr(_block, "name", "?")
                                _ti = getattr(_block, "input", {})
                                _resp_lines.append(f"  tool_use: {_tn}({str(_ti)[:200]})")
                            elif _kind == "text":
                                _tx = getattr(_block, "text", "")
                                _resp_lines.append(f"  text: {_tx[:300]!r}")
                            else:
                                _resp_lines.append(f"  {_kind}: ?")
                        with open("/tmp/klo-live-trace.log", "a") as _tf:
                            _tf.write("\n".join(_resp_lines) + "\n")
                    except Exception:  # noqa: BLE001
                        pass
                    attempt_exc = None
                    break
                except Exception as exc:  # noqa: BLE001
                    attempt_exc = exc
                    code = _classify_run_error(exc)
                    if code == "auth_expired" and attempt < 2:
                        log.warning(
                            "model call auth_expired — rebuilding client + retrying (attempt %d/3)",
                            attempt + 2,
                        )
                        try:
                            self.client = make_anthropic_client()
                        except Exception as rebuild_exc:  # noqa: BLE001
                            log.warning("client rebuild failed: %s", rebuild_exc)
                            break
                        await asyncio.sleep(0.5)
                        continue
                    if code in {"upstream_overloaded", "upstream_timeout"} and attempt < 2:
                        backoff = 0.75 * (2 ** attempt)  # 0.75s, 1.5s
                        log.warning(
                            "model call %s — retrying in %.2fs (attempt %d/3)",
                            code, backoff, attempt + 2,
                        )
                        await asyncio.sleep(backoff)
                        continue
                    break
            if attempt_exc is not None:
                log.exception("model call failed", exc_info=attempt_exc)
                result.error = _classify_run_error(attempt_exc)
                break

            usage = getattr(resp, "usage", None)
            if usage is not None:
                # Anthropic surfaces input/output and cache stats separately.
                result.input_tokens += getattr(usage, "input_tokens", 0) or 0
                result.output_tokens += getattr(usage, "output_tokens", 0) or 0
                cache_read = getattr(usage, "cache_read_input_tokens", 0) or 0
                cache_create = getattr(usage, "cache_creation_input_tokens", 0) or 0
                result.cached_input_tokens += cache_read
                if self.verbose and (cache_read or cache_create):
                    print(f"            cache: read={cache_read} create={cache_create}")

            # Recompute cost after each model turn. Soft-warn at the
            # configured threshold (one-shot), hard-stop above the cap.
            result.estimated_cost_usd = _estimate_cost_usd(result, model=self.model)
            if (result.estimated_cost_usd >= BUDGET_HARD_STOP_USD
                    and not os.environ.get("KLO_BUDGET_OVERRIDE")):
                result.error = (
                    f"budget hard-stop: ${result.estimated_cost_usd:.2f} ≥ "
                    f"${BUDGET_HARD_STOP_USD:.2f}. Set KLO_BUDGET_OVERRIDE=1 "
                    f"to disable. Increase KLO_BUDGET_HARD_STOP to raise the cap."
                )
                if self.verbose:
                    print(f"  [{time.perf_counter() - t0:5.1f}s] BUDGET HARD-STOP: {result.error}")
                break
            if (result.estimated_cost_usd >= BUDGET_SOFT_WARN_USD
                    and not result.budget_warning):
                result.budget_warning = (
                    f"running cost ${result.estimated_cost_usd:.2f} crossed soft-warn "
                    f"threshold ${BUDGET_SOFT_WARN_USD:.2f}"
                )
                ev = TraceEvent(
                    ts=time.perf_counter() - t0, kind="budget_warning",
                    payload={"cost_usd": round(result.estimated_cost_usd, 4),
                             "threshold_usd": BUDGET_SOFT_WARN_USD},
                )
                result.trace.append(ev)
                await self._emit(ev)

            # Anthropic returns content as a list of typed blocks. Pull
            # out the text + tool_use blocks separately, then preserve
            # the FULL list verbatim when appending the assistant message
            # so the next API call gets exactly what Claude emitted
            # (preserves any thinking blocks, etc.).
            content_blocks = list(getattr(resp, "content", []) or [])
            text = "".join(
                getattr(b, "text", "") for b in content_blocks
                if getattr(b, "type", "") == "text"
            )
            tool_use_blocks = [
                b for b in content_blocks if getattr(b, "type", "") == "tool_use"
            ]

            if text:
                ev = TraceEvent(ts=time.perf_counter() - t0, kind="thought", payload={"text": text[:200]})
                result.trace.append(ev)
                await self._emit(ev)
                if self.verbose:
                    print(f"  [{time.perf_counter() - t0:5.1f}s] thought: {text[:160]}")
                # Mid-run text accompanied by tool_use is a "progress"
                # utterance — surface so the host can speak it before tools run.
                if tool_use_blocks:
                    prog_ev = TraceEvent(
                        ts=time.perf_counter() - t0, kind="progress",
                        payload={"text": text},
                    )
                    result.trace.append(prog_ev)
                    await self._emit(prog_ev)

            # Rebuild the assistant message's content list from the SDK
            # blocks so it round-trips cleanly on the next call. Anthropic
            # requires every tool_use to be followed by a matching
            # tool_result in the next user message — preserving the full
            # block list (rather than re-stringifying text) keeps the
            # IDs intact.
            assistant_content: list[dict[str, Any]] = []
            for b in content_blocks:
                bt = getattr(b, "type", "")
                if bt == "text":
                    assistant_content.append({"type": "text", "text": getattr(b, "text", "") or ""})
                elif bt == "tool_use":
                    assistant_content.append({
                        "type": "tool_use",
                        "id": b.id,
                        "name": b.name,
                        "input": b.input or {},
                    })
                # Other block types (thinking, image, etc.) — pass through
                # using model_dump if available so we don't lose them.
                elif hasattr(b, "model_dump"):
                    try:
                        assistant_content.append(b.model_dump(exclude_none=True))
                    except Exception:
                        pass
            messages.append({"role": "assistant", "content": assistant_content})

            if not tool_use_blocks:
                # Preamble-bail guard. Highest priority: catch the model
                # narrating intent ("I'll look up John Smith…") on turn 0
                # without calling a single tool. Without this, the loop
                # accepts that text as the run's final answer and the
                # user sees "you need to do this yourself" instead of
                # the actual task being done. Mirrors the chrome chat
                # path's hardwired tool_choice="any", but as a one-shot
                # corrective so we don't burn turns on a model that
                # genuinely has nothing to do.
                if not forced_retry_used and _detect_preamble_bail(text, result.trace, turn):
                    if self.verbose:
                        print(
                            f"  [{time.perf_counter() - t0:5.1f}s] preamble bail intercepted "
                            f"(text={text[:80]!r}) — re-firing with tool_choice=any"
                        )
                    forced_retry_used = True
                    # Drop the bail assistant message so the model doesn't
                    # see its own preamble as 'already answered.'
                    messages.pop()
                    force_tool_use = True
                    # Don't increment turn — this is a corrective retry,
                    # not a real turn. But the for-loop's `range` already
                    # advances; for max_turns purposes one preamble bail
                    # costs one turn of budget. Acceptable; max_turns is
                    # generous (~30) and this fires at most once per run.
                    continue
                # Natural end — model returned text only. Before we accept
                # it as the run's final, screen for the prose-refusal anti-
                # pattern: the model bailing on a TCC-gated task by saying
                # "I can't / I don't have permission..." instead of trying
                # the relevant tool. The model has a stubborn prior toward
                # this even with explicit anti-pattern guidance in the
                # system prompt. When detected AND no gated tool was
                # actually attempted this run, we suppress the final and
                # flag the run for the orchestrator-routed grant flow.
                refusal_service = _detect_prose_refusal(text, result.trace)
                if refusal_service is not None:
                    if self.verbose:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] prose refusal intercepted (service={refusal_service}) — suppressing final, routing to grant flow")
                    result.permission_refusal_service = refusal_service
                    # Leave result.final as None so no final_message event
                    # fires. desktop_api will set state.error_code +
                    # permission_service from result.permission_refusal_service
                    # and the Mac app's AgentClient routes to the
                    # PermissionGrantOrchestrator.
                    result.turns = turn + 1
                    break
                # Guarantee a non-empty final so the desktop_api emits a
                # `final_message` event (its guard at line ~659 skips on
                # falsy result.final). Without this, when the model
                # returns empty text on the closing turn — common after
                # a successful side-effect-only action like writing to
                # Notes — the Mac client never receives the completion
                # signal and the working-state UI stays up forever.
                result.final = text or "(done)"
                result.turns = turn + 1
                break

            honest_failure_payload: dict[str, Any] | None = None
            stuck_intervention_fired = False
            # Set true when the model called handoff_to_user this turn.
            # Breaks both the per-tool inner loop and the outer turn loop
            # so the run ends cleanly with the model's final message.
            handoff_break = False
            # Hard short-circuit for TCC permission denials. The model has
            # a strong prior toward "explain in prose what you couldn't
            # do" that no amount of prompt-anti-pattern guidance has been
            # able to fully overrule. So we don't let the model see the
            # permission_denied tool result at all — we terminate the run
            # here. desktop_api's on_event has already captured error_code
            # + permission_service into the run state, which the run
            # runner surfaces in the terminal status_change event. The
            # Mac app's AgentClient picks that up and routes to
            # PermissionGrantOrchestrator (Settings deep-link +
            # instruction card + auto-retry). The user sees the grant
            # flow instead of a refusal sentence.
            permission_denied_hit: bool = False
            # Anthropic Messages: collect tool_result blocks; they all go
            # into ONE user message after the for-loop. Images live INSIDE
            # the tool_result.content (typed-block content), so the
            # OpenAI-era deferred_user_messages hack is gone — the only
            # thing we still defer is the fabrication-warning text, since
            # that's a separate user text after the tool batch.
            tool_result_blocks: list[dict[str, Any]] = []
            deferred_user_messages: list[dict[str, Any]] = []
            for tu in tool_use_blocks:
                name = tu.name
                args = tu.input or {}
                if not isinstance(args, dict):
                    args = {}
                tu_id = tu.id
                # Stuck detector: track this call's fingerprint. If the last
                # 3 calls (this one included) are all identical and not
                # exempt, fire the intervention once at the end of this turn.
                fp = _fingerprint(name, args)
                if fp[0] != "__exempt__":
                    self._recent_calls.append(fp)
                    last_three = list(self._recent_calls)[-3:]
                    if len(last_three) == 3 and len(set(last_three)) == 1 and not stuck_intervention_fired:
                        stuck_intervention_fired = True
                if self.verbose:
                    print(f"  [{time.perf_counter() - t0:5.1f}s] → {name} {json.dumps(args)[:160]}")
                call_ev = TraceEvent(
                    ts=time.perf_counter() - t0, kind="tool_call",
                    payload={"name": name, "args": args},
                )
                result.trace.append(call_ev)
                await self._emit(call_ev)
                # confirm_action is handled inline so we can block on a
                # per-run asyncio.Event without imposing the host bridge
                # on every tool. Falls through to the user-bridge
                # callback wired by desktop_api._run_agent. Absent that
                # bridge (CLI / test paths), auto-approve so headless
                # runs don't hang waiting for a user that isn't there.
                if name == "confirm_action":
                    if self.on_request_confirm is not None:
                        try:
                            decision = await self.on_request_confirm(args)
                        except Exception as exc:  # noqa: BLE001
                            decision = {"approved": False, "reason": f"bridge error: {exc}"}
                    else:
                        decision = {"approved": True, "reason": "no confirm bridge — auto-approved"}
                    output = json.dumps(decision, ensure_ascii=False)
                else:
                    output = await dispatch(name, args)
                # Strip embedded data_urls before logging — they're huge.
                preview_output = _strip_data_urls(output)
                if self.verbose:
                    preview = preview_output[:160].replace("\n", " ⏎ ")
                    print(f"            ↳ {preview}")
                result_ev = TraceEvent(
                    ts=time.perf_counter() - t0, kind="tool_result",
                    payload={"text": preview_output[:800]},
                )
                result.trace.append(result_ev)
                await self._emit(result_ev)
                # Split tool output: text + optional inline image data_url.
                tool_text, image_payload = _split_tool_output(output)

                # Build the tool_result block. Anthropic accepts mixed
                # text + image inside a single tool_result.content list.
                tr_content: list[dict[str, Any]] = []
                if tool_text:
                    tr_content.append({"type": "text", "text": tool_text})
                if image_payload is not None:
                    media_type, b64_data = _parse_data_url(image_payload)
                    if b64_data:
                        tr_content.append({
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media_type,
                                "data": b64_data,
                            },
                        })
                        if self.verbose:
                            print(f"            ↳ [forwarded screenshot to model — {len(image_payload)} chars]")
                if not tr_content:
                    # Anthropic requires non-empty tool_result.content.
                    tr_content = [{"type": "text", "text": "(no output)"}]
                tool_result_blocks.append({
                    "type": "tool_result",
                    "tool_use_id": tu_id,
                    "content": tr_content,
                })

                # Explicit handoff to user. The model has signalled "I'm
                # done — over to you" via the dedicated tool. Set result.final
                # to the message arg (NOT the tool's JSON output), flag
                # handoff_break so the outer turn loop exits after this turn's
                # tool_result batch is flushed. We do NOT skip the rest of the
                # per-tool loop body — tool_result is already appended above
                # so the Anthropic tool_use/tool_result contract holds. We
                # also do NOT break the inner for-loop early; if the model
                # emitted other tools in the same turn we still record them.
                # handoff_break is the terminal flag, checked after the loop.
                if name == "handoff_to_user":
                    msg = str(args.get("message") or "").strip() or "(handoff)"
                    result.final = msg
                    result.handoff = True
                    result.handoff_message = msg
                    handoff_ev = TraceEvent(
                        ts=time.perf_counter() - t0, kind="handoff_to_user",
                        payload={"message": msg, "next_steps": list(args.get("next_steps") or [])},
                    )
                    result.trace.append(handoff_ev)
                    await self._emit(handoff_ev)
                    handoff_break = True
                    if self.verbose:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] [handoff_to_user] {msg[:120]}")

                # Navigate-and-show guard: nudge the model toward handoff
                # when it tries to re-navigate to a URL we already visited
                # this run. Soft signal (advisory user-role message) — never
                # blocks the call. _handoff_armed flips on the FIRST nav so
                # the very first one isn't flagged. Covers both `web` (the
                # default web tool that routes through the extension bridge)
                # and `browser_extension` (opt-in via env var). action shapes
                # are normalized — web uses "open", browser_extension uses
                # "tabs_navigate" / "tabs_create".
                is_web_nav = (name == "web" and isinstance(args, dict)
                              and args.get("action") == "open")
                is_ext_nav = (name == "browser_extension" and isinstance(args, dict)
                              and args.get("action") in {"tabs_navigate", "tabs_create"})
                if is_web_nav or is_ext_nav:
                    raw_url = str(args.get("url") or "").strip()
                    nav_url = raw_url.rstrip("/")
                    if nav_url:
                        if nav_url in self._visited_urls and self._handoff_armed:
                            deferred_user_messages.append({"role": "user", "content": (
                                f"GUARD: you already navigated to {raw_url} this run. "
                                "The user asked you to TAKE THEM there, not to bounce them "
                                "around. Call handoff_to_user(message=...) now with what they "
                                "should do on the page, then stop. Do not navigate again."
                            )})
                            if self.verbose:
                                print(f"  [{time.perf_counter() - t0:5.1f}s] [renav-guard] {raw_url} → nudging handoff")
                        self._visited_urls.add(nav_url)
                        self._handoff_armed = True

                # Fabrication check (same heuristic, different placement).
                if (name == "computer"
                        and isinstance(args, dict)
                        and args.get("action") in {"type", "paste_text"}):
                    suspects = _check_for_fabricated_urls(str(args.get("text", "")), messages)
                    if suspects:
                        ev = TraceEvent(
                            ts=time.perf_counter() - t0, kind="fabrication_warning",
                            payload={"suspects": suspects[:5], "tool": "computer." + str(args.get("action"))},
                        )
                        result.trace.append(ev)
                        await self._emit(ev)
                        warning_text = (
                            "FABRICATION WARNING: you just typed URL(s) that don't "
                            "appear in any recent tool result: "
                            + ", ".join(suspects[:3])
                            + ". These were almost certainly fabricated (constructed by "
                            "guessing a slug from a product name). Stop. Either fetch the "
                            "canonical URL — shell open -a the product's site to a search "
                            "URL, then read the current URL back (applescript on Safari, "
                            "or accessibility focused_snapshot on Chromium) — or remove "
                            "the URL from the output entirely. Then redo the type with the "
                            "correct content (e.g. cmd+a, delete, type again)."
                        )
                        deferred_user_messages.append({"role": "user", "content": warning_text})
                        if self.verbose:
                            print(f"  [{time.perf_counter() - t0:5.1f}s] [fabrication warning] suspects: {suspects[:3]}")

                # Web-specific stuck signal: count web tool calls that
                # didn't make progress this run. Triggers a one-shot
                # redirect to web.snapshot when the model is clearly
                # guessing selectors / text without learning. We bump
                # on:
                #   - ok=false on any web action (click, evaluate,
                #     press, fill, type — anything that should affect
                #     state)
                #   - state_changed=false on click/press/type (the
                #     click landed but didn't navigate)
                # We DON'T bump on read-only actions (text, url,
                # screenshot, snapshot) — those are how we learn,
                # not how we act.
                if name == "web" and isinstance(args, dict):
                    web_action = args.get("action", "")
                    is_actor = web_action in {"click", "press", "type", "fill", "evaluate"}
                    if is_actor:
                        tt = tool_text or ""
                        no_progress = (
                            '"ok": false' in tt
                            or '"ok":false' in tt
                            or '"state_changed": false' in tt
                            or '"state_changed":false' in tt
                        )
                        if no_progress:
                            self._web_noprogress_count = getattr(self, "_web_noprogress_count", 0) + 1
                        else:
                            self._web_noprogress_count = 0
                    # If the model called snapshot, it's making progress
                    # the smart way — reset the counter.
                    if web_action == "snapshot":
                        self._web_noprogress_count = 0

                if name == "i_couldnt_do_this":
                    try:
                        honest_failure_payload = json.loads(tool_text)
                    except json.JSONDecodeError:
                        honest_failure_payload = {"reason": str(args.get("reason", ""))}

                # Permission-denied short-circuit. tool result JSON
                # carries `"error_code": "permission_denied"` when the
                # Mac-side preflight rejected the op. Detect cheaply via
                # substring; outer loop breaks BEFORE handing the result
                # back to the model so it can't compose a prose refusal.
                if '"error_code"' in tool_text and "permission_denied" in tool_text:
                    permission_denied_hit = True

            # All tool_results in ONE user message — Anthropic requires
            # each tool_use in the prior assistant message to have a
            # corresponding tool_result.
            messages.append({"role": "user", "content": tool_result_blocks})

            # Hermes-style budget pressure. After tool_results land, the
            # NEXT model call sees this conversation. If we're crossing
            # 70%/90% of the turn budget, inject a user-role nudge so the
            # model knows to consolidate before getting cut off. One-shot
            # per threshold per run — we don't keep nagging.
            if self.max_turns > 0 and not handoff_break:
                next_turn = turn + 1
                pct = next_turn / self.max_turns
                if pct >= BUDGET_PRESSURE_HARD_PCT and not budget_pressure_hard_fired:
                    budget_pressure_hard_fired = True
                    remaining = max(0, self.max_turns - next_turn)
                    messages.append({
                        "role": "user",
                        "content": (
                            f"[KLO BUDGET WARNING: {next_turn}/{self.max_turns} turns used — "
                            f"only {remaining} left. Wrap up NOW: finalize what you can, "
                            f"summarize what's incomplete, and stop calling tools.]"
                        ),
                    })
                    ev = TraceEvent(
                        ts=time.perf_counter() - t0, kind="budget_pressure",
                        payload={"level": "hard", "turn": next_turn,
                                 "max_turns": self.max_turns, "pct": round(pct, 2)},
                    )
                    result.trace.append(ev)
                    await self._emit(ev)
                    if self.verbose:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] [budget] HARD pressure: {next_turn}/{self.max_turns}")
                elif pct >= BUDGET_PRESSURE_SOFT_PCT and not (
                        budget_pressure_soft_fired or budget_pressure_hard_fired):
                    budget_pressure_soft_fired = True
                    remaining = max(0, self.max_turns - next_turn)
                    messages.append({
                        "role": "user",
                        "content": (
                            f"[KLO BUDGET: {next_turn}/{self.max_turns} turns used, "
                            f"{remaining} left. Start consolidating — finish your current "
                            f"step, then summarize. Don't start new exploratory work.]"
                        ),
                    })
                    ev = TraceEvent(
                        ts=time.perf_counter() - t0, kind="budget_pressure",
                        payload={"level": "soft", "turn": next_turn,
                                 "max_turns": self.max_turns, "pct": round(pct, 2)},
                    )
                    result.trace.append(ev)
                    await self._emit(ev)
                    if self.verbose:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] [budget] soft pressure: {next_turn}/{self.max_turns}")

            # Any extra user-role nudges (fabrication warnings) go after
            # the tool_result batch.
            for msg in deferred_user_messages:
                messages.append(msg)

            # Handoff terminator. tool_result is now appended so the
            # Anthropic contract is honored; end the run cleanly.
            if handoff_break:
                result.turns = turn + 1
                break

            # Web-stuck redirect. Fires ONCE per run when 3+ consecutive
            # web action calls (click/press/type/fill/evaluate) returned
            # ok=false OR state_changed=false. Hard-redirects the model
            # away from the text-guessing path toward the snapshot+press
            # path which is far more reliable on heavy SPAs.
            if (getattr(self, "_web_noprogress_count", 0) >= 3
                    and not getattr(self, "_web_redirect_fired", False)):
                self._web_redirect_fired = True
                messages.append({
                    "role": "user",
                    "content": (
                        "STUCK SIGNAL: you've called 3+ consecutive web actions "
                        "without making progress (each one came back ok=false "
                        "or state_changed=false). Stop guessing selectors and "
                        "text patterns. Right now:\n"
                        "  1. Call `web.snapshot()` — returns an indexed list of "
                        "every interactive element on the page with its ARIA "
                        "role + accessible name (Playwright-style).\n"
                        "  2. Read items carefully. Pick the right idx by role+name.\n"
                        "  3. Call `web.press(idx)` or `web.fill(idx, text)`.\n"
                        "This is FAR more reliable than guessing text matches on "
                        "heavy SPAs (Google Flights, Booking, Notion, anything "
                        "Material/MUI). The accessible name uniquely identifies "
                        "each element the way a screen reader does."
                    ),
                })
                if self.verbose:
                    print(f"  [{time.perf_counter() - t0:5.1f}s] [web-stuck] redirecting to snapshot+press")

            # User-interrupt drain. Polled here — at the cleanest possible
            # breakpoint (after the tool_result batch lands, before the
            # next model call). Two paths:
            #   1. cancel=True   → break the for-turn loop with a clean
            #                       "cancelled_by_user" error. The
            #                       desktop_api layer turns this into a
            #                       cancelled status_change.
            #   2. messages=[…]  → append user-role dicts to the convo so
            #                       the next model call sees them. This is
            #                       what powers "steer" (pivot) and
            #                       "inject" (additive). The Python side
            #                       of the inbox does the steer/inject
            #                       translation; we just append.
            if self.on_user_interrupt is not None:
                try:
                    interrupt = await self.on_user_interrupt()
                except Exception:
                    interrupt = None
                if interrupt:
                    if interrupt.get("cancel"):
                        result.error = "cancelled_by_user"
                        if self.verbose:
                            print(f"  [{time.perf_counter() - t0:5.1f}s] [interrupt] user cancelled")
                        break
                    for inj in interrupt.get("messages", []):
                        messages.append(inj)
                        if self.verbose:
                            content_preview = str(inj.get("content", ""))[:80]
                            print(f"  [{time.perf_counter() - t0:5.1f}s] [interrupt] {content_preview}…")

            # Passive user-focus takeover. Distinct from on_check_paused:
            # this fires when the user has switched tab/window away from
            # where the agent put them (background.js detects the
            # tabs.onActivated / windows.onFocusChanged event and pushes
            # a `user_focus_changed` event over the bridge). Locked decision
            # is "force handoff, not pause" — emit a clean over-to-you
            # message and break the outer loop. One-shot semantics on the
            # bridge side (consume_user_focus_taken clears the flag), so
            # a brief excursion doesn't permanently poison future runs.
            if self.on_user_focus_taken is not None:
                try:
                    taken = await self.on_user_focus_taken()
                except Exception:
                    taken = False
                if taken:
                    msg = (
                        "paused — you're driving the page i opened. "
                        "say 'keep going' or hit ⌘k when you want me back."
                    )
                    result.final = msg
                    result.handoff = True
                    result.handoff_message = msg
                    ev = TraceEvent(
                        ts=time.perf_counter() - t0, kind="user_focus_takeover",
                        payload={"message": msg},
                    )
                    result.trace.append(ev)
                    await self._emit(ev)
                    result.turns = turn + 1
                    if self.verbose:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] [user-focus-takeover] forcing handoff")
                    break

            # Pause / take-over check. If the user clicked TAKE OVER on
            # the web pane, the run state's `paused` flag is True. We
            # sleep + re-poll every 250ms instead of advancing the loop.
            # Cancel still wins (Esc beats pause), and inject messages
            # queued during the pause are picked up by the next interrupt
            # poll once resumed — so the user can both take over AND
            # leave a note for klo to consider once it resumes.
            if self.on_check_paused is not None:
                paused_logged = False
                while True:
                    try:
                        is_paused = await self.on_check_paused()
                    except Exception:
                        is_paused = False
                    if not is_paused:
                        break
                    if self.verbose and not paused_logged:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] [paused] user took over — waiting for hand back")
                        paused_logged = True
                    # Honor cancel while paused — Esc must always escape.
                    if self.on_user_interrupt is not None:
                        try:
                            cmaybe = await self.on_user_interrupt()
                        except Exception:
                            cmaybe = None
                        if cmaybe and cmaybe.get("cancel"):
                            result.error = "cancelled_by_user"
                            break
                    if result.error == "cancelled_by_user":
                        break
                    await asyncio.sleep(0.25)
                if result.error == "cancelled_by_user":
                    break
                if paused_logged and self.verbose:
                    print(f"  [{time.perf_counter() - t0:5.1f}s] [resumed] hand back received")

            # Prune stale screenshots from prior turns. Keeps the freshest
            # before/after pair in attention so the model doesn't compare
            # 6 versions of "current state" and pick the wrong one.
            _prune_old_screenshots(messages, keep_last=2)
            _age_tool_result_text(messages, keep_last_n_turns=3, char_threshold=4000)

            if stuck_intervention_fired:
                # Three identical tool calls in a row — model is stuck on a
                # broken approach. Escalation ladder, indexed by how many
                # times the detector has fired THIS run:
                #   1: text nudge (existing behavior).
                #   2: stronger message + force_tool_use so the next call
                #      must commit to a tool (rather than the model trying
                #      to talk its way out via prose).
                #   3+: synthesize honest_failure_payload and terminate.
                #      Past two distinct wedges the run is unrecoverable
                #      and burning turn budget; surface a clean fail.
                # Always clear the deque so the next 3-streak measures from
                # zero, not piggy-backed on prior history.
                self._stuck_fires_count += 1
                fire_n = self._stuck_fires_count
                last_fp = list(self._recent_calls)[-1] if self._recent_calls else ("", "")
                stuck_ev = TraceEvent(
                    ts=time.perf_counter() - t0, kind="stuck_intervention",
                    payload={
                        "fire_n": fire_n,
                        "fingerprint": list(last_fp),
                        "action": (
                            "honest_failure_terminate" if fire_n >= 3
                            else "force_tool_use" if fire_n == 2
                            else "text_nudge"
                        ),
                    },
                )
                result.trace.append(stuck_ev)
                await self._emit(stuck_ev)

                if fire_n >= 3:
                    # Hard-terminate as honest failure. The next block (already
                    # below) processes honest_failure_payload and breaks the
                    # outer for-loop with result.final set. Synthesize a
                    # payload that names the wedge fingerprint as the blocker.
                    fp_name = last_fp[0] or "(unknown tool)"
                    fp_args = last_fp[1] or ""
                    honest_failure_payload = {
                        "reason": "stuck detector terminated run after repeated wedges",
                        "blocker": f"model kept retrying {fp_name} with args={fp_args[:200]} despite two prior interventions",
                        "what_i_tried": [
                            "wedged on identical tool calls 3+ times in a row",
                            "received stuck-detector text nudge — kept wedging",
                            "received forced-tool-use intervention — kept wedging",
                        ],
                    }
                    if self.verbose:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] [stuck detector fire #{fire_n} → honest_failure terminate]")
                elif fire_n == 2:
                    messages.append({
                        "role": "user",
                        "content": (
                            "STUCK DETECTOR (SECOND FIRE this run): the repeated approach is still failing. "
                            "Your next tool call must be structurally different — switch surfaces. "
                            "If you were clicking, try accessibility.actionable_index. "
                            "If you were calling AX, try shell or applescript. "
                            "If nothing else is reachable, call i_couldnt_do_this honestly with what_i_tried. "
                            "Do NOT repeat the same tool+approach again. One more wedge ends this run."
                        ),
                    })
                    force_tool_use = True
                    if self.verbose:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] [stuck detector fire #{fire_n} → force_tool_use]")
                else:
                    messages.append({
                        "role": "user",
                        "content": (
                            "STUCK DETECTOR: 3 identical tool calls in a row. "
                            "The repeated approach is not working. Stop. Pick a "
                            "structurally different approach — different "
                            "coordinates, different action, take a fresh "
                            "screenshot to re-orient — or call i_couldnt_do_this "
                            "honestly with what_i_tried. Do not retry the exact "
                            "same call again."
                        ),
                    })
                    if self.verbose:
                        print(f"  [{time.perf_counter() - t0:5.1f}s] [stuck detector fire #{fire_n} → text_nudge]")
                self._recent_calls.clear()

            if honest_failure_payload is not None:
                # Terminal honest-failure path. Render the failure as the run's final.
                reason = honest_failure_payload.get("reason", "blocked")
                tried = honest_failure_payload.get("what_i_tried") or []
                blocker = honest_failure_payload.get("blocker") or ""
                tried_str = "; ".join(tried) if isinstance(tried, list) else str(tried)
                bits = [f"[honest_failure] {reason}"]
                if blocker:
                    bits.append(f"blocker: {blocker}")
                if tried_str:
                    bits.append(f"tried: {tried_str}")
                result.final = " — ".join(bits)
                result.turns = turn + 1
                if self.verbose:
                    print(f"  [{time.perf_counter() - t0:5.1f}s] honest_failure: {result.final}")
                break

            if permission_denied_hit:
                # Terminate without giving the model another turn. result.final
                # stays None so no final_message event fires — desktop_api's
                # status_change carries error_code=permission_denied +
                # permission_service, the Mac app routes to the orchestrator,
                # the user sees the Settings deep-link + instruction card.
                # The original task auto-retries on grant.
                result.turns = turn + 1
                if self.verbose:
                    print(f"  [{time.perf_counter() - t0:5.1f}s] permission_denied — ending run silently for grant flow")
                break
        else:
            result.error = f"hit max_turns={self.max_turns}"

        result.elapsed_s = time.perf_counter() - t0
        if result.final is None and result.error is None:
            result.error = "ended without final text"

        # Fire the run-end hook AFTER result fields are finalized so the
        # extension gets the full story (handoff vs error vs natural
        # end). Best-effort. Note: we don't wrap the whole run body in
        # try/finally here — if the body raises uncaught, on_run_end
        # won't fire and the extension falls back to its safety timer.
        # That's a deliberate tradeoff to keep the change scope tight;
        # the safety timer is short enough that it doesn't pin the
        # extension state for long.
        if self.on_run_end is not None:
            try:
                await self.on_run_end({
                    "final": result.final,
                    "handoff": result.handoff,
                    "error": result.error,
                    "turns": result.turns,
                    "elapsed_s": result.elapsed_s,
                })
            except Exception as exc:  # noqa: BLE001
                log.warning("on_run_end hook failed: %s", exc)
        return result
