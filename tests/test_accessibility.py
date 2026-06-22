from api.core.accessibility import (
    ACCESSIBILITY_TOOL,
    AccessibilityExecutor,
    _ocr_center,
    extract_text_lines,
)


def test_accessibility_tool_actions_match_contract():
    # The accessibility tool exposes both READ (snapshot/text) and WRITE
    # (press/fill/menu_select) actions so klo can drive native macOS
    # apps via the AX API without a screen-recording-permission round-trip.
    # If new actions are added, update this list. If actions are removed,
    # think hard about whether you're breaking the AX-write codepath in
    # agent2/prompts.py before doing it.
    assert ACCESSIBILITY_TOOL["name"] == "accessibility"
    assert set(ACCESSIBILITY_TOOL["input_schema"]["properties"]["action"]["enum"]) == {
        # reads
        "focused_snapshot",
        "visible_text",
        "screen_text",
        "screen_text_locations",
        # writes
        "actionable_index",
        "press",
        "fill",
        "focus",
        "confirm",
        "menu_select",
    }


async def test_accessibility_rejects_unknown_action():
    executor = AccessibilityExecutor()

    try:
        await executor.execute({"action": "click_button"})
    except ValueError as exc:
        assert "Unsupported accessibility action" in str(exc)
    else:
        raise AssertionError("expected ValueError")


def test_extract_text_lines_flattens_tree():
    lines = extract_text_lines({"tree": {"title": "Window", "children": [{"value": "Body"}]}})

    assert lines == ["Window", "Body"]


def test_ocr_center_converts_vision_coordinates():
    box = type(
        "Box",
        (),
        {
            "origin": type("Origin", (), {"x": 0.25, "y": 0.25})(),
            "size": type("Size", (), {"width": 0.5, "height": 0.5})(),
        },
    )()
    geometry = type("Geometry", (), {"logical_width_px": 1000, "logical_height_px": 800})()

    assert _ocr_center(box, geometry) == {"x": 500, "y": 400}
