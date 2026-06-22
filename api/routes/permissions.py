import shutil
from typing import Any

from fastapi import APIRouter

from api.core.screenshot import ScreenRecordingPermissionError, screenshot


router = APIRouter()


@router.get("/permissions/status")
async def permissions_status(probe: bool = False) -> dict[str, Any]:
    """Report macOS permission status for klo.

    `probe=true` runs a real cursor-move probe to verify Accessibility events
    actually reach the OS. Defaults to false because the probe moves the user's
    cursor 17 pixels (and back), which is intrusive for a status endpoint.

    Without `probe=true`, the response uses Apple's `AXIsProcessTrusted`, which
    can return True even when synthetic events are silently dropped (e.g. when
    the launching app's TCC entry exists but events still get filtered). For
    honesty, the response includes a warning when `probe` is false.
    """
    return {
        "accessibility": await _accessibility_status(probe=probe),
        "screen_recording": await _screen_recording_status(),
        "cliclick": _cliclick_status(),
    }


async def _accessibility_status(probe: bool) -> dict[str, Any]:
    api_trusted: bool | None
    api_detail: str | None
    try:
        import ApplicationServices

        api_trusted = bool(ApplicationServices.AXIsProcessTrusted())
        api_detail = (
            None
            if api_trusted
            else "Grant Accessibility to the app that launches klo (Terminal.app is the most reliable)."
        )
    except Exception as exc:
        api_trusted = None
        api_detail = f"AXIsProcessTrusted check crashed: {exc}"

    if not probe:
        # Honesty: AXIsProcessTrusted is necessary but NOT sufficient.
        return {
            "ok": api_trusted,
            "trusted_api": api_trusted,
            "events_land": None,
            "detail": api_detail,
            "note": (
                "trusted_api can be true while events are still dropped. Re-call "
                "with ?probe=true to run a real cursor-move test."
            ),
        }

    # Real probe: move cursor 17 pixels and verify it actually moved.
    events_land, probe_detail = await _real_probe()
    return {
        "ok": bool(api_trusted) and events_land,
        "trusted_api": api_trusted,
        "events_land": events_land,
        "detail": probe_detail or api_detail,
    }


async def _real_probe() -> tuple[bool, str | None]:
    try:
        from api.core.screenshot import cursor_position
        from api.core import input as mac_input
    except Exception as exc:
        return False, f"could not import probe modules: {exc}"
    try:
        before = cursor_position()
        target = (before[0] + 17, before[1] + 17) if before[0] < 1500 else (before[0] - 17, before[1] - 17)
        await mac_input.mouse_move(*target)
        after = cursor_position()
        if after == before:
            return False, (
                "cliclick exited 0 but the cursor did not move — macOS dropped the synthetic event. "
                "Toggle Accessibility for the launching app (Terminal.app recommended) and re-test."
            )
        await mac_input.mouse_move(*before)
        return True, None
    except Exception as exc:
        return False, f"probe crashed: {exc}"


async def _screen_recording_status() -> dict[str, Any]:
    try:
        await screenshot()
        return {"ok": True, "detail": None}
    except ScreenRecordingPermissionError as exc:
        return {"ok": False, "detail": str(exc)}
    except Exception as exc:
        return {"ok": False, "detail": f"Screenshot check failed: {exc}"}


def _cliclick_status() -> dict[str, Any]:
    path = shutil.which("cliclick")
    return {
        "ok": bool(path),
        "path": path,
        "detail": None if path else "Install with `brew install cliclick`.",
    }
