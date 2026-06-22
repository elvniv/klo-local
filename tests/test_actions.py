from api.core.actions import ActionExecutor
from api.core.coords import ScreenGeometry


async def test_click_maps_image_coords_to_logical(monkeypatch):
    calls = []

    async def fake_click(x, y, button="left", clicks=1):
        calls.append((x, y, button, clicks))

    monkeypatch.setattr("api.core.input.click", fake_click)
    executor = ActionExecutor()
    executor.geometry = ScreenGeometry(2000, 1000, 1000, 500)

    result = await executor.execute({"action": "left_click", "coordinate": [1000, 500]})

    assert calls == [(500, 250, "left", 1)]
    assert result.text == "left_click at 500,250"


async def test_type_uses_generic_text_input(monkeypatch):
    calls = []

    async def fake_type_text(text):
        calls.append(text)

    monkeypatch.setattr("api.core.input.type_text", fake_type_text)
    executor = ActionExecutor()
    executor.geometry = ScreenGeometry(100, 100, 100, 100)

    await executor.execute({"action": "type", "text": "hello"})

    assert calls == ["hello"]


async def test_long_type_uses_paste(monkeypatch):
    calls = []

    async def fake_paste_text(text):
        calls.append(text)

    monkeypatch.setattr("api.core.input.paste_text", fake_paste_text)
    executor = ActionExecutor()
    executor.geometry = ScreenGeometry(100, 100, 100, 100)

    result = await executor.execute({"action": "type", "text": "hello from a long note"})

    assert calls == ["hello from a long note"]
    assert result.text == "pasted text"


async def test_triple_click_is_supported(monkeypatch):
    calls = []

    async def fake_click(x, y, button="left", clicks=1):
        calls.append((x, y, button, clicks))

    monkeypatch.setattr("api.core.input.click", fake_click)
    executor = ActionExecutor()
    executor.geometry = ScreenGeometry(100, 100, 100, 100)

    await executor.execute({"action": "triple_click", "coordinate": [10, 20]})

    assert calls == [(10, 20, "left", 3)]


async def test_wait_is_capped(monkeypatch):
    calls = []

    async def fake_sleep(duration):
        calls.append(duration)

    monkeypatch.setattr("api.core.actions.asyncio.sleep", fake_sleep)
    executor = ActionExecutor()
    executor.geometry = ScreenGeometry(100, 100, 100, 100)

    result = await executor.execute({"action": "wait", "duration": 1200})

    assert calls == [5]
    assert result.text == "waited 5s"


async def test_get_cursor_position(monkeypatch):
    monkeypatch.setattr("api.core.actions.cursor_position", lambda: (12, 34))
    executor = ActionExecutor()

    result = await executor.execute({"action": "get_cursor_position"})

    assert result.text == "cursor at 12,34"
