"""Long-horizon workspace — the durable artifact klo reads and writes for
any initiative that spans hours, days, or weeks.

The reactive `agent2/agent.py` loop has no notion of cross-session state
beyond `~/.agent2/memory.db` (one bucket, no per-initiative scoping). That's
fine for "open Notes and jot this down." It's not fine for "be my CMO for
meal tracking for the next 30 days" or "run my Series A pipeline" or "ship
the API by September 1" — work where klo plans, schedules its own check-ins,
delegates research, tracks decisions, and re-reads state across turns.

This module is the primitive that makes that possible. It is INTENTIONALLY
domain-neutral. klo decides what each workspace is for (marketing campaign,
fundraise, product launch, KPI watch, anything) based on the user's brief
and its system prompt. No CMO logic, no CTO logic — just files on disk
with clear purposes that any role can use.

Each workspace lives at:
    ~/Library/Application Support/com.klorah.klo/workspaces/{slug}/
        brief.md          — the user's ask, immutable. klo's anchor.
        plan.md           — klo's decomposition + status flags ([ ]/[x]/[?]/[!])
        log.md            — append-only event stream (human-readable summary)
        decisions.md      — user-approved choices (semantic memory)
        pending.json      — escalation queue for external-action approval

        progress.log      — internal JSON-lines machine log for idempotency
                            checks + workspace audit (not for the user to read)

Files are plain markdown so the user can open in any editor and redirect
between sessions. The agent never rewrites a file the user edited without
showing the diff first (Phase 2 — for now, the agent's writes overwrite).

Read/write goes through `Workspace` so the idempotency layer and the
pending queue catch every external effect that needs gating.
"""
from __future__ import annotations

import json
import re
import time
from contextvars import ContextVar, Token
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# ─── Paths ─────────────────────────────────────────────────────────────

def _workspaces_root() -> Path:
    """Root of all workspaces. macOS conventional location so the user
    can browse to it in Finder and edit files in any editor."""
    return Path.home() / "Library" / "Application Support" / "com.klorah.klo" / "workspaces"


def _slugify(name: str) -> str:
    """Filesystem-safe slug. Lowercase, hyphens, suffix with today's date
    so re-running the same brief on a different day gets a fresh workspace
    instead of overwriting yesterday's work."""
    base = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    base = base[:60] or "workspace"
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return f"{base}-{today}"


# ─── Workspace ─────────────────────────────────────────────────────────

