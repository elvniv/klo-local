"""Compat shim that lets the klo-agent-ui Electron desktop app talk to agent2.

The desktop expects a FastAPI sidecar on http://127.0.0.1:8787 with a specific
contract: POST /runs, WS /ws/runs/{id}, plus stubs for credits/usage/etc that
the dashboard polls. This server speaks that contract and proxies real run
execution to agent2.Agent.

Usage:
    uv run python -m agent2.desktop_api
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .agent import Agent, MODEL_DEFAULT, TraceEvent
from .bridge import serve as bridge_serve, bridge as bridge_singleton
from . import cloud_auth, cloud_config

import json
import errno
import os
import re


load_dotenv()
log = logging.getLogger("agent2.desktop_api")


# ── TCC-denial memory (sidecar-process lifetime) ──────────────────────
#
# When the user clicks "Don't Allow" on Apple's per-folder consent
# dialog, the shell tool's command continues to run but its stderr
# carries `Operation not permitted` against the protected path.
# AppleEvents denials show up as `not allowed to send Apple events`.
# We notice these post-hoc, bucket the path into a coarse scope name
# ("Documents", "Downloads", etc.), and stash the scope in a process-
# global set. On every subsequent agent run we inject a one-line system
# note listing the declined scopes so the model stops re-trying them —
# the user reported "kept granting and it kept reopening the same one"
# which is exactly this loop: the agent ignores the denial and walks
# the next file in the same protected folder, re-firing the dialog.
#
# Scope, not exact path: per-folder TCC is bucket-level, so refusing
# `~/Documents/foo` means `~/Documents/bar` will also be denied. We
# track scopes, not paths.

_DENIED_TCC_SCOPES: set[str] = set()

# Matches an `Operation not permitted` line carrying an absolute path.
# Captures the offending path so we can bucket it into a scope.
_TCC_OP_NOT_PERMITTED_RE = re.compile(
    r"(/[\w./~ -]+?):\s*Operation not permitted",
)

# Apple Events / Automation denial — `osascript` and CoreServices both
# emit some form of "not allowed to send Apple events".
_TCC_APPLE_EVENTS_RE = re.compile(
    r"not allowed to send Apple events",
    re.IGNORECASE,
)


def _bucket_path_to_scope(path: str) -> str | None:
    """Map a TCC-denied absolute path to a coarse scope name. Returns
    None if the path doesn't fall in a scope we track."""
    home = os.path.expanduser("~")
    p = path.strip().rstrip("/")
    # Strip the user's home prefix so the match is portable across users.
    if p.startswith(home):
        rel = p[len(home):].lstrip("/")
    else:
        rel = None
    folder_scopes = ("Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures")
    if rel is not None:
        for folder in folder_scopes:
            if rel == folder or rel.startswith(folder + "/"):
                return folder
        if rel.startswith("Library/Mobile Documents") or rel.startswith("Library/CloudStorage"):
            return "iCloud Drive"
    if p.startswith("/Volumes/"):
        return "External volumes"
    return None


# ─── Secret redaction for cloud-forwarded events ───────────────────────────
#
# When a run was initiated from iOS (cloud bridge), every event the agent
# emits is forwarded over the WS to klo-cloud, which may store it in the
# messages table and mirror it to the user's other devices. If the agent
# happens to read a file containing a PEM private key, JWT, sk-* token,
# etc. — or fills one into a webpage — that secret WILL land in cloud
# storage + cross-device fan-out unless we scrub here.
#
# Strategy: best-effort regex sweep over likely fields. False positives
# (e.g., a long hex hash in a real conversation) are acceptable; the
# event still reaches the cloud with the secret masked.
import re as _re

# PEM blocks — match the entire body between BEGIN/END markers.
_PEM_BLOCK_RE = _re.compile(
    r"-----BEGIN [A-Z ]+-----[\s\S]+?-----END [A-Z ]+-----",
    _re.MULTILINE,
)
# JWTs — three base64url segments separated by dots, ≥ 12 chars each.
_JWT_RE = _re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\b")
# OpenAI / Anthropic / generic API key prefixes.
_API_KEY_PREFIX_RE = _re.compile(
    r"\b(sk-(?:proj-)?[A-Za-z0-9_-]{20,}"
    r"|rk_(?:live|test)_[A-Za-z0-9]{20,}"
    r"|xoxb-[0-9]{8,}-[0-9]{8,}-[A-Za-z0-9]{20,}"
    r"|ghp_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,})\b",
)
# Lone long hex blob — 40+ hex chars without spaces.
_LONG_HEX_RE = _re.compile(r"\b[0-9a-fA-F]{40,}\b")
# AWS keys.
_AWS_KEY_RE = _re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b")
_REDACTED = "[redacted]"


def _redact_text(value: str) -> str:
    if not value:
        return value
    out = _PEM_BLOCK_RE.sub(_REDACTED, value)
    out = _JWT_RE.sub(_REDACTED, out)
    out = _API_KEY_PREFIX_RE.sub(_REDACTED, out)
    out = _AWS_KEY_RE.sub(_REDACTED, out)
    out = _LONG_HEX_RE.sub(_REDACTED, out)
    return out


def _redact_payload(payload: Any) -> Any:
    """Recursively scrub strings inside a tool payload."""
    if isinstance(payload, str):
        return _redact_text(payload)
    if isinstance(payload, dict):
        return {k: _redact_payload(v) for k, v in payload.items()}
    if isinstance(payload, list):
        return [_redact_payload(v) for v in payload]
    return payload


def _redact_event_for_cloud(event: dict[str, Any]) -> dict[str, Any]:
    """Return a shallow-copied event with secret-shaped strings scrubbed.
    The original event dict is not mutated."""
    redacted: dict[str, Any] = dict(event)
    if "payload" in redacted:
        redacted["payload"] = _redact_payload(redacted["payload"])
    return redacted


