import asyncio
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class EventBus:
    def __init__(self) -> None:
        self._queues: dict[str, set[asyncio.Queue[dict[str, Any]]]] = defaultdict(set)

    async def publish(self, run_id: str, event_type: str, payload: Any) -> dict[str, Any]:
        event = {
            "id": str(uuid4()),
            "run_id": run_id,
            "type": event_type,
            "payload": payload,
            "timestamp": now_iso(),
        }
        for queue in list(self._queues[run_id]):
            await queue.put(event)
        return event

    async def subscribe(self, run_id: str):
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._queues[run_id].add(queue)
        try:
            while True:
                yield await queue.get()
        finally:
            self._queues[run_id].discard(queue)


bus = EventBus()
