"""End-to-end smoke for the long-horizon harness.

Exercises the workspace primitive + tools + ContextVar propagation +
self-scheduled cron pattern + approval gate + idempotency, all without
spending a token. Tactics:
  - sandbox workspace dir at ~/.klo-smoke-test/
  - real workspace + tool code (no mocks)
  - schedule_task replaced with an in-memory fake cron
  - Agent class replaced with a MockAgent that executes a few real tool
    calls based on the prompt (proves ContextVar propagation through
    delegate_task without an LLM)

Run via:
    uv run python -m agent2._smoke_workspace
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
import textwrap
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import workspace as ws_mod
from . import tools


# ─── Sandbox setup ─────────────────────────────────────────────────────

SANDBOX = Path.home() / ".klo-smoke-test"


def setup_sandbox() -> None:
    shutil.rmtree(SANDBOX, ignore_errors=True)
    SANDBOX.mkdir(parents=True, exist_ok=True)
    # Redirect workspaces root to the sandbox so we don't touch the real
    # ~/Library location.
    ws_mod._workspaces_root = lambda: SANDBOX / "workspaces"


def teardown_sandbox() -> None:
    shutil.rmtree(SANDBOX, ignore_errors=True)


# ─── Fake cron store ───────────────────────────────────────────────────

FAKE_CRON: list[dict[str, Any]] = []


async def fake_schedule_task(user_phrase: str, prompt: str, scoped_service: str | None = None) -> str:
    """Replaces the real schedule_task. Records the schedule in
    FAKE_CRON; in a real run klo-cloud would persist it and the
    scheduler would fire it on cadence."""
    entry = {
        "id": f"sched_{len(FAKE_CRON) + 1}",
        "user_phrase": user_phrase,
        "prompt": prompt,
        "scoped_service": scoped_service,
        "drafted_at": time.time(),
        "fires_so_far": 0,
    }
    FAKE_CRON.append(entry)
    return json.dumps({"ok": True, "drafted": True, "schedule_id": entry["id"]})


# ─── MockAgent for delegate_task children ─────────────────────────────

@dataclass
class MockRunResult:
    """Shape-compatible with agent.RunResult for the bits delegate_task reads."""
    task: str
    final: str | None
    turns: int = 1
    elapsed_s: float = 0.1
    input_tokens: int = 0
    output_tokens: int = 0
    cached_input_tokens: int = 0
    anthropic_input_tokens: int = 0
    anthropic_output_tokens: int = 0
    anthropic_calls: int = 0
    estimated_cost_usd: float = 0.0
    budget_warning: str | None = None
    error: str | None = None
    trace: list = field(default_factory=list)
    permission_refusal_service: str | None = None
    handoff: bool = False
    handoff_message: str | None = None


class MockAgent:
    """Stand-in for agent2.agent.Agent. Doesn't call any LLM — instead
    executes a hand-coded recipe based on the prompt so we can verify
    real tool dispatch + ContextVar propagation in a delegated child."""
    def __init__(self, model: str = "mock", max_turns: int = 10, verbose: bool = False,
                 disabled_tools: set[str] | None = None, **_ignored: Any) -> None:
        self.model = model
        self.max_turns = max_turns
        self.disabled_tools = disabled_tools or set()

    async def run(self, prompt: str, extra_system_notes: str | None = None,
                  prior_messages: list[dict] | None = None) -> MockRunResult:
        # Recipe: a "research worker" reads the brief, saves an evidence
        # file, returns a tight summary. This is the canonical Worker
        # shape from KLO_LONG_HORIZON.
        if "TikTok" in prompt or "tiktok" in prompt.lower():
            return await self._research_tiktok(prompt)
        if "Reddit" in prompt or "reddit" in prompt.lower():
            return await self._research_reddit(prompt)
        return MockRunResult(task=prompt, final=f"(mock child ran for {prompt[:60]!r})")

    async def _research_tiktok(self, prompt: str) -> MockRunResult:
        # Verify ContextVar propagation: child reads workspace via the tool.
        br = await tools.dispatch("workspace_read", {"name": "brief"})
        assert json.loads(br)["ok"], "child could not read brief — ContextVar didn't propagate"
        # Save dense findings as evidence
        evidence = json.dumps([
            {"handle": "@mealtracker_app", "followers": 240_000, "hook": "POV: ADHD and you actually want to eat healthy", "views": 1_200_000},
            {"handle": "@calorielab", "followers": 86_000, "hook": "watch me track this in 0.3 seconds", "views": 880_000},
            {"handle": "@whatieatinaday_real", "followers": 410_000, "hook": "no judgment edition", "views": 2_100_000},
        ], indent=2)
        await tools.dispatch("workspace_save_evidence", {
            "name": "tiktok-top-creators.json", "content": evidence,
        })
        summary = (
            "Top TikTok pattern: under-30s POV Reels with hand-held camera, "
            "no-judgment register, hook in first 1.5s. Strongest creators: "
            "@whatieatinaday_real (2.1M views), @mealtracker_app (1.2M), "
            "@calorielab (880k). Recurring comment gap: people asking how to "
            "track restaurant meals without weighing them. NOBODY in the top "
            "10 is addressing that well."
        )
        return MockRunResult(task=prompt, final=summary)

    async def _research_reddit(self, prompt: str) -> MockRunResult:
        br = await tools.dispatch("workspace_read", {"name": "brief"})
        assert json.loads(br)["ok"], "child could not read brief — ContextVar didn't propagate"
        evidence = json.dumps([
            {"subreddit": "r/loseit", "thread": "reddit.com/r/loseit/comments/xyz1", "question": "best app for ADHD calorie counting?"},
            {"subreddit": "r/1500isplenty", "thread": "reddit.com/r/1500isplenty/comments/xyz2", "question": "anyone use the camera scan feature?"},
        ], indent=2)
        await tools.dispatch("workspace_save_evidence", {
            "name": "reddit-questions.json", "content": evidence,
        })
        summary = (
            "Reddit r/loseit + r/1500isplenty: heavy ADHD audience, "
            "repeated unanswered question about camera-scan accuracy in "
            "restaurant settings. Sentiment: tired of MyFitnessPal's UI."
        )
        return MockRunResult(task=prompt, final=summary)


# ─── Test phases ───────────────────────────────────────────────────────

async def phase_1_init_and_plan() -> str:
    """Phase 1: simulate klo recognizing a long-horizon ask and spinning
    up a workspace. Returns the slug for later phases."""
    print()
    print("━" * 72)
    print("PHASE 1 — klo recognizes 'be my CMO for X' → workspace_init + plan")
    print("━" * 72)

    user_ask = (
        "be my CMO for meal tracking for the next 30 days. "
        "product is a camera-based calorie scanner. budget $200/mo."
    )

    res = await tools.dispatch("workspace_init", {
        "name": "meal-tracking-launch",
        "brief": user_ask,
    })
    parsed = json.loads(res)
    assert parsed["ok"], f"workspace_init failed: {parsed}"
    slug = parsed["slug"]
    print(f"✓ workspace_init slug={slug}")

    # klo writes its initial plan
    plan_md = textwrap.dedent("""\
        # Plan — meal-tracking-launch

        ## Week 1 — Research + foundation
        - [ ] Research TikTok creators in the meal-tracking + ADHD audience
        - [ ] Research Reddit threads (r/loseit, r/1500isplenty) for unanswered questions
        - [ ] Identify the gap competitors are missing
        - [ ] Pick primary + secondary content formats

        ## Week 2 — Production
        - [ ] Cut + caption first 3 Shorts
        - [ ] Schedule shoot days against the user's calendar
        - [ ] Set up YouTube Shorts channel art

        ## Week 3 — Distribution
        - [ ] Publish Shorts 1-3 on cadence
        - [ ] Engage with comments
        - [ ] Cross-post to Instagram Reels

        ## Week 4 — Measure + replan
        - [ ] Pull analytics
        - [ ] Identify what worked
        - [ ] Replan: run weekly KPI review + Strategist refresh
        """)
    res = await tools.dispatch("workspace_write", {"name": "plan", "content": plan_md})
    assert json.loads(res)["ok"]
    print("✓ wrote initial plan.md")

    await tools.dispatch("workspace_append_log", {
        "message": "initiative initialized; drafted week-by-week plan",
    })
    print("✓ logged initiation event")

    # klo notes a user-explicit constraint as a decision
    await tools.dispatch("workspace_append_decision", {
        "text": "budget capped at $200/mo (per user brief)",
    })
    print("✓ logged budget decision")

    return slug


async def phase_2_parallel_workers(slug: str) -> None:
    """Phase 2: klo spawns parallel research workers via delegate_task.
    Workers inherit the workspace via ContextVar and save evidence."""
    print()
    print("━" * 72)
    print("PHASE 2 — delegate_task fans out research workers (ContextVar inheritance)")
    print("━" * 72)

    # Confirm the workspace is bound from phase 1
    assert ws_mod.current_workspace() is not None
    assert ws_mod.current_workspace().slug == slug
    print(f"✓ workspace still bound to parent: {slug}")

    res = await tools.dispatch("delegate_task", {
        "tasks": [
            {"prompt": "Research TikTok creators in meal-tracking. Hooks + comment gaps.", "worker_kind": "research"},
            {"prompt": "Research Reddit r/loseit + r/1500isplenty for unanswered questions.", "worker_kind": "research"},
        ],
    })
    parsed = json.loads(res)
    assert parsed["ok"], f"delegate_task failed: {parsed}"
    assert len(parsed["results"]) == 2
    for r in parsed["results"]:
        print(f"  ✓ worker returned: {r['summary'][:80]}…")

    # Verify evidence files landed on disk (proves children's
    # workspace_save_evidence calls hit the parent's workspace)
    ws = ws_mod.current_workspace()
    evidence_files = sorted(p.name for p in ws.evidence_dir.iterdir())
    print(f"✓ evidence/ contents: {evidence_files}")
    assert "tiktok-top-creators.json" in evidence_files
    assert "reddit-questions.json" in evidence_files

    await tools.dispatch("workspace_append_log", {
        "message": f"delegated 2 research workers; {len(evidence_files)} evidence files captured",
    })


async def phase_3_self_schedule(slug: str) -> str:
    """Phase 3: klo schedules its OWN weekly KPI review. Returns the
    schedule_id for the simulated fire in phase 4."""
    print()
    print("━" * 72)
    print("PHASE 3 — klo schedules itself for a weekly KPI review (the cron primitive)")
    print("━" * 72)

    # The canonical pattern from KLO_LONG_HORIZON: scheduled prompt
    # starts with workspace_load("<slug>") so the future klo invocation
    # picks up state.
    weekly_prompt = textwrap.dedent(f"""\
        workspace_load("{slug}"). Pull this week's YouTube Shorts analytics via web tools.
        Read recent events via workspace_read(name='log'). Compare this week's view counts
        and CTR against last week. If above target, append a one-line entry to log.md and
        reply [SILENT]. If below target, draft a one-paragraph diagnosis + a suggested plan
        revision and surface it.""")

    res = await tools.dispatch("schedule_task", {
        "user_phrase": "every monday at 8am",
        "prompt": weekly_prompt,
    })
    parsed = json.loads(res)
    assert parsed["ok"]
    assert parsed["drafted"]
    schedule_id = parsed["schedule_id"]
    print(f"✓ scheduled weekly KPI review: {schedule_id}")
    print(f"  prompt: {weekly_prompt[:100]}…")

    await tools.dispatch("workspace_append_log", {
        "message": f"scheduled weekly KPI review ({schedule_id}) for Mondays 8am",
    })
    return schedule_id


async def phase_4_cron_fires(slug: str, schedule_id: str) -> None:
    """Phase 4: simulate the scheduler firing the weekly job a week
    later. Verifies the workspace_load handoff works."""
    print()
    print("━" * 72)
    print("PHASE 4 — simulate cron firing one week later")
    print("━" * 72)

    # Find the scheduled entry
    entry = next(s for s in FAKE_CRON if s["id"] == schedule_id)
    entry["fires_so_far"] += 1

    # Simulate the scheduler invoking klo with the scheduled prompt.
    # In real klo-cloud this is a new agent run with no prior context.
    # The agent's FIRST action would be to parse the workspace_load
    # directive and bind. We do that here directly.
    print(f"  scheduler fires {schedule_id}, fire #{entry['fires_so_far']}")
    print(f"  scheduled prompt directs: workspace_load(\"{slug}\")")

    # Clear context to simulate a fresh agent run. set(None) returns a
    # Token whose prior value is the bound workspace; we DON'T reset
    # because we want to actually leave it at None for the rest of this
    # phase (workspace_load will rebind below).
    ws_mod._current_workspace.set(None)
    assert ws_mod.current_workspace() is None
    print("  (cleared context — simulating fresh agent invocation)")

    # New agent's first call: workspace_load
    res = await tools.dispatch("workspace_load", {"slug": slug})
    parsed = json.loads(res)
    assert parsed["ok"]
    assert parsed["slug"] == slug
    print(f"  ✓ workspace_load picked up state: brief={parsed['brief'][:60]!r}…")

    # New agent reads the log to see what's been done
    res = await tools.dispatch("workspace_read", {"name": "log"})
    parsed = json.loads(res)
    log_content = parsed["content"]
    print(f"  ✓ log has {len(log_content.splitlines())} lines of prior history")

    # Simulate a KPI-above-target outcome: append summary to log + reply [SILENT]
    await tools.dispatch("workspace_append_log", {
        "message": "week 1 KPI review: Tue Short hit 12k views (above 5k target); Thu Short hit 800 (below 2k)",
    })
    print("  ✓ appended week-1 KPI summary to log")
    print("  → reply [SILENT] (mixed results, no user buzz this run since not below threshold)")


async def phase_5_approval_gate(slug: str) -> None:
    """Phase 5: simulate a worker trying to publish, getting gated,
    user approving, idempotent re-fire blocked."""
    print()
    print("━" * 72)
    print("PHASE 5 — approval gate + idempotency on external action")
    print("━" * 72)

    ws = ws_mod.current_workspace()
    assert ws is not None and ws.slug == slug

    # Worker wants to publish a YouTube Short
    res = await tools.dispatch("workspace_request_human", {
        "reason": "publishing to YouTube",
        "ask": "approve YT Short #1 for publish?",
        "payload": {
            "title": "POV: ADHD and you actually want to eat healthy",
            "file": "~/Movies/meal-tracking-finished/2026-06-23-shorts-1.mp4",
            "publish_time": "Wed 7am",
        },
    })
    parsed = json.loads(res)
    assert parsed["ok"]
    cid = parsed["clearance_id"]
    print(f"✓ worker queued approval: {cid}")

    # Worker polls — still pending
    res = await tools.dispatch("workspace_check_clearance", {"clearance_id": cid})
    assert json.loads(res)["status"] == "pending"
    print("✓ check_clearance pending (worker would wait or handoff here)")

    # Simulate user tapping APPROVE in the notch panel
    ws.resolve_pending(cid, approved=True, note="lgtm, ship it")
    print("✓ user approved via desktop UI (resolve_pending)")

    res = await tools.dispatch("workspace_check_clearance", {"clearance_id": cid})
    parsed = json.loads(res)
    assert parsed["status"] == "approved"
    print(f"✓ check_clearance now: {parsed['status']}")

    # Worker executes the publish + records idempotency key
    idem_key = f"{slug}/week-2-step-1/publish_youtube"
    assert ws.check_idempotency(idem_key) is False
    ws.record_external("publish_youtube", idem_key, {
        "video_id": "abc123",
        "clearance_id": cid,
    })
    print(f"✓ external action recorded with idempotency key: {idem_key}")

    # Simulate a scheduled-task replay (cron re-fires for any reason)
    # — the gate MUST block re-publish.
    assert ws.check_idempotency(idem_key) is True
    print("✓ idempotency layer blocks re-fire of same action — would skip publish on replay")


def phase_6_show_artifacts(slug: str) -> None:
    """Phase 6: print the final workspace dir tree + key file contents."""
    print()
    print("━" * 72)
    print("PHASE 6 — final workspace state on disk")
    print("━" * 72)

    ws = ws_mod.load(slug)
    print(f"\n📁 {ws.root}")
    for p in sorted(ws.root.rglob("*")):
        rel = p.relative_to(ws.root)
        if p.is_dir():
            print(f"  {rel}/")
        else:
            size = p.stat().st_size
            print(f"  {rel}  ({size} bytes)")

    print()
    print("─ brief.md ─")
    print(textwrap.indent(ws.read_brief(), "  "))

    print()
    print("─ plan.md (first 20 lines) ─")
    plan = ws.read_plan().splitlines()
    print(textwrap.indent("\n".join(plan[:20]), "  "))

    print()
    print("─ log.md ─")
    print(textwrap.indent(ws.read_log(), "  "))

    print()
    print("─ decisions.md ─")
    print(textwrap.indent(ws.read_decisions(), "  "))

    print()
    print("─ pending.json ─")
    print(textwrap.indent(json.dumps(ws._read_pending_queue(), indent=2), "  "))

    print()
    print("─ FAKE_CRON store ─")
    for s in FAKE_CRON:
        print(f"  {s['id']}: {s['user_phrase']!r}  fired={s['fires_so_far']}x")
        print(f"    prompt: {s['prompt'][:120]!r}…")


# ─── Main ──────────────────────────────────────────────────────────────

async def main() -> int:
    setup_sandbox()

    # Install mocks for schedule_task + the child Agent class
    original_schedule_handler = tools._DISPATCH["schedule_task"]
    tools._DISPATCH["schedule_task"] = fake_schedule_task

    from . import agent as agent_mod
    original_agent_cls = agent_mod.Agent
    agent_mod.Agent = MockAgent  # delegate_task will instantiate the mock

    try:
        slug = await phase_1_init_and_plan()
        await phase_2_parallel_workers(slug)
        sched_id = await phase_3_self_schedule(slug)
        await phase_4_cron_fires(slug, sched_id)
        await phase_5_approval_gate(slug)
        phase_6_show_artifacts(slug)
    finally:
        tools._DISPATCH["schedule_task"] = original_schedule_handler
        agent_mod.Agent = original_agent_cls

    print()
    print("=" * 72)
    print("END-TO-END SMOKE: PASSED")
    print("=" * 72)
    # Leave the sandbox in place so the user can browse it
    print(f"\n(workspace artifacts preserved at {SANDBOX} — `rm -rf` when done)")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
