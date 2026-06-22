import json

from api.core import system
from api.core.system import SystemExecutor, _resolve_command, run_shell


def test_resolve_command_rejects_unallowed_command():
    try:
        _resolve_command("rm", "write")
    except ValueError as exc:
        assert "not allowed" in str(exc)
    else:
        raise AssertionError("expected ValueError")


async def test_command_exists_reports_path():
    result = await SystemExecutor().execute({"action": "command_exists", "command": "system_profiler"})

    assert '"exists": true' in result


async def test_run_command_can_read_sw_vers():
    result = await SystemExecutor().execute(
        {"action": "run_command", "command": "sw_vers", "args": [], "intent": "read"}
    )

    assert '"returncode": 0' in result
    assert "ProductName" in result


async def test_run_command_blocks_unallowed_read():
    try:
        await SystemExecutor().execute(
            {"action": "run_command", "command": "rm", "args": ["-rf", "/tmp/nope"], "intent": "read"}
        )
    except ValueError as exc:
        assert "not allowed" in str(exc)
    else:
        raise AssertionError("expected ValueError")


async def test_run_shell_read_command():
    result = await run_shell("printf hello", intent="read")

    assert '"returncode": 0' in result
    assert "hello" in result


async def test_run_shell_blocks_mutation_as_read():
    try:
        await run_shell("touch /tmp/nope", intent="read")
    except ValueError as exc:
        assert "appears to mutate" in str(exc)
    else:
        raise AssertionError("expected ValueError")


async def test_run_shell_blocks_dangerous_snippets():
    try:
        await run_shell("sudo rm -rf /", intent="write")
    except ValueError as exc:
        assert "Blocked dangerous" in str(exc)
    else:
        raise AssertionError("expected ValueError")


async def test_audio_default_output_parses_system_profiler(monkeypatch):
    fixture = {
        "SPAudioDataType": [
            {
                "_items": [
                    {
                        "_name": "MacBook Pro Speakers",
                        "coreaudio_device_transport": "built-in",
                    },
                    {
                        "_name": "AirPods Pro",
                        "coreaudio_device_transport": "Bluetooth",
                        "coreaudio_default_audio_output_device": "spaudio_yes",
                        "coreaudio_default_audio_input_device": "spaudio_yes",
                    },
                ]
            }
        ]
    }

    async def fake_run_command(command, args, intent="read", timeout=10):
        return json.dumps(
            {
                "command": command,
                "args": args,
                "intent": intent,
                "returncode": 0,
                "stdout": json.dumps(fixture),
                "stderr": "",
            }
        )

    monkeypatch.setattr(system, "run_command", fake_run_command)

    raw = await SystemExecutor().execute({"action": "audio_default_output"})
    payload = json.loads(raw)

    assert payload["ok"] is True
    assert payload["default_output"] == "AirPods Pro"
    assert payload["default_output_transport"] == "Bluetooth"
    assert any(d["name"] == "MacBook Pro Speakers" for d in payload["devices"])


async def test_audio_default_output_handles_no_default(monkeypatch):
    fixture = {"SPAudioDataType": [{"_items": [{"_name": "Speakers"}]}]}

    async def fake_run_command(command, args, intent="read", timeout=10):
        return json.dumps(
            {"command": command, "args": args, "intent": intent, "returncode": 0, "stdout": json.dumps(fixture), "stderr": ""}
        )

    monkeypatch.setattr(system, "run_command", fake_run_command)

    raw = await SystemExecutor().execute({"action": "audio_default_output"})
    payload = json.loads(raw)

    assert payload["ok"] is False
    assert payload["default_output"] is None
