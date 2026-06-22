from api.core.coords import ScreenGeometry
from api.core.screenshot import _logical_to_image


def test_logical_to_image_scales_retina_coords():
    geometry = ScreenGeometry(
        image_width_px=2000,
        image_height_px=1000,
        logical_width_px=1000,
        logical_height_px=500,
    )

    assert _logical_to_image((250, 125), geometry) == (500, 250)
