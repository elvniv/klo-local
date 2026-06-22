from pathlib import Path

from api.store.persist import RunStore


async def test_store_lists_and_gets_runs(tmp_path: Path):
    store = RunStore(tmp_path / "runs.sqlite3")
    await store.create_run("run_1", "do it")
    await store.set_status("run_1", "completed")

    listed = await store.list_runs()
    fetched = await store.get_run("run_1")

    assert listed[0]["id"] == "run_1"
    assert fetched is not None
    assert fetched["prompt"] == "do it"
    assert fetched["status"] == "completed"
