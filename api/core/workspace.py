from __future__ import annotations

import asyncio
from dataclasses import dataclass

from api.config import Settings
from api.core import input as mac_input
from api.core.os_context import get_os_context


FOCUS_SENSITIVE_ACTIONS = {
    "left_click_drag",
    "type",
    "paste_text",
    "key",
    "hold_key",
    "scroll",
}


class FocusLeaseLost(RuntimeError):
    pass


@dataclass(frozen=True)
class WorkspaceState:
    dedicated_space_enabled: bool
    dedicated_space_key: str
    active_app: str | None
    controller_apps: list[str]

    def to_dict(self) -> dict:
        return {
            "dedicated_space_enabled": self.dedicated_space_enabled,
            "dedicated_space_key": self.dedicated_space_key,
            "active_app": self.active_app,
            "controller_apps": self.controller_apps,
        }


class WorkspaceGuard:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def enter(self) -> WorkspaceState:
        if self.settings.use_dedicated_space:
            await mac_input.key_press(self.settings.dedicated_space_key)
            await asyncio.sleep(0.8)
        return self.state()

    def state(self) -> WorkspaceState:
        context = get_os_context()
        active_app = next((app.name for app in context.running_apps if app.active), None)
        return WorkspaceState(
            dedicated_space_enabled=self.settings.use_dedicated_space,
            dedicated_space_key=self.settings.dedicated_space_key,
            active_app=active_app,
            controller_apps=self.controller_apps,
        )

    def ensure_can_act(self, tool_name: str, tool_input: dict) -> None:
        if not self.settings.pause_on_controller_focus:
            return
        if tool_name not in {"computer", "macos"}:
            return
        if tool_input.get("action") not in FOCUS_SENSITIVE_ACTIONS:
            return

        active_app = self.state().active_app
        if active_app and active_app.lower() in {app.lower() for app in self.controller_apps}:
            raise FocusLeaseLost(
                f"Paused because {active_app} is frontmost. The user may be using the Mac; "
                "resume after switching back to klo's workspace or target app."
            )

    @property
    def controller_apps(self) -> list[str]:
        return [
            name.strip()
            for name in self.settings.controller_app_names.split(",")
            if name.strip()
        ]
