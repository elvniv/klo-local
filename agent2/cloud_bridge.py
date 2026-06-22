"""Mac sidecar → klo-cloud persistent WebSocket bridge.

This module is the Mac side of the iOS companion app. It opens an
authenticated WebSocket to klo-cloud's `/ws/devices/{device_id}` and
holds it open for the lifetime of the sidecar. The cloud forwards run
requests from the iPhone over this channel; the sidecar runs them
through the existing `agent2.Agent` machinery (no agent changes — the
same `_run_agent` function that powers the local /runs HTTP endpoint)
and streams events back over the same WS.

Operational notes:

  * Sign-in dependency. The bridge can't run until the user has signed
    into klo-cloud (we need their Supabase JWT). When session.json is
    missing, the loop retries every 30s. This means a fresh install
    that hasn't been signed in yet will sit idle here, then come alive
    the moment the Mac app writes a session.

  * Device identity. The sidecar registers itself on first run via
    POST /devices/register and caches the returned device_id in
    `~/.klo/device.json`. Subsequent boots reuse the same id. If the
    user signs in as a different account, the old device_id will fail
    ownership check on the WS upgrade (403) — the receive loop catches
    that and re-registers.

  * Reconnect strategy. Exponential backoff 1s → 60s cap. Render's
    free-tier app sleeps after 15 min of idle traffic; our 25s pings
    keep that at bay.

  * Sleep/wake + network awareness. A plain backoff sleep meant a Mac
    waking from sleep could sit "offline" (from the phone's point of
    view) for up to 60s. Two cheap signals fix that without new deps:

      - Wake: a 1s ticker watches for wall-clock jumps. While the Mac
        sleeps the process is suspended, so on wake the next tick sees
        a multi-second gap → we probe the live WS (ping, 2s timeout),
        close it if it's dead, drop the backoff to 0.5s, and nudge the
        reconnect loop immediately. (We deliberately don't use
        NSWorkspaceDidWakeNotification: it needs an NSRunLoop thread +
        AppKit, and mach_absolute_time/runloop semantics differ across
        Intel vs Apple Silicon. The clock-jump detector is arch- and
        bundle-independent.)

      - Network: while waiting out a backoff longer than ~2s, we run a
        cheap TCP probe to the cloud host every 2s. Only a down→up
        TRANSITION nudges the loop, so a healthy network with a dead
        server still respects the 60s cap.

  * Opt-out. Set `KLO_DISABLE_CLOUD_BRIDGE=1` to skip the bridge
    entirely. Useful for dev machines that don't have a phone to pair
    with anyway.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import platform
import socket
import time
import uuid
from pathlib import Path
from typing import Any, Awaitable, Callable

import httpx

from . import cloud_auth


log = logging.getLogger("agent2.cloud_bridge")


# Where we cache the device_id returned by /devices/register so we
# don't pile up duplicate rows on each sidecar boot.
_DEVICE_FILE = Path(
    os.environ.get(
        "KLO_DEVICE_PATH",
        str(Path.home() / ".klo" / "device.json"),
    )
)


# Backoff window for reconnects. Doubles on each failure up to 60s.
_BACKOFF_INITIAL = 1.0
_BACKOFF_CAP = 60.0

# Backoff to drop to when a wake / connectivity-restored nudge fires —
# we want to be reconnecting within ~2s of the Mac coming back.
_BACKOFF_AFTER_NUDGE = 0.5

# Wake detection: the ticker interval and how much extra wall-clock gap
# between ticks counts as "we were asleep". 2s of slop tolerates event-
# loop jitter under load; a false positive only costs one early probe.
_WAKE_TICK_INTERVAL = 1.0
_WAKE_GAP_THRESHOLD = 2.0

# How long after a nudge a successful connect still counts as a
# "reconnected after wake" event for the latency log line.
_NUDGE_LOG_WINDOW = 120.0

# Post-wake liveness check on the existing WS connection.
_WAKE_PING_TIMEOUT = 2.0

# Connectivity probe (TCP connect to the cloud host) used while waiting
# out a long backoff. Only runs while disconnected.
_NET_PROBE_INTERVAL = 2.0
_NET_PROBE_TIMEOUT = 1.5

# Heartbeat cadence — send a `pong` (or unsolicited heartbeat) at this
# interval so Render's idle-connection reaper doesn't drop us.
_HEARTBEAT_INTERVAL = 25.0


# ─── Device identity cache ──────────────────────────────────────────────────

def _read_cached_device_id() -> str | None:
    try:
        data = json.loads(_DEVICE_FILE.read_text())
        did = data.get("device_id")
        return did if isinstance(did, str) and did else None
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def _write_cached_device_id(device_id: str, name: str) -> None:
    try:
        _DEVICE_FILE.parent.mkdir(parents=True, exist_ok=True)
        _DEVICE_FILE.write_text(json.dumps({"device_id": device_id, "name": name}))
        # Tighten — same posture as session.json.
        try:
            os.chmod(_DEVICE_FILE, 0o600)
        except OSError:
            pass
    except OSError as exc:
        log.warning("could not persist device.json: %s", exc)


def _device_name() -> str:
    """Friendly hostname for the device row.

    `socket.gethostname()` returns "Elvins-MacBook-Pro.local" on macOS,
    which is fine but the trailing `.local` is noise. SCUtil's
    ComputerName would be friendlier ("Elvin's MacBook Pro") but
    requires shelling out. For now, strip `.local` and call it good —
    user can rename via Supabase later if it matters.
    """
    host = socket.gethostname()
    if host.endswith(".local"):
        host = host[:-len(".local")]
    return host or f"klo-device-{uuid.uuid4().hex[:8]}"


def _device_metadata() -> dict[str, str]:
    return {
        "os_version": platform.mac_ver()[0] or platform.release(),
        "model": platform.machine(),
    }


async def _register_or_load_device(token: str) -> tuple[str, str] | None:
    """Return (device_id, name). Reuses cached id if present, otherwise
    calls POST /devices/register. Returns None on failure (caller
    retries with backoff)."""
    cached = _read_cached_device_id()
    name = _device_name()
    if cached:
        return cached, name
    meta = _device_metadata()
    url = f"{cloud_auth.KLO_CLOUD_URL}/devices/register"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": cloud_auth.SIDECAR_UA,
        "Content-Type": "application/json",
    }
    body = {
        "name": name,
        "device_type": "mac",
        "os_version": meta["os_version"],
        "model": meta["model"],
    }
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, headers=headers, json=body)
    except httpx.HTTPError as exc:
        log.warning("device register network error: %s", exc)
        return None
    if resp.status_code >= 400:
        log.warning("device register HTTP %d: %s", resp.status_code, resp.text[:200])
        return None
    payload = resp.json()
    device_id = payload.get("device_id")
    if not isinstance(device_id, str) or not device_id:
        log.warning("device register returned no device_id: %s", payload)
        return None
    _write_cached_device_id(device_id, name)
    log.info("registered device %s (%s)", device_id, name)
    return device_id, name


# ─── Sleep/wake + reconnect plumbing ────────────────────────────────────────


class ClockJumpDetector:
    """Detects system sleep by watching for big wall-clock gaps between
    ticks of a steady ticker. While the Mac sleeps the process is
    suspended, so the first tick after wake observes a gap far larger
    than the tick interval.

    Why ``time.time`` and not ``time.monotonic``: CPython's monotonic
    clock on macOS is mach_absolute_time, which pauses during sleep on
    Intel Macs (but not Apple Silicon) — so a monotonic-based detector
    would silently miss wakes on Intel. The wall clock always advances
    through sleep. NTP step-adjustments can fake a jump, but the cost
    is one harmless early reconnect probe.
    """

    def __init__(
        self,
        interval: float = _WAKE_TICK_INTERVAL,
        threshold: float = _WAKE_GAP_THRESHOLD,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.interval = interval
        self._threshold = threshold
        self._clock = clock
        self._last = clock()

    def tick(self) -> float | None:
        """Call once per ticker iteration. Returns the estimated sleep
        duration (seconds) if a jump was detected, else None."""
        now = self._clock()
        gap = now - self._last - self.interval
        self._last = now
        return gap if gap > self._threshold else None


class ReconnectController:
    """Owns the reconnect backoff and the wake/connectivity 'nudge'
    that lets external signals short-circuit a long backoff sleep."""

    def __init__(
        self,
        initial: float = _BACKOFF_INITIAL,
        cap: float = _BACKOFF_CAP,
        nudge_backoff: float = _BACKOFF_AFTER_NUDGE,
        probe_interval: float = _NET_PROBE_INTERVAL,
    ) -> None:
        self._initial = initial
        self._cap = cap
        self._nudge_backoff = nudge_backoff
        self._probe_interval = probe_interval
        self.backoff = initial
        self._nudge_event = asyncio.Event()
        self._net_was_down = False
        self.last_nudge_reason: str | None = None
        self._last_nudge_at: float | None = None

    def reset(self) -> None:
        self.backoff = self._initial

    def increase(self) -> None:
        self.backoff = min(self.backoff * 2, self._cap)

    def nudge(self, reason: str) -> None:
        """Wake/connectivity signal: drop the backoff and release any
        in-flight wait() immediately. Safe to call from any task on the
        same loop."""
        self.backoff = min(self.backoff, self._nudge_backoff)
        self.last_nudge_reason = reason
        self._last_nudge_at = time.monotonic()
        self._nudge_event.set()

    def seconds_since_nudge(self) -> float | None:
        if self._last_nudge_at is None:
            return None
        return time.monotonic() - self._last_nudge_at

    def clear_nudge_marker(self) -> None:
        self.last_nudge_reason = None
        self._last_nudge_at = None

    async def wait(
        self,
        shutdown: asyncio.Event,
        probe: Callable[[], Awaitable[bool]] | None = None,
    ) -> None:
        """Sleep for the current backoff, returning early when shutdown
        or a nudge arrives. While waiting out a backoff longer than the
        probe interval, run the connectivity probe; a down→up TRANSITION
        counts as a nudge (a steadily-up network with a dead server does
        not, so the backoff cap still applies there)."""
        deadline = time.monotonic() + self.backoff
        try:
            while not shutdown.is_set() and not self._nudge_event.is_set():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return
                do_probe = probe is not None and remaining > self._probe_interval
                slice_ = min(remaining, self._probe_interval) if do_probe else remaining
                await self._wait_events(shutdown, slice_)
                if do_probe and not shutdown.is_set() and not self._nudge_event.is_set():
                    up = await probe()
                    if up and self._net_was_down:
                        self._net_was_down = False
                        self.nudge("network recovery")
                        return
                    if not up:
                        self._net_was_down = True
        finally:
            self._nudge_event.clear()

    async def _wait_events(self, shutdown: asyncio.Event, timeout: float) -> None:
        waiters = [
            asyncio.create_task(shutdown.wait()),
            asyncio.create_task(self._nudge_event.wait()),
        ]
        try:
            await asyncio.wait(waiters, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for t in waiters:
                t.cancel()
            for t in waiters:
                with contextlib.suppress(asyncio.CancelledError):
                    await t


async def _probe_cloud_reachable() -> bool:
    """Cheap reachability check: TCP connect to the cloud host. No TLS,
    no HTTP — we only care whether the network path exists again."""
    base = cloud_auth.KLO_CLOUD_URL
    https = base.startswith("https")
    netloc = base.split("://", 1)[1].split("/", 1)[0]
    if ":" in netloc:
        host, _, port_s = netloc.partition(":")
        port = int(port_s)
    else:
        host, port = netloc, (443 if https else 80)
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout=_NET_PROBE_TIMEOUT
        )
    except (OSError, asyncio.TimeoutError):
        return False
    writer.close()
    with contextlib.suppress(Exception):
        await writer.wait_closed()
    return True


async def _ws_alive_after_wake() -> bool:
    """Post-wake check on the current WS connection (if any). Returns
    True only when a ping round-trips within the timeout; on failure the
    stale socket gets closed so the serve loop unwinds right away."""
    ws = _active_ws
    if ws is None:
        return False
    try:
        pong_waiter = await ws.ping()
        await asyncio.wait_for(pong_waiter, timeout=_WAKE_PING_TIMEOUT)
        return True
    except Exception:  # noqa: BLE001
        with contextlib.suppress(Exception):
            await ws.close()
        return False


async def _wake_watcher(controller: ReconnectController) -> None:
    """1s ticker that turns clock jumps (= sleep) into reconnect nudges."""
    detector = ClockJumpDetector()
    while not _shutdown.is_set():
        try:
            await asyncio.wait_for(_shutdown.wait(), timeout=detector.interval)
            return
        except asyncio.TimeoutError:
            pass
        gap = detector.tick()
        if gap is None:
            continue
        log.info("bridge: wake detected (clock jumped %.1fs)", gap)
        if await _ws_alive_after_wake():
            log.debug("bridge: connection survived sleep; no reconnect needed")
            continue
        controller.nudge("wake")


# ─── Main loop ──────────────────────────────────────────────────────────────


_shutdown = asyncio.Event()

# Current live WS connection, if any — lets the wake watcher probe/close
# a connection that died while the Mac slept instead of waiting out the
# 20s+15s ping/pong timeout.
_active_ws: Any = None


def request_shutdown() -> None:
    """Called from app shutdown handler in desktop_api.py."""
    _shutdown.set()


class _AuthExpired(Exception):
    """Signal from `_connect_and_serve` to `run_bridge`: the WS handshake
    was rejected because the access token is no longer valid. Caller
    should hand off to `_handle_auth_expired` (refresh attempt + wait
    for session.json) instead of the usual reconnect backoff loop —
    burning CPU and Render bandwidth with the same dead token at 2s
    intervals helps nobody."""


async def _handle_auth_expired(controller: "ReconnectController") -> None:
    """Auth recovery path. Triggered when WS rejects with 403/token
    expired. Try to self-refresh; if we can't, wait for session.json to
    change before retrying instead of hammering the cloud with the same
    dead token.
    """
    # Step 1: try to self-refresh. Best case, we walk away with a fresh
    # access token written to session.json and the next iteration of
    # run_bridge's loop reconnects immediately.
    try:
        new_token = await cloud_auth.refresh_session_token()
        if new_token:
            log.info("cloud bridge: self-refreshed access token")
            return
        # None = the lock was held by another process. The Mac app or a
        # peer sidecar is refreshing right now. Fall through to the wait.
        log.info("cloud bridge: refresh lock held by another process; waiting on session.json")
    except cloud_auth.AuthRefreshDead as exc:
        log.warning(
            "cloud bridge: refresh permanently dead (%s) — waiting for user re-signin",
            exc,
        )
    except cloud_auth.AuthRefreshFailed as exc:
        log.warning(
            "cloud bridge: refresh transient failure (%s) — waiting for session.json or nudge",
            exc,
        )

    # Step 2: wait for either session.json to change (someone else
    # refreshed) or a wake nudge (user came back, Mac app might write
    # a fresh token). The point: we DO NOT reconnect with the stale
    # token. The hammer stops here.
    start_mtime = cloud_auth.get_session_mtime()
    deadline = time.monotonic() + _AUTH_WAIT_MAX_SECONDS
    poll_interval = 1.0
    while time.monotonic() < deadline:
        if _shutdown.is_set():
            return
        if cloud_auth.get_session_mtime() != start_mtime:
            log.info("cloud bridge: session.json updated by external writer; resuming")
            return
        try:
            await asyncio.wait_for(
                controller._nudge_event.wait(),  # noqa: SLF001
                timeout=poll_interval,
            )
            controller._nudge_event.clear()  # noqa: SLF001
            log.info("cloud bridge: wake nudge during auth wait; rechecking session")
            return
        except asyncio.TimeoutError:
            continue
    log.info(
        "cloud bridge: auth wait timed out after %.0fs; resuming reconnect loop",
        _AUTH_WAIT_MAX_SECONDS,
    )


# Upper cap on the auth-expired wait. We don't want a forgotten orphan
# sidecar to sit silent for days — eventually we resume the normal
# backoff loop so a user that DID sign back in via a different path
# (different machine, mobile) can see the bridge revive.
_AUTH_WAIT_MAX_SECONDS = 30 * 60


async def run_bridge() -> None:
    """Top-level coroutine. Runs forever, reconnecting on disconnect.
    Started from `desktop_api`'s FastAPI startup hook."""
    if os.environ.get("KLO_DISABLE_CLOUD_BRIDGE", "0") == "1":
        log.info("cloud bridge disabled via KLO_DISABLE_CLOUD_BRIDGE=1")
        return
    controller = ReconnectController()
    watcher = asyncio.create_task(_wake_watcher(controller))
    try:
        while not _shutdown.is_set():
            try:
                await _connect_and_serve(controller)
                controller.reset()  # successful run resets the timer
            except asyncio.CancelledError:
                return
            except _AuthExpired:
                await _handle_auth_expired(controller)
                # After auth handling we want to retry immediately —
                # either the refresh worked or session.json changed, so
                # the next _connect_and_serve will pick up a fresh
                # token. Skip the normal backoff sleep entirely.
                controller.reset()
                continue
            except Exception as exc:  # noqa: BLE001
                log.warning(
                    "cloud bridge error: %s — reconnecting in %.1fs",
                    exc,
                    controller.backoff,
                )
            await controller.wait(_shutdown, probe=_probe_cloud_reachable)
            controller.increase()
    finally:
        watcher.cancel()


