"""Provider-agnostic core for klo's plan/execute/verify/commit loop.

LoopCore drives turn-by-turn dispatch: model emits tool_use blocks, the loop
classifies them (plan/revise_plan/escalate/commit_subtask are meta-tools that
mutate run state; macos/browser/system/web/accessibility/computer dispatch to
real executors), checks each result against the active subtask's evidence
rows, and refuses to finalize until every subtask is committed with evidence
satisfied. Provider-specific message shaping lives in ModelAdapter
implementations (AnthropicAdapter, OpenAIAdapter).
"""
from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from typing import Any, Protocol

from api.config import Settings
from api.core.accessibility import ACCESSIBILITY_TOOL, AccessibilityExecutor
from api.core.actions import ActionExecutor, ActionResult
from api.core.browser import BROWSER_TOOL, BrowserControlExecutor
from api.core.contract import TrustedHandles
from api.core.macos import MACOS_TOOL, MacOSAssistExecutor
from api.core.os_context import format_os_context, get_os_context
from api.core.prompts import SYSTEM_PROMPT
from api.core.system import SYSTEM_TOOL, SystemExecutor
from api.core.web import WEB_TOOL, WebContentExecutor
from api.core.workspace import FocusLeaseLost, WorkspaceGuard
from api.store.bus import bus
from api.store.persist import RunStore


# Hermes-style budget pressure thresholds. Inject a user-role nudge when
# the loop crosses these fractions of max_turns so the model can wrap up
# before being cut off mid-task. One-shot per threshold per run. Mirror
# of agent2/agent.py BUDGET_PRESSURE_*_PCT — keep in sync.
BUDGET_PRESSURE_SOFT_PCT = 0.70
BUDGET_PRESSURE_HARD_PCT = 0.90


# ----------------------------------------------------------------- dataclasses

@dataclass
class ToolCall:
    id: str
    name: str
    input: dict[str, Any] = field(default_factory=dict)


@dataclass
class ParsedResponse:
    text: str
    tool_calls: list[ToolCall]


@dataclass
class TurnResult:
    tool_id: str
    text: str | None = None
    has_screenshot: bool = False
    raw_content: list[dict[str, Any]] = field(default_factory=list)
    is_error: bool = False


# --------------------------------------------------------- model adapter shape

class ModelAdapter(Protocol):
    def initial_messages(
        self,
        prior_messages: list[dict[str, Any]],
        prompt: str,
        system_prompt: str,
    ) -> list[Any]: ...

    def adapter_tools(
        self,
        generic_tools: list[dict[str, Any]],
        display_width: int,
        display_height: int,
    ) -> list[dict[str, Any]]: ...

    async def create_turn(
        self,
        system_prompt: str,
        messages: list[Any],
        tools: list[dict[str, Any]],
    ) -> Any: ...

    def parse(self, raw: Any) -> ParsedResponse: ...

    def append_assistant(self, messages: list[Any], raw: Any) -> None: ...

    def extend_with_tool_results(
        self, messages: list[Any], results: list[TurnResult]
    ) -> None: ...

    def append_user_text(self, messages: list[Any], text: str) -> None: ...

    def usage(self, raw: Any) -> dict[str, int]:
        """Normalized token usage for one model turn. Optional — default = empty
        dict when an adapter doesn't expose usage. Keys: input_tokens,
        output_tokens, cached_input_tokens (when available)."""
        ...


# -------------------------------------------------------------- plan internals

@dataclass
class EvidenceRow:
    from_tool: str
    from_action: str | None
    from_intent: str | None
    expectation: dict[str, Any]
    satisfied: bool = False
    last_observed: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "from_tool": self.from_tool,
            "from_action": self.from_action,
            "from_intent": self.from_intent,
            "expectation": self.expectation,
            "satisfied": self.satisfied,
        }


@dataclass
class Subtask:
    id: str
    goal: str
    surface: str
    evidence: list[EvidenceRow]
    fallback_surface: str | None = None
    final_surface: bool = False
    committed: bool = False
    abandoned: bool = False
    abandon_reason: str | None = None
    escalations: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "goal": self.goal,
            "surface": self.surface,
            "fallback_surface": self.fallback_surface,
            "final_surface": self.final_surface,
            "committed": self.committed,
            "abandoned": self.abandoned,
            "abandon_reason": self.abandon_reason,
            "evidence": [row.to_dict() for row in self.evidence],
        }

    def is_terminal(self) -> bool:
        """Either successfully committed or honestly abandoned. Both unblock finalize."""
        return self.committed or self.abandoned

    def all_evidence_satisfied(self) -> bool:
        return all(row.satisfied for row in self.evidence)

    def missing_evidence(self) -> list[dict[str, Any]]:
        return [row.to_dict() for row in self.evidence if not row.satisfied]


