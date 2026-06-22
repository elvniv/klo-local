from api.config import Settings
from api.core.workspace import FocusLeaseLost, WorkspaceGuard


def test_controller_apps_parse_csv():
    settings = Settings(controller_app_names="Cursor, Terminal")
    guard = WorkspaceGuard(settings)

    assert guard.controller_apps == ["Cursor", "Terminal"]


def test_guard_pauses_dangerous_computer_action_on_controller_focus(monkeypatch):
    settings = Settings(pause_on_controller_focus=True, controller_app_names="Cursor")
    guard = WorkspaceGuard(settings)
    monkeypatch.setattr(
        guard,
        "state",
        lambda: type("State", (), {"active_app": "Cursor"})(),
    )

    try:
        guard.ensure_can_act("computer", {"action": "type"})
    except FocusLeaseLost as exc:
        assert "Cursor is frontmost" in str(exc)
    else:
        raise AssertionError("expected FocusLeaseLost")


def test_guard_pauses_macos_paste_on_controller_focus(monkeypatch):
    settings = Settings(pause_on_controller_focus=True, controller_app_names="Cursor")
    guard = WorkspaceGuard(settings)
    monkeypatch.setattr(
        guard,
        "state",
        lambda: type("State", (), {"active_app": "Cursor"})(),
    )

    try:
        guard.ensure_can_act("macos", {"action": "paste_text"})
    except FocusLeaseLost:
        pass
    else:
        raise AssertionError("expected FocusLeaseLost")


def test_guard_allows_observation_on_controller_focus(monkeypatch):
    settings = Settings(pause_on_controller_focus=True, controller_app_names="Cursor")
    guard = WorkspaceGuard(settings)
    monkeypatch.setattr(
        guard,
        "state",
        lambda: type("State", (), {"active_app": "Cursor"})(),
    )

    guard.ensure_can_act("computer", {"action": "screenshot"})
    guard.ensure_can_act("computer", {"action": "left_click"})
    guard.ensure_can_act("accessibility", {"action": "focused_snapshot"})
