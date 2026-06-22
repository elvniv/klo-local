"""`klo doctor` — diagnose every gotcha that prevents klo from working.

Checks API keys, Accessibility (with a REAL mouse-move probe — not just the
TCC trust check that AXIsProcessTrusted returns), Screen Recording, cliclick,
default browser, controlled-browser CDP, sidecar reachability.

Also identifies the launching .app in the process tree and runs a separate
AppleEvent probe to distinguish "no Accessibility at all" from "Accessibility
works for AppleEvents but cliclick events get dropped" (the Cursor / Electron
launcher gotcha).

Exits 0 if everything's green, 1 otherwise. Prints actionable hints.
"""
from __future__ import annotations

import asyncio
import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv


GREEN = "\x1b[32m"
RED = "\x1b[31m"
YELLOW = "\x1b[33m"
DIM = "\x1b[2m"
RESET = "\x1b[0m"


def _check(label: str, ok: bool, hint: str = "") -> bool:
    icon = f"{GREEN}✓{RESET}" if ok else f"{RED}✗{RESET}"
    print(f"  {icon} {label}")
    if not ok and hint:
        for line in hint.splitlines():
            print(f"    {DIM}{line}{RESET}")
    return ok


def _warn(label: str, detail: str = "") -> None:
    print(f"  {YELLOW}–{RESET} {label}")
    if detail:
        for line in detail.splitlines():
            print(f"    {DIM}{line}{RESET}")


def _walk_to_app() -> tuple[str | None, str | None]:
    """Walk the parent process chain until we hit a .app bundle.

    Returns (app_name, app_path) or (None, None). Used to give specific advice
    when the launching app is known to be problematic (Cursor, Electron IDEs).
    """
    pid = os.getpid()
    for _ in range(12):
        try:
            parent = subprocess.run(
                ["ps", "-p", str(pid), "-o", "ppid="],
                capture_output=True, text=True, timeout=2,
            ).stdout.strip()
        except Exception:
            return None, None
        if not parent or parent in ("0", "1"):
            return None, None
        try:
            cmd = subprocess.run(
                ["ps", "-p", parent, "-o", "command="],
                capture_output=True, text=True, timeout=2,
            ).stdout.strip()
        except Exception:
            return None, None
        if "/Applications/" in cmd or "/Desktop/" in cmd:
            # Find the .app boundary
            tokens = cmd.split()
            for tok in tokens:
                if ".app/Contents/MacOS/" in tok:
                    app_path = tok.split(".app", 1)[0] + ".app"
                    app_name = Path(app_path).stem
                    return app_name, app_path
        pid = int(parent)
    return None, None