def _detect_tcc_denials(tool_result_text: str) -> set[str]:
    """Scan a tool_result payload's text for TCC denial signatures.
    Returns the set of scope names denied (possibly empty)."""
    if not tool_result_text:
        return set()
    out: set[str] = set()
    for match in _TCC_OP_NOT_PERMITTED_RE.finditer(tool_result_text):
        scope = _bucket_path_to_scope(match.group(1))
        if scope is not None:
            out.add(scope)
    if _TCC_APPLE_EVENTS_RE.search(tool_result_text):
        out.add("Apple Events (Automation)")
    return out


def _denied_scopes_system_note() -> str:
    """Render the current denied-scopes set as a system-prompt addendum.
    Empty string when nothing's been denied this session."""
    if not _DENIED_TCC_SCOPES:
        return ""
    scopes = sorted(_DENIED_TCC_SCOPES)
    bullet = "\n".join(f"  - {s}" for s in scopes)
    return (
        "\n\nDECLINED THIS SESSION — macOS access the user refused. "
        "DO NOT re-try these paths; either skip them with a one-line "
        "honest acknowledgment in your final reply, or ask the user "
        "if they want to grant access before you try again:\n" + bullet
    )

app = FastAPI(title="agent2 desktop api", version="0.2.0")


# Run the chrome extension's WebSocket bridge inside this same Python process
# so killing/starting the desktop_api also handles the bridge cleanly.
_bridge_task: asyncio.Task | None = None
_cloud_config_task: asyncio.Task | None = None


# Bootstrap hosted cloud-config only when explicitly running hosted mode.
# KLO Local uses bundled defaults and never needs a network call to start.
if not cloud_auth.is_local_mode():
    cloud_config.bootstrap()


@app.on_event("startup")
async def _request_accessibility_prompt() -> None:
    # READ-ONLY accessibility check. We log whether klo currently has
    # AX trust, but we never set kAXTrustedCheckOptionPrompt=True
    # here — that fires the macOS-native modal every sidecar boot
    # (because sidecar is a fresh subprocess per app launch, macOS's
    # per-process debounce doesn't help). The Mac app's onboarding
    # flow (CloudPermissionsStep) is the SOLE owner of the prompt
    # call — fires once during onboarding alongside the explanatory
    # cloud card. The sidecar should never surface OS modals.
    try:
        import ApplicationServices as _AS  # type: ignore
        trusted = bool(_AS.AXIsProcessTrusted())
        log.info("accessibility startup check (read-only): trusted=%s", trusted)
    except Exception as exc:  # noqa: BLE001
        log.warning("accessibility check skipped (PyObjC unavailable?): %s", exc)


@app.on_event("startup")
async def _start_bridge() -> None:
    global _bridge_task
    _bridge_task = asyncio.create_task(_run_bridge_with_restart())


@app.on_event("startup")
async def _start_cloud_config_refresh() -> None:
    """Kick off the cloud-config refresh loop. Fires an immediate fetch
    on startup, then loops every KLO_CLOUD_REFRESH_SEC (default 300s).
    Bootstrap (synchronous, runs at module import above) already gave us
    a usable config — this loop just keeps it fresh."""
    global _cloud_config_task
    if cloud_auth.is_local_mode():
        return
    _cloud_config_task = asyncio.create_task(cloud_config.refresh_loop())


@app.on_event("startup")
async def _start_active_app_tracker() -> None:
    """Boot the NSWorkspace activation tracker so the AX walker and the
    agent's CURRENT CONTEXT block have authoritative recent-app data.
    Polls NSWorkspace on a background thread; no AppKit run loop needed.
    """
    try:
        from . import active_apps  # noqa: WPS433
        active_apps.tracker().start()
    except Exception as exc:  # noqa: BLE001
        log.warning("ActiveAppTracker failed to start: %s", exc)


_cloud_bridge_task: asyncio.Task | None = None


@app.on_event("startup")
async def _start_cloud_bridge() -> None:
    """Open the persistent WS to klo-cloud so the iOS companion app can
    forward runs through us. Failure to connect (user not signed in,
    network down) is non-fatal — the bridge module's reconnect loop
    handles backoff. Mac app users without an iPhone never notice this
    runs."""
    global _cloud_bridge_task
    if cloud_auth.is_local_mode():
        return
    try:
        from . import cloud_bridge  # noqa: WPS433
        _cloud_bridge_task = asyncio.create_task(cloud_bridge.run_bridge())
    except Exception as exc:  # noqa: BLE001
        log.warning("cloud bridge failed to start: %s", exc)


@app.on_event("shutdown")
async def _stop_bridge() -> None:
    global _bridge_task, _cloud_config_task, _cloud_bridge_task
    if _bridge_task is not None and not _bridge_task.done():
        _bridge_task.cancel()
    if _cloud_config_task is not None and not _cloud_config_task.done():
        _cloud_config_task.cancel()
    if _cloud_bridge_task is not None and not _cloud_bridge_task.done():
        try:
            from . import cloud_bridge as _cb
            _cb.request_shutdown()
        except Exception:  # noqa: BLE001
            pass
        _cloud_bridge_task.cancel()


async def _run_bridge_with_restart() -> None:
    while True:
        try:
            await bridge_serve()
        except asyncio.CancelledError:
            raise
        except OSError as exc:
            # "Address already in use" (errno EADDRINUSE / 48) almost
            # always means another klo-sidecar process is holding 8767.
            # Restart-looping here previously left the FastAPI half
            # running on 8787 without a bridge — extension connects to
            # the OTHER process's bridge, but /health reads THIS
            # process's empty bridge state and reports "disconnected"
            # forever. Loudly terminate the whole sidecar instead;
            # SidecarLauncher's watchdog surfaces "klo agent
            # unavailable — Retry" in the notch, and its `reapStaleSidecars`
            # path will clear the conflict on the next attempt.
            if getattr(exc, "errno", None) == errno.EADDRINUSE:
                log.error(
                    "bridge could not bind port (EADDRINUSE) — another "
                    "klo-sidecar instance is holding it. Exiting so the "
                    "Mac watchdog can restart cleanly: %s",
                    exc,
                )
                os._exit(1)
            log.warning("bridge crashed (OSError), restarting in 2s: %s", exc)
            await asyncio.sleep(2)
        except Exception as exc:  # noqa: BLE001
            log.warning("bridge crashed, restarting in 2s: %s", exc)
            await asyncio.sleep(2)
        else:
            return


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------- in-memory store

