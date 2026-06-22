from api.core import input as mac_input


async def test_letter_shortcuts_use_modified_text(monkeypatch):
    calls = []

    async def fake_cliclick(*args):
        calls.append(args)
        return mac_input.InputResult(ok=True)

    monkeypatch.setattr(mac_input, "_cliclick", fake_cliclick)

    await mac_input.key_press("cmd+t")

    assert calls == [("kd:cmd", "t:t", "ku:cmd")]


async def test_named_keys_still_use_key_press(monkeypatch):
    calls = []

    async def fake_cliclick(*args):
        calls.append(args)
        return mac_input.InputResult(ok=True)

    monkeypatch.setattr(mac_input, "_cliclick", fake_cliclick)

    await mac_input.key_press("Return")

    assert calls == [("kp:return",)]


async def test_underscore_key_names_are_normalized(monkeypatch):
    calls = []

    async def fake_cliclick(*args):
        calls.append(args)
        return mac_input.InputResult(ok=True)

    monkeypatch.setattr(mac_input, "_cliclick", fake_cliclick)

    await mac_input.key_press("page_down")

    assert calls == [("kp:page-down",)]


async def test_hold_key_uses_down_and_up(monkeypatch):
    calls = []

    async def fake_cliclick(*args):
        calls.append(args)
        return mac_input.InputResult(ok=True)

    monkeypatch.setattr(mac_input, "_cliclick", fake_cliclick)

    await mac_input.hold_key("cmd", 0)

    assert calls == [("kd:cmd",), ("ku:cmd",)]


async def test_paste_text_uses_pbcopy_and_paste(monkeypatch):
    calls = []

    class FakeProc:
        returncode = 0

        async def communicate(self, data):
            calls.append(("pbcopy", data))
            return b"", b""

    async def fake_create_subprocess_exec(*args, **kwargs):
        calls.append(args)
        return FakeProc()

    async def fake_key_press(combo):
        calls.append(("key", combo))
        return mac_input.InputResult(ok=True)

    monkeypatch.setattr(mac_input.asyncio, "create_subprocess_exec", fake_create_subprocess_exec)
    monkeypatch.setattr(mac_input, "key_press", fake_key_press)

    await mac_input.paste_text("hello")

    assert ("key", "cmd+v") in calls


async def test_scroll_uses_quartz(monkeypatch):
    calls = []

    def fake_quartz_scroll(dx, dy):
        calls.append((dx, dy))

    monkeypatch.setattr(mac_input, "_quartz_scroll", fake_quartz_scroll)

    await mac_input.scroll(dx=1, dy=-3)

    assert calls == [(1, -3)]
