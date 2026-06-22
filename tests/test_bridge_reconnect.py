"""Tests for the cloud bridge's sleep/network-aware reconnection.

Covers the pure-python pieces added to agent2/cloud_bridge.py:

  * ClockJumpDetector — wall-clock gap detection used to spot Mac wake.
  * ReconnectController — backoff math, wake/connectivity nudges, and
    the nudge-aware `wait()` that replaces the plain backoff sleep.

No real sockets: the connectivity probe is injected as a fake coroutine
and the WS path isn't exercised here.
"""
from __future__ import annotations

import asyncio
import time

from agent2.cloud_bridge import ClockJumpDetector, ReconnectController


# ─── ClockJumpDetector ───────────────────────────────────────────────────────


class _FakeClock:
    def __init__(self, start: float = 1000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def test_clock_jump_steady_ticks_do_not_fire():
    clock = _FakeClock()
    det = ClockJumpDetector(interval=1.0, threshold=2.0, clock=clock)
    for _ in range(10):
        clock.advance(1.0)
        assert det.tick() is None


def test_clock_jump_tolerates_scheduler_jitter():
    clock = _FakeClock()
    det = ClockJumpDetector(interval=1.0, threshold=2.0, clock=clock)
    clock.advance(2.5)  # 1.5s late — under the 2.0s threshold
    assert det.tick() is None


def test_clock_jump_detects_sleep_gap():
    clock = _FakeClock()
    det = ClockJumpDetector(interval=1.0, threshold=2.0, clock=clock)
    clock.advance(1.0)
    assert det.tick() is None
    clock.advance(301.0)  # Mac slept ~5 minutes
    gap = det.tick()
    assert gap is not None
    assert abs(gap - 300.0) < 1e-6


def test_clock_jump_resets_after_detection():
    clock = _FakeClock()
    det = ClockJumpDetector(interval=1.0, threshold=2.0, clock=clock)
    clock.advance(100.0)
    assert det.tick() is not None
    clock.advance(1.0)  # back to steady ticking
    assert det.tick() is None


# ─── ReconnectController backoff math ────────────────────────────────────────


def test_backoff_doubles_to_cap_and_resets():
    c = ReconnectController(initial=1.0, cap=60.0)
    assert c.backoff == 1.0
    seen = []
    for _ in range(8):
        c.increase()
        seen.append(c.backoff)
    assert seen == [2.0, 4.0, 8.0, 16.0, 32.0, 60.0, 60.0, 60.0]
    c.reset()
    assert c.backoff == 1.0


def test_nudge_drops_backoff_and_records_reason():
    c = ReconnectController(initial=1.0, cap=60.0, nudge_backoff=0.5)
    for _ in range(6):
        c.increase()
    assert c.backoff == 60.0
    c.nudge("wake")
    assert c.backoff == 0.5
    assert c.last_nudge_reason == "wake"
    since = c.seconds_since_nudge()
    assert since is not None and since < 1.0


def test_nudge_never_raises_backoff():
    c = ReconnectController(initial=0.1, nudge_backoff=0.5)
    assert c.backoff == 0.1
    c.nudge("wake")
    assert c.backoff == 0.1  # min(), not assignment


def test_clear_nudge_marker():
    c = ReconnectController()
    c.nudge("wake")
    c.clear_nudge_marker()
    assert c.seconds_since_nudge() is None
    assert c.last_nudge_reason is None


# ─── ReconnectController.wait() ──────────────────────────────────────────────


async def test_wait_sleeps_full_backoff_without_signals():
    c = ReconnectController(initial=0.1)
    start = time.monotonic()
    await c.wait(asyncio.Event())
    assert time.monotonic() - start >= 0.09


async def test_wait_returns_early_on_nudge():
    c = ReconnectController(initial=30.0)
    shutdown = asyncio.Event()

    async def fire_nudge():
        await asyncio.sleep(0.05)
        c.nudge("wake")

    task = asyncio.create_task(fire_nudge())
    start = time.monotonic()
    await c.wait(shutdown)
    elapsed = time.monotonic() - start
    await task
    assert elapsed < 5.0  # nowhere near the 30s backoff
    assert c.backoff == 0.5


async def test_wait_returns_immediately_if_nudged_before():
    c = ReconnectController(initial=30.0)
    c.nudge("wake")
    start = time.monotonic()
    await c.wait(asyncio.Event())
    assert time.monotonic() - start < 1.0


async def test_wait_clears_nudge_so_next_wait_sleeps():
    c = ReconnectController(initial=30.0)
    c.nudge("wake")
    await c.wait(asyncio.Event())  # consumed the nudge
    c.backoff = 0.1
    start = time.monotonic()
    await c.wait(asyncio.Event())
    assert time.monotonic() - start >= 0.09


async def test_wait_returns_early_on_shutdown():
    c = ReconnectController(initial=30.0)
    shutdown = asyncio.Event()

    async def fire_shutdown():
        await asyncio.sleep(0.05)
        shutdown.set()

    task = asyncio.create_task(fire_shutdown())
    start = time.monotonic()
    await c.wait(shutdown)
    await task
    assert time.monotonic() - start < 5.0


# ─── Connectivity probe integration ──────────────────────────────────────────


async def test_wait_nudges_on_network_down_up_transition():
    c = ReconnectController(initial=30.0, probe_interval=0.01)
    states = iter([False, False, True])

    async def probe() -> bool:
        return next(states, True)

    start = time.monotonic()
    await c.wait(asyncio.Event(), probe=probe)
    assert time.monotonic() - start < 5.0
    assert c.last_nudge_reason == "network recovery"
    assert c.backoff == 0.5


async def test_wait_does_not_shortcut_when_network_stays_up():
    # Server-down-but-network-up must still respect the full backoff,
    # otherwise the probe would defeat the 60s cap and hammer the cloud.
    c = ReconnectController(initial=0.15, probe_interval=0.02)

    async def probe() -> bool:
        return True

    start = time.monotonic()
    await c.wait(asyncio.Event(), probe=probe)
    assert time.monotonic() - start >= 0.14
    assert c.last_nudge_reason is None


async def test_short_backoff_skips_probe():
    c = ReconnectController(initial=0.05, probe_interval=10.0)
    calls = []

    async def probe() -> bool:
        calls.append(1)
        return True

    await c.wait(asyncio.Event(), probe=probe)
    assert calls == []