# ------------------------------------------------------------- meta-tool spec

PLAN_TOOL = {
    "name": "plan",
    "description": (
        "Install the run's subtask plan. Must be called on the first turn. Each "
        "subtask declares a surface (macos|browser|system|web|accessibility|computer), "
        "a goal, and one-or-more evidence rows. Evidence rows must point at "
        "readback tools — not at clicks/screenshots."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "subtasks": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "goal": {"type": "string"},
                        "surface": {
                            "type": "string",
                            "enum": ["macos", "browser", "system", "web", "accessibility", "computer"],
                        },
                        "fallback_surface": {
                            "type": "string",
                            "enum": ["macos", "browser", "system", "web", "accessibility", "computer"],
                        },
                        "final_surface": {"type": "boolean"},
                        "evidence": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "from_tool": {"type": "string"},
                                    "from_action": {"type": "string"},
                                    "from_intent": {"type": "string"},
                                    "expectation": {"type": "object"},
                                },
                                "required": ["from_tool", "expectation"],
                            },
                        },
                    },
                    "required": ["id", "goal", "surface", "evidence"],
                },
            }
        },
        "required": ["subtasks"],
    },
}


REVISE_PLAN_TOOL = {
    "name": "revise_plan",
    "description": (
        "Append additional subtasks to the plan. Cannot modify or relax existing "
        "evidence rows; only adds new subtasks."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "append": PLAN_TOOL["input_schema"]["properties"]["subtasks"],
        },
        "required": ["append"],
    },
}

ESCALATE_TOOL = {
    "name": "escalate",
    "description": "Switch the active subtask to its fallback or a new surface (logged & counted).",
    "input_schema": {
        "type": "object",
        "properties": {
            "subtask_id": {"type": "string"},
            "reason": {"type": "string"},
            "new_surface": {
                "type": "string",
                "enum": ["macos", "browser", "system", "web", "accessibility", "computer"],
            },
        },
        "required": ["subtask_id", "reason", "new_surface"],
    },
}

COMMIT_SUBTASK_TOOL = {
    "name": "commit_subtask",
    "description": (
        "Mark a subtask complete. Refused if any evidence row is not yet "
        "satisfied — you must call the right readback tool first."
    ),
    "input_schema": {
        "type": "object",
        "properties": {"subtask_id": {"type": "string"}},
        "required": ["subtask_id"],
    },
}

ABANDON_SUBTASK_TOOL = {
    "name": "abandon_subtask",
    "description": (
        "Honestly abandon a subtask whose declared evidence cannot be satisfied "
        "(e.g. you wrote an expectation that doesn't match the readback's actual "
        "structure, or the surface doesn't expose what you assumed). Provide a "
        "concrete reason. The run is allowed to finalize after every subtask is "
        "either committed or abandoned. Use this RARELY — only when you've "
        "verified via revise_plan + a corrected subtask that the goal itself "
        "was met, but the original subtask's evidence is structurally wrong."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "subtask_id": {"type": "string"},
            "reason": {
                "type": "string",
                "description": (
                    "Why the original evidence cannot be satisfied. Reference "
                    "the actual readback structure that contradicted it."
                ),
            },
        },
        "required": ["subtask_id", "reason"],
    },
}


META_TOOL_NAMES = {"plan", "revise_plan", "escalate", "commit_subtask", "abandon_subtask"}
SURFACE_TOOLS = {"macos", "browser", "system", "web", "accessibility", "computer"}


# ------------------------------------------------------------- pause / resume

@dataclass
class PauseState:
    """In-memory continuation for a paused run. Lost on sidecar restart —
    the resume endpoint reports that and the client must start a new run."""
    prompt: str
    messages: list[Any]
    plan: list[Subtask]
    active_id: str | None
    plan_installed: bool
    tool_call_count: int
    screenshot_count: int
    usage_total: dict[str, int]
    pause_reason: str


_PAUSE_STATES: dict[str, PauseState] = {}


def pop_pause_state(run_id: str) -> PauseState | None:
    return _PAUSE_STATES.pop(run_id, None)


# ------------------------------------------------------------------ LoopCore