class _RunState:
    def __init__(
        self,
        run_id: str,
        prompt: str,
        prior_messages: list[dict[str, Any]] | None = None,
        scoped_service: str | None = None,
    ) -> None:
        self.id = run_id
        self.prompt = prompt
        self.prior_messages = prior_messages or []
        # Soft scope hint set when the user prefixed their submission
        # with `/<slug>` in TextInputView. Used by `_run_agent` to
        # augment the system prompt — "user is asking specifically
        # about <service>, prefer those tools." Not a hard restriction.
        self.scoped_service = scoped_service
        # klo 2.1 Track D: run-time safety context. `source` tags the
        # run so the composio_execute wrapper can recognize scheduled
        # vs interactive runs ('scheduled' / 'scheduled_routine' /
        # 'scheduled_preview' all imply pre-auth gating).
        # `allowed_actions` carries the routine's allowlist; anything
        # not in this list drafts to chat instead of executing.
        # Both are populated from the run_start payload at dispatch.
        self.source: str | None = None
        self.allowed_actions: list[dict[str, Any]] = []
        self.status = "queued"
        self.created_at = _now()
        self.updated_at = self.created_at
        self.events: list[dict[str, Any]] = []
        self.subscribers: set[asyncio.Queue[dict[str, Any]]] = set()
        self.cancel_event = asyncio.Event()
        self.task: asyncio.Task | None = None
        # Set when a tool result carries a typed error_code
        # ("extension_not_connected", "permission_denied", etc).
        # Surfaced in the run's terminal status_change event so the
        # Mac app can render a branded card instead of raw text.
        self.error_code: str | None = None
        # Companion to error_code for "permission_denied" — names the
        # TCC service ("accessibility" / "screen_recording" / "apple_events")
        # so the Mac app can deep-link the user to the right Privacy
        # pane without parsing the agent's prose.
        self.permission_service: str | None = None
        # confirm_action plumbing — when the agent calls confirm_action,
        # the on_request_confirm closure in _run_agent emits a
        # confirm_request event, sets state.confirm_pending=True, then
        # awaits state.confirm_event. POST /runs/{id}/confirm sets
        # state.confirm_result and fires the event so the agent
        # unblocks and returns {"approved": …} to the model.
        self.confirm_event: asyncio.Event = asyncio.Event()
        self.confirm_result: dict[str, Any] | None = None
        self.confirm_pending: bool = False
        # Mid-run user-interrupt inbox. The Mac app's WebPaneView lets
        # the user keep typing while the agent is running — each typed
        # message goes onto this queue via the WS "inject_message"
        # frame. The agent loop drains it at the natural turn boundary
        # (after a tool_result batch lands, before the next model call).
        #   kind="steer"  → "abandon current plan, pursue this instead"
        #   kind="inject" → "additional context, keep current plan"
        # Bounded so a runaway client can't unbound-memory us — but
        # 64 is far more than any real run will see (a user typing
        # 64 follow-ups before the agent finishes one turn is
        # adversarial, not realistic).
        self.inbox: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=64)
        # Take-over / hand-back. When True, the agent loop pauses at the
        # next turn boundary (doesn't make a model call, doesn't dispatch
        # tools) and polls every 250ms until it's cleared. The Mac app
        # flips this via POST /runs/{id}/pause and /resume; the WebPaneView
        # surfaces a "TAKE OVER" button that triggers pause and a
        # "HAND BACK" button that triggers resume. Useful when the agent
        # is doing the wrong thing on a page and the user wants to drive
        # for a beat (sign in to a paywall, navigate past a captcha, etc.)
        # without killing + restarting the whole run.
        self.paused: bool = False
        # Cloud bridge hook — set by cloud_bridge.py when a run was
        # triggered from the iOS companion app. Each event the run
        # generates also gets forwarded to klo-cloud over the bridge WS.
        # Local-run path (Electron / Mac app) leaves this None.
        self.bridge_forward: Any = None  # Callable[[dict], None] | None

    def add_event(self, event: dict[str, Any]) -> None:
        self.events.append(event)
        self.updated_at = event["created_at"]
        # Cloud bridge forward — when this run was initiated by the iOS
        # companion app via klo-cloud's WS bridge, `bridge_forward` is
        # set to a callable that enqueues the event on the outbound WS.
        # Fires for EVERY event, same set the local WS subscribers see.
        # Redact secret-shaped strings (PEM blocks, JWTs, sk-* keys, long
        # hex tokens) before crossing the cloud boundary. Local subscribers
        # still see the unredacted event — the data isn't leaving the Mac
        # for them — but anything destined for klo-cloud / mirror /
        # Supabase storage gets scrubbed.
        if self.bridge_forward is not None:
            try:
                self.bridge_forward(_redact_event_for_cloud(event))
            except Exception as exc:  # noqa: BLE001
                log.warning("bridge_forward raised for run %s: %s", self.id, exc)
        for q in list(self.subscribers):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                # Subscriber's queue is full → client has stalled or
                # disconnected without us noticing. Used to be silent
                # `pass`. Now: log once per subscriber so we can spot a
                # stuck UI in incident logs ("WS subscriber queue full"
                # bursts mean the client stopped draining and is missing
                # events). Still don't disconnect the subscriber here —
                # the WS keep-alive loop owns disconnection — but the
                # log gives us the visibility we lacked before.
                log.warning(
                    "subscriber queue full for run %s — dropping event type=%s (client may be stalled)",
                    self.id, event.get("type", "?"),
                )

    def to_summary(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "prompt": self.prompt,
            "status": self.status,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


_runs: dict[str, _RunState] = {}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# --------------------------------------------------------------- event mapping

def _make_event(run_id: str, event_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": str(uuid.uuid4()),
        "run_id": run_id,
        "type": event_type,
        "payload": payload,
        "created_at": _now(),
    }


def _trace_to_desktop_events(run_id: str, ev: TraceEvent) -> list[dict[str, Any]]:
    if ev.kind == "thought":
        text = (ev.payload or {}).get("text", "")
        return [_make_event(run_id, "agent_thought", {"text": text})]
    if ev.kind == "progress":
        text = (ev.payload or {}).get("text", "")
        return [_make_event(run_id, "progress_message", {"text": text})]
    if ev.kind == "tool_call":
        name = (ev.payload or {}).get("name", "?")
        args = (ev.payload or {}).get("args", {})
        action = args.get("action") if isinstance(args, dict) else None
        detail = (
            args.get("text") or args.get("url") or args.get("cmd") or args.get("script")
            or args.get("query") or args.get("name") or args.get("selector")
            if isinstance(args, dict) else None
        )
        return [_make_event(run_id, "step_progress", {
            "name": name,
            "action": action or name,
            "detail": (str(detail)[:200] if detail else ""),
            "i": 0,
            "total": 0,
        })]
    if ev.kind == "tool_result":
        text = (ev.payload or {}).get("text", "")
        return [_make_event(run_id, "tool_result", {"text": text[:400]})]
    # Diagnostic events emitted by the agent loop. These were dropped on
    # the floor before — making the stuck detector / fabrication guard /
    # budget warnings invisible in run traces. Forward them verbatim under
    # their own type so klo-trace and the web panel can render them.
    if ev.kind in ("stuck_intervention", "fabrication_warning", "budget_warning"):
        return [_make_event(run_id, ev.kind, dict(ev.payload or {}))]
    return []


# ------------------------------------------------------------------ run runner

async def _run_agent(state: _RunState) -> None:
    state.status = "running"
    state.add_event(_make_event(state.id, "status_change", {"status": "running"}))

    # klo 2.1 Track D: bind this run's state into a ContextVar so any
    # tool handler dispatched within the run can read it without us
    # threading the state through every function signature. Used by
    # composio_execute to gate destructive actions behind the
    # routine's pre-authorization allowlist for scheduled runs.
    from . import run_context
    _run_ctx_token = run_context.set_current_run(state)

    async def on_event(ev: TraceEvent):
        # Capture the FIRST tool result that carries a typed error_code,
        # so even if the agent gracefully degrades and ends in a
        # "completed" state, the Mac app still gets to know the
        # extension was missing for at least one tool call. We don't
        # overwrite once set — first-seen wins. Also captures the
        # companion permission_service field for permission_denied
        # codes so the Mac app can deep-link to the right Privacy pane.
        if ev.kind == "tool_result" and state.error_code is None:
            text = (ev.payload or {}).get("text", "")
            if text and '"error_code"' in text:
                # Cheap parse — payload text is JSON the tool wrote in
                # tools.py. Safe to load.
                try:
                    parsed = json.loads(text)
                    code = parsed.get("error_code") if isinstance(parsed, dict) else None
                    if isinstance(code, str):
                        state.error_code = code
                        svc = parsed.get("permission_service")
                        if isinstance(svc, str):
                            state.permission_service = svc
                except (ValueError, TypeError):
                    pass
        # TCC-denial sniffer — separate from the structured error_code
        # check above because Apple's per-folder denials surface as plain
        # stderr text inside the shell tool's JSON envelope, NOT as a
        # typed error_code. We update the process-global denial set so
        # subsequent runs in the same sidecar lifetime get a system-note
        # warning the agent away from re-trying the same protected scope.
        if ev.kind == "tool_result":
            text = (ev.payload or {}).get("text", "")
            new_scopes = _detect_tcc_denials(text) if text else set()
            if new_scopes - _DENIED_TCC_SCOPES:
                _DENIED_TCC_SCOPES.update(new_scopes)
                log.info("TCC denial recorded — scopes now: %s", sorted(_DENIED_TCC_SCOPES))
        for desktop_ev in _trace_to_desktop_events(state.id, ev):
            state.add_event(desktop_ev)

    async def on_request_confirm(args: dict[str, Any]) -> dict[str, Any]:
        """Bridge between the agent's confirm_action tool call and the
        Mac UI. Emits a confirm_request event so AgentClient can
        surface the inline confirm bar, then awaits POST /runs/{id}/confirm.

        Returns the user's decision as a dict (passed back to the model
        as JSON). Auto-denies after a 5-minute timeout so a forgotten
        prompt doesn't pin the run forever.

        klo 2.1 Track D: scheduled runs have no user present, so
        confirm_action cannot interactively prompt. Instead of
        auto-approving (the old behavior — a real safety hole), we
        auto-DENY with a clear reason. The agent gets back
        approved=false and includes "klo wanted to do X but you
        weren't around to confirm — opening Settings → Schedules to
        pre-authorize it would let this run autonomously next time"
        in its final reply. The user reviews in chat.
        """
        # Scheduled-run safety gate. composio_execute already gates
        # composio toolkits via the allowlist; this handles confirm_action
        # calls the agent makes for OTHER destructive paths (shell rm,
        # applescript delete, computer.click on destructive buttons, etc).
        src = (getattr(state, "source", None) or "").lower()
        if src.startswith("scheduled"):
            log.info(
                "confirm_action in scheduled run %s — auto-denying (no user present)",
                state.id,
            )
            return {
                "approved": False,
                "reason": (
                    "scheduled run, no user present to confirm. Drafted "
                    "this action — tell the user what you wanted to do "
                    "and that they need to either run it manually next "
                    "time or pre-authorize it in Settings → Schedules."
                ),
            }

        state.confirm_event.clear()
        state.confirm_result = None
        state.confirm_pending = True
        # Emit a desktop event the Mac client can render. AgentClient
        # handles `confirm_request` in handleMessage and flips state
        # to .confirmingAction.
        state.add_event(_make_event(state.id, "confirm_request", {
            "summary": (args.get("summary") or "").strip(),
            "irreversible": bool(args.get("irreversible")),
            "danger": (args.get("danger") or None),
        }))
        try:
            await asyncio.wait_for(state.confirm_event.wait(), timeout=300.0)
        except asyncio.TimeoutError:
            state.confirm_pending = False
            log.info("confirm_action timed out — auto-denying for run %s", state.id)
            return {"approved": False, "reason": "timeout"}
        state.confirm_pending = False
        return state.confirm_result or {"approved": False}

    async def on_check_paused() -> bool:
        """Polled by the agent loop at each turn boundary. While True,
        the loop sleeps + re-polls every 250ms instead of making a
        model call. The Mac app flips this via POST /runs/{id}/pause
        and /resume.

        Returns the current pause state. Loop logic: if True, await
        sleep then re-check. Cancellation through cancel_event still
        wins over pause — Esc beats pause every time.
        """
        return state.paused

    async def on_user_focus_taken() -> bool:
        """Polled by the agent loop at each turn boundary, BEFORE
        on_check_paused. Returns True once when the user has switched
        away from the agent's tab (background.js → bridge event →
        bridge._user_focus_taken). Locked decision is force-handoff,
        not pause, so a True return causes the loop to emit a clean
        over-to-you message and exit. One-shot semantics on the
        bridge — consume_user_focus_taken() returns + clears.

        We poll over the same RPC channel the tools use (bridge_server
        lives in a different process than the agent), so connection
        failures are normal during sidecar boot and reduce to False
        rather than poisoning the run.
        """
        try:
            from .bridge import call_via_server
            return bool(await call_via_server(
                "_internal.consume_focus_taken", {}, timeout=2,
            ))
        except Exception:
            return False

    async def on_run_start(payload: dict) -> None:
        """Push task.begin so the extension knows a run is in flight.
        Replaces the prior 60s idle heuristic — the extension stays
        in 'task active' mode until on_run_end fires (or its long
        safety timer kicks in if this process crashes).

        In-process: desktop_api shares the bridge singleton with the
        WS server, so we call push_event directly. The CLI path in
        run.py uses call_via_server('_internal.push_event', ...).
        """
        try:
            await bridge_singleton.push_event("task.begin", {
                "run_id": state.id,
                "task": (payload or {}).get("task", "")[:200],
            })
        except Exception as exc:  # noqa: BLE001
            log.warning("push task.begin failed: %s", exc)

    async def on_run_end(payload: dict) -> None:
        """Push task.end so the extension clears its 'task active'
        gate (focus listeners stop firing, agentLastNavigatedTabId
        resets). Always best-effort; the extension's safety timer
        is the fallback if this never lands."""
        try:
            data = dict(payload or {})
            data["run_id"] = state.id
            await bridge_singleton.push_event("task.end", data)
        except Exception as exc:  # noqa: BLE001
            log.warning("push task.end failed: %s", exc)

    async def on_user_interrupt() -> dict[str, Any]:
        """Drain the run's inbox of mid-run user messages typed in the
        Mac app's WebPaneView. Called by the agent loop at each turn
        boundary. Returns a dict the agent recognises:
          {"cancel": bool, "messages": [{"role": "user", "content": ...}]}

        Two message kinds, translated here into user-role content that
        the model understands as either a hard pivot (steer) or
        additive context (inject). Keeping the translation Python-side
        means we can iterate the prompt wording without re-shipping
        the Mac app.
        """
        drained: list[dict[str, Any]] = []
        while not state.inbox.empty():
            try:
                item = state.inbox.get_nowait()
            except asyncio.QueueEmpty:
                break
            txt = (item.get("text") or "").strip()
            if not txt:
                continue
            if item.get("kind") == "steer":
                content = (
                    f"PLAN CHANGE FROM THE USER (interrupted mid-run): {txt}\n\n"
                    "The user typed this while watching you work. Stop your "
                    "current trajectory if it conflicts with this. Acknowledge "
                    "briefly what you're switching to, then pursue the new "
                    "request."
                )
            else:
                content = (
                    f"ADDITIONAL CONTEXT FROM THE USER (keep your current plan): "
                    f"{txt}\n\nFold this into what you're already doing — do not "
                    "abandon the original task."
                )
            drained.append({"role": "user", "content": content})
        return {"cancel": state.cancel_event.is_set(), "messages": drained}

    agent = Agent(
        verbose=os.environ.get("KLO_AGENT_VERBOSE", "0") == "1",
        on_event=on_event,
        on_request_confirm=on_request_confirm,
        on_user_interrupt=on_user_interrupt,
        on_check_paused=on_check_paused,
        on_user_focus_taken=on_user_focus_taken,
        on_run_start=on_run_start,
        on_run_end=on_run_end,
        model=MODEL_DEFAULT,
    )
    # Combine the standing TCC-denied-scopes note (if any) with the
    # per-run soft scope hint (if the user typed `/<slug>` in the
    # input bar). Both are appended to the system prompt; nil parts
    # collapse to empty so we only join non-empty notes.
    notes_parts: list[str] = []
    if denied_note := _denied_scopes_system_note():
        notes_parts.append(denied_note)
    if state.scoped_service:
        notes_parts.append(_scoped_service_system_note(state.scoped_service))
    extra_notes = "\n\n".join(notes_parts) if notes_parts else None

    try:
        result = await agent.run(
            state.prompt,
            prior_messages=state.prior_messages,
            extra_system_notes=extra_notes,
        )
        if state.cancel_event.is_set() or result.error == "cancelled_by_user":
            state.status = "cancelled"
            state.add_event(_make_event(state.id, "status_change", {"status": "cancelled"}))
            return
        # Prose-refusal interception: the agent loop detected that the
        # natural-end text was a "I can't / I don't have permission..."
        # bail without an actual tool attempt. Promote to a structured
        # permission_denied so the Mac app's AgentClient routes to the
        # PermissionGrantOrchestrator (Settings deep-link + instruction
        # card + auto-retry on grant), exactly like a real tool-level
        # denial would.
        if result.permission_refusal_service and not state.error_code:
            state.error_code = "permission_denied"
            state.permission_service = result.permission_refusal_service
            log.info(
                "prose refusal intercepted — promoting to permission_denied (service=%s)",
                result.permission_refusal_service,
            )
        if result.error:
            state.status = "failed"
            payload: dict[str, Any] = {"status": "failed", "reason": result.error}
            if state.error_code:
                payload["error_code"] = state.error_code
            if state.permission_service:
                payload["permission_service"] = state.permission_service
            state.add_event(_make_event(state.id, "status_change", payload))
            return
        # Belt-and-suspenders: the agent loop now guarantees a non-empty
        # result.final on normal completion (see agent.py text-only break
        # path). If we ever reach here with no final AND no error AND no
        # permission refusal, still emit a sentinel so the Mac client's
        # working-state UI gets the completion signal. Without this, any
        # future code path that ends without setting result.final would
        # leave the notch's fire+bubbles stuck up indefinitely.
        if not result.final and not state.permission_service:
            result.final = "(done)"
        if result.final:
            state.add_event(_make_event(state.id, "final_message", {"text": result.final}))
            if not cloud_auth.is_local_mode():
                # Mirror the turn to hosted KLO so the user's other
                # surfaces can pick up where this run left off.
                from . import cloud_mirror as _cm
                asyncio.create_task(_cm.post_message(
                    role="user",
                    content=state.prompt,
                    source="mac",
                    source_session_id=state.id,
                    scoped_service=state.scoped_service,
                    run_id=state.id,
                ))
                asyncio.create_task(_cm.post_message(
                    role="assistant",
                    content=result.final,
                    source="mac",
                    source_session_id=state.id,
                    scoped_service=state.scoped_service,
                    run_id=state.id,
                ))
            # Hermes-five M3 — fire the background skill-review fork.
            # Reads the just-completed turn + existing skills and
            # decides whether to patch or create a skill (defaulting
            # heavily toward noop). Same fire-and-forget rule: this
            # is never on the user's critical path.
            from . import background_review as _br
            transcript = (
                f"USER:\n{state.prompt}\n\n"
                f"KLO:\n{result.final}"
            )
            asyncio.create_task(_br.review(transcript))
        state.status = "completed"
        # Even on a "completed" run, surface the error_code so the Mac
        # app can show the branded card if the agent worked around a
        # missing extension or denied permission by replying anyway.
        completed_payload: dict[str, Any] = {"status": "completed"}
        if state.error_code:
            completed_payload["error_code"] = state.error_code
        if state.permission_service:
            completed_payload["permission_service"] = state.permission_service
        state.add_event(_make_event(state.id, "status_change", completed_payload))
    except Exception as exc:  # noqa: BLE001
        log.exception("run %s crashed", state.id)
        state.status = "failed"
        crash_payload: dict[str, Any] = {"status": "failed", "reason": str(exc)}
        if state.error_code:
            crash_payload["error_code"] = state.error_code
        if state.permission_service:
            crash_payload["permission_service"] = state.permission_service
        state.add_event(_make_event(state.id, "status_change", crash_payload))
    finally:
        # Always release the ContextVar binding so a later run doesn't
        # inherit stale state. Token-based reset must run on the same
        # Task that called .set(); we're guaranteed that here because
        # `_run_agent` is the Task body.
        run_context.reset_current_run(_run_ctx_token)


# ---------------------------------------------------------------- HTTP routes

@app.get("/health")
async def health():
    import shutil as _shutil
    import httpx as _httpx

    # Reach over to the Mac app's /v1/health (port 8788) for the REAL
    # AX/SR trust state. The Mac app is the TCC consumer now — its
    # trust is what matters, not this sidecar's. Fall back to the
    # sidecar's own probe if the Mac app isn't reachable (dev workflow
    # without Mac app running, or Mac-app boot race).
    ax_trusted: bool | None = None
    sr_trusted: bool | None = None
    mac_ops_reachable = False
    try:
        async with _httpx.AsyncClient(timeout=1.0) as _c:
            _resp = await _c.get("http://127.0.0.1:8788/v1/health")
        if _resp.status_code == 200:
            _data = _resp.json()
            ax_trusted = bool(_data.get("ax_trusted"))
            sr_trusted = bool(_data.get("sr_trusted"))
            mac_ops_reachable = True
    except Exception:
        pass
    if ax_trusted is None:
        try:
            import ApplicationServices as _AS  # type: ignore
            ax_trusted = bool(_AS.AXIsProcessTrusted())
        except Exception:
            ax_trusted = None

    cliclick = bool(_shutil.which("cliclick"))

    cc_status = cloud_config.get_config_status() if not cloud_auth.is_local_mode() else {
        "source": "local",
        "version": "bundled",
        "last_fetch_age_sec": None,
    }
    # Re-surfaced after the canonical-browser flip: the extension IS the
    # browser surface again, so its connection state is a real klo
    # capability gate. Mac KLO observes this via BridgeStatusManager;
    # klo-cloud relays it to iOS via the /devices feed.
    from . import bridge as _bridge_module
    ext_connected = _bridge_module.bridge.connected
    ext_meta = _bridge_module.bridge.client_meta if ext_connected else {}
    subsystems = {
        "desktop_api": "ok",
        "bridge_server": "ok",
        "chrome_extension": "connected" if ext_connected else "disconnected",
        "chrome_extension_version": ext_meta.get("version") if ext_connected else None,
        "mac_ops_server": "reachable" if mac_ops_reachable else "unreachable",
        "accessibility_api": "trusted" if ax_trusted else ("untrusted" if ax_trusted is False else "unknown"),
        "screen_recording": "trusted" if sr_trusted else ("untrusted" if sr_trusted is False else "unknown"),
        "cliclick": "installed" if cliclick else "missing",
        "cloud_config": (
            f"{cc_status['source']} (v={cc_status['version']})"
            if cc_status['source'] != 'cloud'
            else f"cloud (v={cc_status['version']}, age={cc_status['last_fetch_age_sec']}s)"
        ),
    }
    # openai_key state — DROPPED. The sidecar doesn't need a local
    # OPENAI_API_KEY env var; it talks to klo-cloud's /api/llm/openai
    # proxy with the user's Supabase session token (cloud_auth.py).
    degraded: list[str] = []
    if ax_trusted is False:
        degraded.append("synthetic input may be dropped (Accessibility not granted)")
    if not ext_connected:
        degraded.append("chrome extension not connected — web tools unavailable")

    return {
        "ok": not degraded or all(d.startswith("synthetic") for d in degraded),
        "service": "agent2.desktop_api",
        "ts": _now(),
        "subsystems": subsystems,
        "degraded": degraded,
    }


class RunCreate(BaseModel):
    prompt: str
    mode: str | None = "auto"
    browser_mode: str | None = "real"
    strict_approvals: bool | None = False
    prior_messages: list[dict[str, Any]] | None = None
    # Composio toolkit slug when the user prefixed their input with
    # `/<slug>` (e.g., "/notion list my pages"). Surfaced to the agent
    # via a system-prompt note so the model prefers tools for that
    # service. Soft hint — the model is free to reach for cross-app
    # tools when the task actually needs them.
    scoped_service: str | None = None


def _scoped_service_system_note(slug: str) -> str:
    """Build the soft-scope system-prompt augmentation for a `/<slug>`
    user submission. Returns a short paragraph the agent loop appends
    to its base system prompt — same hook the TCC-denial note uses."""
    clean = slug.strip().lower()
    return (
        f"The user prefixed their request with /{clean}. They want help with "
        f"their {clean} workflow specifically. Prefer Composio tools for "
        f"{clean} when they're applicable, but use other tools too if the "
        f"task genuinely needs them — this is a soft scope hint, not a "
        f"hard restriction."
    )


@app.post("/runs")
async def create_run(body: RunCreate):
    # Pre-flight: ask klo-cloud whether this run is allowed and claim a
    # trial-budget slot (no-op for paid subs). Fail closed — if cloud is
    # unreachable here, the run would fail on its first LLM call anyway
    # (also cloud-routed), so an early structured error is friendlier
    # than a mid-run "upstream_unreachable".
    if cloud_auth.is_local_mode():
        gate = {"mode": "local", "trial_runs_used": None, "trial_runs_limit": None}
    else:
        try:
            gate = await cloud_auth.request_task_start()
        except cloud_auth.NotSignedIn:
            raise HTTPException(
                status_code=401,
                detail={"error": "not_signed_in",
                        "message": "Sign in to KLO hosted to start a run."},
            )
        except cloud_auth.TrialExhausted as exc:
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "trial_exhausted",
                    "trial_runs_used": exc.trial_runs_used,
                    "trial_runs_limit": exc.trial_runs_limit,
                    "subscription_status": exc.subscription_status,
                    "message": "Free trial used up. Subscribe to keep going.",
                },
            )
        except cloud_auth.CloudUnreachable as exc:
            log.warning("create_run blocked: cloud unreachable (%s)", exc)
            raise HTTPException(
                status_code=503,
                detail={"error": "cloud_unreachable",
                        "message": "Couldn't reach KLO hosted. Try again."},
            )

    run_id = str(uuid.uuid4())
    state = _RunState(
        run_id=run_id,
        prompt=body.prompt,
        prior_messages=body.prior_messages,
        scoped_service=body.scoped_service,
    )
    _runs[run_id] = state
    state.task = asyncio.create_task(_run_agent(state))
    return {
        "id": run_id,
        # Echo the access decision so the Mac client can update its
        # usage strip without an extra /auth/me round-trip.
        "access_mode": gate.get("mode"),
        "trial_runs_used": gate.get("trial_runs_used"),
        "trial_runs_limit": gate.get("trial_runs_limit"),
    }


