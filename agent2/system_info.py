"""System-level facts the agent needs to ground its actions correctly:
the user's default browser, frontmost app, etc.

The default-browser detection is the load-bearing one — when the agent
needs to do something on the web, it MUST use browser_extension (which
drives the user's actual signed-in Chrome session via the extension
bridge), NOT the `computer` tool to open Safari or some other browser
the user doesn't actually use day-to-day. Without knowing the default
browser the agent has been making bad routing decisions.
"""
from __future__ import annotations

import asyncio
import plistlib
import subprocess
from pathlib import Path
from typing import Any

# Friendly names for the bundle IDs LaunchServices reports. Anything
# missing from this map falls back to the bundle ID itself, which is
# still useful for the agent (it can pattern-match on "browser" or
# "chrome" in the string).
_BROWSER_NAMES: dict[str, str] = {
    "com.google.chrome": "Google Chrome",
    "com.google.chrome.canary": "Google Chrome Canary",
    "com.google.chrome.beta": "Google Chrome Beta",
    "com.google.chrome.dev": "Google Chrome Dev",
    "com.apple.safari": "Safari",
    "com.apple.safaritechnologypreview": "Safari Technology Preview",
    "org.mozilla.firefox": "Firefox",
    "org.mozilla.firefoxdeveloperedition": "Firefox Developer Edition",
    "com.brave.browser": "Brave Browser",
    "com.brave.browser.beta": "Brave Browser Beta",
    "company.thebrowser.browser": "Arc",
    "company.thebrowser.dia": "Dia",
    "com.microsoft.edgemac": "Microsoft Edge",
    "com.microsoft.edgemac.beta": "Microsoft Edge Beta",
    "com.microsoft.edgemac.dev": "Microsoft Edge Dev",
    "com.vivaldi.vivaldi": "Vivaldi",
    "com.operasoftware.opera": "Opera",
    "com.operasoftware.operagx": "Opera GX",
    "com.kagi.kagimacos": "Orion",
    "io.zen-browser.zen": "Zen Browser",
    "com.duckduckgo.macos.browser": "DuckDuckGo",
}


def _default_browser_bundle_id_via_launchservices() -> str | None:
    """Use LaunchServices via pyobjc — the canonical Apple API."""
    try:
        import LaunchServices  # type: ignore
        import CoreFoundation  # type: ignore
    except ImportError:
        return None
    try:
        scheme = CoreFoundation.CFStringCreateWithCString(
            None, b"http", CoreFoundation.kCFStringEncodingUTF8
        )
        if scheme is None:
            return None
        result = LaunchServices.LSCopyDefaultHandlerForURLScheme(scheme)
        if result is None:
            return None
        return str(result).lower()
    except Exception:
        return None


def _default_browser_bundle_id_via_plist() -> str | None:
    """Fallback: read the LaunchServices plist directly. Useful in
    sandboxed contexts where the framework call returns None."""
    plist_path = (
        Path.home()
        / "Library"
        / "Preferences"
        / "com.apple.LaunchServices"
        / "com.apple.launchservices.secure.plist"
    )
    if not plist_path.exists():
        return None
    try:
        proc = subprocess.run(
            ["plutil", "-convert", "xml1", "-o", "-", str(plist_path)],
            capture_output=True,
            timeout=2,
        )
        if proc.returncode != 0:
            return None
        data: Any = plistlib.loads(proc.stdout)
    except Exception:
        return None
    handlers = data.get("LSHandlers", []) if isinstance(data, dict) else []
    for h in handlers:
        if not isinstance(h, dict):
            continue
        if h.get("LSHandlerURLScheme") == "http":
            handler = h.get("LSHandlerRoleAll") or h.get("LSHandlerRoleViewer")
            if isinstance(handler, str):
                return handler.lower()
    return None


def default_browser() -> dict[str, str | None]:
    """Synchronous default-browser probe. Returns a dict with:
      - bundle_id: "com.google.chrome" or None
      - name: "Google Chrome" or None
    """
    bid = _default_browser_bundle_id_via_launchservices()
    if not bid:
        bid = _default_browser_bundle_id_via_plist()
    if not bid:
        return {"bundle_id": None, "name": None}
    return {
        "bundle_id": bid,
        "name": _BROWSER_NAMES.get(bid, bid),
    }


async def default_browser_async() -> dict[str, str | None]:
    """Awaitable wrapper for use inside the agent loop."""
    return await asyncio.to_thread(default_browser)