class LoopCore:
    def __init__(
        self,
        settings: Settings,
        store: RunStore,
        adapter: ModelAdapter,
    ) -> None:
        self.settings = settings
        self.store = store
        self.adapter = adapter
        self._guard = WorkspaceGuard(settings)
        self._trusted = TrustedHandles()
        self._action = ActionExecutor()
        self._macos_exec = MacOSAssistExecutor()
        self._browser_exec = BrowserControlExecutor(trusted=self._trusted)
        self._system_exec = SystemExecutor()
        self._web_exec = WebContentExecutor(trusted=self._trusted)
        self._a11y_exec = AccessibilityExecutor()

    # ----- public

    async def run(
        self,
        run_id: str,
        prompt: str,
        prior_messages: list[dict[str, Any]] | None = None,
        resume_state: PauseState | None = None,
    ) -> None:
        await self.store.set_status(run_id, "running")
        await self._emit(run_id, "status_change", {"status": "running"})

        plan: list[Subtask] = []
        active_id: str | None = None
        plan_installed = False
        tool_call_count = 0
        screenshot_count = 0
        finalized = False
        usage_total: dict[str, int] = {}
        failure_reason: str | None = None
        failure_detail: str | None = None
        caps_hit: set[str] = set()
        fast_path = self.settings.fast_path and _is_simple_prompt(prompt)

        system_prompt = SYSTEM_PROMPT + "\n\n" + format_os_context(get_os_context())
        if resume_state is not None:
            messages = resume_state.messages
            plan = resume_state.plan
            active_id = resume_state.active_id
            plan_installed = resume_state.plan_installed
            tool_call_count = resume_state.tool_call_count
            screenshot_count = resume_state.screenshot_count
            usage_total = dict(resume_state.usage_total)
            self.adapter.append_user_text(
                messages, "[klo] Run resumed after pause. Continue the task."
            )
        else:
            messages = self.adapter.initial_messages(prior_messages or [], prompt, system_prompt)

        if self.settings.use_dedicated_space:
            try:
                ws_state = await self._guard.enter()
                await self._emit(run_id, "workspace", ws_state.to_dict())
            except Exception as exc:  # noqa: BLE001
                await self._emit(run_id, "error", {"text": f"workspace enter failed: {exc}"})

        # Display geometry: derive from a real screenshot probe so the model's
        # coordinate space matches the images it will see. Fall back to
        # 1440x900 only when the screen can't be queried.
        display_w, display_h = 1440, 900
        try:
            geometry = await self._action.ensure_geometry()
            if geometry is not None:
                display_w, display_h = geometry.image_width_px, geometry.image_height_px
        except Exception as exc:  # noqa: BLE001
            await self._emit(
                run_id, "error", {"text": f"display geometry probe failed: {exc}"}
            )
        tools = self.adapter.adapter_tools(self._generic_tools(), display_w, display_h)

        started_at = time.monotonic()
        # Budget-pressure one-shot flags (see BUDGET_PRESSURE_*_PCT).
        budget_pressure_soft_fired = False
        budget_pressure_hard_fired = False
        for turn in range(self.settings.max_turns):
            wall_limit = self.settings.max_wall_time_seconds
            if wall_limit and time.monotonic() - started_at > wall_limit:
                failure_reason = "wall_time"
                failure_detail = f"run exceeded max_wall_time_seconds ({wall_limit}s)"
                await self._emit(run_id, "error", {"text": failure_detail})
                break
            try:
                raw = await self.adapter.create_turn(system_prompt, messages, tools)
            except Exception as exc:  # noqa: BLE001
                failure_reason = "model_error"
                failure_detail = f"model call failed: {exc}"
                await self._emit(run_id, "error", {"text": failure_detail})
                break
            self.adapter.append_assistant(messages, raw)
            parsed = self.adapter.parse(raw)

            # Token-usage accounting (if the adapter exposes it).
            try:
                turn_usage = self.adapter.usage(raw) or {}
            except Exception:
                turn_usage = {}
            if turn_usage:
                for k, v in turn_usage.items():
                    usage_total[k] = usage_total.get(k, 0) + v
                await self._emit(
                    run_id,
                    "model_usage",
                    {"turn": turn, "delta": turn_usage, "total": dict(usage_total)},
                )

            if parsed.text:
                await self._emit(run_id, "agent_thought", {"text": parsed.text})

            if not parsed.tool_calls:
                # Text-only response. Either finalize or coerce.
                if not plan_installed and not fast_path:
                    await self._emit(run_id, "plan_required", {"turn": turn})
                    self.adapter.append_user_text(
                        messages,
                        "[klo] You MUST call `plan` first. No other action is permitted "
                        "before a plan is installed.",
                    )
                    continue
                pending = [s.id for s in plan if not s.is_terminal()]
                if pending:
                    debug_pending = _build_pending_debug(plan)
                    await self._emit(
                        run_id,
                        "verification_required",
                        {
                            "pending_subtasks": pending,
                            "pending": debug_pending,
                        },
                    )
                    self.adapter.append_user_text(
                        messages,
                        "[klo] Cannot finalize — these evidence rows are still "
                        "unsatisfied. For each row, the loop included the last "
                        "readback it saw matching the row's tool/action/intent "
                        "(`last_observed`). If `last_observed` is null, you "
                        "haven't run the readback yet — call it. If it's set, "
                        "your expectation didn't match its actual structure — "
                        "either narrow your readback or call revise_plan with a "
                        "corrected expectation that matches what the readback "
                        "actually returns.\n\n"
                        + json.dumps(debug_pending, ensure_ascii=False, indent=2),
                    )
                    continue
                await self._emit(run_id, "final_message", {"text": parsed.text})
                if usage_total:
                    await self._emit(run_id, "usage_total", usage_total)
                await self.store.set_status(run_id, "completed")
                await self._emit(run_id, "status_change", {"status": "completed"})
                finalized = True
                break

            results: list[TurnResult] = []
            for tc in parsed.tool_calls:
                tool_call_count += 1
                await self._emit(
                    run_id,
                    "tool_call",
                    {"id": tc.id, "name": tc.name, "input": _safe_input(tc.input)},
                )

                # Hard caps
                if tool_call_count > self.settings.max_tool_calls:
                    caps_hit.add("max_tool_calls")
                    results.append(self._error_result(tc.id, "max_tool_calls exceeded"))
                    await self._emit(run_id, "error", {"text": "max_tool_calls exceeded"})
                    continue

                if tc.name == "plan":
                    if plan_installed:
                        results.append(self._error_result(tc.id, "plan already installed; use revise_plan"))
                        continue
                    err, parsed_plan = _parse_plan(tc.input)
                    if err:
                        await self._emit(run_id, "plan_failed", {"reason": err})
                        results.append(self._error_result(tc.id, err))
                        continue
                    plan = parsed_plan
                    plan_installed = True
                    active_id = plan[0].id if plan else None
                    await self._emit(
                        run_id,
                        "plan",
                        {"subtasks": [s.to_dict() for s in plan], "active_subtask": active_id},
                    )
                    results.append(self._ok_result(tc.id, "plan installed"))
                    continue

                if tc.name == "revise_plan":
                    if not plan_installed:
                        results.append(self._error_result(tc.id, "must call plan first"))
                        continue
                    err, extra = _parse_plan({"subtasks": tc.input.get("append") or []})
                    if err:
                        results.append(self._error_result(tc.id, err))
                        continue
                    existing_ids = {s.id for s in plan}
                    new_ones = [s for s in extra if s.id not in existing_ids]
                    plan.extend(new_ones)
                    await self._emit(
                        run_id,
                        "plan_revised",
                        {"appended": [s.to_dict() for s in new_ones]},
                    )
                    results.append(
                        self._ok_result(tc.id, f"appended {len(new_ones)} subtask(s)")
                    )
                    continue

                if tc.name == "escalate":
                    if not plan_installed:
                        results.append(self._error_result(tc.id, "must call plan first"))
                        continue
                    sid = str(tc.input.get("subtask_id") or "")
                    target = next((s for s in plan if s.id == sid), None)
                    if target is None:
                        results.append(self._error_result(tc.id, f"unknown subtask {sid!r}"))
                        continue
                    target.escalations += 1
                    if target.escalations > self.settings.max_escalations_per_subtask:
                        results.append(
                            self._error_result(
                                tc.id,
                                f"escalation cap exceeded for subtask {sid}",
                            )
                        )
                        continue
                    new_surface = str(tc.input.get("new_surface") or target.surface)
                    target.surface = new_surface
                    active_id = sid
                    await self._emit(
                        run_id,
                        "escalate",
                        {
                            "subtask_id": sid,
                            "new_surface": new_surface,
                            "reason": tc.input.get("reason"),
                            "escalations": target.escalations,
                        },
                    )
                    results.append(self._ok_result(tc.id, f"surface={new_surface}"))
                    continue

                if tc.name == "commit_subtask":
                    if not plan_installed:
                        results.append(self._error_result(tc.id, "must call plan first"))
                        continue
                    sid = str(tc.input.get("subtask_id") or "")
                    target = next((s for s in plan if s.id == sid), None)
                    if target is None:
                        results.append(self._error_result(tc.id, f"unknown subtask {sid!r}"))
                        continue
                    if not target.all_evidence_satisfied():
                        missing = target.missing_evidence()
                        # Include each row's last observed readback (if any)
                        # so the model can see the actual structure and rewrite
                        # its expectation via revise_plan.
                        debug = []
                        for row in target.evidence:
                            if row.satisfied:
                                continue
                            entry = row.to_dict()
                            entry["last_observed"] = row.last_observed
                            debug.append(entry)
                        results.append(
                            self._error_result(
                                tc.id,
                                "missing evidence — see last_observed fields below to "
                                "see what your readback actually returned, then "
                                "revise_plan with corrected evidence: "
                                + json.dumps(debug, ensure_ascii=False),
                            )
                        )
                        continue
                    target.committed = True
                    await self._emit(run_id, "subtask_commit", {"subtask_id": sid})
                    # Advance active to next non-terminal
                    next_active = next((s for s in plan if not s.is_terminal()), None)
                    active_id = next_active.id if next_active else None
                    results.append(self._ok_result(tc.id, "committed"))
                    continue

                if tc.name == "abandon_subtask":
                    if not plan_installed:
                        results.append(self._error_result(tc.id, "must call plan first"))
                        continue
                    sid = str(tc.input.get("subtask_id") or "")
                    reason = str(tc.input.get("reason") or "").strip()
                    target = next((s for s in plan if s.id == sid), None)
                    if target is None:
                        results.append(self._error_result(tc.id, f"unknown subtask {sid!r}"))
                        continue
                    if target.is_terminal():
                        results.append(self._error_result(tc.id, f"subtask {sid!r} already terminal"))
                        continue
                    if len(reason) < 10:
                        results.append(self._error_result(
                            tc.id,
                            "abandon_subtask requires a concrete reason (≥10 chars) "
                            "explaining why the original evidence is unsatisfiable.",
                        ))
                        continue
                    target.abandoned = True
                    target.abandon_reason = reason
                    await self._emit(
                        run_id,
                        "subtask_abandoned",
                        {"subtask_id": sid, "reason": reason},
                    )
                    next_active = next((s for s in plan if not s.is_terminal()), None)
                    active_id = next_active.id if next_active else None
                    results.append(self._ok_result(tc.id, f"abandoned: {reason[:80]}"))
                    continue

                # Surface tools — must have a plan, unless the fast path is
                # active and the call is strictly read-only.
                if not plan_installed and not (fast_path and _is_read_only_call(tc)):
                    results.append(self._error_result(tc.id, "must call plan first"))
                    continue
                if tc.name not in SURFACE_TOOLS:
                    results.append(self._error_result(tc.id, f"unknown tool {tc.name!r}"))
                    continue

                # Workspace guard for focus-sensitive actions.
                try:
                    self._guard.ensure_can_act(tc.name, tc.input)
                except FocusLeaseLost as exc:
                    results.append(self._error_result(tc.id, str(exc)))
                    idx = parsed.tool_calls.index(tc)
                    for skipped in parsed.tool_calls[idx + 1:]:
                        results.append(self._error_result(skipped.id, "skipped: run paused"))
                    self.adapter.extend_with_tool_results(messages, results)
                    _PAUSE_STATES[run_id] = PauseState(
                        prompt=prompt,
                        messages=messages,
                        plan=plan,
                        active_id=active_id,
                        plan_installed=plan_installed,
                        tool_call_count=tool_call_count,
                        screenshot_count=screenshot_count,
                        usage_total=dict(usage_total),
                        pause_reason=str(exc),
                    )
                    await self.store.set_status(run_id, "paused")
                    await self._emit(
                        run_id,
                        "status_change",
                        {"status": "paused", "reason": str(exc), "pause_reason": str(exc)},
                    )
                    return

                try:
                    output_text, raw_content, has_shot = await self._dispatch_surface(tc)
                except Exception as exc:  # noqa: BLE001
                    results.append(self._error_result(tc.id, f"{type(exc).__name__}: {exc}"))
                    await self._emit(
                        run_id,
                        "tool_result",
                        {"id": tc.id, "name": tc.name, "is_error": True, "text": f"{type(exc).__name__}: {exc}"},
                    )
                    continue

                if has_shot:
                    screenshot_count += 1
                    if screenshot_count > self.settings.max_screenshots:
                        caps_hit.add("max_screenshots")
                        results.append(self._error_result(tc.id, "max_screenshots exceeded"))
                        await self._emit(run_id, "error", {"text": "max_screenshots exceeded"})
                        continue

                # Evidence check across every uncommitted subtask. This lets the
                # model recover from a bad initial plan via revise_plan: a new
                # subtask whose rows match the readback gets its evidence
                # marked as we go, even before it becomes the active one.
                for subtask in plan:
                    if subtask.is_terminal():
                        continue
                    for row in subtask.evidence:
                        if row.satisfied:
                            continue
                        if _tool_triple_matches(row, tc):
                            # Record the readback text even if the expectation
                            # doesn't match yet — model needs this to debug
                            # bad evidence rows on the next commit attempt.
                            row.last_observed = (output_text or "")[:600]
                        if _matches_evidence(row, tc, output_text):
                            row.satisfied = True
                            await self._emit(
                                run_id,
                                "evidence_satisfied",
                                {
                                    "subtask_id": subtask.id,
                                    "row": row.to_dict(),
                                },
                            )

                results.append(
                    TurnResult(
                        tool_id=tc.id,
                        text=output_text,
                        has_screenshot=has_shot,
                        raw_content=raw_content,
                        is_error=False,
                    )
                )
                await self._emit(
                    run_id,
                    "tool_result",
                    {
                        "id": tc.id,
                        "name": tc.name,
                        "is_error": False,
                        "has_screenshot": has_shot,
                        "text": (output_text or "")[:1200],
                    },
                )

            self.adapter.extend_with_tool_results(messages, results)

            # Hermes-style budget pressure. After tool_results land, the
            # NEXT model call sees this conversation; nudge the model to
            # consolidate at 70%/90%. One-shot per threshold per run.
            max_turns = self.settings.max_turns
            if max_turns > 0:
                next_turn = turn + 1
                pct = next_turn / max_turns
                if pct >= BUDGET_PRESSURE_HARD_PCT and not budget_pressure_hard_fired:
                    budget_pressure_hard_fired = True
                    remaining = max(0, max_turns - next_turn)
                    self.adapter.append_user_text(
                        messages,
                        f"[KLO BUDGET WARNING: {next_turn}/{max_turns} turns used — "
                        f"only {remaining} left. Wrap up NOW: finalize what you can, "
                        f"summarize what's incomplete, and stop calling tools.]",
                    )
                    await self._emit(
                        run_id, "budget_pressure",
                        {"level": "hard", "turn": next_turn,
                         "max_turns": max_turns, "pct": round(pct, 2)},
                    )
                elif pct >= BUDGET_PRESSURE_SOFT_PCT and not (
                        budget_pressure_soft_fired or budget_pressure_hard_fired):
                    budget_pressure_soft_fired = True
                    remaining = max(0, max_turns - next_turn)
                    self.adapter.append_user_text(
                        messages,
                        f"[KLO BUDGET: {next_turn}/{max_turns} turns used, "
                        f"{remaining} left. Start consolidating — finish your current "
                        f"step, then summarize. Don't start new exploratory work.]",
                    )
                    await self._emit(
                        run_id, "budget_pressure",
                        {"level": "soft", "turn": next_turn,
                         "max_turns": max_turns, "pct": round(pct, 2)},
                    )

        if not finalized:
            if usage_total:
                await self._emit(run_id, "usage_total", usage_total)
            if failure_reason is None:
                if "max_screenshots" in caps_hit:
                    failure_reason = "max_screenshots"
                    failure_detail = (
                        f"screenshot cap ({self.settings.max_screenshots}) exceeded"
                    )
                elif "max_tool_calls" in caps_hit:
                    failure_reason = "max_tool_calls"
                    failure_detail = (
                        f"tool-call cap ({self.settings.max_tool_calls}) exceeded"
                    )
                else:
                    failure_reason = "max_turns"
                    failure_detail = (
                        f"reached max_turns ({self.settings.max_turns}) without finalizing"
                    )
            await self.store.set_status(run_id, "failed")
            await self._emit(
                run_id,
                "status_change",
                {
                    "status": "failed",
                    "reason": failure_detail,
                    "failure_reason": failure_reason,
                    "failure_detail": failure_detail,
                },
            )

    # ----- helpers

    def _generic_tools(self) -> list[dict[str, Any]]:
        return [
            MACOS_TOOL,
            BROWSER_TOOL,
            SYSTEM_TOOL,
            WEB_TOOL,
            ACCESSIBILITY_TOOL,
            PLAN_TOOL,
            REVISE_PLAN_TOOL,
            ESCALATE_TOOL,
            COMMIT_SUBTASK_TOOL,
            ABANDON_SUBTASK_TOOL,
        ]

    async def _dispatch_surface(self, tc: ToolCall) -> tuple[str | None, list[dict[str, Any]], bool]:
        """Run one surface-tool call. Returns (text_for_evidence, raw_content_blocks, has_screenshot)."""
        if tc.name == "computer":
            result: ActionResult = await self._action.execute(tc.input)
            blocks = result.to_tool_content()
            has_shot = result.screenshot is not None
            text = None if has_shot else (result.text or "ok")
            return text, blocks, has_shot

        executor: Any = {
            "macos": self._macos_exec,
            "browser": self._browser_exec,
            "system": self._system_exec,
            "web": self._web_exec,
            "accessibility": self._a11y_exec,
        }[tc.name]
        output = await executor.execute(tc.input)
        text = output if isinstance(output, str) else json.dumps(output, ensure_ascii=False, default=str)
        return text, [{"type": "text", "text": text}], False

    @staticmethod
    def _ok_result(tool_id: str, text: str) -> TurnResult:
        return TurnResult(
            tool_id=tool_id,
            text=text,
            has_screenshot=False,
            raw_content=[{"type": "text", "text": text}],
            is_error=False,
        )

    @staticmethod
    def _error_result(tool_id: str, text: str) -> TurnResult:
        return TurnResult(
            tool_id=tool_id,
            text=text,
            has_screenshot=False,
            raw_content=[{"type": "text", "text": text}],
            is_error=True,
        )

    async def _emit(self, run_id: str, event_type: str, payload: dict[str, Any]) -> None:
        event = await bus.publish(run_id, event_type, payload)
        await self.store.add_event(event)


