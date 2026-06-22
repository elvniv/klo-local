"""Push/pull helpers for the cloud-side user_skills table (hermes-five M3).

Mac sidecar treats local `~/.agent2/skills/*.md` as the in-process
source of truth (fast read at run start, ~zero latency), and cloud as
the cross-surface store. After saving locally, push to cloud
silently. On first-time-on-this-device, pull from cloud to seed the
local cache (TODO — not invoked yet on this branch; v1 only writes).
"""
from __future__ import annotations

import logging
from typing import Any

import httpx

from . import cloud_auth, skills


log = logging.getLogger("agent2.cloud_skills")


async def push_skill(skill: skills.Skill) -> None:
    """Upsert one skill to klo-cloud. Silent on failure."""
    token = cloud_auth.get_session_token()
    if not token:
        return
    url = f"{cloud_auth.KLO_CLOUD_URL}/skills"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "User-Agent": cloud_auth.SIDECAR_UA,
    }
    body: dict[str, Any] = {
        "slug": skill.slug,
        "title": skill.title,
        "content": skill.content,
        "source": skill.source,
    }
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(url, headers=headers, json=body)
            if resp.status_code >= 400:
                log.debug("push_skill: cloud HTTP %d: %s", resp.status_code, resp.text[:200])
    except httpx.HTTPError as exc:
        log.debug("push_skill: network: %s", exc)


async def pull_all() -> list[skills.Skill]:
    """Fetch every cloud-side skill for the signed-in user. Used by
    a future "first-time-on-this-Mac seed" path. Not wired today —
    file-system writes from background_review are the primary path
    and they sync to cloud already."""
    token = cloud_auth.get_session_token()
    if not token:
        return []
    url = f"{cloud_auth.KLO_CLOUD_URL}/skills"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": cloud_auth.SIDECAR_UA,
    }
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(url, headers=headers)
            if resp.status_code >= 400:
                return []
            payload = resp.json()
    except httpx.HTTPError:
        return []
    out: list[skills.Skill] = []
    for row in payload.get("skills", []) or []:
        slug = (row.get("slug") or "").strip().lower()
        if not skills.is_valid_slug(slug):
            continue
        out.append(skills.Skill(
            slug=slug,
            title=(row.get("title") or slug).strip(),
            content=(row.get("content") or "").strip(),
            source=(row.get("source") or "auto").strip(),
        ))
    return out
