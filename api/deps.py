from functools import lru_cache

from api.config import get_settings
from api.store.persist import RunStore


@lru_cache
def get_store() -> RunStore:
    settings = get_settings()
    return RunStore(settings.database_path)
