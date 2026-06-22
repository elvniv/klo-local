from api.core.coords import ScreenGeometry


def test_image_to_logical_retina_scale():
    geometry = ScreenGeometry(
        image_width_px=3024,
        image_height_px=1964,
        logical_width_px=1512,
        logical_height_px=982,
    )

    assert geometry.image_to_logical(1512, 982) == (756, 491)


def test_scroll_units_are_positive_and_coarse():
    geometry = ScreenGeometry(
        image_width_px=1440,
        image_height_px=900,
        logical_width_px=1440,
        logical_height_px=900,
    )

    assert geometry.scroll_units(10) == 1
    assert geometry.scroll_units(240) == 3