@app.get("/runs/{run_id}")
async def get_run(run_id: str):
    state = _runs.get(run_id)
    if state is None:
        return {"error": "not found"}, 404
    return {**state.to_summary(), "events": state.events}


@app.post("/runs/{run_id}/cancel")
async def cancel_run(run_id: str):
    state = _runs.get(run_id)
    if state is None:
        return {"ok": False, "error": "not found"}
    state.cancel_event.set()
    if state.task and not state.task.done():
        state.task.cancel()
    return {"ok": True}


# The voice path runs entirely client-side via OpenAI Realtime API
# (see desktop-mac/KLO/Voice/RealtimeBridge.swift). The Mac client
# opens a WebRTC peer connection directly to OpenAI using an ephemeral
# key minted by klo-cloud's /voice/realtime/ephemeral-key. When the
# Realtime model emits a klo_run function call, it routes through
# AgentClient.dispatchFromRealtime → /runs → agent.py (same as text
# mode), and the result is ferried back via .kloRealtimeRunComplete.
# So this sidecar has no voice-specific routes anymore.

# ─── Cloud config inspection ──────────────────────────────────────────────────

@app.get("/config/sidecar")
async def get_sidecar_config():
    """What this sidecar currently believes the config is + provenance.
    Useful for diagnosing 'is the hot-fix I pushed actually live yet'."""
    return {
        "status": cloud_config.get_config_status(),
        "config": cloud_config.get_config(),
    }


