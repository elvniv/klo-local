"""Live evaluation harness for klo.

Each suite entry is a Prompt with expected_evidence — the bench asserts that
every declared evidence row appeared as an `evidence_satisfied` event during the
run, and counts surface_locked / verification_required events as discipline
failures.

Run:
    klo-bench --suite acceptance
    klo-bench --suite browser --json
    klo-bench --prompt "play sakpase by gunna in apple music" \
              --expect macos run_applescript playing
"""
from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import time
from dataclasses import asdict, dataclass, field
from typing import Any

import httpx
import websockets


DEFAULT_API = "http://127.0.0.1:8765"
TERMINAL_STATUSES = {"completed", "failed", "paused"}


@dataclass(frozen=True)
class ExpectedEvidence:
    from_tool: str
    from_action: str
    description: str = ""


@dataclass(frozen=True)
class Prompt:
    text: str
    expected_evidence: tuple[ExpectedEvidence, ...] = ()


@dataclass
class EvidenceCheck:
    expected: ExpectedEvidence
    satisfied: bool


@dataclass
class BenchResult:
    prompt: str
    run_id: str
    status: str
    elapsed_ms: int
    tool_calls: int
    screenshots: int
    final_message: str | None
    evidence: list[EvidenceCheck] = field(default_factory=list)
    plan_present: bool = False
    escalations: int = 0
    surface_lock_violations: int = 0
    verification_required: int = 0
    subtask_commits: int = 0

    @property
    def evidence_pass_rate(self) -> float:
        if not self.evidence:
            return 1.0 if self.status == "completed" else 0.0
        return sum(1 for row in self.evidence if row.satisfied) / len(self.evidence)

    @property
    def passed(self) -> bool:
        if self.status != "completed":
            return False
        if self.verification_required:
            return False
        if self.evidence and self.evidence_pass_rate < 1.0:
            return False
        return True


SUITES: dict[str, list[Prompt]] = {
    "smoke": [
        Prompt(
            "open Google in my default browser and search for 'macOS automation accessibility api'",
            (
                ExpectedEvidence("browser", "active_tab", "active tab is google search"),
            ),
        ),
        Prompt(
            "play sakpase by gunna in apple music",
            (
                ExpectedEvidence(
                    "macos",
                    "run_applescript",
                    "Music reports player state == playing for the requested track",
                ),
            ),
        ),
    ],
    "browser": [
        Prompt(
            "open the New York Times in my default browser",
            (ExpectedEvidence("browser", "active_tab", "active tab is nytimes.com"),),
        ),
        Prompt(
            "search Google for 'best ramen in nyc' in my default browser",
            (ExpectedEvidence("browser", "active_tab", "active tab is google with the query"),),
        ),
    ],
    "acceptance": [
        Prompt(
            "play human by sevdaliza in apple music",
            (
                ExpectedEvidence(
                    "macos",
                    "run_applescript",
                    "Music reports playing AND track name contains Human",
                ),
            ),
        ),
        Prompt(
            "open the new york times in my browser",
            (ExpectedEvidence("browser", "active_tab", "active tab is nytimes.com"),),
        ),
        Prompt(
            "search 'best ramen in nyc' on google",
            (ExpectedEvidence("browser", "active_tab", "active tab is google with the query"),),
        ),
        Prompt(
            "create a new note titled 'shopping list' in Notes app",
            (
                ExpectedEvidence(
                    "macos",
                    "run_applescript",
                    "Notes script returns the new note's id/body, confirming creation",
                ),
            ),
        ),
        Prompt(
            "what's the weather in tokyo right now",
            (ExpectedEvidence("web", "fetch_text", "weather text fetched from a public source"),),
        ),
    ],
}


