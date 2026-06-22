from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_provider: str = "anthropic"
    anthropic_api_key: str = ""
    anthropic_model: str = "claude-opus-4-7"
    openai_api_key: str = ""
    openai_model: str = "gpt-4.1"
    max_turns: int = 90
    max_tool_calls: int = 80
    max_screenshots: int = 40
    max_wall_time_seconds: int = 300
    max_escalations_per_subtask: int = 3
    fast_path: bool = True
    controlled_browser_port: int = 9333
    controlled_browser_profile: Path = Path(".klo/controlled-browser")
    database_path: Path = Path("klo.sqlite3")
    artifacts_dir: Path = Path(".klo/runs")
    use_dedicated_space: bool = False
    dedicated_space_key: str = "ctrl+right"
    pause_on_controller_focus: bool = True
    controller_app_names: str = "Cursor"
    host: str = "127.0.0.1"
    port: int = 8765

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()