async def _connect_and_serve(controller: ReconnectController | None = None) -> None:
    """One end-to-end bridge session: get auth, register if needed,
    open WS, dispatch run requests until disconnect."""
    token = cloud_auth.get_session_token()
    if not token:
        # User isn't signed in yet — wait a bit and let `run_bridge`'s
        # backoff retry. Don't burn CPU polling.
        raise RuntimeError("not signed in (session.json missing)")

    reg = await _register_or_load_device(token)
    if reg is None:
        raise RuntimeError("could not register device")
    device_id, _ = reg

    # `websockets` is already a sidecar dep (uvicorn[standard] pulls it).
    import websockets

    cloud_base = cloud_auth.KLO_CLOUD_URL
    ws_scheme = "wss" if cloud_base.startswith("https") else "ws"
    host = cloud_base.split("://", 1)[1]
    url = f"{ws_scheme}://{host}/ws/devices/{device_id}?token={token}"
    log.info("connecting to %s", url.replace(token, "***"))

    # Active per-run state: run_id → asyncio.Task. Lets us cancel cleanly
    # if the cloud forwards run_cancel mid-flight.
    active_runs: dict[str, asyncio.Task[Any]] = {}

    global _active_ws
    try:
        async with websockets.connect(
            url,
            ping_interval=20,
            ping_timeout=15,
            max_size=2 * 1024 * 1024,  # 2 MiB cap; agent events stay well under
            user_agent_header=cloud_auth.SIDECAR_UA,
        ) as ws:
            _active_ws = ws
            log.info("cloud bridge connected (device=%s)", device_id)
            if controller is not None:
                nudge_age = controller.seconds_since_nudge()
                if nudge_age is not None and nudge_age < _NUDGE_LOG_WINDOW:
                    log.info(
                        "bridge: reconnected after %s in %.1fs",
                        controller.last_nudge_reason,
                        nudge_age,
                    )
                    controller.clear_nudge_marker()
            async for raw in ws:
                try:
                    frame = json.loads(raw)
                except json.JSONDecodeError:
                    log.warning("bridge: invalid JSON frame; dropping")
                    continue
                ftype = frame.get("type")
                if ftype == "run_start":
                    run_id = frame.get("run_id")
                    payload = frame.get("payload") or {}
                    if not isinstance(run_id, str):
                        continue
                    task = asyncio.create_task(
                        _dispatch_bridge_run(ws, run_id, payload, active_runs)
                    )
                    active_runs[run_id] = task
                elif ftype == "run_inject":
                    run_id = frame.get("run_id")
                    _route_inject(run_id, frame.get("payload") or {})
                elif ftype == "run_cancel":
                    run_id = frame.get("run_id")
                    _route_cancel(run_id)
                elif ftype == "ping":
                    # Cloud's keep-alive ping; respond so cloud knows we're
                    # alive. (Also covered by websockets' built-in ping_*
                    # handshake, but explicit pong here is cheap.)
                    try:
                        await ws.send(json.dumps({"type": "pong"}))
                    except Exception:  # noqa: BLE001
                        return
                elif ftype == "mirror":
                    # klo 2.1.1: scheduled-task result (preview run,
                    # background fire, or manual run-now) arrived from
                    # cloud. Previously this was dropped on the floor —
                    # the user saw the working state but never the
                    # completion. Now we forward as a DistributedNotification
                    # the Mac KLO.app subscribes to so the chat surface
                    # gets the result + the smart completion router can
                    # decide whether to auto-open the notch or just
                    # surface a quiet toast/dot.
                    msg = frame.get("message") or {}
                    _post_mac_notification("klo.cloud.mirror", msg)
                elif ftype == "run_event":
                    # klo 2.1.1: cloud-dispatched run is emitting a step
                    # progress event the Mac would otherwise miss. Forward
                    # so the notch's working state shows live activity
                    # bubbles during a preview / scheduled fire, not just
                    # the brief opener.
                    payload = frame.get("event") or {}
                    _post_mac_notification("klo.cloud.run.event", payload)
                elif ftype == "snapshot_request":
                    # Phone wants a fresh screenshot of the Mac. Handled
                    # off the agent loop entirely — no LLM cost, no
                    # confirm_action gating. Calls MacOpsServer directly
                    # and emits the PNG as a synthetic run_event so iOS
                    # can render via its existing SSE handler.
                    req_id = frame.get("req_id")
                    if isinstance(req_id, str):
                        asyncio.create_task(_handle_snapshot_request(ws, req_id))
                elif ftype == "confirm_response":
                    # Phone answered a confirm_action prompt via voice
                    # or tap. Resolves the run state's awaiting future
                    # so the agent loop unblocks and gets the decision
                    # back as the tool result.
                    run_id = frame.get("run_id")
                    approved = bool(frame.get("approved"))
                    _route_confirm(run_id, approved)
                else:
                    log.debug("bridge: ignored frame type=%s", ftype)
    except _AuthExpired:
        # Re-raise verbatim — run_bridge has the auth-recovery handler.
        raise
    except Exception as exc:  # noqa: BLE001
        # WS handshake rejected with 403 (auth expired). Re-raise as
        # _AuthExpired so run_bridge takes the recovery path instead of
        # the normal backoff loop with the same dead token.
        if _is_403_rejection(exc):
            log.info("cloud bridge: WS rejected (403) — handing off to auth recovery")
            raise _AuthExpired() from exc
        raise
    finally:
        _active_ws = None


