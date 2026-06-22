from __future__ import annotations

import asyncio
import json
import shutil
from typing import Any

from api.core.redact import redact_payload, redact_text


SYSTEM_TOOL = {
    "name": "system",
    "description": (
        "Generic local system runner. Use it like a careful macOS operator: inspect "
        "state, run installed utilities, invoke shell pipelines when useful, and verify "
        "results. Commands have timeouts, redaction, and destructive-command guards."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": [
                    "command_exists",
                    "run_command",
                    "run_shell",
                    "list_shortcuts",
                    "run_shortcut",
                    "audio_default_output",
                ],
            },
            "command": {
                "type": "string",
                "description": "Executable name or absolute path, e.g. blueutil or /usr/sbin/system_profiler.",
            },
            "args": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Command arguments. No shell is used.",
            },
            "intent": {
                "type": "string",
                "enum": ["read", "write"],
                "description": "Whether the command reads state or mutates state.",
            },
            "name": {
                "type": "string",
                "description": "Shortcut name for run_shortcut.",
            },
            "timeout": {
                "type": "number",
                "description": "Timeout in seconds, capped by the runtime.",
            },
            "script": {
                "type": "string",
                "description": "Shell script for run_shell. Use intent='read' or intent='write'.",
            },
        },
        "required": ["action"],
        "additionalProperties": False,
    },
}


READ_COMMANDS = {
    "automator",
    "blueutil",
    "curl",
    "defaults",
    "diskutil",
    "ffmpeg",
    "find",
    "mdfind",
    "mdls",
    "networksetup",
    "open",
    "pmset",
    "python",
    "python3",
    "scutil",
    "say",
    "screencapture",
    "shortcuts",
    "system_profiler",
    "sw_vers",
    "whoami",
    "yt-dlp",
}

WRITE_COMMANDS = {
    "automator",
    "blueutil",
    "curl",
    "ffmpeg",
    "networksetup",
    "open",
    "osascript",
    "pmset",
    "python",
    "python3",
    "say",
    "screencapture",
    "shortcuts",
    "yt-dlp",
}

BLOCKED_SHELL_SNIPPETS = {
    "rm -rf /",
    "sudo rm",
    "mkfs",
    "diskutil erase",
    ":(){",
    "shutdown",
    "reboot",
    "killall -9",
}


class SystemExecutor:
    async def execute(self, tool_input: dict[str, Any]) -> str:
        action = tool_input.get("action")
        if action == "command_exists":
            command = str(tool_input.get("command") or "")
            path = shutil.which(command)
            return json.dumps({"exists": bool(path), "path": path}, ensure_ascii=False)

        if action == "list_shortcuts":
            return await run_command("shortcuts", ["list"], intent="read")

        if action == "run_shortcut":
            name = str(tool_input.get("name") or "")
            if not name:
                raise ValueError("run_shortcut requires name")
            return await run_command("shortcuts", ["run", name], intent="write")

        if action == "run_command":
            command = str(tool_input.get("command") or "")
            args = [str(arg) for arg in tool_input.get("args", [])]
            intent = str(tool_input.get("intent") or "read")
            timeout = float(tool_input.get("timeout", 10))
            return await run_command(command, args, intent=intent, timeout=timeout)

        if action == "run_shell":
            script = str(tool_input.get("script") or "")
            intent = str(tool_input.get("intent") or "read")
            timeout = float(tool_input.get("timeout", 10))
            return await run_shell(script, intent=intent, timeout=timeout)

        if action == "audio_default_output":
            return await audio_default_output()

        raise ValueError(f"Unsupported system action: {action!r}")


async def run_command(
    command: str,
    args: list[str],
    intent: str = "read",
    timeout: float = 10,
) -> str:
    executable = _resolve_command(command, intent)
    timeout = min(max(timeout, 0.5), 20)
    proc = await asyncio.create_subprocess_exec(
        executable,
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError as exc:
        proc.kill()
        await proc.communicate()
        raise RuntimeError(f"{command} timed out after {timeout:g}s") from exc

    payload = {
        "command": command,
        "args": args,
        "intent": intent,
        "returncode": proc.returncode,
        "stdout": stdout.decode("utf-8", errors="replace")[:20000],
        "stderr": stderr.decode("utf-8", errors="replace")[:8000],
    }
    return json.dumps(redact_payload(payload), ensure_ascii=False)


async def run_shell(script: str, intent: str = "read", timeout: float = 10) -> str:
    if not script.strip():
        raise ValueError("script is required")
    _validate_shell(script, intent)
    timeout = min(max(timeout, 0.5), 20)
    proc = await asyncio.create_subprocess_exec(
        "/bin/zsh",
        "-lc",
        script,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError as exc:
        proc.kill()
        await proc.communicate()
        raise RuntimeError(f"shell timed out after {timeout:g}s") from exc

    payload = {
        "script": script,
        "intent": intent,
        "returncode": proc.returncode,
        "stdout": stdout.decode("utf-8", errors="replace")[:20000],
        "stderr": stderr.decode("utf-8", errors="replace")[:8000],
    }
    return json.dumps(redact_payload(payload), ensure_ascii=False)


async def audio_default_output() -> str:
    raw = await run_command(
        "system_profiler",
        ["SPAudioDataType", "-json"],
        intent="read",
        timeout=10,
    )
    try:
        wrapper = json.loads(raw)
        stdout = wrapper.get("stdout", "")
        data = json.loads(stdout) if stdout else {}
    except (ValueError, json.JSONDecodeError) as exc:
        return json.dumps({"ok": False, "error": f"could not parse system_profiler output: {exc}"})

    devices = []
    default_output = None
    for group in data.get("SPAudioDataType", []):
        for item in group.get("_items", []):
            name = item.get("_name") or ""
            is_default_output = item.get("coreaudio_default_audio_output_device") == "spaudio_yes"
            transport = item.get("coreaudio_device_transport") or item.get("coreaudio_device_manufacturer") or ""
            entry = {
                "name": name,
                "transport": transport,
                "default_output": is_default_output,
                "default_input": item.get("coreaudio_default_audio_input_device") == "spaudio_yes",
            }
            devices.append(entry)
            if is_default_output:
                default_output = entry
    return json.dumps(
        {
            "ok": default_output is not None,
            "default_output": default_output["name"] if default_output else None,
            "default_output_transport": default_output["transport"] if default_output else None,
            "devices": devices,
        },
        ensure_ascii=False,
    )


def _resolve_command(command: str, intent: str) -> str:
    if not command:
        raise ValueError("command is required")
    base = command.rsplit("/", 1)[-1]
    allowed = READ_COMMANDS if intent == "read" else WRITE_COMMANDS
    if base not in allowed:
        raise ValueError(f"Command {base!r} is not allowed for {intent!r} intent")
    path = command if command.startswith("/") else shutil.which(command)
    if not path:
        raise ValueError(f"Command {base!r} was not found")
    return path


def _validate_shell(script: str, intent: str) -> None:
    lowered = script.lower()
    for blocked in BLOCKED_SHELL_SNIPPETS:
        if blocked in lowered:
            raise ValueError(f"Blocked dangerous shell snippet: {blocked}")
    if intent == "read":
        write_markers = [" > ", ">>", "rm ", "mv ", "cp ", "touch ", "mkdir ", "osascript", "open "]
        if any(marker in lowered for marker in write_markers):
            raise ValueError("Shell script appears to mutate state; use intent='write'")