@app.post("/config/refresh")
async def force_config_refresh():
    """Force an immediate cloud-config fetch (instead of waiting for the
    next scheduled refresh). Returns the result."""
    ok = await cloud_config.fetch_and_apply_remote_config()
    return {"ok": ok, "status": cloud_config.get_config_status()}


@app.post("/runs/{run_id}/approve")
async def approve_event(run_id: str, body: dict[str, Any]):
    state = _runs.get(run_id)
    if state is None:
        return {"ok": False}
    state.add_event(_make_event(run_id, "approval_decided", {
        "event_id": body.get("event_id"),
        "approved": bool(body.get("approved")),
    }))
    return {"ok": True}


@app.post("/runs/{run_id}/confirm")
async def confirm_run(run_id: str, body: dict[str, Any]):
    """User responded to a confirm_action prompt from the agent.

    Body: {"approved": bool}. Resolves the run's confirm_event so the
    agent's pending confirm_action tool call unblocks and returns the
    decision to the model. No-op if no confirm is pending.
    """
    state = _runs.get(run_id)
    if state is None:
        return {"ok": False, "error": "not found"}
    if not state.confirm_pending:
        return {"ok": False, "error": "no confirm pending"}
    state.confirm_result = {"approved": bool(body.get("approved"))}
    state.confirm_event.set()
    return {"ok": True}


