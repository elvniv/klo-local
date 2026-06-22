"""Mac sidecar → klo-cloud `/messages` mirror (hermes-five M1).

The Mac agent's transcript today lives only in `Agent.messages` for the
duration of a single run and then evaporates. To make "your phone
drives your Mac" emotionally true, we post each completed turn to
klo-cloud's `/messages` endpoint so the user's OTHER surfaces (iOS,
extension, future voice continuity) can pick up where things left
off.

Two design notes:

  * Fire-and-forget. The mirror call is never on the user's critical
    path. The caller wraps `asyncio.create_task(post_message(...))`
    and ignores the result. Network blips, cloud sleeps, expired
    tokens — all swallowed here so a missed mirror never delays the
    agent's reply.

  * Auth follows the same path as every other sidecar → cloud call:
    `cloud_auth.get_session_token()` reads the access token the Mac
    app's AccountManager writes to ~/.klo/session.json on sign-in +
    every refresh. No separate auth dance.
"""
from __future__ import annotations

import asyncio
import logging
from typing import Any

import httpx

from . import cloud_auth


log = logging.getLogger("agent2.cloud_mirror")


async def post_message(
    *,
    role: str,
    content: str,
    source: str = "mac",
    source_session_id: str | None = None,
    scoped_service: str | None = None,
    run_id: str | None = None,
    originating_device_id: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    """Mirror one turn to klo-cloud.

    Silent on every failure mode. Caller schedules this via
    `asyncio.create_task` and doesn't await; the agent's reply ships
    to the user immediately while this runs in the background.
    """
    token = cloud_auth.get_session_token()
    if not token:
        # Not signed in — nothing to do. Don't even log; this is normal
        # on first launch before the Mac app's deep-link OAuth lands.
        return
    if not content or not content.strip():
        return

    url = f"{cloud_auth.KLO_CLOUD_URL}/messages"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "User-Agent": cloud_auth.SIDECAR_UA,
    }
    body: dict[str, Any] = {
        "source": source,
        "role": role,
        "content": content,
    }
    if source_session_id is not None:
        body["source_session_id"] = source_session_id
    if scoped_service is not None:
        body["scoped_service"] = scoped_service
    if run_id is not None:
        body["run_id"] = run_id
    if originating_device_id is not None:
        body["originating_device_id"] = originating_device_id
    if metadata:
        body["metadata"] = metadata

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(url, headers=headers, json=body)
            if resp.status_code >= 400:
                # Log but don't raise. The pickup-on-foreground path
                # will still get the message via GET /messages on the
                # next open IF the row landed via the cloud's other
                # surfaces. If it didn't, the turn just doesn't mirror;
                # the local transcript still has it.
                log.debug(
                    "mirror post failed (status=%s body=%s) — silently skipped",
                    resp.status_code, resp.text[:160],
                )
    except (httpx.HTTPError, asyncio.CancelledError):
        log.debug("mirror post network error — silently skipped")
    except Exception as exc:  # noqa: BLE001
        log.debug("mirror post unexpected error: %s", exc)