async def _appleevent_probe() -> tuple[bool, str]:
    """Test whether AppleEvents to System Events succeed. Read-only — gets the
    name of the frontmost process. If this works but cliclick doesn't, the
    Accessibility allowlist covers AppleEvents from this process but not the
    cliclick subprocess.
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            "/usr/bin/osascript",
            "-e",
            'tell application "System Events" to get the name of first application process whose frontmost is true',
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=4)
    except Exception as exc:
        return False, f"AppleEvent probe crashed: {exc}"
    if proc.returncode != 0:
        err = stderr.decode("utf-8", errors="replace").strip()
        return False, f"osascript exit={proc.returncode}: {err[:200]}"
    return True, stdout.decode("utf-8", errors="replace").strip()


async def _real_accessibility_probe() -> tuple[bool, str]:
    """Move the cursor 17 pixels and check it moved. The only honest test —
    AXIsProcessTrusted() returns True even when synthetic events are silently
    dropped, which is what happens when the launching app isn't actually in
    the Accessibility allowlist."""
    try:
        from api.core.screenshot import cursor_position
        from api.core import input as mac_input
    except Exception as exc:
        return False, f"could not import probe modules: {exc}"

    try:
        before = cursor_position()
        target = (before[0] + 17, before[1] + 17) if before[0] < 1500 else (before[0] - 17, before[1] - 17)
        await mac_input.mouse_move(*target)
        # Quartz events are queued asynchronously. Brief sleep lets the event
        # land before we re-read the cursor position.
        await asyncio.sleep(0.15)
        after = cursor_position()
        if after == before:
            return False, (
                "Synthetic input did not move the cursor. macOS dropped the event.\n"
                "→ Open System Settings → Privacy & Security → Accessibility.\n"
                "→ Toggle ON the app that launched this shell (Terminal.app is most reliable).\n"
                "→ If you launched klo from Cursor's terminal, also try restarting Cursor."
            )
        # Restore cursor
        await mac_input.mouse_move(*before)
        await asyncio.sleep(0.05)
        return True, ""
    except Exception as exc:
        return False, f"probe crashed: {exc}"


async def _check_sidecar(port: int) -> tuple[bool, str]:
    try:
        async with httpx.AsyncClient(timeout=1) as client:
            response = await client.get(f"http://127.0.0.1:{port}/runs")
            return response.status_code == 200, ""
    except Exception:
        return False, ""


def _check_cdp(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.3):
            return True
    except OSError:
        return False


async def main() -> int:
    load_dotenv()

    print(f"{DIM}# klo doctor — checking the harness{RESET}\n")

    all_ok = True

    print(f"{DIM}## API keys{RESET}")
    anthropic_set = bool(os.environ.get("ANTHROPIC_API_KEY", "").strip().rstrip("."))
    openai_set = bool(os.environ.get("OPENAI_API_KEY", "").strip().rstrip("."))
    provider = os.environ.get("MODEL_PROVIDER", "anthropic").lower()

    if provider == "anthropic":
        all_ok &= _check(
            f"ANTHROPIC_API_KEY (provider={provider})",
            anthropic_set,
            "Set ANTHROPIC_API_KEY in .env or shell.",
        )
    elif provider == "openai":
        all_ok &= _check(
            f"OPENAI_API_KEY (provider={provider})",
            openai_set,
            "Set OPENAI_API_KEY in .env or shell.",
        )
    else:
        all_ok &= _check(f"MODEL_PROVIDER={provider!r} not recognized", False, "Set to 'anthropic' or 'openai'.")
    print()

    print(f"{DIM}## Launcher (which .app owns Accessibility for klo){RESET}")
    app_name, app_path = _walk_to_app()
    if app_name:
        print(f"  {GREEN}✓{RESET} launcher: {app_name}  {DIM}({app_path}){RESET}")
        if app_name.lower() in {"cursor", "vscode", "code", "electron"}:
            print(
                f"    {DIM}FYI: Electron-based launchers used to break synthetic input via{RESET}"
            )
            print(
                f"    {DIM}cliclick subprocess. klo now posts events in-process via Quartz,{RESET}"
            )
            print(
                f"    {DIM}so the cliclick subprocess gotcha is bypassed. The probe below{RESET}"
            )
            print(
                f"    {DIM}is the source of truth — if it's green, you're fine.{RESET}"
            )
    else:
        _warn("could not identify launcher .app from process tree")
    print()

    print(f"{DIM}## macOS permissions (the bit that actually decides if klo can click){RESET}")
    cliclick_path = shutil.which("cliclick")
    if cliclick_path:
        print(f"  {GREEN}·{RESET} cliclick present at {cliclick_path}  {DIM}(no longer required — events post in-process via Quartz){RESET}")
    else:
        print(f"  {DIM}· cliclick not installed (fine — no longer required){RESET}")

    # Screen recording — try a screenshot
    sr_ok = False
    sr_hint = ""
    try:
        from api.core.screenshot import screenshot, ScreenRecordingPermissionError
        await screenshot()
        sr_ok = True
    except ScreenRecordingPermissionError as exc:
        sr_hint = str(exc)
    except Exception as exc:
        sr_hint = f"screenshot probe crashed: {exc}"
    all_ok &= _check("Screen Recording permission lets klo see the display", sr_ok, sr_hint)

    # AppleEvent probe — distinguishes "no Accessibility at all" from "events
    # work for AppleEvents but cliclick events get dropped".
    ae_ok, ae_detail = await _appleevent_probe()
    if ae_ok:
        print(f"  {GREEN}✓{RESET} Accessibility — AppleEvents to System Events succeed")
        print(f"    {DIM}(System Events returned frontmost process: {ae_detail!r}){RESET}")
    else:
        print(f"  {RED}✗{RESET} Accessibility — AppleEvents path is closed")
        print(f"    {DIM}{ae_detail}{RESET}")

    # Real cursor-move probe — proves the Quartz dispatch path actually lands.
    ax_ok, ax_hint = await _real_accessibility_probe()
    if ax_ok:
        print(f"  {GREEN}✓{RESET} Accessibility — synthetic events reach the OS")
    else:
        print(f"  {RED}✗{RESET} Accessibility — synthetic events are being dropped")
        for line in ax_hint.splitlines():
            print(f"    {DIM}{line}{RESET}")
    all_ok &= ax_ok
    print()

    print(f"{DIM}## Browser{RESET}")
    try:
        from api.core.os_context import get_os_context
        ctx = get_os_context()
        if ctx.default_browser_name:
            _check(f"default browser: {ctx.default_browser_name}", True)
        else:
            all_ok &= _check("default browser detected", False, "macOS did not report a default https handler.")
    except Exception as exc:
        all_ok &= _check("default browser detected", False, f"detection crashed: {exc}")

    cdp_port = int(os.environ.get("CONTROLLED_BROWSER_PORT", "9333"))
    if _check_cdp(cdp_port):
        _check(f"controlled-browser CDP listening on :{cdp_port}", True)
    else:
        _warn(
            f"controlled-browser CDP not running on :{cdp_port}",
            "Klo will launch it on demand via browser/ensure_controlled.",
        )
    print()

    print(f"{DIM}## Sidecar{RESET}")
    sidecar_port = int(os.environ.get("PORT", "8765"))
    sidecar_ok, _ = await _check_sidecar(sidecar_port)
    if sidecar_ok:
        _check(f"klo-api reachable on :{sidecar_port}", True)
    else:
        _warn(
            f"klo-api not running on :{sidecar_port}",
            "That's fine for in-process runs (dryrun.smoke_real). For the CLI, start it: `klo-api`.",
        )
    print()

    if all_ok:
        print(f"{GREEN}all green — klo should work end-to-end.{RESET}")
        return 0
    print(f"{RED}some checks failed. Fix the {RED}✗{RED} items above and re-run `klo doctor`.{RESET}")
    return 1


def entrypoint() -> None:
    sys.exit(asyncio.run(main()))


if __name__ == "__main__":
    entrypoint()