@app.post("/runs/{run_id}/pause")
async def pause_run(run_id: str):
    """User clicked TAKE OVER in the WebPaneView. The agent loop will
    suspend at its next turn boundary; the user can drive the WKWebView
    directly (clicks, types, scrolls) until they click HAND BACK.

    No-op if the run already completed or was cancelled.
    """
    state = _runs.get(run_id)
    if state is None:
        return {"ok": False, "error": "not found"}
    if state.status in {"completed", "failed", "cancelled"}:
        return {"ok": False, "error": "run is " + state.status}
    state.paused = True
    state.add_event(_make_event(run_id, "status_change", {
        "status": state.status,
        "paused": True,
    }))
    return {"ok": True, "paused": True}


@app.post("/runs/{run_id}/resume")
async def resume_run(run_id: str):
    """User clicked HAND BACK. Agent loop resumes from where it paused
    on the next 250ms poll cycle (no work lost — the pause was at the
    turn boundary, not mid-tool-call)."""
    state = _runs.get(run_id)
    if state is None:
        return {"ok": False, "error": "not found"}
    state.paused = False
    state.add_event(_make_event(run_id, "status_change", {
        "status": state.status,
        "paused": False,
    }))
    return {"ok": True, "paused": False}


@app.websocket("/ws/runs/{run_id}")
async def ws_run(websocket: WebSocket, run_id: str):
    await websocket.accept()
    state = _runs.get(run_id)
    if state is None:
        await websocket.send_json({"error": "run not found"})
        await websocket.close()
        return

    for ev in state.events:
        await websocket.send_json(ev)

    queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=512)
    state.subscribers.add(queue)

    # Concurrent reader for inbound client frames. The only inbound
    # frame shape we accept today is inject_message — the user typing
    # mid-run in the Mac app's WebPaneView. Anything else is ignored.
    # The reader stops on disconnect; the outbound stream loop below
    # is the one that breaks the run via the WebSocketDisconnect path.
    async def _read_inbound() -> None:
        try:
            while True:
                try:
                    msg = await websocket.receive_json()
                except WebSocketDisconnect:
                    return
                except Exception:
                    return
                if not isinstance(msg, dict):
                    continue
                if msg.get("type") != "inject_message":
                    continue
                payload = msg.get("payload") or {}
                if not isinstance(payload, dict):
                    continue
                text = (payload.get("text") or "").strip()
                kind = payload.get("kind") or "inject"
                if kind not in ("steer", "inject"):
                    kind = "inject"
                if not text:
                    continue
                try:
                    state.inbox.put_nowait({"kind": kind, "text": text})
                except asyncio.QueueFull:
                    log.warning("inbox full for run %s — dropping interrupt", run_id)
                    continue
                # Echo acknowledgement so the Mac app can render the
                # "↪ steered" / "↳ injected" toast. The agent will
                # actually drain the message at its next turn boundary.
                ack = _make_event(run_id, "injection_acknowledged", {
                    "kind": kind, "text": text,
                })
                state.add_event(ack)
        except Exception:
            return

    reader_task = asyncio.create_task(_read_inbound())

    try:
        while True:
            try:
                ev = await asyncio.wait_for(queue.get(), timeout=1.0)
            except asyncio.TimeoutError:
                if state.status in {"completed", "failed", "cancelled"}:
                    while not queue.empty():
                        try:
                            ev = queue.get_nowait()
                            await websocket.send_json(ev)
                        except asyncio.QueueEmpty:
                            break
                    break
                continue
            await websocket.send_json(ev)
            if ev.get("type") == "status_change" and ev.get("payload", {}).get("status") in {
                "completed", "failed", "cancelled", "needs_review",
            }:
                break
    except WebSocketDisconnect:
        # Client closed the WS mid-run (panel dismissed, network blip,
        # process killed). The agent loop runs to completion server-side
        # regardless. Used to be silent `pass`; now log distinctly so
        # we can correlate user "klo went silent" reports with
        # mid-stream WS drops. Don't propagate — the run's events still
        # get queued + can be replayed via /runs/{id}/events.
        log.info("WS disconnected mid-run for %s (events still queued; client may reconnect)", run_id)
    finally:
        reader_task.cancel()
        try:
            await reader_task
        except (asyncio.CancelledError, Exception):
            pass
        state.subscribers.discard(queue)
        try:
            await websocket.close()
        except Exception:
            pass