# ------------------------------------------------------------------ fast path

_QUESTION_PREFIXES = (
    "what", "which", "who", "whose", "when", "where", "how", "why",
    "is ", "are ", "was ", "does ", "do ", "did ", "can ", "could ",
)

_READ_VERB_PREFIXES = (
    "list ", "show ", "read ", "check ", "tell ", "describe ",
    "summarize ", "summarise ", "count ", "find ", "look ",
)

_WRITE_HINT_WORDS = (
    "write", "create", "delete", "remove", "send", "type", "click",
    "install", "uninstall", "rename", "edit", "change", "update",
    "submit", "buy", "order", "download", "upload", "save", "compose",
    "reply", "draft", "fill", "drag", "press", "move", "set",
    "launch", "quit", "switch", "post",
)


def _is_simple_prompt(prompt: str) -> bool:
    """Conservative gate: a prompt qualifies for the fast path only when it
    reads like a short question/inspection and contains no write-ish verbs."""
    p = prompt.strip().lower()
    if not p or len(p) > 200:
        return False
    words = set(re.findall(r"[a-z_]+", p))
    if words & set(_WRITE_HINT_WORDS):
        return False
    if p.startswith(_READ_VERB_PREFIXES):
        return True
    return p.startswith(_QUESTION_PREFIXES) and p.endswith("?")


