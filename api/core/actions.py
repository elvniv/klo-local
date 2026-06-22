from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any

from . import input as mac_input
from .coords import ScreenGeometry
from .screenshot import Screenshot, cursor_position, screenshot


@dataclass(frozen=True)
class ActionResult:
    text: str | None = None
    screenshot: Screenshot | None = None

    def to_tool_content(self) -> list[dict[str, Any]]:
        if self.screenshot:
            return [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": self.screenshot.base64_png,
                    },
                }
            ]
        return [{"type": "text", "text": self.text or "ok"}]


class ActionExecutor:
    def __init__(self) -> None:
        self.geometry: ScreenGeometry | None = None

    async def ensure_geometry(self) -> ScreenGeometry | None:
        """Probe the screen once (cached) so callers can size the computer
        tool's declared display to the real screenshot dimensions."""
        if self.geometry is None:
            shot = await screenshot()
            self.geometry = shot.geometry
        return self.geometry

    async def execute(self, tool_input: dict[str, Any]) -> ActionResult:
        action = tool_input.get("action")

        if action == "screenshot":
            scope = str(tool_input.get("scope") or "desktop")
            app_name = tool_input.get("app_name")
            shot = await screenshot(scope=scope, app_name=app_name)
            self.geometry = shot.geometry
            return ActionResult(screenshot=shot)

        if action == "get_cursor_position":
            x, y = cursor_position()
            return ActionResult(text=f"cursor at {x},{y}")

        if self.geometry is None:
            shot = await screenshot()
            self.geometry = shot.geometry

        if action in {"left_click", "right_click", "double_click", "triple_click"}:
            x, y = self._point(tool_input)
            if action == "left_click":
                await mac_input.click(x, y)
            elif action == "right_click":
                await mac_input.click(x, y, button="right")
            elif action == "double_click":
                await mac_input.click(x, y, clicks=2)
            else:
                await mac_input.click(x, y, clicks=3)
            return ActionResult(text=f"{action} at {x},{y}")

        if action == "mouse_move":
            x, y = self._point(tool_input)
            await mac_input.mouse_move(x, y)
            return ActionResult(text=f"moved mouse to {x},{y}")

        if action == "left_click_drag":
            start_x, start_y = self._point(tool_input, "start_coordinate")
            end_x, end_y = self._point(tool_input, "coordinate")
            await mac_input.drag(start_x, start_y, end_x, end_y)
            return ActionResult(text=f"dragged from {start_x},{start_y} to {end_x},{end_y}")

        if action == "type":
            text = str(tool_input.get("text", ""))
            if len(text) > 12 or "\n" in text:
                await mac_input.paste_text(text)
                return ActionResult(text="pasted text")
            await mac_input.type_text(text)
            return ActionResult(text="typed text")

        if action == "paste_text":
            await mac_input.paste_text(str(tool_input.get("text", "")))
            return ActionResult(text="pasted text")

        if action == "key":
            await mac_input.key_press(str(tool_input.get("text") or tool_input.get("key", "")))
            return ActionResult(text="pressed key")

        if action == "hold_key":
            await mac_input.hold_key(
                str(tool_input.get("text") or tool_input.get("key", "")),
                float(tool_input.get("duration", 1)),
            )
            return ActionResult(text="held key")

        if action == "scroll":
            if tool_input.get("coordinate") is not None:
                x, y = self._point(tool_input)
                await mac_input.mouse_move(x, y)
            dx = int(tool_input.get("scroll_x", 0))
            dy = int(tool_input.get("scroll_y", 0))
            units_x = self.geometry.scroll_units(dx)
            units_y = self.geometry.scroll_units(dy)
            await mac_input.scroll(dx=units_x if dx > 0 else -units_x if dx < 0 else 0, dy=units_y if dy > 0 else -units_y if dy < 0 else 0)
            return ActionResult(text="scrolled")

        if action == "wait":
            duration = min(max(float(tool_input.get("duration", 1)), 0), 5)
            await asyncio.sleep(duration)
            return ActionResult(text=f"waited {duration:g}s")

        raise ValueError(f"Unsupported computer action: {action!r}")

    def _point(
        self, tool_input: dict[str, Any], key: str = "coordinate"
    ) -> tuple[int, int]:
        if self.geometry is None:
            raise ValueError("No screen geometry available.")
        coordinate = tool_input.get(key)
        if not isinstance(coordinate, (list, tuple)) or len(coordinate) != 2:
            raise ValueError(f"Expected {key} to be [x, y].")
        return self.geometry.image_to_logical(coordinate[0], coordinate[1])
