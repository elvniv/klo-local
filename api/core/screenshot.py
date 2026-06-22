from __future__ import annotations

import asyncio
import base64
import threading
from dataclasses import dataclass

from .coords import ScreenGeometry


class ScreenCaptureError(RuntimeError):
    pass


class ScreenRecordingPermissionError(ScreenCaptureError):
    def __init__(self) -> None:
        super().__init__(
            "Screen Recording permission is not producing real pixels. Run "
            "`tccutil reset ScreenCapture`, then trigger a klo screenshot from "
            "the same process that launches klo (Terminal, Cursor, Electron, "
            "etc.) and grant Screen Recording to that app in System Settings."
        )


@dataclass(frozen=True)
class Screenshot:
    png: bytes
    geometry: ScreenGeometry

    @property
    def base64_png(self) -> str:
        return base64.b64encode(self.png).decode("ascii")


async def screenshot(scope: str = "desktop", app_name: str | None = None) -> Screenshot:
    """Capture a screenshot.

    scope='desktop' → full primary display (default, backward-compatible).
    scope='window'  → only windows belonging to the frontmost app (or
                       app_name if provided). Other apps and the desktop
                       are blacked out — Anthropic Computer Use focuses
                       on the active app instead of being distracted by
                       background windows. Coordinate space stays the
                       full display so click coordinates don't need
                       translation.
    """
    return await asyncio.to_thread(_sck_capture, scope, app_name)


def _sck_capture(scope: str = "desktop", app_name: str | None = None) -> Screenshot:
    try:
        import AppKit
        import Quartz
        import ScreenCaptureKit
    except ImportError as exc:
        raise ScreenCaptureError(
            "Install pyobjc ScreenCaptureKit dependencies with `pip install -e .`."
        ) from exc

    content = _get_shareable_content(ScreenCaptureKit)
    displays = list(content.displays())
    if not displays:
        raise ScreenCaptureError("ScreenCaptureKit did not report any displays.")

    display = displays[0]

    if scope == "window":
        filter_ = _build_app_scoped_filter(
            content, display, app_name, ScreenCaptureKit, AppKit
        )
    else:
        # Default desktop scope still excludes klo's own windows. The notch
        # panel sits on the working screen and otherwise appears in every
        # screenshot, encouraging the model to treat its own UI as a target
        # ("I'll click on the klo panel" → wrong). The AX path already
        # filters klo via _SKIP_BUNDLE_IDS; do the same for the screen.
        # If klo isn't currently in the shareable applications list (early
        # boot, or running headless), the exclusion list is empty and we
        # fall back to behavior identical to the previous code path.
        klo_app = _klo_running_application(content)
        excluded_apps = [klo_app] if klo_app is not None else []
        filter_ = ScreenCaptureKit.SCContentFilter.alloc().initWithDisplay_excludingApplications_exceptingWindows_(
            display, excluded_apps, []
        )

    config = ScreenCaptureKit.SCStreamConfiguration.alloc().init()
    config.setShowsCursor_(True)
    config.setWidth_(int(display.width()))
    config.setHeight_(int(display.height()))

    cg_image = _capture_image(ScreenCaptureKit, filter_, config)
    image_width = int(Quartz.CGImageGetWidth(cg_image))
    image_height = int(Quartz.CGImageGetHeight(cg_image))

    if _is_mostly_black(cg_image, Quartz):
        # If we asked for a window scope and the result is black, the
        # target app might have no on-screen windows. Retry full desktop
        # so the agent at least sees the whole screen.
        if scope == "window":
            return _sck_capture("desktop", None)
        raise ScreenRecordingPermissionError()

    logical_width, logical_height = _main_logical_size(AppKit)
    geometry = ScreenGeometry(
        image_width_px=image_width,
        image_height_px=image_height,
        logical_width_px=logical_width,
        logical_height_px=logical_height,
    )
    marked_image = _draw_cursor_crosshair(cg_image, geometry, AppKit, Quartz)
    rep = AppKit.NSBitmapImageRep.alloc().initWithCGImage_(marked_image)
    png_data = rep.representationUsingType_properties_(AppKit.NSPNGFileType, {})
    png = bytes(png_data)

    return Screenshot(
        png=png,
        geometry=geometry,
    )


def _build_app_scoped_filter(content, display, app_name, ScreenCaptureKit, AppKit):
    """Build an SCContentFilter that includes only the frontmost app's
    windows (or `app_name` if provided). Falls back to a full-display
    filter if the target app can't be resolved."""
    target_pid: int | None = None
    if app_name and app_name.strip():
        target_pid = _running_app_pid_by_name(content, app_name.strip())
    if target_pid is None:
        target_pid = _frontmost_app_pid(AppKit)

    target_running_app = None
    if target_pid is not None:
        for running in content.applications():
            try:
                if int(running.processID()) == target_pid:
                    target_running_app = running
                    break
            except Exception:
                continue

    if target_running_app is not None:
        return ScreenCaptureKit.SCContentFilter.alloc().initWithDisplay_includingApplications_exceptingWindows_(
            display, [target_running_app], []
        )
    return ScreenCaptureKit.SCContentFilter.alloc().initWithDisplay_excludingWindows_(
        display, []
    )


def _running_app_pid_by_name(content, app_name: str) -> int | None:
    """Find an SCRunningApplication's PID by its localized name."""
    target = app_name.lower()
    for running in content.applications():
        try:
            name = str(running.applicationName())
        except Exception:
            continue
        if name and name.lower() == target:
            try:
                return int(running.processID())
            except Exception:
                return None
    return None