_READ_ONLY_COMPUTER_ACTIONS = {"screenshot", "get_cursor_position", "wait"}
_READ_ONLY_ACCESSIBILITY_ACTIONS = {
    "focused_snapshot",
    "visible_text",
    "screen_text",
    "screen_text_locations",
    "actionable_index",
}


def _is_read_only_call(tc: ToolCall) -> bool:
    inp = tc.input if isinstance(tc.input, dict) else {}
    action = inp.get("action")
    if tc.name == "computer":
        return action in _READ_ONLY_COMPUTER_ACTIONS
    if tc.name == "web":
        return True
    if tc.name == "accessibility":
        return action in _READ_ONLY_ACCESSIBILITY_ACTIONS
    if tc.name == "macos":
        if action == "desktop_inventory":
            return True
        return action == "run_applescript" and inp.get("intent") == "read"
    return False


# ------------------------------------------------------------------ utilities

def _parse_plan(payload: dict[str, Any]) -> tuple[str | None, list[Subtask]]:
    """Validate plan payload. Returns (error_message, subtasks)."""
    subtasks_raw = payload.get("subtasks")
    if not isinstance(subtasks_raw, list) or not subtasks_raw:
        return "subtasks must be a non-empty list", []
    out: list[Subtask] = []
    seen_ids: set[str] = set()
    for raw in subtasks_raw:
        if not isinstance(raw, dict):
            return "each subtask must be an object", []
        sid = str(raw.get("id") or "").strip()
        if not sid:
            return "subtask.id is required", []
        if sid in seen_ids:
            return f"duplicate subtask id {sid!r}", []
        seen_ids.add(sid)
        goal = str(raw.get("goal") or "").strip()
        if not goal:
            return f"subtask {sid}: goal is required", []
        surface = str(raw.get("surface") or "").strip()
        if surface not in SURFACE_TOOLS:
            return f"subtask {sid}: invalid surface {surface!r}", []
        evidence_raw = raw.get("evidence") or []
        if not isinstance(evidence_raw, list) or not evidence_raw:
            return f"subtask {sid}: evidence rows required", []
        rows: list[EvidenceRow] = []
        for row in evidence_raw:
            if not isinstance(row, dict):
                return f"subtask {sid}: evidence row must be object", []
            from_tool = str(row.get("from_tool") or "").strip()
            if not from_tool:
                return f"subtask {sid}: evidence.from_tool required", []
            expectation = row.get("expectation")
            if not isinstance(expectation, dict) or not expectation:
                # Tolerate models that flatten expectation keys onto the row
                # itself instead of nesting under "expectation".
                inferred: dict[str, Any] = {}
                for k in ("must_contain", "must_match", "json_path", "json_equals"):
                    if k in row:
                        inferred[k] = row[k]
                if inferred:
                    expectation = inferred
                else:
                    return (
                        f"subtask {sid}: evidence.expectation required — pass it as a "
                        "nested object: \"expectation\": {\"must_contain\": \"...\"} "
                        "or \"expectation\": {\"json_path\": \"...\", \"json_equals\": ...}",
                        [],
                    )
            err = _validate_expectation(expectation)
            if err:
                return f"subtask {sid}: {err}", []
            rows.append(
                EvidenceRow(
                    from_tool=from_tool,
                    from_action=row.get("from_action"),
                    from_intent=row.get("from_intent"),
                    expectation=expectation,
                )
            )
        out.append(
            Subtask(
                id=sid,
                goal=goal,
                surface=surface,
                evidence=rows,
                fallback_surface=raw.get("fallback_surface"),
                final_surface=bool(raw.get("final_surface")),
            )
        )
    return None, out