def _is_403_rejection(exc: BaseException) -> bool:
    """Detect a 403 WebSocket rejection across `websockets` library
    versions. v10+ raises InvalidStatusCode (status_code attribute); v11+
    raises InvalidStatus (response.status_code). Fall back to string
    match so future versions don't slip through silently."""
    status = getattr(exc, "status_code", None)
    if status is None:
        resp = getattr(exc, "response", None)
        status = getattr(resp, "status_code", None) if resp is not None else None
    if status == 403:
        return True
    text = str(exc).lower()
    return "403" in text and ("forbidden" in text or "rejected" in text)


# ─── Run dispatch ──────────────────────────────────────────────────────────


async def _dispatch_bridge_run(
    ws: Any,
    run_id: str,
    payload: dict[str, Any],
    active_runs: dict[str, asyncio.Task[Any]],
) -> None:
    """Stand up a _RunState for a phone-initiated run, hook event
    forwarding to the WS, and call _run_agent. Lives in its own task
    so the bridge receive loop stays responsive."""
    # Local import — avoids a circular dependency with desktop_api
    # importing this module at startup.
    from . import desktop_api

    prompt = (payload.get("prompt") or "").strip()
    if not prompt:
        log.warning("bridge run_start with empty prompt; ignoring")
        active_runs.pop(run_id, None)
        return

    state = desktop_api._RunState(
        run_id=run_id,
        prompt=prompt,
        prior_messages=payload.get("prior_messages") or [],
        scoped_service=payload.get("scoped_service"),
    )
    # klo 2.1 Track D: thread scheduled-run safety context into the
    # run state. composio_execute checks these to gate destructive
    # actions behind the routine's pre-auth allowlist.
    state.source = payload.get("source")
    state.allowed_actions = payload.get("allowed_actions") or []

    # Forward every event back over the WS as a `run_event` frame.
    # asyncio.create_task wraps the send so add_event (which is sync)
    # doesn't block the agent loop on a network write.
    #
    # klo 2.1.1: also surface step_progress events to the local Mac
    # KLO.app so the user sees live activity bubbles during a cloud-
    # dispatched run (scheduled fire, routine preview, etc). Without
    # this the user gets a brief "Checking on that…" opener and then
    # the working state goes silent until completion. The local
    # DistributedNotification path is the same one the Mac already
    # uses for the run.start / run.end fire toggles.
    is_scheduled_run = (state.source or "").startswith("scheduled")
    def forward(event: dict[str, Any]) -> None:
        asyncio.create_task(_safe_send(ws, {
            "type": "run_event",
            "run_id": run_id,
            "event": event,
        }))
        if is_scheduled_run and event.get("kind") == "step_progress":
            _post_mac_notification("klo.cloud.run.event", {
                "run_id": run_id,
                "source": state.source,
                "event": event,
            })

    state.bridge_forward = forward

    desktop_api._runs[run_id] = state
    # Tell the Mac KLO app that a phone-initiated run is starting so the
    # notch fire activates while we work. The Mac app subscribes to the
    # paired notification names below via DistributedNotificationCenter.
    _post_mac_notification(
        "klo.bridge.run.start",
        {"run_id": run_id, "prompt": prompt[:200]},
    )
    try:
        await desktop_api._run_agent(state)
    except Exception as exc:  # noqa: BLE001
        log.exception("bridge run %s crashed: %s", run_id, exc)
    finally:
        active_runs.pop(run_id, None)
        # Stop the fire — same notification on every exit path (success,
        # cancel, crash) so the Mac panel never gets stuck in .working.
        _post_mac_notification(
            "klo.bridge.run.end",
            {"run_id": run_id},
        )
        # Keep _runs entry for ~30s in case the cloud sends a late
        # follow-up (cancel, inject) — the local cleanup matches what
        # desktop_api does for local runs.


