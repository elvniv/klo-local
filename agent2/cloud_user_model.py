"""Mac sidecar fetch + cache for klo-cloud's user_model (hermes-five M5).

We pull the cloud-side JSONB at agent run start, format it as the
"# Things klo knows about you" block, and append to the system prompt.
Cached in-process for `_CACHE_TTL_SECONDS` so we don't refetch on every
turn within a session.
"""
from __future__ import annotations

import logging
import time
from typing import Any

import httpx

from . import cloud_auth


log = logging.getLogger("agent2.cloud_user_model")


_CACHE_TTL_SECONDS = 5 * 60.0


_cached: dict[str, Any] | None = None
_cached_at: float = 0.0


async def fetch_user_model(force: bool = False) -> dict[str, Any]:
    """Return the cached or freshly-fetched user_model dict. Empty {}
    when not signed in or the call fails — agent.py treats that as
    "no signal" and just doesn't render the block."""
    global _cached, _cached_at
    now = time.monotonic()
    if not force and _cached is not None and (now - _cached_at) < _CACHE_TTL_SECONDS:
        return _cached
    token = cloud_auth.get_session_token()
    if not token:
        return {}
    url = f"{cloud_auth.KLO_CLOUD_URL}/user_model"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": cloud_auth.SIDECAR_UA,
    }
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            resp = await client.get(url, headers=headers)
            if resp.status_code >= 400:
                log.debug("user_model: HTTP %d", resp.status_code)
                return _cached or {}
            payload = resp.json()
    except httpx.HTTPError as exc:
        log.debug("user_model: network: %s", exc)
        return _cached or {}
    model = payload.get("model") or {}
    if isinstance(model, dict):
        _cached = model
        _cached_at = now
    return model


def format_for_system_prompt(model: dict[str, Any]) -> str:
    """Render the model dict into a system-prompt block, or empty
    string if there's nothing yet. Keys are rendered in a stable order
    so the resulting prefix is cache-friendly across runs."""
    if not model:
        return ""
    sections: list[str] = ["# Things klo knows about you"]
    # Stable order — most-load-bearing keys first.
    ordered_keys = ["tone", "vocabulary", "working_style", "frustrations"]
    seen: set[str] = set()
    for key in ordered_keys + [k for k in model.keys() if k not in ordered_keys]:
        if key in seen:
            continue
        seen.add(key)
        value = model.get(key)
        if not value:
            continue
        if isinstance(value, list):
            bullets = "\n".join(f"- {v}" for v in value if v)
            if bullets:
                sections.append(f"\n## {key.replace('_', ' ').title()}\n{bullets}")
        elif isinstance(value, dict):
            bullets = "\n".join(f"- {k}: {v}" for k, v in value.items())
            if bullets:
                sections.append(f"\n## {key.replace('_', ' ').title()}\n{bullets}")
        else:
            sections.append(f"\n## {key.replace('_', ' ').title()}\n- {value}")
    body = "\n".join(sections).strip()
    return body if len(sections) > 1 else ""
