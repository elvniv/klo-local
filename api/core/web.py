from __future__ import annotations

import json
import re
from typing import Any
from urllib.parse import quote_plus

import httpx
from bs4 import BeautifulSoup

from api.core.contract import TrustedHandles
from api.core.redact import redact_text


WEB_TOOL = {
    "name": "web",
    "description": (
        "Generic web content tool for reading public pages and extracting links, "
        "YouTube search results, and YouTube transcripts. Use this before "
        "visual clicking for web research/transcript tasks."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["fetch_text", "fetch_links", "search_youtube", "youtube_transcript"],
            },
            "url": {"type": "string"},
            "query": {"type": "string"},
            "video_id": {"type": "string"},
            "max_results": {"type": "integer", "minimum": 1, "maximum": 10, "default": 5},
        },
        "required": ["action"],
        "additionalProperties": False,
    },
}


class WebContentExecutor:
    def __init__(self, trusted: TrustedHandles | None = None) -> None:
        self.trusted = trusted

    async def execute(self, tool_input: dict[str, Any]) -> str:
        action = tool_input.get("action")
        if action == "fetch_text":
            return await fetch_text(str(tool_input.get("url") or ""))
        if action == "fetch_links":
            links = await fetch_links(str(tool_input.get("url") or ""))
            return json.dumps(links[:100], ensure_ascii=False)
        if action == "search_youtube":
            results = await search_youtube(
                str(tool_input.get("query") or ""),
                int(tool_input.get("max_results", 5)),
            )
            if self.trusted is not None:
                self.trusted.add_urls(item.get("url", "") for item in results)
            return json.dumps(results, ensure_ascii=False)
        if action == "youtube_transcript":
            return await youtube_transcript(
                str(tool_input.get("video_id") or _video_id_from_url(str(tool_input.get("url") or "")))
            )
        raise ValueError(f"Unsupported web action: {action!r}")


async def fetch_text(url: str) -> str:
    html = await _fetch(url)
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()
    text = "\n".join(line.strip() for line in soup.get_text("\n").splitlines() if line.strip())
    return redact_text(text[:20000])


async def fetch_links(url: str) -> list[dict[str, str]]:
    html = await _fetch(url)
    soup = BeautifulSoup(html, "html.parser")
    links = []
    for anchor in soup.find_all("a"):
        href = anchor.get("href")
        label = " ".join(anchor.get_text(" ", strip=True).split())
        if href and label:
            links.append({"text": label[:300], "href": href})
    return links


async def search_youtube(query: str, max_results: int = 5) -> list[dict[str, str]]:
    if not query:
        raise ValueError("search_youtube requires query")
    url = f"https://www.youtube.com/results?search_query={quote_plus(query)}"
    html = await _fetch(url)
    data = _extract_yt_initial_data(html)
    videos = []
    for renderer in _find_video_renderers(data):
        video_id = renderer.get("videoId")
        title = _runs_text(renderer.get("title"))
        if not video_id or not title:
            continue
        videos.append(
            {
                "title": title,
                "video_id": video_id,
                "url": f"https://www.youtube.com/watch?v={video_id}",
                "channel": _runs_text(renderer.get("ownerText")),
                "length": _simple_text(renderer.get("lengthText")),
                "views": _simple_text(renderer.get("viewCountText")),
                "published": _simple_text(renderer.get("publishedTimeText")),
                "description": _runs_text(renderer.get("detailedMetadataSnippets")),
            }
        )
        if len(videos) >= max_results:
            break
    return videos


async def youtube_transcript(video_id: str) -> str:
    if not video_id:
        raise ValueError("youtube_transcript requires video_id or url")

    try:
        from youtube_transcript_api import YouTubeTranscriptApi

        try:
            rows = YouTubeTranscriptApi.get_transcript(video_id, languages=["en"])
        except AttributeError:
            rows = YouTubeTranscriptApi().fetch(video_id, languages=["en"]).to_raw_data()
    except Exception as exc:
        raise RuntimeError(f"Could not fetch YouTube transcript for {video_id}: {exc}") from exc

    text = "\n".join(row.get("text", "") for row in rows if row.get("text"))
    return redact_text(text[:50000])


async def _fetch(url: str) -> str:
    if not url.startswith(("https://", "http://")):
        raise ValueError("URL must be http(s)")
    headers = {
        "user-agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
        )
    }
    async with httpx.AsyncClient(headers=headers, follow_redirects=True, timeout=20) as client:
        response = await client.get(url)
        response.raise_for_status()
        return response.text


def _extract_yt_initial_data(html: str) -> dict[str, Any]:
    patterns = [
        r"var ytInitialData = (\{.*?\});</script>",
        r"ytInitialData\s*=\s*(\{.*?\});",
    ]
    for pattern in patterns:
        match = re.search(pattern, html, flags=re.DOTALL)
        if match:
            return json.loads(match.group(1))
    raise ValueError("Could not find ytInitialData in YouTube response")


def _find_video_renderers(value: Any):
    if isinstance(value, dict):
        if "videoRenderer" in value:
            yield value["videoRenderer"]
        for child in value.values():
            yield from _find_video_renderers(child)
    elif isinstance(value, list):
        for child in value:
            yield from _find_video_renderers(child)


def _runs_text(value: Any) -> str:
    if isinstance(value, list):
        return " ".join(_runs_text(item) for item in value if item)
    if not isinstance(value, dict):
        return ""
    if "simpleText" in value:
        return str(value["simpleText"])
    if "runs" in value:
        return " ".join(str(run.get("text", "")) for run in value["runs"]).strip()
    if "snippetText" in value:
        return _runs_text(value["snippetText"])
    return ""


def _simple_text(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("simpleText") or _runs_text(value))
    return ""


def _video_id_from_url(url: str) -> str:
    match = re.search(r"(?:v=|youtu\.be/)([A-Za-z0-9_-]{6,})", url)
    return match.group(1) if match else ""
