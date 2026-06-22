"""Synthetic input via in-process Quartz CGEventPost.

We used to spawn `cliclick` as a subprocess, but that has a TCC gotcha:
when klo is launched from Cursor (or other Electron-based IDEs), the
cliclick subprocess gets a different "responsible app" classification
than the Python process that spawned it. macOS evaluates Accessibility
against that responsible app and silently drops the event when the
classification doesn't match the allowlist — even though the Python
process itself is trusted.

The fix: post events directly from Python via Quartz, so the OS
attributes them to the trusted Python process. Function signatures and
the internal cliclick-style command strings are preserved (so existing
tests that monkeypatch `_cliclick` keep working), but `_cliclick` now
parses those strings and emits CGEventPost calls instead of shelling
out.

For full coverage of all keys and characters, key_press/type_text use
two complementary approaches:
  - Plain text → Quartz keyboard event with CGEventKeyboardSetUnicodeString.
    No virtual-key-code lookup needed; macOS handles the unicode mapping.
  - Modified shortcuts (cmd+t, etc.) and named keys (return, esc, arrows)
    → virtual key code + CGEventSetFlags.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass


class InputError(RuntimeError):
    pass


@dataclass(frozen=True)
class InputResult:
    ok: bool
    output: str = ""


MODIFIERS = {"cmd", "command", "shift", "alt", "option", "ctrl", "control", "fn"}
MODIFIER_ALIASES = {
    "command": "cmd",
    "option": "alt",
    "control": "ctrl",
}

KEY_ALIASES = {
    "return": "return",
    "enter": "return",
    "escape": "esc",
    "esc": "esc",
    "space": "space",
    "tab": "tab",
    "delete": "delete",
    "backspace": "delete",
    "up": "arrow-up",
    "down": "arrow-down",
    "left": "arrow-left",
    "right": "arrow-right",
    "pageup": "page-up",
    "pagedown": "page-down",
    "page_up": "page-up",
    "page_down": "page-down",
    "arrow_up": "arrow-up",
    "arrow_down": "arrow-down",
    "arrow_left": "arrow-left",
    "arrow_right": "arrow-right",
}


# Virtual key codes — Apple's standard US-layout mapping. Used for named keys
# and keys with modifiers (where unicode-keystroke doesn't carry the modifier
# semantics through cleanly).
_KEY_CODES: dict[str, int] = {
    # Letters
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
    "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
    "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
    "y": 16, "z": 6,
    # Digits
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
    "7": 26, "8": 28, "9": 25,
    # Named keys (cliclick names — hyphenated)
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
    "esc": 53, "escape": 53,
    "arrow-up": 126, "arrow-down": 125, "arrow-left": 123, "arrow-right": 124,
    "page-up": 116, "page-down": 121, "home": 115, "end": 119,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
}

_MODIFIER_FLAGS: dict[str, int] = {
    # Pulled from Quartz constants — kept as ints so this module imports
    # without Quartz at test-collection time.
    "cmd": 1 << 20,
    "shift": 1 << 17,
    "alt": 1 << 19,
    "ctrl": 1 << 18,
    "fn": 1 << 23,
}


# ---------------------------------------------------------------- public API

async def click(x: int, y: int, button: str = "left", clicks: int = 1) -> InputResult:
    if button == "left" and clicks == 3:
        return await _cliclick(f"c:{x},{y}", f"c:{x},{y}", f"c:{x},{y}")

    command = {("left", 1): "c", ("left", 2): "dc", ("right", 1): "rc"}.get(
        (button, clicks)
    )
    if command is None:
        raise InputError(f"Unsupported click: button={button!r}, clicks={clicks!r}")
    return await _cliclick(f"{command}:{x},{y}")


async def mouse_move(x: int, y: int) -> InputResult:
    return await _cliclick(f"m:{x},{y}")


async def drag(from_x: int, from_y: int, to_x: int, to_y: int) -> InputResult:
    return await _cliclick(f"m:{from_x},{from_y}", "dd:.", f"m:{to_x},{to_y}", "du:.")


async def type_text(text: str) -> InputResult:
    # Drop the legacy cliclick `-w 8` wait flag — the Quartz dispatcher posts
    # events on the asyncio main thread without race conditions, and inter-key
    # timing is handled by macOS' event tap. Passing flag args also broke our
    # _cliclick parser (it tried to interpret "8" as a verb).
    return await _cliclick(f"t:{text}")


async def paste_text(text: str) -> InputResult:
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/pbcopy",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate(text.encode("utf-8"))
    if proc.returncode != 0:
        output = (stdout + stderr).decode("utf-8", errors="replace").strip()
        raise InputError(output or "pbcopy failed")
    await key_press("cmd+v")
    return InputResult(ok=True)


async def key_press(combo: str) -> InputResult:
    parts = [part.strip().lower() for part in combo.split("+") if part.strip()]
    if not parts:
        raise InputError("Empty key combo.")

    modifiers = [MODIFIER_ALIASES.get(p, p) for p in parts[:-1]]
    key_name = parts[-1].replace(" ", "_")
    key = KEY_ALIASES.get(key_name, key_name)
    for modifier in modifiers:
        if modifier not in MODIFIERS:
            raise InputError(f"Unsupported modifier in combo {combo!r}.")

    commands = [f"kd:{modifier}" for modifier in modifiers]
    commands.append(f"t:{key}" if len(key) == 1 else f"kp:{key}")
    commands.extend(f"ku:{modifier}" for modifier in reversed(modifiers))
    return await _cliclick(*commands)


async def hold_key(key: str, duration: float) -> InputResult:
    key_name = key.strip().lower().replace(" ", "_")
    normalized = MODIFIER_ALIASES.get(key_name, KEY_ALIASES.get(key_name, key_name))
    await _cliclick(f"kd:{normalized}")
    try:
        await asyncio.sleep(duration)
    finally:
        await _cliclick(f"ku:{normalized}")
    return InputResult(ok=True)


async def scroll(dx: int = 0, dy: int = 0) -> InputResult:
    if not dx and not dy:
        return InputResult(ok=True)
    await asyncio.to_thread(_quartz_scroll, dx, dy)
    return InputResult(ok=True)


def _quartz_scroll(dx: int = 0, dy: int = 0) -> None:
    try:
        import Quartz
    except ImportError as exc:
        raise InputError("Quartz is required for scroll events.") from exc

    if dx:
        event = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 2, dy, dx)
    else:
        event = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 1, dy)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


# ---------------------------------------------------------------- dispatcher

# Tracks which modifiers are currently "held down" via kd:NAME so subsequent
# t:CHAR / kp:NAME events get the correct flag mask.
_held_modifiers: set[str] = set()


async def _cliclick(*args: str) -> InputResult:
    """Dispatch cliclick-style command strings through Quartz CGEventPost.

    Preserves the cliclick command vocabulary so existing call sites and tests
    don't change. Internally posts each event from this Python process so
    macOS attributes the event to the trusted process rather than to a
    cliclick subprocess.
    """
    output_lines: list[str] = []
    try:
        import Quartz
    except ImportError as exc:
        raise InputError("Quartz is required for synthetic input events.") from exc

    for arg in args:
        cmd = arg.strip()
        if not cmd:
            continue
        # cliclick options like "-w" "8" (wait between commands) — we just no-op
        if cmd.startswith("-"):
            continue
        try:
            verb, _, payload = cmd.partition(":")
            # Critical: must run on the asyncio main thread, NOT via
            # asyncio.to_thread — Quartz events posted from a worker thread
            # get a different responsible-app attribution and macOS drops
            # them (the same failure mode that bites the cliclick subprocess).
            _dispatch_one(Quartz, verb, payload)
        except Exception as exc:  # noqa: BLE001
            raise InputError(f"input event failed for {cmd!r}: {exc}") from exc
        output_lines.append(cmd)

    return InputResult(ok=True, output="\n".join(output_lines))


def _dispatch_one(Quartz, verb: str, payload: str) -> None:
    """Run a single cliclick-style verb via Quartz."""
    if verb in {"c", "dc", "rc"}:
        x, y = _parse_xy(payload)
        button = "right" if verb == "rc" else "left"
        clicks = 2 if verb == "dc" else 1
        _quartz_click(Quartz, x, y, button=button, clicks=clicks)
        return

    if verb == "m":
        x, y = _parse_xy(payload)
        _quartz_mouse_move(Quartz, x, y)
        return

    if verb == "dd":
        # drag-down: press left button at current cursor position
        pos = _current_cursor_position(Quartz)
        _quartz_mouse_button(Quartz, pos[0], pos[1], button="left", down=True, drag=True)
        return

    if verb == "du":
        pos = _current_cursor_position(Quartz)
        _quartz_mouse_button(Quartz, pos[0], pos[1], button="left", down=False, drag=True)
        return

    if verb == "kd":
        name = MODIFIER_ALIASES.get(payload, payload)
        if name in _MODIFIER_FLAGS:
            _held_modifiers.add(name)
            return
        # Non-modifier key down (uncommon; cliclick uses kp: for that)
        _quartz_keyboard_event(Quartz, name, key_down=True)
        return

    if verb == "ku":
        name = MODIFIER_ALIASES.get(payload, payload)
        if name in _MODIFIER_FLAGS:
            _held_modifiers.discard(name)
            return
        _quartz_keyboard_event(Quartz, name, key_down=False)
        return

    if verb == "kp":
        # Single key press (down + up) — used for named keys (return, esc, ...).
        name = KEY_ALIASES.get(payload.replace(" ", "_"), payload)
        _quartz_keyboard_event(Quartz, name, key_down=True)
        _quartz_keyboard_event(Quartz, name, key_down=False)
        return

    if verb == "t":
        # Type literal text. If modifiers are held (cmd+t etc.), emit each
        # char with the modifier flags set; otherwise send unicode keystrokes.
        if _held_modifiers:
            for ch in payload:
                _quartz_keyboard_event(Quartz, ch, key_down=True)
                _quartz_keyboard_event(Quartz, ch, key_down=False)
        else:
            _quartz_unicode_keystroke(Quartz, payload)
        return

    raise InputError(f"unknown cliclick verb: {verb!r}")


# ---------------------------------------------------------------- Quartz helpers

def _parse_xy(payload: str) -> tuple[int, int]:
    a, _, b = payload.partition(",")
    return int(a), int(b)


def _current_cursor_position(Quartz) -> tuple[int, int]:
    event = Quartz.CGEventCreate(None)
    loc = Quartz.CGEventGetLocation(event)
    return int(loc.x), int(loc.y)


def _flags_mask() -> int:
    mask = 0
    for m in _held_modifiers:
        mask |= _MODIFIER_FLAGS[m]
    return mask


def _quartz_mouse_move(Quartz, x: int, y: int) -> None:
    event = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (x, y), 0)
    if (mask := _flags_mask()):
        Quartz.CGEventSetFlags(event, mask)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def _quartz_click(Quartz, x: int, y: int, button: str = "left", clicks: int = 1) -> None:
    if button == "left":
        button_const = Quartz.kCGMouseButtonLeft
        down_type, up_type = Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp
    else:
        button_const = Quartz.kCGMouseButtonRight
        down_type, up_type = Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp

    mask = _flags_mask()
    for i in range(clicks):
        d = Quartz.CGEventCreateMouseEvent(None, down_type, (x, y), button_const)
        Quartz.CGEventSetIntegerValueField(d, Quartz.kCGMouseEventClickState, i + 1)
        if mask:
            Quartz.CGEventSetFlags(d, mask)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, d)
        u = Quartz.CGEventCreateMouseEvent(None, up_type, (x, y), button_const)
        Quartz.CGEventSetIntegerValueField(u, Quartz.kCGMouseEventClickState, i + 1)
        if mask:
            Quartz.CGEventSetFlags(u, mask)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, u)


def _quartz_mouse_button(Quartz, x: int, y: int, button: str, down: bool, drag: bool = False) -> None:
    if button == "left":
        if drag:
            event_type = Quartz.kCGEventLeftMouseDragged if down else Quartz.kCGEventLeftMouseUp
        else:
            event_type = Quartz.kCGEventLeftMouseDown if down else Quartz.kCGEventLeftMouseUp
        button_const = Quartz.kCGMouseButtonLeft
    else:
        if drag:
            event_type = Quartz.kCGEventRightMouseDragged if down else Quartz.kCGEventRightMouseUp
        else:
            event_type = Quartz.kCGEventRightMouseDown if down else Quartz.kCGEventRightMouseUp
        button_const = Quartz.kCGMouseButtonRight
    event = Quartz.CGEventCreateMouseEvent(None, event_type, (x, y), button_const)
    if (mask := _flags_mask()):
        Quartz.CGEventSetFlags(event, mask)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def _quartz_keyboard_event(Quartz, name: str, key_down: bool) -> None:
    """Press or release a single named/letter key."""
    code = _KEY_CODES.get(name.lower())
    if code is None:
        # Unknown name — fall back to a unicode-keystroke for a single char.
        if len(name) == 1:
            event = Quartz.CGEventCreateKeyboardEvent(None, 0, key_down)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(name), name)
            if (mask := _flags_mask()):
                Quartz.CGEventSetFlags(event, mask)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
            return
        raise InputError(f"unknown key name: {name!r}")
    event = Quartz.CGEventCreateKeyboardEvent(None, code, key_down)
    if (mask := _flags_mask()):
        Quartz.CGEventSetFlags(event, mask)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def _quartz_unicode_keystroke(Quartz, text: str) -> None:
    """Type literal text via unicode keystrokes — bypasses the virtual-key-code
    map so any character (including non-ASCII) works."""
    for ch in text:
        for key_down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, 0, key_down)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(ch), ch)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