# ---------------------------------------------------------------- stubs

@app.get("/credits")
async def credits():
    return {
        "balance_cents": 50_000,
        "lifetime_granted_cents": 50_000,
        "lifetime_spent_cents": 0,
    }


@app.get("/usage")
async def usage():
    return {"items": []}


@app.get("/integrations")
async def integrations():
    return {"items": []}


@app.post("/integrations/oauth/start")
async def oauth_start(body: dict[str, Any]):
    return {"redirect_url": "", "connection_id": ""}


class ChatBody(BaseModel):
    messages: list[dict[str, Any]]


@app.post("/chat")
async def chat(body: ChatBody):
    if not body.messages:
        return {"reply": ""}
    last = body.messages[-1]
    prompt = last.get("content", "")
    if not prompt:
        return {"reply": ""}
    agent = Agent(verbose=os.environ.get("KLO_AGENT_VERBOSE", "0") == "1")
    result = await agent.run(prompt)
    return {"reply": result.final or "(no reply)"}


@app.get("/permissions/status")
async def permissions_status():
    perms = {
        "screen_recording": {"name": "screen_recording", "granted": True, "label": "Screen Recording", "why": "see your screen", "optional": False},
        "accessibility": {"name": "accessibility", "granted": True, "label": "Accessibility", "why": "drive your apps", "optional": False},
    }
    return {"permissions": perms, "any_required_missing": False}


@app.post("/permissions/request/{name}")
async def request_permission(name: str):
    return {"already_granted": True}


@app.get("/permissions/binary")
async def perm_binary():
    return {"path": ""}


@app.post("/permissions/reveal_binary")
async def reveal_binary():
    return {"ok": True, "path": ""}


@app.post("/permissions/open_settings/{name}")
async def open_settings(name: str):
    return {"ok": True}


# ---------------------------------------------------------------- run

def main():
    import uvicorn
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    print("agent2 desktop_api on http://127.0.0.1:8787 — point klo-agent-ui's VITE_API_BASE here")
    uvicorn.run(app, host="127.0.0.1", port=8787, log_level="info")


if __name__ == "__main__":
    main()
