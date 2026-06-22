import json

from api.core.contract import TrustedHandles
from api.core.web import (
    WebContentExecutor,
    _extract_yt_initial_data,
    _find_video_renderers,
    _video_id_from_url,
    search_youtube,
)


def test_video_id_from_url_supports_common_urls():
    assert _video_id_from_url("https://www.youtube.com/watch?v=abc123XYZ") == "abc123XYZ"
    assert _video_id_from_url("https://youtu.be/abc123XYZ") == "abc123XYZ"


def test_extract_youtube_initial_data_and_renderers():
    data = {
        "contents": [
            {
                "videoRenderer": {
                    "videoId": "vid123",
                    "title": {"runs": [{"text": "A title"}]},
                }
            }
        ]
    }
    html = f"<script>var ytInitialData = {json.dumps(data)};</script>"

    parsed = _extract_yt_initial_data(html)
    renderers = list(_find_video_renderers(parsed))

    assert renderers[0]["videoId"] == "vid123"


async def test_search_youtube_parses_results(monkeypatch):
    data = {
        "contents": [
            {
                "videoRenderer": {
                    "videoId": "vid123",
                    "title": {"runs": [{"text": "Notion CEO interview"}]},
                    "ownerText": {"runs": [{"text": "Channel"}]},
                    "lengthText": {"simpleText": "10:00"},
                }
            }
        ]
    }
    html = f"<script>var ytInitialData = {json.dumps(data)};</script>"

    async def fake_fetch(url):
        return html

    monkeypatch.setattr("api.core.web._fetch", fake_fetch)

    results = await search_youtube("notion ceo", 1)

    assert results == [
        {
            "title": "Notion CEO interview",
            "video_id": "vid123",
            "url": "https://www.youtube.com/watch?v=vid123",
            "channel": "Channel",
            "length": "10:00",
            "views": "",
            "published": "",
            "description": "",
        }
    ]


async def test_search_youtube_populates_trusted_handles(monkeypatch):
    data = {
        "contents": [
            {
                "videoRenderer": {
                    "videoId": "vid123",
                    "title": {"runs": [{"text": "x"}]},
                }
            }
        ]
    }
    html = f"<script>var ytInitialData = {json.dumps(data)};</script>"

    async def fake_fetch(url):
        return html

    monkeypatch.setattr("api.core.web._fetch", fake_fetch)
    trusted = TrustedHandles()
    executor = WebContentExecutor(trusted=trusted)

    await executor.execute({"action": "search_youtube", "query": "x", "max_results": 1})

    assert trusted.has_url("https://www.youtube.com/watch?v=vid123")