def _validate_expectation(exp: dict[str, Any]) -> str | None:
    keys = set(exp.keys())
    if "must_contain" in keys:
        s = str(exp["must_contain"])
        if len(re.sub(r"\s+", "", s)) < 3:
            return "must_contain needs ≥3 non-whitespace characters"
        return None
    if "must_match" in keys:
        s = str(exp["must_match"])
        if s in {"", ".*", ".+"}:
            return "must_match too permissive"
        try:
            re.compile(s)
        except re.error as e:
            return f"must_match is not a valid regex: {e}"
        return None
    if "json_path" in keys:
        path = str(exp.get("json_path") or "").strip()
        if not path:
            return "json_path is empty"
        return None
    return f"unknown expectation keys: {sorted(keys)!r}"


def _strip_function_prefix(name: str | None) -> str:
    """OpenAI's tool-call format sometimes namespaces tools as 'functions.X'.
    Normalize so 'functions.macos' and 'macos' compare equal."""
    if not isinstance(name, str):
        return ""
    return name.removeprefix("functions.")


def _tool_triple_matches(row: EvidenceRow, tc: ToolCall) -> bool:
    """Cheap match by tool/action/intent only — lets us record the readback
    even when the expectation doesn't yet pass."""
    if _strip_function_prefix(tc.name) != _strip_function_prefix(row.from_tool):
        return False
    action = tc.input.get("action") if isinstance(tc.input, dict) else None
    if row.from_action and action != row.from_action:
        return False
    intent = tc.input.get("intent") if isinstance(tc.input, dict) else None
    if row.from_intent and intent != row.from_intent:
        return False
    return True


