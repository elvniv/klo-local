"""Local skill markdown files for hermes-style self-curation (M3).

Skills are short markdown files keyed by a kebab-case slug, stored at
`~/.agent2/skills/{slug}.md`. Each carries a YAML-ish frontmatter
header (slug/title/source) and a freeform body that gets injected into
the agent's system prompt at run start.

The background-review fork after each run reads the transcript +
existing skills and decides whether to patch one, create one, or do
nothing. Same files are mirrored to klo-cloud's `user_skills` table
so future surfaces can read them.

Frontmatter shape (simple key:value lines, blank line, body):

    ---
    slug: no-em-dashes
    title: Never use em dashes
    source: auto
    ---
    When delivering written copy, do not use em dashes. Use a comma,
    a period, or a colon instead. Stated by user on 2026-04-12.
"""
from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


log = logging.getLogger("agent2.skills")


SKILLS_DIR = Path(
    os.environ.get("KLO_SKILLS_DIR", str(Path.home() / ".agent2" / "skills"))
)


@dataclass
class Skill:
    slug: str
    title: str
    content: str
    source: str = "auto"  # 'auto' | 'manual'

    def to_markdown(self) -> str:
        lines = [
            "---",
            f"slug: {self.slug}",
            f"title: {self.title}",
            f"source: {self.source}",
            "---",
            "",
            self.content.strip(),
            "",
        ]
        return "\n".join(lines)


_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,80}$")


def is_valid_slug(s: str) -> bool:
    return bool(_SLUG_RE.match(s))


def ensure_dir() -> None:
    SKILLS_DIR.mkdir(parents=True, exist_ok=True)


def _path(slug: str) -> Path:
    return SKILLS_DIR / f"{slug}.md"


def load_all() -> list[Skill]:
    """Read every *.md under the skills dir. Silent on per-file parse
    failures so a malformed skill doesn't take down the whole agent.
    """
    if not SKILLS_DIR.exists():
        return []
    out: list[Skill] = []
    for p in sorted(SKILLS_DIR.glob("*.md")):
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        s = _parse(text)
        if s is not None:
            out.append(s)
    return out


def get(slug: str) -> Skill | None:
    p = _path(slug)
    if not p.exists():
        return None
    try:
        return _parse(p.read_text(encoding="utf-8"))
    except OSError:
        return None


def save(skill: Skill) -> None:
    """Write or overwrite the skill file. Caller validates slug shape
    via is_valid_slug; we re-check defensively because cloud-sync
    could deliver a hostile slug.
    """
    if not is_valid_slug(skill.slug):
        raise ValueError(f"invalid skill slug: {skill.slug!r}")
    ensure_dir()
    _path(skill.slug).write_text(skill.to_markdown(), encoding="utf-8")


def delete(slug: str) -> bool:
    if not is_valid_slug(slug):
        return False
    p = _path(slug)
    if p.exists():
        try:
            p.unlink()
            return True
        except OSError:
            return False
    return False


def _parse(text: str) -> Optional[Skill]:
    """Split frontmatter (between two `---` lines at the top) from
    the markdown body. Tolerant of trailing whitespace and missing
    trailing newline; returns None if the structure isn't recognizable.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    # find the second ---
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return None
    meta: dict[str, str] = {}
    for raw in lines[1:end]:
        if ":" not in raw:
            continue
        k, _, v = raw.partition(":")
        meta[k.strip().lower()] = v.strip()
    slug = meta.get("slug", "").strip()
    title = meta.get("title", "").strip() or slug
    source = meta.get("source", "auto").strip() or "auto"
    if not is_valid_slug(slug):
        return None
    body = "\n".join(lines[end + 1:]).strip()
    return Skill(slug=slug, title=title, source=source, content=body)


# ─── Prompt formatting ──────────────────────────────────────────────────────


def format_for_system_prompt() -> str:
    """Produce the system-prompt block listing the user's skills. Empty
    string when there are no skills — keeps the prompt cache hit when
    the user hasn't accumulated any yet.
    """
    skills = load_all()
    if not skills:
        return ""
    parts = ["# Things you've learned about this user"]
    for s in skills:
        parts.append(f"\n## {s.title}")
        parts.append(s.content)
    return "\n".join(parts).strip()
