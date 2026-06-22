from __future__ import annotations

import plistlib
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class AppInfo:
    name: str
    bundle_id: str | None = None
    active: bool = False


@dataclass(frozen=True)
class OSContext:
    default_browser_name: str | None
    default_browser_bundle_id: str | None
    running_apps: list[AppInfo]

    def to_dict(self) -> dict:
        return {
            "default_browser": {
                "name": self.default_browser_name,
                "bundle_id": self.default_browser_bundle_id,
            },
            "running_apps": [
                {"name": app.name, "bundle_id": app.bundle_id, "active": app.active}
                for app in self.running_apps
            ],
        }


def get_os_context() -> OSContext:
    browser_bundle_id = _default_browser_bundle_id()
    frontmost = frontmost_app_name()
    running_apps = _running_regular_apps()
    if frontmost:
        running_apps = [
            AppInfo(name=app.name, bundle_id=app.bundle_id, active=app.name == frontmost)
            for app in running_apps
        ]
    return OSContext(
        default_browser_name=_app_name_for_bundle_id(browser_bundle_id),
        default_browser_bundle_id=browser_bundle_id,
        running_apps=running_apps,
    )


def frontmost_app_name() -> str | None:
    try:
        output = subprocess.check_output(
            [
                "/usr/bin/osascript",
                "-e",
                'tell application "System Events" to get name of first application process whose frontmost is true',
            ],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        )
        return output.strip() or None
    except Exception:
        return None


def format_os_context(context: OSContext) -> str:
    browser = context.default_browser_name or context.default_browser_bundle_id or "unknown"
    active = next((app.name for app in context.running_apps if app.active), "unknown")
    running = ", ".join(app.name for app in context.running_apps[:20])
    return f"""
CURRENT MACOS CONTEXT:

- Default web browser: {browser}
- Active app: {active}
- Running regular apps: {running or "unknown"}

Use this OS context to avoid stale assumptions, especially for browser tasks.
For example, if the user asks to open a web page, prefer the default browser
listed above or an already-visible/running browser. This context is advisory:
still verify the actual app, URL, and page contents from screenshots before
claiming success.
"""


def _default_browser_bundle_id() -> str | None:
    try:
        import LaunchServices

        return str(LaunchServices.LSCopyDefaultHandlerForURLScheme("https"))
    except Exception:
        return _default_browser_bundle_id_from_defaults()


def _default_browser_bundle_id_from_defaults() -> str | None:
    try:
        output = subprocess.check_output(
            [
                "defaults",
                "export",
                "com.apple.LaunchServices/com.apple.launchservices.secure",
                "-",
            ],
            stderr=subprocess.DEVNULL,
        )
        data = plistlib.loads(output)
        handlers = data.get("LSHandlers", [])
        for handler in reversed(handlers):
            if handler.get("LSHandlerURLScheme") == "https":
                return handler.get("LSHandlerRoleAll")
    except Exception:
        return None
    return None


def _app_name_for_bundle_id(bundle_id: str | None) -> str | None:
    if not bundle_id:
        return None

    try:
        import AppKit

        workspace = AppKit.NSWorkspace.sharedWorkspace()
        url = workspace.URLForApplicationWithBundleIdentifier_(bundle_id)
        if not url:
            return bundle_id

        bundle = AppKit.NSBundle.bundleWithURL_(url)
        name = bundle.objectForInfoDictionaryKey_("CFBundleName")
        return str(name or url.lastPathComponent().stringByDeletingPathExtension())
    except Exception:
        return bundle_id


def _running_regular_apps() -> list[AppInfo]:
    try:
        import AppKit

        apps = []
        for app in AppKit.NSWorkspace.sharedWorkspace().runningApplications():
            if int(app.activationPolicy()) != 0:
                continue
            name = app.localizedName()
            if not name:
                continue
            apps.append(
                AppInfo(
                    name=str(name),
                    bundle_id=str(app.bundleIdentifier()) if app.bundleIdentifier() else None,
                    active=bool(app.isActive()),
                )
            )
        return sorted(apps, key=lambda item: (not item.active, item.name.lower()))
    except Exception:
        return []
