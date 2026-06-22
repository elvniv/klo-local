"""Run all tasks, grade each, dump JSONL trace + a summary table.

Usage:
    uv run python -m agent2.eval                # all tasks
    uv run python -m agent2.eval 04 07 10       # only listed task ids (prefix match)
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from dataclasses import asdict
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

from .agent import Agent
from .tasks import TASKS, Task


ARTIFACT_ROOT = Path(__file__).resolve().parent / "eval_artifacts"


def _color(s: str, c: str) -> str:
    return f"\x1b[{c}m{s}\x1b[0m"

GREEN = "32"
RED = "31"
YELLOW = "33"
DIM = "2"
CYAN = "36"


async def _run_task(task: Task, agent: Agent, run_dir: Path) -> dict:
    print(_color(f"\n=== {task.id} [{task.surface}] ===", CYAN))
    print(_color(f"  prompt: {task.prompt}", DIM))
    t0 = time.perf_counter()
    try:
        result = await asyncio.wait_for(agent.run(task.prompt), timeout=task.timeout_s)
        elapsed = time.perf_counter() - t0
        passed, reason = (False, "no final text")
        if result.final is not None:
            passed, reason = task.grader(result.final)
        flag = _color("PASS", GREEN) if passed else _color("FAIL", RED)
        print(f"  {flag}  reason: {reason}")
        print(_color(f"  final: {result.final!r}", DIM))
        print(_color(
            f"  turns={result.turns} elapsed={elapsed:.1f}s tokens(in/out/cached)={result.input_tokens}/{result.output_tokens}/{result.cached_input_tokens}",
            DIM,
        ))
        # Persist the per-task trace
        (run_dir / f"{task.id}.json").write_text(
            json.dumps({
                "task_id": task.id,
                "surface": task.surface,
                "prompt": task.prompt,
                "passed": passed,
                "reason": reason,
                "result": result.to_dict(),
            }, ensure_ascii=False, indent=2)
        )
        return {
            "task_id": task.id,
            "surface": task.surface,
            "passed": passed,
            "reason": reason,
            "final": result.final,
            "turns": result.turns,
            "elapsed_s": round(elapsed, 2),
            "input_tokens": result.input_tokens,
            "output_tokens": result.output_tokens,
            "cached_input_tokens": result.cached_input_tokens,
            "error": result.error,
        }
    except asyncio.TimeoutError:
        elapsed = time.perf_counter() - t0
        print(_color(f"  TIMEOUT after {task.timeout_s}s", RED))
        return {
            "task_id": task.id,
            "surface": task.surface,
            "passed": False,
            "reason": "timeout",
            "final": None,
            "turns": 0,
            "elapsed_s": round(elapsed, 2),
            "error": "timeout",
        }
    except Exception as exc:  # noqa: BLE001
        elapsed = time.perf_counter() - t0
        print(_color(f"  CRASHED: {type(exc).__name__}: {exc}", RED))
        return {
            "task_id": task.id,
            "surface": task.surface,
            "passed": False,
            "reason": f"crash: {exc}",
            "final": None,
            "turns": 0,
            "elapsed_s": round(elapsed, 2),
            "error": f"{type(exc).__name__}: {exc}",
        }


def _filter_tasks(prefixes: list[str]) -> list[Task]:
    if not prefixes:
        return list(TASKS)
    selected: list[Task] = []
    for prefix in prefixes:
        matches = [t for t in TASKS if t.id.startswith(prefix)]
        if not matches:
            print(f"  warn: no task id matched prefix {prefix!r}", file=sys.stderr)
        selected.extend(matches)
    return selected or list(TASKS)


def _summarize(results: list[dict]) -> None:
    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    in_tok = sum(r.get("input_tokens", 0) or 0 for r in results)
    out_tok = sum(r.get("output_tokens", 0) or 0 for r in results)
    cached = sum(r.get("cached_input_tokens", 0) or 0 for r in results)
    elapsed = sum(r.get("elapsed_s", 0) or 0 for r in results)

    print(_color("\n========================================", CYAN))
    print(_color(f"PASS RATE: {passed}/{total}  ({100*passed/total:.0f}%)", GREEN if passed >= total * 0.7 else YELLOW if passed > 0 else RED))
    print(f"  total time: {elapsed:.1f}s")
    print(f"  total tokens: in={in_tok} out={out_tok} cached={cached}")
    if cached and in_tok:
        print(f"  prompt cache hit rate: {100*cached/in_tok:.1f}%")
    print()
    print(f"  {'id':22s} {'surface':18s} {'pass':5s} {'turns':5s} {'time':>7s} {'tokens(io/cache)':>20s}  reason")
    for r in results:
        flag = _color("PASS", GREEN) if r["passed"] else _color("FAIL", RED)
        in_t = r.get("input_tokens", 0) or 0
        out_t = r.get("output_tokens", 0) or 0
        ct = r.get("cached_input_tokens", 0) or 0
        token_str = f"{in_t}/{out_t}/{ct}"
        print(
            f"  {r['task_id']:22s} {r['surface']:18s} {flag}  "
            f"{r['turns']:5d} {r['elapsed_s']:6.1f}s {token_str:>20s}  {r.get('reason', '')[:60]}"
        )


async def main(argv: list[str]) -> int:
    load_dotenv()
    prefixes = argv[1:]
    tasks = _filter_tasks(prefixes)

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = ARTIFACT_ROOT / timestamp
    run_dir.mkdir(parents=True, exist_ok=True)
    print(_color(f"agent2 eval — {len(tasks)} tasks → {run_dir}", CYAN))

    agent = Agent()
    results: list[dict] = []
    for task in tasks:
        result = await _run_task(task, agent, run_dir)
        results.append(result)
        # Append running summary after each task so we have data on crash
        (run_dir / "summary.jsonl").open("a").write(json.dumps(result, ensure_ascii=False) + "\n")

    _summarize(results)
    summary_json = run_dir / "summary.json"
    summary_json.write_text(json.dumps({"results": results}, ensure_ascii=False, indent=2))

    passed = sum(1 for r in results if r["passed"])
    return 0 if passed >= len(results) * 0.7 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv)))
