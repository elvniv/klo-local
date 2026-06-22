"""12 real evaluation tasks. No texting/messaging/purchasing. Mix of shell,
applescript, browser, and shell+browser flavors.

Graders are pure Python (no second LLM call) — they consume the agent's final
text and optionally check the filesystem for artifacts. Loose pass criteria
on purpose: we want to measure "did the agent actually figure it out" not
"did it match an exact string".
"""
from __future__ import annotations

import datetime as _dt
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable


GraderResult = tuple[bool, str]


@dataclass
class Task:
    id: str
    surface: str
    prompt: str
    grader: Callable[[str], GraderResult]
    timeout_s: float = 180.0
    artifact_paths: list[str] = field(default_factory=list)


def _has_digit(text: str) -> bool:
    return bool(re.search(r"\d", text))


def _contains_any(text: str, needles: list[str], case_insensitive: bool = True) -> bool:
    body = text.lower() if case_insensitive else text
    return any((n.lower() if case_insensitive else n) in body for n in needles)


# ----------------------------------------------------------------- graders

def _grade_disk_space(answer: str) -> GraderResult:
    if re.search(r"\d+(\.\d+)?\s*(GB|G\b|Gi|TB|T\b)", answer, re.IGNORECASE):
        return True, "found gigabyte/terabyte figure"
    return False, "no GB/TB figure in answer"


def _grade_has_number(answer: str) -> GraderResult:
    if _has_digit(answer):
        return True, "contains a digit"
    return False, "no digit in answer"


def _grade_lists_three(answer: str) -> GraderResult:
    # Three filename-like lines OR three commas
    lines = [ln for ln in answer.splitlines() if ln.strip()]
    if len(lines) >= 3:
        return True, f"{len(lines)} lines"
    if answer.count(",") >= 2:
        return True, "comma-separated, ≥3 items"
    return False, f"only {len(lines)} non-empty lines, no commas"


def _grade_music_state(answer: str) -> GraderResult:
    body = answer.lower()
    if "nothing" in body or "not playing" in body or "no track" in body or "stopped" in body or "paused" in body:
        return True, "honest 'not playing' answer"
    # We expect some actual track from earlier sessions; just require a non-empty answer with text
    if len(answer.strip()) > 5 and re.search(r"[A-Za-z]", answer):
        return True, "named a track or state"
    return False, "no track or state info"


def _grade_calendar(answer: str) -> GraderResult:
    # Any non-empty answer that mentions either 'no event' or has time-like text
    if not answer.strip():
        return False, "empty"
    body = answer.lower()
    if "no event" in body or "nothing" in body or "empty" in body:
        return True, "honestly reports no events"
    if re.search(r"\b\d{1,2}(:\d{2})?\s*(am|pm)?\b", answer, re.IGNORECASE):
        return True, "has time-like text"
    if len(answer.strip()) > 12:
        return True, "non-trivial answer"
    return False, "no time / event info"


def _grade_frontmost(answer: str) -> GraderResult:
    if len(answer.strip()) >= 3:
        return True, "non-empty frontmost reference"
    return False, "empty"


def _grade_hn_title(answer: str) -> GraderResult:
    txt = answer.strip()
    if len(txt) < 8:
        return False, "too short to be a real HN headline"
    if re.search(r"[A-Za-z]", txt):
        return True, "has alphabetic content"
    return False, "no alpha"


def _grade_weather(answer: str) -> GraderResult:
    # Want a temperature: number + (°|degrees|F|C) somewhere
    if re.search(r"\d+\s*°", answer) or re.search(r"\d+\s*(degrees|deg|°)", answer, re.IGNORECASE):
        return True, "has degree symbol with number"
    if re.search(r"\d+\s*[°]?\s*[FC]\b", answer):
        return True, "has F or C with number"
    return False, "no temperature pattern"


def _grade_repo_stars(answer: str) -> GraderResult:
    # Look for a number > 100 with star/k context
    m = re.search(r"(\d[\d,]{2,}|\d+\.\d+\s*k)", answer, re.IGNORECASE)
    if not m:
        return False, "no number in answer"
    return True, f"found stars-like number: {m.group(0)}"