def _post_mac_notification(name: str, user_info: dict[str, Any]) -> None:
    """Best-effort macOS DistributedNotificationCenter post. The Mac KLO
    app listens for these to mirror remote-run lifecycle into its own
    .working / .idle mode (notch fire on/off). Silent no-op when PyObjC
    isn't available so non-Mac sidecar runs don't crash."""
    try:
        from Foundation import NSDistributedNotificationCenter  # type: ignore
        NSDistributedNotificationCenter.defaultCenter().postNotificationName_object_userInfo_deliverImmediately_(
            name,
            None,
            user_info,
            True,
        )
    except Exception as exc:  # noqa: BLE001
        log.debug("mac notification %s skipped: %s", name, exc)


async def _handle_snapshot_request(ws: Any, req_id: str) -> None:
    """Service one cloud-side snapshot_request frame.

    Calls MacOpsServer directly (port 8788), then sends two events back
    over the WS: a `snapshot` event carrying the PNG, then a terminal
    `status_change` so iOS's SSE subscriber closes cleanly. Errors are
    surfaced as a `status_change` with status=failed + reason so the
    phone can show a useful message instead of timing out.
    """
    import base64
    import httpx
    error: str | None = None
    payload: dict[str, Any] | None = None
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            resp = await client.post("http://127.0.0.1:8788/v1/screenshot", json={})
            data = resp.json()
        if not data.get("ok"):
            error = str(data.get("error") or "screenshot failed")
        else:
            payload = {
                "req_id": req_id,
                "png_b64": data.get("base64_png"),
                "geometry": data.get("geometry"),
            }
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"
    if payload is not None:
        await _safe_send(ws, {
            "type": "run_event",
            "run_id": req_id,
            "event": {"type": "snapshot", "kind": "snapshot", "payload": payload},
        })
        await _safe_send(ws, {
            "type": "run_event",
            "run_id": req_id,
            "event": {"type": "status_change", "payload": {"status": "completed"}},
        })
        return
    await _safe_send(ws, {
        "type": "run_event",
        "run_id": req_id,
        "event": {
            "type": "status_change",
            "payload": {"status": "failed", "error": error or "unknown"},
        },
    })