@dataclass
class Workspace:
    """Handle to one long-horizon workspace on disk.

    Construct via `init()` (new) or `load()` (existing). Don't instantiate
    directly — `__init__` won't seed the directory or files.
    """
    slug: str
    root: Path
    brief: str
    created_at: str

    # ─── File paths ─────────────────────────────────────────────────

    @property
    def brief_path(self) -> Path:
        return self.root / "brief.md"

    @property
    def plan_path(self) -> Path:
        return self.root / "plan.md"

    @property
    def log_path(self) -> Path:
        return self.root / "log.md"

    @property
    def decisions_path(self) -> Path:
        return self.root / "decisions.md"

    @property
    def pending_path(self) -> Path:
        return self.root / "pending.json"

    @property
    def meta_path(self) -> Path:
        return self.root / "meta.json"

    @property
    def progress_path(self) -> Path:
        """Internal JSONL audit log. Not surfaced to the user — it's the
        idempotency-check + event-replay substrate."""
        return self.root / "progress.log"

    @property
    def evidence_dir(self) -> Path:
        d = self.root / "evidence"
        d.mkdir(parents=True, exist_ok=True)
        return d

    # ─── Brief + plan (the human-readable docs) ─────────────────────

    def read_brief(self) -> str:
        return self.brief_path.read_text(encoding="utf-8") if self.brief_path.exists() else ""

    def write_brief(self, content: str) -> None:
        """Overwrite brief.md. Use only when the user materially clarifies
        the scope — klo's working interpretation lives in plan.md."""
        self.brief_path.write_text(content, encoding="utf-8")
        self._record("brief.written", {"chars": len(content)})

    def read_plan(self) -> str:
        return self.plan_path.read_text(encoding="utf-8") if self.plan_path.exists() else ""

    def write_plan(self, content: str) -> None:
        self.plan_path.write_text(content, encoding="utf-8")
        self._record("plan.written", {"chars": len(content)})

    # ─── Human-readable log (markdown, what happened today) ─────────

    def append_log(self, message: str) -> None:
        """Append a human-readable line to log.md. Use sparingly — this
        is what the user reads to catch up on the initiative, NOT a debug
        trace. One line per substantive event."""
        message = (message or "").strip()
        if not message:
            return
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        with self.log_path.open("a", encoding="utf-8") as f:
            f.write(f"- {stamp} — {message}\n")
        self._record("log.appended", {"chars": len(message)})

    def read_log(self, tail: int | None = None) -> str:
        if not self.log_path.exists():
            return ""
        text = self.log_path.read_text(encoding="utf-8")
        if tail is None:
            return text
        lines = text.splitlines()
        return "\n".join(lines[-tail:])

    # ─── Decisions (semantic memory of user-approved choices) ───────

    def add_decision(self, text: str) -> None:
        text = (text or "").strip()
        if not text:
            return
        line = f"- {datetime.now(timezone.utc).strftime('%Y-%m-%d')}: {text}\n"
        with self.decisions_path.open("a", encoding="utf-8") as f:
            f.write(line)
        self._record("decision.added", {"text": text[:200]})

    def read_decisions(self) -> str:
        return self.decisions_path.read_text(encoding="utf-8") if self.decisions_path.exists() else ""

    # ─── Pending human approvals (escalation queue) ─────────────────

    def add_pending(self, reason: str, ask: str, payload: dict[str, Any] | None = None) -> str:
        clearance_id = f"clr_{int(time.time() * 1000)}"
        item = {
            "clearance_id": clearance_id,
            "reason": reason,
            "ask": ask,
            "payload": payload or {},
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "status": "pending",
        }
        queue = self._read_pending_queue()
        queue.append(item)
        self._write_pending_queue(queue)
        self._record("pending.added", {"clearance_id": clearance_id, "reason": reason})
        return clearance_id

    def resolve_pending(self, clearance_id: str, approved: bool, note: str | None = None) -> bool:
        queue = self._read_pending_queue()
        for item in queue:
            if item.get("clearance_id") == clearance_id and item.get("status") == "pending":
                item["status"] = "approved" if approved else "rejected"
                item["resolved_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
                if note:
                    item["note"] = note
                self._write_pending_queue(queue)
                self._record(
                    "pending.resolved",
                    {"clearance_id": clearance_id, "approved": approved},
                )
                return True
        return False

    def get_pending(self, clearance_id: str) -> dict[str, Any] | None:
        for item in self._read_pending_queue():
            if item.get("clearance_id") == clearance_id:
                return item
        return None

    def list_pending(self, status: str | None = "pending") -> list[dict[str, Any]]:
        queue = self._read_pending_queue()
        if status is None:
            return queue
        return [it for it in queue if it.get("status") == status]

    def _read_pending_queue(self) -> list[dict[str, Any]]:
        if not self.pending_path.exists():
            return []
        try:
            return json.loads(self.pending_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return []

    def _write_pending_queue(self, queue: list[dict[str, Any]]) -> None:
        self.pending_path.write_text(json.dumps(queue, indent=2), encoding="utf-8")

    # ─── Idempotency keys for external actions ──────────────────────

    def check_idempotency(self, key: str) -> bool:
        """True if this idempotency key has fired before. Workers MUST
        consult this before any external side-effect; the gate prevents
        scheduled-job replay from double-posting."""
        if not self.progress_path.exists():
            return False
        for record in self._read_progress():
            if record.get("event") == "external.action" and record.get("idempotency_key") == key:
                return True
        return False

    def record_external(self, action: str, idempotency_key: str, payload: dict[str, Any]) -> None:
        """Log an external side-effect with its idempotency key. Caller
        invokes AFTER the side-effect succeeds; crash before this line
        means the action will retry on resume (at-least-once delivery)."""
        self._record("external.action", {
            "action": action,
            "idempotency_key": idempotency_key,
            **payload,
        })

    # ─── Evidence artifacts ─────────────────────────────────────────

    def write_evidence(self, name: str, content: str | bytes) -> Path:
        """Save an evidence artifact (research dump, draft, screenshot,
        SVG) under evidence/. Returns the path."""
        path = self.evidence_dir / name
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        self._record("evidence.saved", {"name": name, "bytes": len(content)})
        return path

    # ─── Internal: JSONL progress audit ─────────────────────────────

    def _record(self, event: str, payload: dict[str, Any] | None = None) -> None:
        """Append one event to progress.log (internal JSONL audit). NOT
        the same as log.md — that's the human-readable summary."""
        record = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "event": event,
            **(payload or {}),
        }
        line = json.dumps(record, ensure_ascii=False)
        with self.progress_path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    def _read_progress(self) -> list[dict[str, Any]]:
        if not self.progress_path.exists():
            return []
        out: list[dict[str, Any]] = []
        for ln in self.progress_path.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if not ln:
                continue
            try:
                out.append(json.loads(ln))
            except json.JSONDecodeError:
                continue
        return out

    def recent_events(self, limit: int = 30) -> list[dict[str, Any]]:
        """Return the last N audit events (newest-last). Used by klo when
        resuming an initiative — read the tail to know what state things
        are in."""
        events = self._read_progress()
        return events[-limit:] if limit else events

    # ─── Meta ───────────────────────────────────────────────────────

    def _persist_meta(self) -> None:
        self.meta_path.write_text(json.dumps({
            "slug": self.slug,
            "brief": self.brief,
            "created_at": self.created_at,
        }, indent=2), encoding="utf-8")


# ─── Factory functions ─────────────────────────────────────────────────

def init(brief: str, name: str | None = None) -> Workspace:
    """Initialize a fresh workspace for an initiative.

    Args:
        brief: The user's ask, captured verbatim into brief.md so klo can
               re-read it later without drift. Required.
        name:  Optional human-friendly name used to derive the slug.
               Defaults to deriving from the brief. Either way, today's
               date is suffixed so re-init on a new day gets a fresh dir.
    """
    brief = (brief or "").strip()
    if not brief:
        raise ValueError("brief required")
    slug = _slugify(name or brief)
    root = _workspaces_root() / slug
    root.mkdir(parents=True, exist_ok=True)
    created_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    ws = Workspace(slug=slug, root=root, brief=brief, created_at=created_at)

    # Seed initial files. brief.md gets the user's verbatim ask. plan.md
    # gets a status-flag legend. decisions.md gets a header. log.md gets
    # the initiation event so the user sees something on first open.
    if not ws.brief_path.exists():
        ws.brief_path.write_text(
            f"# Brief — {slug}\n\n"
            f"_The user's ask, captured verbatim. klo re-reads this to stay anchored._\n\n"
            f"---\n\n"
            f"{brief}\n",
            encoding="utf-8",
        )
    if not ws.plan_path.exists():
        ws.plan_path.write_text(
            f"# Plan — {slug}\n\n"
            f"_klo's working decomposition. Updated as the initiative evolves._\n\n"
            f"Status flags:\n"
            f"- `[ ]` not started\n"
            f"- `[x]` complete\n"
            f"- `[?]` blocked / needs human\n"
            f"- `[!]` failed, replan needed\n\n"
            f"_klo will overwrite this file with the real plan on first run._\n",
            encoding="utf-8",
        )
    if not ws.decisions_path.exists():
        ws.decisions_path.write_text(
            f"# Decisions — {slug}\n\n"
            f"User-approved choices that shape the initiative. Append-only.\n\n",
            encoding="utf-8",
        )
    if not ws.log_path.exists():
        ws.log_path.write_text(
            f"# Log — {slug}\n\n"
            f"_Human-readable summary of what klo has done. Append-only._\n\n",
            encoding="utf-8",
        )
        ws.append_log("initiative initialized")
    if not ws.pending_path.exists():
        ws._write_pending_queue([])
    ws._persist_meta()
    ws._record("workspace.initialized", {"brief": brief[:200]})
    return ws


def load(slug: str) -> Workspace:
    """Load an existing workspace by slug. Raises FileNotFoundError if
    the directory or meta.json doesn't exist."""
    root = _workspaces_root() / slug
    meta_path = root / "meta.json"
    if not meta_path.exists():
        raise FileNotFoundError(f"no workspace at {root}")
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    return Workspace(
        slug=meta["slug"],
        root=root,
        brief=meta["brief"],
        created_at=meta["created_at"],
    )


def list_all() -> list[Workspace]:
    """Enumerate every workspace on disk, newest-first."""
    root = _workspaces_root()
    if not root.exists():
        return []
    out: list[Workspace] = []
    for child in sorted(root.iterdir(), reverse=True):
        if not child.is_dir():
            continue
        try:
            out.append(load(child.name))
        except (FileNotFoundError, KeyError, json.JSONDecodeError):
            continue
    return out


# ─── ContextVar binding ────────────────────────────────────────────────
#
# Workspace tools (workspace_read, workspace_write, etc.) read from a
# ContextVar so once klo binds a workspace, every nested coroutine —
# including delegate_task children — inherits it. Same pattern as
# agent2/run_context.py. Children can read the workspace but write only
# via tools that route through the gates (idempotency, pending queue).

_current_workspace: ContextVar[Workspace | None] = ContextVar(
    "klo_current_workspace", default=None,
)


def set_current_workspace(ws: Workspace) -> Token:
    return _current_workspace.set(ws)


def reset_current_workspace(token: Token) -> None:
    _current_workspace.reset(token)


def current_workspace() -> Workspace | None:
    return _current_workspace.get()


def bind_workspace_for_run(slug: str) -> Token:
    """Convenience: load by slug and bind in one call. Used by the
    agent's `workspace_load` tool to switch into an existing workspace
    mid-run."""
    ws = load(slug)
    return set_current_workspace(ws)