def _grade_penguin_artifact(answer: str) -> GraderResult:
    p = Path("/tmp/penguins.txt")
    if not p.exists():
        return False, "/tmp/penguins.txt missing"
    content = p.read_text(errors="replace")
    if len(content) < 80:
        return False, f"file too short ({len(content)} chars)"
    if "penguin" not in content.lower():
        return False, "file doesn't mention penguin"
    return True, f"file ok ({len(content)} chars)"


def _grade_anthropic_pricing(answer: str) -> GraderResult:
    # Looking for some $/Mtok pattern OR explicit Sonnet pricing numbers ($3, $15)
    if re.search(r"\$\s*\d+(\.\d+)?", answer):
        return True, "has dollar amount"
    if re.search(r"\d+(\.\d+)?\s*/\s*M", answer, re.IGNORECASE):
        return True, "per-million-token rate"
    return False, "no pricing pattern"


def _grade_current_year(answer: str) -> GraderResult:
    year = str(_dt.datetime.now().year)
    if year in answer:
        return True, f"contains {year}"
    return False, f"missing current year {year}"


# ----------------------------------------------------------------- the 12

TASKS: list[Task] = [
    # ---- shell-only ----
    Task(
        id="01-disk-free",
        surface="shell",
        prompt="What's the free disk space on my Mac's main volume? Give me a human-readable size like '120 GB'.",
        grader=_grade_disk_space,
        timeout_s=60,
    ),
    Task(
        id="02-pdf-count",
        surface="shell",
        prompt="How many .pdf files are in my ~/Downloads folder? Just the number.",
        grader=_grade_has_number,
        timeout_s=60,
    ),
    Task(
        id="03-recent-docs",
        surface="shell",
        prompt="List the 3 most recently modified files (or directories) in ~/Documents. One per line, just names.",
        grader=_grade_lists_three,
        timeout_s=60,
    ),
    Task(
        id="04-current-date",
        surface="shell",
        prompt="What's the current date and time on this Mac? Brief.",
        grader=_grade_current_year,
        timeout_s=30,
    ),
    # ---- applescript ----
    Task(
        id="05-music-state",
        surface="applescript",
        prompt="What's currently playing in the Music app? If nothing's playing, say 'nothing'.",
        grader=_grade_music_state,
        timeout_s=30,
    ),
    Task(
        id="06-calendar-today",
        surface="applescript",
        prompt="What events do I have on my Calendar today? If none, say so. Don't list more than 5. If Calendar.app is slow, you may use shell + `icalBuddy eventsToday` if available, otherwise just answer based on what AppleScript returns.",
        grader=_grade_calendar,
        timeout_s=120,
    ),
    Task(
        id="07-frontmost-app",
        surface="applescript",
        prompt="What macOS application is currently frontmost (active) on my screen?",
        grader=_grade_frontmost,
        timeout_s=30,
    ),
    # ---- browser ----
    Task(
        id="08-hn-top",
        surface="browser",
        prompt="What's the current top story on Hacker News (news.ycombinator.com)? Give me just the title.",
        grader=_grade_hn_title,
        timeout_s=180,
    ),
    Task(
        id="09-sf-weather",
        surface="browser",
        prompt="What's the current temperature in San Francisco? Just the number with degrees, like '63°F'.",
        grader=_grade_weather,
        timeout_s=180,
    ),
    Task(
        id="10-anthropic-sdk-stars",
        surface="browser",
        prompt="How many GitHub stars does the repo `anthropics/anthropic-sdk-python` have right now? Just the number.",
        grader=_grade_repo_stars,
        timeout_s=180,
    ),
    Task(
        id="11-penguin-artifact",
        surface="browser+write_file",
        prompt="Read the first paragraph of the Wikipedia article on Penguins (https://en.wikipedia.org/wiki/Penguin) and save it to /tmp/penguins.txt. Then tell me how many characters you saved.",
        grader=_grade_penguin_artifact,
        timeout_s=240,
        artifact_paths=["/tmp/penguins.txt"],
    ),
    Task(
        id="12-anthropic-pricing",
        surface="browser",
        prompt="On Anthropic's pricing page (https://www.anthropic.com/pricing), what's the input token price per million for Claude Sonnet 4.5? Give me the dollar figure.",
        grader=_grade_anthropic_pricing,
        timeout_s=240,
    ),
]