def _matches_evidence(row: EvidenceRow, tc: ToolCall, output_text: str | None) -> bool:
    if not _tool_triple_matches(row, tc):
        return False
    text = output_text or ""
    exp = row.expectation
    if "must_contain" in exp:
        return str(exp["must_contain"]) in text
    if "must_match" in exp:
        try:
            return bool(re.search(str(exp["must_match"]), text))
        except re.error:
            return False
    if "json_path" in exp:
        try:
            data = json.loads(text)
        except (json.JSONDecodeError, TypeError):
            return False
        path = str(exp["json_path"])
        # If json_equals is missing or a wildcard, treat as path-exists check.
        if "json_equals" not in exp or exp.get("json_equals") in (None, "__ANY__", "*"):
            return _json_path_exists(data, path)
        return _json_path_equals(data, path, exp["json_equals"])
    return False


def _json_path_resolve(data: Any, path: str) -> tuple[bool, Any]:
    cursor: Any = data
    for part in [p for p in path.split(".") if p]:
        if isinstance(cursor, dict):
            if part not in cursor:
                return False, None
            cursor = cursor[part]
        elif isinstance(cursor, list):
            try:
                cursor = cursor[int(part)]
            except (ValueError, IndexError):
                return False, None
        else:
            return False, None
    return True, cursor


