import asyncio
import json
import sqlite3
from pathlib import Path
from typing import Any

from .bus import now_iso


class RunStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = asyncio.Lock()
        self._init()

    def _init(self) -> None:
        with sqlite3.connect(self.path) as db:
            db.execute(
                """
                CREATE TABLE IF NOT EXISTS runs (
                  id TEXT PRIMARY KEY,
                  prompt TEXT NOT NULL,
                  status TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                )
                """
            )
            db.execute(
                """
                CREATE TABLE IF NOT EXISTS run_events (
                  id TEXT PRIMARY KEY,
                  run_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  payload_json TEXT NOT NULL,
                  timestamp TEXT NOT NULL,
                  FOREIGN KEY(run_id) REFERENCES runs(id)
                )
                """
            )

    async def create_run(self, run_id: str, prompt: str) -> None:
        async with self._lock:
            await asyncio.to_thread(self._create_run_sync, run_id, prompt)

    async def set_status(self, run_id: str, status: str) -> None:
        async with self._lock:
            await asyncio.to_thread(self._set_status_sync, run_id, status)

    async def add_event(self, event: dict[str, Any]) -> None:
        async with self._lock:
            await asyncio.to_thread(self._add_event_sync, event)

    async def events(self, run_id: str) -> list[dict[str, Any]]:
        async with self._lock:
            return await asyncio.to_thread(self._events_sync, run_id)

    async def get_run(self, run_id: str) -> dict[str, Any] | None:
        async with self._lock:
            return await asyncio.to_thread(self._get_run_sync, run_id)

    async def list_runs(self, limit: int = 50) -> list[dict[str, Any]]:
        async with self._lock:
            return await asyncio.to_thread(self._list_runs_sync, limit)

    def _create_run_sync(self, run_id: str, prompt: str) -> None:
        stamp = now_iso()
        with sqlite3.connect(self.path) as db:
            db.execute(
                "INSERT INTO runs VALUES (?, ?, ?, ?, ?)",
                (run_id, prompt, "queued", stamp, stamp),
            )

    def _set_status_sync(self, run_id: str, status: str) -> None:
        with sqlite3.connect(self.path) as db:
            db.execute(
                "UPDATE runs SET status = ?, updated_at = ? WHERE id = ?",
                (status, now_iso(), run_id),
            )

    def _add_event_sync(self, event: dict[str, Any]) -> None:
        with sqlite3.connect(self.path) as db:
            db.execute(
                "INSERT INTO run_events VALUES (?, ?, ?, ?, ?)",
                (
                    event["id"],
                    event["run_id"],
                    event["type"],
                    json.dumps(event["payload"]),
                    event["timestamp"],
                ),
            )

    def _events_sync(self, run_id: str) -> list[dict[str, Any]]:
        with sqlite3.connect(self.path) as db:
            rows = db.execute(
                """
                SELECT id, run_id, type, payload_json, timestamp
                FROM run_events
                WHERE run_id = ?
                ORDER BY timestamp ASC
                """,
                (run_id,),
            ).fetchall()
        return [
            {
                "id": row[0],
                "run_id": row[1],
                "type": row[2],
                "payload": json.loads(row[3]),
                "timestamp": row[4],
            }
            for row in rows
        ]

    def _get_run_sync(self, run_id: str) -> dict[str, Any] | None:
        with sqlite3.connect(self.path) as db:
            row = db.execute(
                """
                SELECT id, prompt, status, created_at, updated_at
                FROM runs
                WHERE id = ?
                """,
                (run_id,),
            ).fetchone()
        if row is None:
            return None
        return _run_row_to_dict(row)

    def _list_runs_sync(self, limit: int) -> list[dict[str, Any]]:
        with sqlite3.connect(self.path) as db:
            rows = db.execute(
                """
                SELECT id, prompt, status, created_at, updated_at
                FROM runs
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [_run_row_to_dict(row) for row in rows]


def _run_row_to_dict(row) -> dict[str, Any]:
    return {
        "id": row[0],
        "prompt": row[1],
        "status": row[2],
        "created_at": row[3],
        "updated_at": row[4],
    }
