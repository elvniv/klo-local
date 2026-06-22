"""Active-application tracker — authoritative history of which apps the
user has been working with, in activation order.

Replaces the "guess via NSWorkspace.frontmostApplication once" pattern
that loses across process boundaries (klo's panel can momentarily grab
key focus during state transitions). Maintains a small ring buffer of
non-klo regular-policy app activations.

Implementation: a background thread polls
`NSWorkspace.frontmostApplication()` every 500ms. When the frontmost
flips to a new (non-klo) bundle, we record a new entry. Polling
instead of `NSWorkspaceDidActivateApplicationNotification` because
notifications require an active AppKit run loop, which the sidecar
(uvicorn/asyncio) does not provide. The 500ms cadence is plenty for
"which app was the user just in" — agents don't sub-second-pivot.
"""
from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from typing import Iterable, Optional


log = logging.getLogger("agent2.active_apps")


# klo's own bundle ID — never recorded in history (we want the user's
# real workflow, not klo bouncing in and out of focus).
_KLO_BUNDLE_ID = "com.klo.KLO"

# System processes that briefly take the frontmost slot during sleep,
# screen lock, fast-user-switch, or Mission Control transitions. They
# show up with activationPolicy()==0 but the user never wants klo to
# drive them — they should be invisible to `most_recent_non_klo`. The
# concrete bug this prevents: after the Mac wakes from sleep, the
# tracker's #1 slot can be `com.apple.loginwindow` for ~200ms, causing
# every accessibility query to resolve to "loginwindow" with an empty
# AX tree, even though the user's real frontmost app (Dia, Notes, etc.)
# is already foregrounded.
_SKIP_BUNDLE_IDS = frozenset({
    _KLO_BUNDLE_ID,
    "com.apple.loginwindow",
})

# Ring buffer cap. 16 is enough to give the prompt's CURRENT CONTEXT
# block 3-5 recent apps without bloating memory.
_HISTORY_CAP = 16

# Polling cadence. 500ms balances responsiveness against thread wakeup
# overhead. Agents typically pause between user-app switches and
# tool calls; the worst case is we miss the difference between two
# apps the user pivoted through in <500ms, which doesn't matter for
# "most recent app" queries.
_POLL_INTERVAL_SEC = 0.5


@dataclass
class AppRecord:
    """One activation event — what app came to the foreground when."""
    bundle_id: str
    name: str
    pid: int
    activated_at: float  # unix epoch seconds

    def to_dict(self) -> dict[str, object]:
        return {
            "bundle_id": self.bundle_id,
            "name": self.name,
            "pid": self.pid,
            "activated_at": self.activated_at,
            "ago_sec": round(time.time() - self.activated_at, 1),
        }


class ActiveAppTracker:
    """Polls `NSWorkspace.frontmostApplication` on a background thread;
    records non-klo app activations in a small ring buffer. Thread-safe
    — reads can come from any thread (FastAPI request handlers etc).
    """

    def __init__(self) -> None:
        self._history: list[AppRecord] = []
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._last_bundle_id: Optional[str] = None

    def start(self) -> None:
        """Start the polling thread. Idempotent."""
        if self._thread is not None and self._thread.is_alive():
            return
        try:
            import AppKit  # noqa: F401 — fail fast if pyobjc absent
        except Exception as exc:
            log.warning("ActiveAppTracker disabled — pyobjc unavailable: %s", exc)
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._poll_loop,
            name="ActiveAppTracker",
            daemon=True,
        )
        self._thread.start()
        log.info("ActiveAppTracker started — polling NSWorkspace every %.2fs", _POLL_INTERVAL_SEC)

    def stop(self) -> None:
        self._stop.set()

    def _poll_loop(self) -> None:
        try:
            import AppKit
        except Exception:
            return
        ws = AppKit.NSWorkspace.sharedWorkspace()
        while not self._stop.is_set():
            try:
                front = ws.frontmostApplication()
                if front is not None and front.activationPolicy() == 0:
                    bid = str(front.bundleIdentifier() or "")
                    if bid and bid not in _SKIP_BUNDLE_IDS:
                        if bid != self._last_bundle_id:
                            # New activation
                            self._record(AppRecord(
                                bundle_id=bid,
                                name=str(front.localizedName() or ""),
                                pid=int(front.processIdentifier()),
                                activated_at=time.time(),
                            ))
                            self._last_bundle_id = bid
                # If frontmost is klo or has no activation policy, keep
                # _last_bundle_id at whatever the last real user app was
                # so a brief klo focus-grab doesn't reset the dedup.
            except Exception as e:
                log.debug("ActiveAppTracker poll exception (continuing): %s", e)
            self._stop.wait(_POLL_INTERVAL_SEC)

    def _record(self, rec: AppRecord) -> None:
        with self._lock:
            # Deduplicate: if the same bundle is already most-recent,
            # just update the timestamp + pid.
            if self._history and self._history[0].bundle_id == rec.bundle_id:
                self._history[0] = rec
                return
            self._history.insert(0, rec)
            if len(self._history) > _HISTORY_CAP:
                self._history.pop()

    # ─── consumer API ──────────────────────────────────────────────────

    def most_recent_non_klo(
        self,
        prefer_bundle_ids: Optional[Iterable[str]] = None,
    ) -> Optional[AppRecord]:
        """Most recently activated non-klo app. If `prefer_bundle_ids`
        is given, scan for the most recent match in that set first;
        if none, fall through to most-recent regardless.

        Used for browser-biased tasks: pass
        `[default_browser_info()["bundle_id"]]` to prefer the user's
        default browser when it's in recent history.
        """
        with self._lock:
            if not self._history:
                return None
            prefer = set(prefer_bundle_ids) if prefer_bundle_ids else None
            if prefer:
                for rec in self._history:
                    if rec.bundle_id in prefer:
                        return rec
            # Belt-and-suspenders skip on read: if the most-recent record
            # is a system pseudo-app that slipped in before the recording
            # filter was active, walk past it. _SKIP_BUNDLE_IDS already
            # excludes klo itself.
            for rec in self._history:
                if rec.bundle_id not in _SKIP_BUNDLE_IDS:
                    return rec
            return None

    def history(self, limit: int = 5) -> list[dict[str, object]]:
        """Most recent first. For the agent's CURRENT CONTEXT block."""
        with self._lock:
            return [r.to_dict() for r in self._history[:max(0, limit)]]


# Module-level singleton — desktop_api.py starts this at boot.
_singleton: Optional[ActiveAppTracker] = None


def tracker() -> ActiveAppTracker:
    """Lazy singleton accessor. desktop_api startup calls .start()."""
    global _singleton
    if _singleton is None:
        _singleton = ActiveAppTracker()
    return _singleton