def _json_path_equals(data: Any, path: str, expected: Any) -> bool:
    found, value = _json_path_resolve(data, path)
    return found and value == expected


def _json_path_exists(data: Any, path: str) -> bool:
    found, value = _json_path_resolve(data, path)
    if not found:
        return False
    # Reject obviously empty values (None, "", [], {}) — "exists" implies content.
    if value is None or value == "" or value == [] or value == {}:
        return False
    return True


def _build_pending_debug(plan: list[Subtask]) -> list[dict[str, Any]]:
    """For verification_required events: each pending subtask's unsatisfied rows
    + the last readback we saw that matched the row's tool/action/intent. Lets
    the model see exactly what its expectation didn't match.
    """
    out: list[dict[str, Any]] = []
    for s in plan:
        if s.is_terminal():
            continue
        rows: list[dict[str, Any]] = []
        for row in s.evidence:
            if row.satisfied:
                continue
            rows.append(
                {
                    "from_tool": row.from_tool,
                    "from_action": row.from_action,
                    "from_intent": row.from_intent,
                    "expectation": row.expectation,
                    "last_observed": row.last_observed,
                }
            )
        if rows:
            out.append({"subtask_id": s.id, "goal": s.goal, "unsatisfied_rows": rows})
    return out


def _safe_input(value: Any) -> Any:
    try:
        json.dumps(value)
    except TypeError:
        return repr(value)
    return value