async def _safe_send(ws: Any, frame: dict[str, Any]) -> None:
    try:
        await ws.send(json.dumps(frame))
    except Exception as exc:  # noqa: BLE001
        log.warning("bridge send failed: %s", exc)


def _route_inject(run_id: str | None, payload: dict[str, Any]) -> None:
    """User typed mid-run on the phone. Drop the message into the
    local run's inbox so the agent picks it up at the next turn
    boundary. Mirrors the local /ws/runs/{id} `inject_message` path."""
    from . import desktop_api
    if not isinstance(run_id, str):
        return
    state = desktop_api._runs.get(run_id)
    if state is None:
        return
    text = (payload.get("text") or "").strip()
    if not text:
        return
    kind = payload.get("kind") or "inject"
    try:
        state.inbox.put_nowait({"text": text, "kind": kind})
    except Exception:  # noqa: BLE001
        log.warning("inbox put failed for run %s", run_id)


def _route_cancel(run_id: str | None) -> None:
    """Phone hit cancel. Signal the local cancel_event + cancel the
    running task. Same as POST /runs/{id}/cancel on the local API."""
    from . import desktop_api
    if not isinstance(run_id, str):
        return
    state = desktop_api._runs.get(run_id)
    if state is None:
        return
    state.cancel_event.set()
    if state.task is not None and not state.task.done():
        with contextlib.suppress(Exception):
            state.task.cancel()


def _route_confirm(run_id: str | None, approved: bool) -> None:
    """Phone answered a confirm_action prompt. Resolves the run's
    awaiting confirm_event so the agent loop unblocks. Same as POST
    /runs/{id}/confirm on the local sidecar API but routed through
    the cloud WS instead."""
    from . import desktop_api
    if not isinstance(run_id, str):
        return
    state = desktop_api._runs.get(run_id)
    if state is None:
        return
    if not state.confirm_pending:
        log.info("confirm_response for %s but no confirm pending — ignoring", run_id)
        return
    state.confirm_result = {"approved": approved}
    state.confirm_event.set()
