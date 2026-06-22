from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ScreenGeometry:
    image_width_px: int
    image_height_px: int
    logical_width_px: float
    logical_height_px: float

    def image_to_logical(self, x: int | float, y: int | float) -> tuple[int, int]:
        x_ratio = self.logical_width_px / self.image_width_px
        y_ratio = self.logical_height_px / self.image_height_px
        return round(x * x_ratio), round(y * y_ratio)

    def scroll_units(self, amount: int | float) -> int:
        # Computer Use sends pixels; cliclick scroll steps are coarser.
        return max(1, round(abs(amount) / 80))
