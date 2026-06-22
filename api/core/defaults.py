"""macOS default-application discovery via LaunchServices.

Thin pyobjc wrappers around `NSWorkspace.urlForApplication(toOpen:)`.
The whole point: never hardcode app bundle IDs in product code. Whatever
the user has set as their default browser / mail client / etc. is what
klo drives, by definition.

Used by:
  - `agent2/agent.py` CURRENT CONTEXT block — surfaces "default browser
    is <name> (bundle <id>)" so the model can `shell open -a` by name
    without guessing.
  - `api/core/accessibility.py:_resolve_target_app` — biases AX-walk
    targeting toward the default browser when the task is browser-y.

No tables, no enumerated lists. The OS knows; we ask.
"""
from __future__ import annotations

from typing import Optional


def default_browser_info() -> Optional[dict[str, str]]:
    """Return {'bundle_id', 'name', 'exec_path'} for the user's default
    HTTP handler, or None if pyobjc/LaunchServices is unavailable.

    Equivalent to System Settings → Default Web Browser. Works for any
    browser the user picks — Safari, Chrome, Dia, Arc, Brave, Vivaldi,
    Edge, Firefox, anything that registers as a `https://` handler.
    """
    return _default_app_for_url("https://example.com")


def default_app_for_scheme(scheme: str) -> Optional[dict[str, str]]:
    """Return the user's default app for a given URL scheme.

    Examples:
      default_app_for_scheme("mailto")    # default email client
      default_app_for_scheme("music")     # default music app
      default_app_for_scheme("calshow")   # default calendar
      default_app_for_scheme("sms")       # default messaging
    """
    s = scheme.strip().rstrip(":/")
    if not s:
        return None
    # Use a placeholder URL that LaunchServices recognizes for handler
    # lookup. The actual host/path doesn't matter; only the scheme.
    return _default_app_for_url(f"{s}://example")


def _default_app_for_url(url_str: str) -> Optional[dict[str, str]]:
    try:
        import AppKit
        import Foundation
    except Exception:
        return None
    try:
        ws = AppKit.NSWorkspace.sharedWorkspace()
        url = Foundation.NSURL.URLWithString_(url_str)
        if url is None:
            return None
        app_url = ws.URLForApplicationToOpenURL_(url)
        if app_url is None:
            return None
        # NSBundle gives us the cleanest path to bundle ID + name.
        bundle = AppKit.NSBundle.bundleWithURL_(app_url)
        bundle_id = ""
        name = ""
        if bundle is not None:
            bundle_id = str(bundle.bundleIdentifier() or "")
            info = bundle.infoDictionary() or {}
            # CFBundleDisplayName preferred; fall back to CFBundleName,
            # then to the .app folder name.
            name = str(
                info.get("CFBundleDisplayName")
                or info.get("CFBundleName")
                or app_url.lastPathComponent().stringByDeletingPathExtension()
                or ""
            )
        exec_path = str(app_url.path() or "")
        if not bundle_id and not name and not exec_path:
            return None
        return {
            "bundle_id": bundle_id,
            "name": name,
            "exec_path": exec_path,
        }
    except Exception:
        return None
