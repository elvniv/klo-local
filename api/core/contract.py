"""Shared contract types passed between executors during a single run."""
from __future__ import annotations

from typing import Iterable


class TrustedHandles:
    """Trust-list of handles (URLs, file paths, IDs) the agent has actually
    encountered this run. Used by tools that should only act on values they've
    independently observed — e.g. opening a YouTube watch URL only after a
    web/search_youtube actually returned it.
    """

    def __init__(self) -> None:
        self._urls: set[str] = set()

    def add_url(self, url: str | None) -> None:
        if isinstance(url, str) and url:
            self._urls.add(url)

    def add_urls(self, urls: Iterable[str | None]) -> None:
        for url in urls:
            self.add_url(url)

    def has_url(self, url: str) -> bool:
        return isinstance(url, str) and url in self._urls

    def urls(self) -> tuple[str, ...]:
        return tuple(sorted(self._urls))
