"""WebSocket bridge between agent2 (this Python process) and the Chrome
extension running in the user's daily browser.

Flow:
  - bridge_server() starts a websockets server on ws://127.0.0.1:8767/extension
  - The extension connects on browser launch / reconnect
  - agent2 calls bridge_call("tabs.list", {...}) which sends an RPC and awaits
    the matching response by id

Single-client design — only one extension is expected to be connected at a
time. If multiple try, the latest wins.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
from dataclasses import dataclass
from typing import Any

import websockets
from websockets.asyncio.server import ServerConnection as WebSocketServerProtocol


HOST = "127.0.0.1"
PORT = 8767
PATH = "/extension"
RPC_PATH = "/rpc"  # Where short-lived agent2 callers connect to send RPCs

log = logging.getLogger("agent2.bridge")


@dataclass
class _Pending:
    fut: asyncio.Future


class BridgeNotConnectedError(RuntimeError):
    """Raised by Bridge.call when no Chrome extension is currently
    holding the /extension WebSocket. The desktop app catches this
    distinctly from a generic RuntimeError so it can render a branded
    "install the Chrome extension" card instead of the raw text.
    """
    code = "extension_not_connected"


class Bridge:
    def __init__(self) -> None:
        self._client: WebSocketServerProtocol | None = None
        self._pending: dict[str, _Pending] = {}
        self._next_id = 0
        self._lock = asyncio.Lock()
        self._client_meta: dict[str, Any] = {}
        # User-presence signal pushed by the extension when the user
        # switches away from the tab the agent navigated them to (see
        # background.js chrome.tabs.onActivated / windows.onFocusChanged
        # listeners). One-shot: consume_user_focus_taken() returns +
        # clears so a single takeover doesn't pin all future runs.
        self._user_focus_taken: bool = False
        self._user_focus_taken_at: float = 0.0

    @property
    def connected(self) -> bool:
        # We clear self._client in the handler's finally block on close, so
        # presence here is the source of truth.
        return self._client is not None

    @property
    def client_meta(self) -> dict[str, Any]:
        return dict(self._client_meta)

    def consume_user_focus_taken(self) -> bool:
        """Return + clear the user-focus-takeover flag. One-shot so the
        agent's next-turn check fires exactly once per takeover. Called
        through the RPC route `_internal.consume_focus_taken` from the
        agent process (which lives outside the bridge_server process).
        """
        taken = self._user_focus_taken
        self._user_focus_taken = False
        return taken

    async def push_event(self, name: str, payload: dict[str, Any] | None = None) -> bool:
        """Push an unsolicited event to the connected extension.
        Best-effort: returns True if sent, False if no client is
        connected or the send fails. Never raises — the call sites
        (run lifecycle hooks) treat these as advisory.

        Wire shape mirrors the extension → bridge `{kind:"event"}`
        frames: `{kind:"event", name, payload}`. Extension's
        onMessage handler dispatches by name (see background.js).
        """
        if self._client is None:
            return False
        try:
            await self._client.send(json.dumps({
                "kind": "event",
                "name": name,
                "payload": payload or {},
            }))
            return True
        except Exception as exc:  # noqa: BLE001
            log.warning("push_event(%s) failed: %s", name, exc)
            return False

    async def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 30) -> Any:
        """RPC into the Chrome extension. Auto-reconnects + retries once
        when the call times out — covers the common case where the MV3
        service worker died mid-RPC and the next tick brought it back.

        Idempotent reads (snapshot/text/screenshot) retry freely. Writes
        (fill/click/press) retry too, since the extension's ID-based
        targets are content-keyed and a duplicate click against a
        re-rendered page is harmless in practice.
        """
        return await self._call_with_reconnect(method, params, timeout=timeout, attempts=2)

    async def _call_with_reconnect(
        self, method: str, params: dict[str, Any] | None, *,
        timeout: float, attempts: int,
    ) -> Any:
        last_exc: BaseException | None = None
        for attempt in range(attempts):
            try:
                return await self._call_once(method, params, timeout=timeout)
            except RuntimeError as exc:
                # _call_once raises RuntimeError on timeout. Wait briefly
                # for the extension to come back (Chrome's chrome.alarms
                # tick wakes the worker every 30s; in dev the heartbeat
                # is faster) then retry the same RPC. Last attempt's
                # exception propagates.
                last_exc = exc
                if attempt + 1 >= attempts:
                    break
                log.info("bridge.call(%s) attempt %d timed out — waiting for reconnect", method, attempt + 1)
                if not await self._await_reconnect(seconds=6):
                    break
        if last_exc is not None:
            raise last_exc
        raise RuntimeError(f"extension RPC {method!r} failed without raising")

    async def _await_reconnect(self, *, seconds: float) -> bool:
        """Poll until self.connected is True or we time out."""
        ticks = int(seconds / 0.15)
        for _ in range(max(ticks, 1)):
            if self.connected:
                return True
            await asyncio.sleep(0.15)
        return self.connected

    async def _call_once(self, method: str, params: dict[str, Any] | None, *, timeout: float) -> Any:
        # Chrome MV3 service workers idle out after ~30s of no activity,
        # and the WS goes with them. Background.js wakes the worker via
        # a chrome.alarms tick every 30s + reconnects immediately, but
        # there's a 1-2s window where self.connected is False even
        # though the extension IS installed and Chrome IS running.
        # Surfacing BridgeNotConnectedError during that window makes
        # the extension look broken when it's not. Give the reconnect
        # a short grace window before giving up.
        if not self.connected:
            for _ in range(20):  # ~3s in 150ms ticks
                await asyncio.sleep(0.15)
                if self.connected:
                    break
        if not self.connected:
            # Typed exception so callers can distinguish "the user
            # hasn't installed the extension yet" from any other
            # RuntimeError. Message preserved verbatim so existing
            # str(exc)-based callers don't change behaviour.
            raise BridgeNotConnectedError(
                "extension not connected — start the agent2 bridge server and install/enable the agent2 chrome extension"
            )
        async with self._lock:
            self._next_id += 1
            req_id = f"r{self._next_id}"
            pending = _Pending(fut=asyncio.get_running_loop().create_future())
            self._pending[req_id] = pending
        payload = json.dumps({"id": req_id, "method": method, "params": params or {}})
        try:
            await self._client.send(payload)
            return await asyncio.wait_for(pending.fut, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending.pop(req_id, None)
            raise RuntimeError(f"extension RPC {method!r} timed out after {timeout}s")
        finally:
            self._pending.pop(req_id, None)

    async def _handle_client(self, websocket: WebSocketServerProtocol) -> None:
        # websockets 13+ exposes the request path on the connection itself.
        path = getattr(getattr(websocket, "request", None), "path", "/")
        if path == RPC_PATH:
            await self._handle_rpc_caller(websocket)
            return
        if path != PATH:
            await websocket.close(code=1008, reason=f"bad path: {path}")
            return
        # New extension instance replaces any existing connection.
        if self._client is not None:
            with contextlib.suppress(Exception):
                await self._client.close()
        self._client = websocket
        log.info(f"extension connected from {websocket.remote_address}")
        try:
            async for raw in websocket:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if msg.get("kind") == "hello":
                    self._client_meta = {k: msg.get(k) for k in ("version", "ua") if msg.get(k)}
                    log.info(f"extension hello: {self._client_meta}")
                    continue
                if msg.get("kind") == "event":
                    # Unsolicited events from the extension. Currently:
                    #   - user_focus_changed: user switched active tab/
                    #     window away from the agent-controlled tab.
                    # Add new event names here; keep the wire shape stable.
                    ev_name = msg.get("name")
                    payload = msg.get("payload") or {}
                    if ev_name == "user_focus_changed" and payload.get("taken"):
                        self._user_focus_taken = True
                        self._user_focus_taken_at = time.time()
                        log.info("user_focus_changed taken=true payload=%s", payload)
                    continue
                req_id = msg.get("id")
                if req_id is None:
                    continue
                pending = self._pending.get(req_id)
                if pending is None:
                    continue
                if "error" in msg:
                    pending.fut.set_exception(RuntimeError(str(msg["error"])))
                else:
                    pending.fut.set_result(msg.get("result"))
        except websockets.ConnectionClosed:
            pass
        finally:
            if self._client is websocket:
                self._client = None
                self._client_meta = {}
            log.info("extension disconnected")
            # Cancel any in-flight RPCs.
            for req_id, pending in list(self._pending.items()):
                if not pending.fut.done():
                    pending.fut.set_exception(RuntimeError("extension disconnected mid-RPC"))


    async def _handle_rpc_caller(self, websocket: WebSocketServerProtocol) -> None:
        """Short-lived caller connection: agent2 processes connect here, send
        one or more RPC requests, get responses, and disconnect.

        Methods prefixed with `_internal.` are served locally from bridge
        state (no extension round-trip) — used by the agent process to
        poll bridge-side state like the user-focus takeover flag.

        Errors carry an optional `error_code` field when the server-side
        exception type maps to one (currently just BridgeNotConnectedError).
        Callers that want the structured signal use `call_via_server`,
        which re-raises the typed exception on receipt.
        """
        try:
            async for raw in websocket:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                req_id = msg.get("id")
                method = msg.get("method")
                params = msg.get("params") or {}
                if not method:
                    continue
                try:
                    if method == "_internal.consume_focus_taken":
                        result = self.consume_user_focus_taken()
                    elif method == "_internal.push_event":
                        # Fire-and-forget event push, used by CLI runs
                        # (run.py) that don't share the in-process
                        # singleton with the bridge server. Returns
                        # whether the event reached the extension.
                        ev_name = str(params.get("name") or "")
                        ev_payload = params.get("payload") or {}
                        if not ev_name:
                            await websocket.send(json.dumps({
                                "id": req_id,
                                "error": "push_event requires non-empty name",
                            }))
                            continue
                        result = await self.push_event(ev_name, ev_payload)
                    elif method.startswith("_internal."):
                        await websocket.send(json.dumps({
                            "id": req_id,
                            "error": f"unknown internal method: {method!r}",
                        }))
                        continue
                    else:
                        result = await self.call(method, params, timeout=30)
                    await websocket.send(json.dumps({"id": req_id, "result": result}))
                except BridgeNotConnectedError as exc:
                    await websocket.send(json.dumps({
                        "id": req_id,
                        "error": str(exc),
                        "error_code": BridgeNotConnectedError.code,
                    }))
                except Exception as exc:  # noqa: BLE001
                    await websocket.send(json.dumps({"id": req_id, "error": str(exc)}))
        except websockets.ConnectionClosed:
            return


# Module-level singleton — agent2 tools dispatch through this.
bridge = Bridge()


# ----- client side: short-lived caller used by agent2.run processes ---------

async def call_via_server(method: str, params: dict[str, Any] | None = None,
                          timeout: float = 30,
                          host: str = HOST, port: int = PORT) -> Any:
    """Open a short-lived connection to the bridge_server's RPC route, send
    one request, await the matching response, close.

    This is what agent2's `browser_extension` tool uses — it's running in a
    different process from the bridge_server, so it can't share the bridge
    object directly.
    """
    url = f"ws://{host}:{port}{RPC_PATH}"
    try:
        ws = await asyncio.wait_for(websockets.connect(url, open_timeout=2), timeout=3)
    except (OSError, asyncio.TimeoutError) as exc:
        raise RuntimeError(
            f"could not reach agent2 bridge at {url}. Is bridge_server running? "
            "Start it with: uv run python -m agent2.bridge_server"
        ) from exc
    try:
        await ws.send(json.dumps({"id": "1", "method": method, "params": params or {}}))
        raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
    finally:
        with contextlib.suppress(Exception):
            await ws.close()
    msg = json.loads(raw)
    if "error" in msg:
        # Re-raise with the original type when the server tagged the
        # error with a known code, so callers can do `except
        # BridgeNotConnectedError:` exactly as they would if they were
        # in the same process as the bridge.
        if msg.get("error_code") == BridgeNotConnectedError.code:
            raise BridgeNotConnectedError(str(msg["error"]))
        raise RuntimeError(str(msg["error"]))
    return msg.get("result")


async def serve(host: str = HOST, port: int = PORT) -> None:
    async def handler(ws):
        await bridge._handle_client(ws)

    async with websockets.serve(handler, host, port):
        log.info(f"agent2 bridge listening on ws://{host}:{port}{PATH}")
        # Run forever
        await asyncio.Future()


async def detect(host: str = HOST, port: int = PORT, timeout: float = 0.3) -> bool:
    """Cheap check: is anything listening on the bridge port? Doesn't tell you
    whether the extension is connected — see bridge.connected for that."""
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout=timeout
        )
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()
        return True
    except (OSError, asyncio.TimeoutError):
        return False
