"""Per-run context the agent2 tools can read at dispatch time.

Tool handlers live in `tools.py` and are dispatched from the agent
loop without explicit access to the `_RunState` they're running for.
For most tools that's fine — they're stateless proxies.

For the klo 2.1 Track D scheduled-run safety work, `composio_execute`
(and potentially other destructive tools later) needs to know whether
it's running inside a scheduled routine + what the routine's
pre-authorization allowlist is. The cleanest way to thread that
without changing every tool function's signature is a ContextVar
that `desktop_api._run_agent` sets at the start of the run and
resets in its finally block.

Async Tasks copy the context at creation time, so this propagates
naturally to every coroutine spawned during a single run — including
tool dispatch.

Pure data carrier. No business logic. tools.py reads via
`current_run_state()`; the only writer is `_run_agent`.
"""
from __future__ import annotations

from contextvars import ContextVar, Token
from typing import Any


# Typed as Any to avoid a circular import — _RunState lives in
# desktop_api which itself imports from tools.py. Callers know the
# shape and use getattr defensively.
_current_run: ContextVar[Any] = ContextVar("klo_current_run", default=None)


def set_current_run(state: Any) -> Token:
    """Bind `state` as the current run for the duration of this Task.
    Returns a token the caller MUST pass to `reset_current_run` in a
    finally block — leaking a token leaves stale state visible to
    later runs in the same event loop."""
    return _current_run.set(state)


def reset_current_run(token: Token) -> None:
    _current_run.reset(token)


def current_run_state() -> Any:
    """Return the active run's `_RunState`, or None if no run is in
    flight on this Task (e.g. CLI / test paths)."""
    return _current_run.get()