# Klo's Swift app bundle ID — used to exclude klo's own windows from
# default desktop screenshots so the model never sees its own UI as a
# capturable target. Mirrors _KLO_BUNDLE_ID in active_apps.py and
# accessibility.py — keep in sync if the bundle ID ever changes.
_KLO_BUNDLE_ID = "com.klo.KLO"


def _klo_running_application(content):
    """Return the SCRunningApplication for klo's Swift app if it's
    currently visible to ScreenCaptureKit, else None. Match by bundle
    ID for precision — application name can be localized.
    """
    for running in content.applications():
        try:
            bid = str(running.bundleIdentifier())
        except Exception:
            continue
        if bid == _KLO_BUNDLE_ID:
            return running
    return None


def _frontmost_app_pid(AppKit) -> int | None:
    try:
        ws = AppKit.NSWorkspace.sharedWorkspace()
        fm = ws.frontmostApplication()
        if fm is None:
            return None
        return int(fm.processIdentifier())
    except Exception:
        return None


def _get_shareable_content(ScreenCaptureKit):
    event = threading.Event()
    box: dict[str, object] = {}

    def completion(content, error):
        box["content"] = content
        box["error"] = error
        event.set()

    ScreenCaptureKit.SCShareableContent.getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler_(
        False, True, completion
    )
    event.wait(timeout=10)

    if box.get("error"):
        raise ScreenCaptureError(str(box["error"]))
    if "content" not in box:
        raise ScreenCaptureError("Timed out waiting for ScreenCaptureKit content.")
    return box["content"]


def _capture_image(ScreenCaptureKit, filter_, config):
    event = threading.Event()
    box: dict[str, object] = {}

    def completion(image, error):
        box["image"] = image
        box["error"] = error
        event.set()

    ScreenCaptureKit.SCScreenshotManager.captureImageWithFilter_configuration_completionHandler_(
        filter_, config, completion
    )
    event.wait(timeout=10)

    if box.get("error"):
        raise ScreenCaptureError(str(box["error"]))
    if "image" not in box:
        raise ScreenCaptureError("Timed out waiting for ScreenCaptureKit image.")
    return box["image"]


def _main_logical_size(AppKit) -> tuple[float, float]:
    screen = AppKit.NSScreen.mainScreen()
    frame = screen.frame()
    return float(frame.size.width), float(frame.size.height)


def cursor_position() -> tuple[int, int]:
    try:
        import AppKit
    except ImportError as exc:
        raise ScreenCaptureError("AppKit is required for cursor position.") from exc

    logical_width, logical_height = _main_logical_size(AppKit)
    point = AppKit.NSEvent.mouseLocation()
    x = max(0, min(logical_width - 1, float(point.x)))
    y = max(0, min(logical_height - 1, logical_height - float(point.y)))
    return round(x), round(y)


def _draw_cursor_crosshair(cg_image, geometry: ScreenGeometry, AppKit, Quartz):
    cursor_x, cursor_y = geometry.image_to_logical(*_logical_to_image(cursor_position(), geometry))
    image_x, image_y = _logical_to_image((cursor_x, cursor_y), geometry)
    image_width = geometry.image_width_px
    image_height = geometry.image_height_px
    color_space = Quartz.CGColorSpaceCreateDeviceRGB()
    context = Quartz.CGBitmapContextCreate(
        None,
        image_width,
        image_height,
        8,
        image_width * 4,
        color_space,
        Quartz.kCGImageAlphaPremultipliedLast,
    )
    Quartz.CGContextDrawImage(
        context,
        Quartz.CGRectMake(0, 0, image_width, image_height),
        cg_image,
    )
    Quartz.CGContextSetRGBStrokeColor(context, 1.0, 0.0, 0.0, 1.0)
    Quartz.CGContextSetLineWidth(context, 3.0)
    size = 22
    Quartz.CGContextMoveToPoint(context, max(0, image_x - size), image_y)
    Quartz.CGContextAddLineToPoint(context, min(image_width - 1, image_x + size), image_y)
    Quartz.CGContextMoveToPoint(context, image_x, max(0, image_y - size))
    Quartz.CGContextAddLineToPoint(context, image_x, min(image_height - 1, image_y + size))
    Quartz.CGContextStrokePath(context)
    return Quartz.CGBitmapContextCreateImage(context)


def _logical_to_image(point: tuple[int, int], geometry: ScreenGeometry) -> tuple[int, int]:
    x, y = point
    image_x = round(x * geometry.image_width_px / geometry.logical_width_px)
    image_y = round(y * geometry.image_height_px / geometry.logical_height_px)
    return image_x, image_y


def _is_mostly_black(cg_image, Quartz) -> bool:
    width = int(Quartz.CGImageGetWidth(cg_image))
    height = int(Quartz.CGImageGetHeight(cg_image))
    sample_width = min(width, 80)
    sample_height = min(height, 80)
    color_space = Quartz.CGColorSpaceCreateDeviceRGB()
    bytes_per_pixel = 4
    buffer = bytearray(sample_width * sample_height * bytes_per_pixel)
    context = Quartz.CGBitmapContextCreate(
        buffer,
        sample_width,
        sample_height,
        8,
        sample_width * bytes_per_pixel,
        color_space,
        Quartz.kCGImageAlphaPremultipliedLast,
    )
    Quartz.CGContextDrawImage(
        context,
        Quartz.CGRectMake(0, 0, sample_width, sample_height),
        cg_image,
    )

    blackish = 0
    pixels = sample_width * sample_height
    for idx in range(0, len(buffer), bytes_per_pixel):
        r, g, b = buffer[idx], buffer[idx + 1], buffer[idx + 2]
        if r < 8 and g < 8 and b < 8:
            blackish += 1
    return blackish / pixels > 0.99