def main() -> None:
    parser = argparse.ArgumentParser(description="Run klo evidence-driven evaluations.")
    parser.add_argument("--api", default=DEFAULT_API)
    parser.add_argument("--suite", choices=sorted(SUITES))
    parser.add_argument(
        "--prompt",
        action="append",
        default=[],
        help="Inline prompt; repeat for multiple. Pair with --expect to assert evidence.",
    )
    parser.add_argument(
        "--expect",
        action="append",
        default=[],
        help="Evidence triple FROM_TOOL FROM_ACTION DESCRIPTION; repeat per row. "
        "Applies to the most recently provided --prompt.",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON only.")
    args = parser.parse_args()

    if not args.suite and not args.prompt:
        args.suite = "smoke"

    if args.prompt:
        prompts = _prompts_from_cli(args.prompt, args.expect)
    else:
        prompts = SUITES[args.suite]

    results = asyncio.run(run_benchmark(prompts, args.api.rstrip("/")))
    if args.json:
        print(json.dumps([_serializable(result) for result in results], indent=2))
    else:
        print_report(results)


def _prompts_from_cli(prompts: list[str], expects: list[str]) -> list[Prompt]:
    by_prompt: list[Prompt] = []
    expects_iter = iter(expects)
    for prompt in prompts:
        evidence: list[ExpectedEvidence] = []
        # naive: each --expect after a --prompt belongs to that prompt until the next --prompt
        # argparse doesn't preserve interleaving, so we apply each to the corresponding index
        by_prompt.append(Prompt(text=prompt, expected_evidence=tuple(evidence)))
    # Apply all --expect to the last prompt for simplicity
    if expects and by_prompt:
        evidence = []
        for raw in expects:
            parts = raw.split(maxsplit=2)
            if len(parts) < 2:
                raise SystemExit(f"--expect requires FROM_TOOL FROM_ACTION [DESCRIPTION], got {raw!r}")
            evidence.append(
                ExpectedEvidence(
                    from_tool=parts[0],
                    from_action=parts[1],
                    description=parts[2] if len(parts) == 3 else "",
                )
            )
        last = by_prompt[-1]
        by_prompt[-1] = Prompt(text=last.text, expected_evidence=tuple(evidence))
    return by_prompt


async def run_benchmark(prompts: list[Prompt], api_base: str = DEFAULT_API) -> list[BenchResult]:
    results = []
    for prompt in prompts:
        results.append(await run_one(prompt, api_base.rstrip("/")))
    return results


async def run_one(prompt: Prompt, api_base: str) -> BenchResult:
    started = time.monotonic()
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(f"{api_base}/runs", json={"prompt": prompt.text})
        response.raise_for_status()
        run_id = response.json()["run_id"]

    final_status = "failed"
    ws_url = api_base.replace("http://", "ws://").replace("https://", "wss://")
    async with websockets.connect(f"{ws_url}/ws/runs/{run_id}") as websocket:
        async for raw in websocket:
            event = json.loads(raw)
            if event["type"] == "status_change":
                status = event["payload"].get("status")
                if status in TERMINAL_STATUSES:
                    final_status = status
                    break

    elapsed_ms = round((time.monotonic() - started) * 1000)
    async with httpx.AsyncClient(timeout=30) as client:
        detail = (await client.get(f"{api_base}/runs/{run_id}")).json()
    summary = detail["run"]
    events = detail["events"]
    return _build_result(prompt, run_id, final_status, elapsed_ms, summary, events)


def _build_result(
    prompt: Prompt,
    run_id: str,
    final_status: str,
    elapsed_ms: int,
    summary: dict[str, Any],
    events: list[dict[str, Any]],
) -> BenchResult:
    satisfied = [
        (event["payload"]["from_tool"], event["payload"]["from_action"])
        for event in events
        if event["type"] == "evidence_satisfied"
    ]
    evidence_checks = [
        EvidenceCheck(
            expected=row,
            satisfied=(row.from_tool, row.from_action) in satisfied,
        )
        for row in prompt.expected_evidence
    ]
    return BenchResult(
        prompt=prompt.text,
        run_id=run_id,
        status=final_status,
        elapsed_ms=elapsed_ms,
        tool_calls=int(summary.get("tool_calls", 0)),
        screenshots=int(summary.get("screenshots", 0)),
        final_message=summary.get("final_message"),
        evidence=evidence_checks,
        plan_present=any(event["type"] == "plan" for event in events),
        escalations=sum(1 for event in events if event["type"] == "escalation"),
        surface_lock_violations=sum(1 for event in events if event["type"] == "surface_locked"),
        verification_required=sum(1 for event in events if event["type"] == "verification_required"),
        subtask_commits=sum(1 for event in events if event["type"] == "subtask_commit"),
    )


def print_report(results: list[BenchResult]) -> None:
    passed = [result for result in results if result.passed]
    print("klo evaluation")
    for result in results:
        verdict = "PASS" if result.passed else "FAIL"
        print(
            f"- {verdict:4} {result.status:9} {result.elapsed_ms / 1000:6.1f}s "
            f"{result.tool_calls:2d} tools {result.screenshots:2d} shots "
            f"plan={'y' if result.plan_present else 'n'} "
            f"esc={result.escalations} lockviol={result.surface_lock_violations} "
            f"vreq={result.verification_required} "
            f":: {result.prompt}"
        )
        for check in result.evidence:
            mark = "+" if check.satisfied else "-"
            print(
                f"    {mark} evidence {check.expected.from_tool}/{check.expected.from_action}"
                + (f" — {check.expected.description}" if check.expected.description else "")
            )
        if result.final_message:
            print(f"    final: {result.final_message[:220]}")
    print()
    print(f"passed: {len(passed)}/{len(results)}")
    if results:
        durations = [result.elapsed_ms / 1000 for result in results]
        print(f"avg: {statistics.mean(durations):.1f}s")
        print(f"median: {statistics.median(durations):.1f}s")


def _serializable(result: BenchResult) -> dict[str, Any]:
    payload = asdict(result)
    payload["evidence"] = [
        {"expected": asdict(check.expected), "satisfied": check.satisfied}
        for check in result.evidence
    ]
    payload["passed"] = result.passed
    return payload


if __name__ == "__main__":
    main()
