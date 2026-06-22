"""Lock in that the AppleEvents permission probe actually probes.

Failure mode this guards against: the previous _ae_permitted_for_system_events
imported `from ApplicationServices import AEDeterminePermissionToAutomateTarget`
via PyObjC — a binding that doesn't exist. The try/except silently swallowed
the AttributeError and the function ALWAYS returned False. The user-facing
behavior happened to be correct (no surprise prompt) but for the wrong reason
— the function pretended to probe but actually didn't.

Replacement uses ctypes to load the framework directly. This test verifies
the function reaches AEDeterminePermissionToAutomateTarget so a future
refactor can't silently revert to the fake-probe shape.
"""
from __future__ import annotations

import unittest.mock as _mock

from agent2.agent import _ae_permitted_for_system_events


def test_probe_actually_loads_framework_and_calls_AE_symbol(monkeypatch):
    """Monkeypatch ctypes.CDLL to record what's loaded and what's called.
    A real probe must load ApplicationServices and reach the
    AEDeterminePermissionToAutomateTarget symbol — anything that returns
    False without doing both is a fake probe and would silently mask
    permission-state changes."""
    fake_lib = _mock.MagicMock()
    fake_lib.AECreateDesc.return_value = 0  # noErr
    # Granted, so the probe should return True if it actually called us.
    fake_lib.AEDeterminePermissionToAutomateTarget.return_value = 0
    fake_lib.AEDisposeDesc.return_value = 0

    loaded_paths: list[str] = []

    def _fake_cdll(path, *a, **kw):
        loaded_paths.append(path)
        return fake_lib

    monkeypatch.setattr("ctypes.CDLL", _fake_cdll)

    result = _ae_permitted_for_system_events()

    # 1. The framework must be loaded (catches "we deleted the load entirely").
    assert any("ApplicationServices" in p for p in loaded_paths), (
        f"probe never loaded ApplicationServices framework. Loaded: {loaded_paths}"
    )

    # 2. The actual permission-determining symbol must be called (catches
    #    "we kept the framework load but stopped calling the function").
    assert fake_lib.AEDeterminePermissionToAutomateTarget.called, (
        "probe loaded the framework but never called "
        "AEDeterminePermissionToAutomateTarget — that's a fake probe."
    )

    # 3. When the symbol returns 0 (granted), the probe must return True.
    #    Catches "we call the symbol but throw away its return value."
    assert result is True, (
        "probe ignored the framework's noErr (granted) result; it would "
        "always return False regardless of real permission state."
    )


def test_probe_returns_false_on_non_zero_status(monkeypatch):
    """If the framework returns ANY non-zero OSStatus (denied, would-prompt,
    process-not-found, etc.), the probe must return False. Treating non-zero
    as 'maybe granted' is exactly how surprise prompts get triggered."""
    fake_lib = _mock.MagicMock()
    fake_lib.AECreateDesc.return_value = 0
    fake_lib.AEDeterminePermissionToAutomateTarget.return_value = -1744  # would prompt
    fake_lib.AEDisposeDesc.return_value = 0

    monkeypatch.setattr("ctypes.CDLL", lambda *a, **kw: fake_lib)

    assert _ae_permitted_for_system_events() is False


def test_probe_handles_framework_load_failure_gracefully(monkeypatch):
    """If the framework can't be loaded for any reason (theoretical: we're
    on a non-Darwin host, or Apple removes the symbol), the probe must
    return False rather than raise. The agent's _current_context() reads
    this directly and assumes a bool."""
    def _explode(*a, **kw):
        raise OSError("framework not loadable")

    monkeypatch.setattr("ctypes.CDLL", _explode)

    assert _ae_permitted_for_system_events() is False
