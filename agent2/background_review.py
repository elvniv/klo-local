"""Post-run skill curation fork (hermes-five M3).

After every Mac agent run completes, desktop_api fires
`background_review.review(...)` as a fire-and-forget task. We feed
the transcript + current skill slugs to a Haiku call and ask it to
decide one of:

    {"action": "noop"}
    {"action": "create", "slug": "...", "title": "...", "content": "..."}
    {"action": "patch",  "slug": "...", "content": "..."}

The default heavily favors "noop" — corrections that survive across
sessions are rare and we don't want every passing comment to become
a skill.

A "create" or "patch" writes the local skill file AND posts to
klo-cloud's `/skills` endpoint so other surfaces (iOS empty-state,
future extension) can see it.
"""
from __future__ import annotations

import json
import logging
import os
import re
from typing import Any, Optional

import httpx

from . import cloud_auth, skills, cloud_skills


log = logging.getLogger("agent2.background_review")


_REVIEW_MODEL = os.environ.get("KLO_SKILL_REVIEW_MODEL", "claude-haiku-4-5-20251001")
_REVIEW_TIMEOUT_SECONDS = 25.0


_SYSTEM_PROMPT = """You are a careful curator of *durable* preferences for a user named "the user".

You will be shown one recent conversation between the user and klo (their assistant), plus the list of preferences klo has already learned about this user (their "skills").

Decide ONE of three actions:

  - "noop"   — nothing in this conversation warrants a new or updated skill.
  - "create" — there is a NEW durable preference here, not already covered by an existing skill. Output a kebab-case slug (lowercase letters/digits/hyphens, max 60 chars), a 1-sentence title, and a 1-3 paragraph body explaining WHEN the preference applies and WHY (cite the conversation only if the user gave a reason).
  - "patch"  — the conversation refines an existing skill. Output the slug + the FULL replacement content.

Bar is HIGH. Default to noop. Only return create/patch when the user has expressed a *stable* preference, frustration with a specific pattern, vocabulary mapping, or working-style fact. Do NOT add transient context, current task state, or one-off facts.

Return ONLY a JSON object. No prose, no markdown. Example:

  {"action": "create", "slug": "no-em-dashes", "title": "Never use em dashes", "content": "When delivering written copy, do not use em dashes. Use a comma, a period, or a colon instead. The user has stated this preference explicitly."}

If unsure, return {"action": "noop"}."""


async def review(transcript_text: str) -> None:
    """Background skill review for one completed run.

    `transcript_text` should be a compact rendering of the run (user
    turns + the final assistant text). The caller wraps this in
    `asyncio.create_task` and ignores the result — failures are silent.
    """
    token = cloud_auth.get_session_token()
    if not token:
        # Not signed in (or session.json missing). Nothing to do.
        return
    try:
        decision = await _ask_for_decision(transcript_text)
    except Exception as exc:  # noqa: BLE001
        log.debug("background_review: ask failed: %s", exc)
        return
    if decision is None:
        return
    action = decision.get("action")
    if action not in ("create", "patch"):
        return
    slug = (decision.get("slug") or "").strip().lower()
    if not skills.is_valid_slug(slug):
        log.info("background_review: rejected non-kebab slug %r", slug)
        return
    title = (decision.get("title") or "").strip() or slug
    content = (decision.get("content") or "").strip()
    if not content:
        return
    if action == "patch":
        existing = skills.get(slug)
        if existing is None:
            # Patch on a slug we don't have — treat as create.
            action = "create"
    new_skill = skills.Skill(slug=slug, title=title, content=content, source="auto")
    try:
        skills.save(new_skill)
        log.info("background_review: %s skill %r", action, slug)
    except Exception as exc:  # noqa: BLE001
        log.warning("background_review: local save failed: %s", exc)
        return
    # Mirror to cloud so other surfaces can see it. Silent on failure.
    try:
        await cloud_skills.push_skill(new_skill)
    except Exception as exc:  # noqa: BLE001
        log.debug("background_review: cloud push failed: %s", exc)


async def _ask_for_decision(transcript_text: str) -> Optional[dict[str, Any]]:
    """One Haiku call returning a JSON decision dict, or None on error."""
    current = skills.load_all()
    current_summary = "\n".join(f"- {s.slug}: {s.title}" for s in current) or "(none yet)"
    user_block = (
        f"# Existing skills\n{current_summary}\n\n"
        f"# Recent conversation\n{transcript_text.strip()}\n\n"
        f"Respond with a JSON object only."
    )
    url = f"{cloud_auth.KLO_CLOUD_URL}/api/llm/anthropic/messages"
    headers = {
        "Authorization": f"Bearer {cloud_auth.get_session_token() or ''}",
        "Content-Type": "application/json",
        "User-Agent": cloud_auth.SIDECAR_UA,
    }
    body: dict[str, Any] = {
        "model": _REVIEW_MODEL,
        "max_tokens": 700,
        "system": _SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": user_block}],
    }
    async with httpx.AsyncClient(timeout=_REVIEW_TIMEOUT_SECONDS) as client:
        resp = await client.post(url, headers=headers, json=body)
        if resp.status_code >= 400:
            log.debug("background_review: cloud HTTP %d: %s", resp.status_code, resp.text[:200])
            return None
        payload = resp.json()
    text = _extract_text(payload)
    return _safe_parse_json(text)


def _extract_text(payload: dict[str, Any]) -> str:
    """Anthropic /messages response → concatenated text from content blocks."""
    chunks: list[str] = []
    for block in payload.get("content", []) or []:
        if block.get("type") == "text":
            chunks.append(block.get("text", ""))
    return "".join(chunks)


_JSON_FENCE_RE = re.compile(r"```(?:json)?\s*(.+?)```", re.DOTALL)


def _safe_parse_json(text: str) -> Optional[dict[str, Any]]:
    if not text:
        return None
    raw = text.strip()
    # If wrapped in a ```json``` fence, peel it.
    m = _JSON_FENCE_RE.search(raw)
    if m:
        raw = m.group(1).strip()
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None
    return obj
