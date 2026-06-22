from __future__ import annotations

import json
import uuid
from collections import OrderedDict
from typing import Any

from api.core.screenshot import screenshot
from api.core.redact import redact_text


# Actions that count as "this element is actually targetable." Mirrors the
# extension's filter for PAGE INTERACTIVES — keep this list narrow so the
# actionable_index doesn't drown the model in passive containers.
_ACTIONABLE_ACTIONS = frozenset({
    # The Cocoa standard set we actually want to fire. Verified against
    # Chromium's internalAccessibilityActionNames (browser_accessibility
    # _cocoa.mm) which emits exactly: AXShowMenu, AXScrollToVisible,
    # AXPress (clickable), AXCancel (menus), AXIncrement/AXDecrement
    # (sliders/spinbuttons). Native Cocoa adds AXConfirm/AXPick/AXRaise
    # and a few others — see Apple's NSAccessibilityActionName docs.
    #
    # Excluded on purpose:
    #   - AXScrollToVisible: Chromium puts it on EVERY element. If we
    #     treated it as actionable the filter would let everything
    #     through and the index would be useless.
    #   - AXDelete: destructive. If exposed by a row/file element the
    #     model could fire it from the generic actionable list without
    #     a confirm. Wire it through confirm_action explicitly if needed.
    #   - AXOpen: not emitted by Chromium's mac AX path (initial guess
    #     was wrong). Native Finder-style "open" maps through AXPress.
    "AXPress",
    "AXShowMenu",
    "AXCancel",     # dismiss menus/popups (Chromium emits for menu-related elements)
    "AXConfirm",    # confirm dialog/selection (Cocoa standard)
    "AXPick",       # selection-based elements (Cocoa standard)
    "AXRaise",      # raise window to foreground (Cocoa standard)
    "AXIncrement",
    "AXDecrement",
    "AXShowAlternateUI",  # hover-reveal hidden controls (Finder dimmed buttons, etc.)
})
# Roles where a settable AXValue means "this is a text input the model can fill."
_TEXTY_ROLES = frozenset({
    "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
})

# Chromium-family browsers expose a near-empty AX tree by default for
# performance reasons — they only populate the full rendered-DOM AX
# tree when assistive technology is detected. The detection signal is
# the `AXManualAccessibility` attribute on the application element;
# setting it to true makes Chromium populate the tree within ~1s.
# We auto-flip this in actionable_index so klo can drive ANY browser's
# web content without requiring the Chrome extension OR Safari.
# Verified live on a Chromium-family browser: 25 → 11,213 nodes / 11,190 actionable
# / 2,089 links after the flip on a Wikipedia article.
_KLO_BUNDLE_ID = "com.klo.KLO"

# Bundle IDs that briefly own frontmost during sleep / lock / fast-user
# switch but are never valid AX walk targets. Kept in sync with
# agent2/active_apps._SKIP_BUNDLE_IDS so the tracker and the live
# fallback agree.
_SKIP_BUNDLE_IDS = frozenset({
    _KLO_BUNDLE_ID,
    "com.apple.loginwindow",
})

# Per-pid cache of "we've already toggled AXManualAccessibility on
# this process" — skip the populate-wait on subsequent walks. The
# attribute is set UNCONDITIONALLY on every AX target (Chromium,
# Electron, native Cocoa, anything): the AX system silently ignores
# it on apps that don't support it, and the apps that DO support it
# populate their full DOM into the AX tree. Cleared on sidecar
# restart, which is fine — Chromium's flag also resets on its own
# restart.
_ax_enriched_pids: set[int] = set()


ACCESSIBILITY_TOOL = {
    "name": "accessibility",
    "description": (
        "macOS Accessibility surface. Read OR act on the focused app via AX. "
        "Read actions (focused_snapshot, visible_text, screen_text, "
        "screen_text_locations) inspect UI; use them as evidence sources. "
        "Write actions (press, fill, focus, confirm, menu_select) drive the UI "
        "deterministically by index — preferred over computer/left_click and "
        "computer/type because they target by element identity, not screen "
        "coordinates. Workflow: call actionable_index → pick an idx from items "
        "→ press/fill/focus/confirm with the returned snapshot_id+idx. For app "
        "menus, call menu_select with the title path (e.g. [\"File\",\"Save\"])."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": [
                    "focused_snapshot",
                    "visible_text",
                    "screen_text",
                    "screen_text_locations",
                    "actionable_index",
                    "press",
                    "fill",
                    "focus",
                    "confirm",
                    "menu_select",
                ],
            },
            "max_depth": {
                "type": "integer",
                "minimum": 1,
                "maximum": 8,
                "default": 4,
            },
            "max_nodes": {
                "type": "integer",
                "minimum": 20,
                "maximum": 600,
                "default": 180,
            },
            "snapshot_id": {
                "type": "string",
                "description": "Identifier returned by actionable_index. Required for press/fill/focus/confirm.",
            },
            "idx": {
                "type": "integer",
                "minimum": 0,
                "description": "Element index from the actionable_index snapshot. Required for press/fill/focus/confirm.",
            },
            "text": {
                "type": "string",
                "description": "Text to write into the field. Required for fill.",
            },
            "path": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Menu title path, e.g. [\"File\",\"Open\"]. Required for menu_select.",
            },
            "target_app": {
                "type": "string",
                "description": (
                    "Optional. App name (localized) or bundle ID to drive. "
                    "Set this if you want to be deterministic about which app "
                    "the walker targets — e.g. you just opened the user's "
                    "default browser via `shell open -a <name>` and want to "
                    "immediately interact with it. If omitted, klo auto-"
                    "resolves the user's most-recently-active non-klo app via "
                    "the NSWorkspace activation tracker. Used by "
                    "actionable_index, menu_select, focused_snapshot."
                ),
            },
        },
        "required": ["action"],
        "additionalProperties": False,
    },
}


# ─── Handle cache ────────────────────────────────────────────────────────────
# Process-memory map: snapshot_id -> {idx -> AXUIElementRef}. LRU bounded so a
# long-running sidecar doesn't hold AX refs forever. Each actionable_index call
# allocates a new snapshot_id; the model passes that back on press/fill/etc.
# Sidecar restart wipes the cache — model has to call actionable_index again,
# which is the correct behavior.

_HANDLE_CACHE_MAX = 4
_handle_cache: "OrderedDict[str, dict[int, Any]]" = OrderedDict()


def _store_handles(snapshot_id: str, handles: dict[int, Any]) -> None:
    _handle_cache[snapshot_id] = handles
    while len(_handle_cache) > _HANDLE_CACHE_MAX:
        _handle_cache.popitem(last=False)


def _lookup_handle(snapshot_id: str, idx: int) -> Any | None:
    bucket = _handle_cache.get(snapshot_id)
    if bucket is None:
        return None
    # Touch for LRU.
    _handle_cache.move_to_end(snapshot_id)
    return bucket.get(idx)


# ─── Executor ────────────────────────────────────────────────────────────────


class AccessibilityExecutor:
    async def execute(self, tool_input: dict[str, Any]) -> str:
        action = tool_input.get("action")
        max_depth = int(tool_input.get("max_depth", 4))
        max_nodes = int(tool_input.get("max_nodes", 180))
        target_app = tool_input.get("target_app")
        if isinstance(target_app, str):
            target_app = target_app.strip() or None
        else:
            target_app = None

        # Read paths (unchanged behavior — these are evidence sources).
        if action == "focused_snapshot":
            return json.dumps(focused_snapshot(max_depth=max_depth, max_nodes=max_nodes, target_app=target_app), ensure_ascii=False)
        if action == "visible_text":
            snap = focused_snapshot(max_depth=max_depth, max_nodes=max_nodes, target_app=target_app)
            return redact_text("\n".join(extract_text_lines(snap)))
        if action == "screen_text":
            return await screen_text()
        if action == "screen_text_locations":
            return await screen_text_locations()

        # Write paths.
        if action == "actionable_index":
            return json.dumps(actionable_index(max_depth=max_depth, max_nodes=max_nodes, target_app=target_app), ensure_ascii=False)
        if action == "press":
            return json.dumps(_perform_axaction(tool_input, "AXPress"), ensure_ascii=False)
        if action == "confirm":
            return json.dumps(_perform_axaction(tool_input, "AXConfirm"), ensure_ascii=False)
        if action == "focus":
            return json.dumps(_set_focused(tool_input), ensure_ascii=False)
        if action == "fill":
            return json.dumps(_fill(tool_input), ensure_ascii=False)
        if action == "menu_select":
            return json.dumps(_menu_select(tool_input), ensure_ascii=False)

        raise ValueError(f"Unsupported accessibility action: {action!r}")


async def screen_text() -> str:
    shot = await screenshot()
    return redact_text("\n".join(item["text"] for item in recognize_text_items(shot.png, shot.geometry)))


async def screen_text_locations() -> str:
    shot = await screenshot()
    items = recognize_text_items(shot.png, shot.geometry)
    return redact_text(json.dumps(items[:120], ensure_ascii=False))


def recognize_text(png: bytes) -> str:
    return "\n".join(item["text"] for item in recognize_text_items(png))


def recognize_text_items(png: bytes, geometry=None) -> list[dict[str, Any]]:
    try:
        import Foundation
        import Vision
    except Exception as exc:
        return [{"text": f"Vision OCR unavailable: {exc}"}]

    data = Foundation.NSData.dataWithBytes_length_(png, len(png))
    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(True)
    handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(data, {})
    ok, error = handler.performRequests_error_([request], None)
    if not ok:
        return [{"text": f"Vision OCR failed: {error}"}]

    items = []
    for observation in request.results() or []:
        candidates = observation.topCandidates_(1)
        if candidates:
            item = {"text": str(candidates[0].string())}
            if geometry is not None:
                item.update(_ocr_center(observation.boundingBox(), geometry))
            items.append(item)
    return items


def _ocr_center(box, geometry) -> dict[str, int]:
    center_x = (box.origin.x + box.size.width / 2) * geometry.logical_width_px
    # Vision coordinates are normalized with origin at bottom-left.
    center_y = (1 - box.origin.y - box.size.height / 2) * geometry.logical_height_px
    return {"x": round(center_x), "y": round(center_y)}


def extract_text_lines(snapshot: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    seen: set[str] = set()

    def visit(node: dict[str, Any]) -> None:
        for key in ("title", "value", "description", "placeholder"):
            value = node.get(key)
            if value and value not in seen:
                seen.add(value)
                lines.append(value)
        for child in node.get("children", []):
            if isinstance(child, dict):
                visit(child)

    tree = snapshot.get("tree")
    if isinstance(tree, dict):
        visit(tree)
    return lines[:300]


# ─── Snapshot (read) ─────────────────────────────────────────────────────────


def focused_snapshot(max_depth: int = 4, max_nodes: int = 180, target_app: str | None = None) -> dict[str, Any]:
    AS = _load_AS()
    if AS is None:
        return {"error": "ApplicationServices unavailable"}
    tcc = _check_ax_trusted(AS)
    if tcc is not None:
        return tcc
    AppKit = _load_AppKit()

    # Use the same skip-klo + target-resolution as actionable_index.
    app, _bid, _pid = _resolve_target_app(AS, AppKit, target_hint=target_app)
    if app is None:
        return {"error": "No non-klo app available to walk."}
    window = _copy_attr(AS, app, "AXFocusedWindow")
    if window is None:
        window = (_copy_attr(AS, app, "AXWindows") or [None])[0]
    root = window or app

    counter = {"count": 0}
    return {
        "focused_app": _node_summary(AS, app) if app is not None else None,
        "focused_window": _node_summary(AS, window) if window is not None else None,
        "tree": _walk(AS, root, max_depth=max_depth, max_nodes=max_nodes, counter=counter),
        "truncated": counter["count"] >= max_nodes,
    }


def _frontmost_app_element(AS, AppKit):
    try:
        app = AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
        if app is None:
            return None
        return AS.AXUIElementCreateApplication(app.processIdentifier())
    except Exception:
        return None


def _frontmost_app_info(AppKit) -> tuple[str | None, int | None]:
    """Returns (bundle_id, pid) of the currently frontmost app.
    Used to detect Chromium-family browsers for AXManualAccessibility."""
    try:
        app = AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
        if app is None:
            return (None, None)
        return (
            str(app.bundleIdentifier() or "") or None,
            int(app.processIdentifier()),
        )
    except Exception:
        return (None, None)


def _recently_launched_non_klo(AppKit, within_seconds: float = 15.0) -> tuple[str | None, int | None]:
    """Scan NSWorkspace.runningApplications() for the most recently
    launched regular-policy non-klo app within the last `within_seconds`.

    Why: when the model does `shell open -a Dia` and immediately calls
    accessibility.actionable_index, two failure modes converge:
      - ActiveAppTracker (500ms poll) hasn't recorded Dia's brief
        foreground flash before klo's panel re-grabbed focus.
      - NSWorkspace.frontmostApplication() returns klo (panel is up).
    Both paths return None and the AX call errors with "No non-klo app
    available to walk." But Dia is RIGHT THERE in runningApplications()
    with a fresh launchDate — that's the signal we need.

    Returns (bundle_id, pid) of the freshest launch, or (None, None)
    if no regular-policy non-klo app launched within the window.
    """
    try:
        import time as _time
        from Foundation import NSDate  # noqa: F401 — fail fast if Foundation missing
    except Exception:
        return (None, None)
    ws = AppKit.NSWorkspace.sharedWorkspace()
    now = _time.time()
    best_pid: int | None = None
    best_bid: str | None = None
    best_age = within_seconds
    for app in ws.runningApplications():
        try:
            if app.activationPolicy() != 0:
                continue
            bid = str(app.bundleIdentifier() or "")
            if not bid or bid in _SKIP_BUNDLE_IDS:
                continue
            ld = app.launchDate()
            if ld is None:
                continue
            # NSDate → unix epoch via timeIntervalSince1970.
            launched_at = float(ld.timeIntervalSince1970())
            age = now - launched_at
            if 0 <= age < best_age:
                best_age = age
                best_pid = int(app.processIdentifier())
                best_bid = bid
        except Exception:
            continue
    return (best_bid, best_pid)


def _resolve_target_app(AS, AppKit, target_hint: str | None = None) -> tuple[Any, str | None, int | None]:
    """Pick the app klo should walk in actionable_index/menu_select.

    Resolution order:
      0. `target_hint` from the tool call (model's explicit override) →
         match against running apps by bundle ID OR localized name,
         activate, return. Escape hatch for the rare case where the
         model knows better than our tracker.
      1. ActiveAppTracker.most_recent_non_klo() → return the user's
         most recently active non-klo app. This is the common path;
         the tracker (agent2/active_apps.py) maintains an authoritative
         history of NSWorkspace activations, so we don't need to guess.
      2. NSWorkspace.frontmostApplication() if it's not klo and the
         tracker isn't ready yet (sidecar boot race).
      3. Recently launched (<15s) non-klo app — catches the
         `shell open -a X` → immediate AX-call race when klo's panel
         re-grabs focus before the tracker poll sees X foreground.
      4. Brief retry loop (~1.2s) over steps 1-3 before giving up.
      5. None → caller falls back / surfaces error.

    Returns (app_element, bundle_id, pid).

    No bundle ID lists, no Chromium-vs-Safari branches. The walker
    after this point enriches every target with AXManualAccessibility
    regardless of which app it is.
    """
    import time as _time

    ws = AppKit.NSWorkspace.sharedWorkspace()

    # Step 0: explicit target from the tool call.
    if target_hint and target_hint.strip():
        hint = target_hint.strip()
        hint_lower = hint.lower()
        for app in ws.runningApplications():
            if app.activationPolicy() != 0:
                continue
            bid = str(app.bundleIdentifier() or "")
            name = str(app.localizedName() or "")
            if (bid == hint
                or bid.lower() == hint_lower
                or name == hint
                or name.lower() == hint_lower):
                pid = int(app.processIdentifier())
                ax_app = AS.AXUIElementCreateApplication(pid)
                try:
                    app.activateWithOptions_(2)
                    _time.sleep(0.35)
                except Exception:
                    pass
                return (ax_app, bid or None, pid)
        # target_hint set but no match — fall through to tracker.

    def _one_shot() -> tuple[Any, str | None, int | None] | None:
        # Step 1: tracker-based resolution.
        try:
            from agent2.active_apps import tracker as _tracker  # type: ignore
            rec = _tracker().most_recent_non_klo()
            if rec is not None:
                ax_app = AS.AXUIElementCreateApplication(rec.pid)
                return (ax_app, rec.bundle_id or None, rec.pid)
        except Exception:
            pass

        # Step 2: live frontmost (skip klo / loginwindow).
        front = ws.frontmostApplication()
        front_bid = str(front.bundleIdentifier() or "") if front is not None else ""
        if front is not None and front_bid not in _SKIP_BUNDLE_IDS:
            pid = int(front.processIdentifier())
            return (AS.AXUIElementCreateApplication(pid), front_bid or None, pid)

        # Step 3: recently launched non-klo app.
        bid, pid = _recently_launched_non_klo(AppKit)
        if pid is not None:
            return (AS.AXUIElementCreateApplication(pid), bid, pid)

        return None

    # First attempt, no wait.
    result = _one_shot()
    if result is not None:
        return result

    # Step 4: brief retry — gives the tracker time to record an app
    # that just launched. Polls 8x150ms = 1.2s total budget.
    for _ in range(8):
        _time.sleep(0.15)
        result = _one_shot()
        if result is not None:
            return result

    return (None, None, None)


def _enrich_ax(AS, app_el, pid: int | None) -> bool:
    """Unconditionally set AXManualAccessibility on the target app.

    Chromium/Electron apps respond by populating their full rendered-
    DOM AX tree (which they otherwise gate on assistive-tech detection
    for performance). Native Cocoa apps get
    err=-25204 kAXErrorAttributeUnsupported and ignore the call — no
    side effect.

    Capability-based: we don't ask "is this a browser?" or check
    bundle IDs. We just set the attribute. The apps that need it
    respond, others don't. Vimac uses this exact pattern in
    production.

    Per-pid cache to skip the populate-wait on subsequent walks
    against the same process this sidecar session.

    Returns True if the target accepted the attribute (i.e. it is a
    Chromium/Electron app exposing the rendered DOM as AX), False
    otherwise. Callers (actionable_index) use this to bump the
    max_nodes default — a real web page typically has 300-600+
    actionable elements, well past the 180 cap that's safe for
    native apps.
    """
    if app_el is None or pid is None:
        return False
    if pid in _ax_enriched_pids:
        # Previously confirmed Chromium-like; signal "yes, web target."
        return True
    err = AS.AXUIElementSetAttributeValue(app_el, "AXManualAccessibility", True)
    if err == 0:
        _ax_enriched_pids.add(pid)
        # Brief wait — Chromium/Electron need ~500ms-1s to populate
        # the AX tree after the flip. Native apps that ignored the
        # call don't need any wait. We pay the wait once per process.
        import time as _time
        _time.sleep(0.6)
        return True
    # err != 0 (typically -25204) → app doesn't support attribute;
    # nothing more to do. Don't cache so we'd retry if the app
    # restarts with new capabilities, but in practice we don't bother.
    return False


def _walk(AS, element, max_depth: int, max_nodes: int, counter: dict[str, int]) -> dict[str, Any]:
    counter["count"] += 1
    node = _node_summary(AS, element)
    if max_depth <= 0 or counter["count"] >= max_nodes:
        return node

    children = _copy_attr(AS, element, "AXChildren") or []
    if not isinstance(children, (list, tuple)):
        return node

    walked = []
    for child in children:
        if counter["count"] >= max_nodes:
            break
        child_node = _walk(AS, child, max_depth - 1, max_nodes, counter)
        if _has_signal(child_node):
            walked.append(child_node)

    if walked:
        node["children"] = walked
    return node


def _node_summary(AS, element) -> dict[str, Any]:
    """Pull the cheap, name-y attributes we always want on a node summary.

    Includes the label-flatten step: if a node has no direct title/desc/
    placeholder, look up to two levels into AXChildren for AXStaticText.
    value/title and use that as the node's effective label. This is how
    SwiftUI exposes row labels (cell → static text) and is the moral
    equivalent of the extension's `<button><span>X</span></button>` flatten.
    Two levels (vs the one we had before) is what catches Chromium's
    `AXButton > AXGroup > AXStaticText "Filmmaking"` pattern that YouTube
    and similar dense React apps emit.
    """
    summary: dict[str, Any] = {}
    for key, name in [
        ("AXRole", "role"),
        ("AXSubrole", "sub"),
        ("AXTitle", "title"),
        ("AXValue", "value"),
        ("AXDescription", "description"),
        ("AXPlaceholderValue", "placeholder"),
        ("AXIdentifier", "identifier"),
        # AXHelp surfaces tooltip text. Chromium maps aria-describedby into
        # this on some elements when the primary label isn't already filled.
        ("AXHelp", "help"),
        # AXRoleDescription is the user-facing role label ("tab", "chip",
        # "button"). Not a target name, but lets the model differentiate
        # an unlabeled AXButton from an unlabeled AXTab without guessing.
        ("AXRoleDescription", "role_description"),
    ]:
        value = _copy_attr(AS, element, key)
        if value not in (None, ""):
            summary[name] = str(value)[:500]

    # Label-flatten: SwiftUI / AppKit nest the visible label inside a child
    # AXStaticText. If nothing labeling came back directly, peek through.
    if not any(k in summary for k in ("title", "description", "placeholder", "help")):
        flat = _flatten_label(AS, element)
        if flat:
            summary["label"] = flat[:500]

    return summary


# Structural-only roles that exist to group layout without contributing a name
# of their own. When _flatten_label sees one of these as an immediate child
# with no extractable label, it descends ONE more level looking for the real
# AXStaticText leaf. Catches Chromium's `AXButton > AXGroup > AXStaticText`
# nesting on YouTube chips, Twitter buttons, etc.
_STRUCTURAL_WRAPPER_ROLES = frozenset({
    "AXGroup",
    "AXGenericElement",
    "AXLayoutArea",
    "AXLayoutItem",
    "AXSplitGroup",
    "AXUnknown",
})


def _flatten_label(AS, element) -> str | None:
    """Concatenate descendant AXStaticText title/value as a fallback label.

    Walks up to TWO levels deep: immediate children first, then through any
    structural-only wrapper child (AXGroup, AXGenericElement, ...) for one
    additional level. Going deeper than 2 produces noise from layout
    containers; stopping at 2 is the sweet spot that catches Chromium's
    `AXButton > AXGroup > AXStaticText` while still ignoring sprawling
    layout trees. Empty strings dropped; results space-joined.
    """
    children = _copy_attr(AS, element, "AXChildren") or []
    if not isinstance(children, (list, tuple)):
        return None
    parts: list[str] = []
    for child in children:
        role = _copy_attr(AS, child, "AXRole")
        # AXCell wraps the static text one extra level in NSTableView-style UI.
        if role == "AXCell":
            for gc in (_copy_attr(AS, child, "AXChildren") or []):
                t = _copy_attr(AS, gc, "AXTitle") or _copy_attr(AS, gc, "AXValue")
                if t:
                    parts.append(str(t))
        elif role in ("AXStaticText", "AXImage"):
            t = _copy_attr(AS, child, "AXTitle") or _copy_attr(AS, child, "AXValue") or _copy_attr(AS, child, "AXDescription")
            if t:
                parts.append(str(t))
        elif role in _STRUCTURAL_WRAPPER_ROLES:
            # Layout wrapper — descend one extra level. Read AXTitle on the
            # wrapper itself first (sometimes set even when it's "structural")
            # then walk its immediate children for AXStaticText leaves.
            wrapper_label = (
                _copy_attr(AS, child, "AXTitle")
                or _copy_attr(AS, child, "AXDescription")
            )
            if wrapper_label:
                parts.append(str(wrapper_label))
                continue
            for gc in (_copy_attr(AS, child, "AXChildren") or []):
                gc_role = _copy_attr(AS, gc, "AXRole")
                if gc_role in ("AXStaticText", "AXImage"):
                    t = (
                        _copy_attr(AS, gc, "AXTitle")
                        or _copy_attr(AS, gc, "AXValue")
                        or _copy_attr(AS, gc, "AXDescription")
                    )
                    if t:
                        parts.append(str(t))
                        # First label found in this wrapper is enough; don't
                        # concatenate every leaf, that ends up reading whole
                        # paragraphs of body text.
                        break
    text = " ".join(p for p in parts if p).strip()
    return text or None


def _copy_attr(AS, element, attr: str):
    try:
        err, value = AS.AXUIElementCopyAttributeValue(element, attr, None)
        if err == 0:
            return value
    except Exception:
        return None
    return None


def _action_names(AS, element) -> list[str]:
    try:
        err, names = AS.AXUIElementCopyActionNames(element, None)
        if err == 0 and names:
            return list(names)
    except Exception:
        pass
    return []


def _is_settable(AS, element, attr: str) -> bool:
    try:
        err, b = AS.AXUIElementIsAttributeSettable(element, attr, None)
        return bool(b) if err == 0 else False
    except Exception:
        return False


def _bounds(AS, element) -> dict[str, float] | None:
    """Return {x,y,w,h} if AXPosition+AXSize are available, else None.

    AX returns these as boxed AXValueRefs wrapping CGPoint/CGSize. PyObjC
    sometimes auto-unboxes; when it doesn't, we parse the repr (which is stable
    and includes the values literally). Repr is the load-bearing fallback —
    the docs-blessed unbox path (AXValueGetValue) is awkward across pyobjc
    versions, but every version we've seen produces a stable repr.
    """
    pos = _copy_attr(AS, element, "AXPosition")
    size = _copy_attr(AS, element, "AXSize")
    if pos is None or size is None:
        return None
    px, py = _parse_axvalue_pair(pos, ("x", "y"))
    sw, sh = _parse_axvalue_pair(size, ("w", "h"))
    if px is None or sw is None:
        return None
    return {"x": round(px, 1), "y": round(py, 1), "w": round(sw, 1), "h": round(sh, 1)}


def _parse_axvalue_pair(value: Any, keys: tuple[str, str]) -> tuple[float | None, float | None]:
    """Extract two floats labeled by `keys` from an AXValue repr.

    Example repr: '<AXValue ... {value = x:52.000000 y:131.000000 type = ...}>'
    """
    try:
        s = str(value)
    except Exception:
        return None, None
    out = []
    for key in keys:
        token = f"{key}:"
        i = s.find(token)
        if i == -1:
            return None, None
        j = i + len(token)
        # Read a float (may be negative).
        end = j
        while end < len(s) and (s[end].isdigit() or s[end] in ".-"):
            end += 1
        try:
            out.append(float(s[j:end]))
        except ValueError:
            return None, None
    return out[0], out[1]


def _has_signal(node: dict[str, Any]) -> bool:
    if any(key in node for key in ("title", "value", "description", "placeholder", "label")):
        return True
    return bool(node.get("children"))


# ─── Actionable index (write surface) ────────────────────────────────────────


def _check_ax_trusted(AS) -> dict[str, Any] | None:
    """Return a TCC-style error dict if the process doesn't have AX
    trust, otherwise None. The error text contains keywords the
    AgentClient's `detectPermissionDenial` matches against so the
    failure surfaces as the in-notch permission island, not as a
    cryptic "no app available" message."""
    try:
        if not AS.AXIsProcessTrusted():
            return {
                "error": (
                    "Accessibility permission denied for this process "
                    "(AXIsProcessTrusted returned false). klo can't read "
                    "or drive app UIs until Accessibility is granted in "
                    "System Settings → Privacy & Security → Accessibility."
                )
            }
    except Exception:
        pass
    return None


def actionable_index(max_depth: int = 6, max_nodes: int = 180, target_app: str | None = None) -> dict[str, Any]:
    """Flat, indexed list of actionable elements in the focused app + its menu.

    Each item is one of:
      - has an AXAction in _ACTIONABLE_ACTIONS, OR
      - is a text-y role whose AXValue is settable (model can fill it)

    The model's normal pattern is:
      1. accessibility/actionable_index
      2. look at items[i].label/role/actions, pick one
      3. accessibility/press (or fill / focus / confirm) with snapshot_id+idx

    For app menus, the model uses accessibility/menu_select with a path of
    titles instead — no snapshot needed, since menu items are addressable by
    name and stable across windows.
    """
    AS = _load_AS()
    if AS is None:
        return {"error": "ApplicationServices unavailable"}
    tcc = _check_ax_trusted(AS)
    if tcc is not None:
        return tcc
    AppKit = _load_AppKit()

    # Resolve which app to walk. If target_app was passed via the tool,
    # match against it deterministically; otherwise skip klo and pick
    # the most-recently-active non-klo regular app (Chromium preferred).
    app_el, target_bid, target_pid = _resolve_target_app(AS, AppKit, target_hint=target_app)
    if app_el is None:
        return {"error": "No non-klo app available to walk."}

    # Unconditional AX enrichment — set AXManualAccessibility on the
    # resolved target. Chromium/Electron apps populate their full DOM;
    # native apps silently ignore. No bundle ID list. Cached per pid
    # so repeat calls skip the populate-wait. See _enrich_ax comment.
    is_web_target = _enrich_ax(AS, app_el, target_pid)

    # Web pages routinely have 300-600+ actionable elements. The 180
    # default cap is right for native apps (where 180 already covers
    # every menu+button) but truncates real pages like Gmail or
    # Linear, leaving the model unable to see the element it needs.
    # If the caller didn't override max_nodes (still at default 180)
    # AND the target is a Chromium-like web surface, bump to 600.
    if is_web_target and max_nodes <= 180:
        max_nodes = 600
    # Same problem on depth. The executor's default is 4; the function's
    # own default is 6. Both are right for native apps (a Cocoa menu tree
    # is ~3-4 levels) but Chromium nests every interactive inside 6-10
    # AXGroup wrappers (page chrome → toolbar → nav → tab strip → tab).
    # On Gmail this is the smoking-gun reason the walker came back with
    # "only high-level groups" — depth ran out before reaching the
    # AXButton/AXTab leaves. Bump to 12 for confirmed web targets when
    # the caller didn't already raise the cap.
    if is_web_target and max_depth <= 6:
        max_depth = 12

    # Use the target app's own focused window (NOT system-wide), since
    # we may have activated a non-frontmost app and system AX might
    # still report klo's old focus.
    focused_window = _copy_attr(AS, app_el, "AXFocusedWindow")
    if focused_window is None:
        focused_window = (_copy_attr(AS, app_el, "AXWindows") or [None])[0]

    snapshot_id = uuid.uuid4().hex[:12]
    handles: dict[int, Any] = {}
    items: list[dict[str, Any]] = []

    if focused_window is not None:
        _collect_actionable(AS, focused_window, items, handles, max_depth=max_depth, max_nodes=max_nodes)

    # Adaptive re-walk for Chromium-like targets that came back skeletal.
    # `_enrich_ax`'s 600ms wait covers Chromium's "attribute accepted, tree
    # rebuild started" baseline, but heavy pages (Gmail, Linear, Notion)
    # need another 1-2s for aria-labels to project into AXDescription on
    # leaf interactives. Symptom: structural AXGroup nodes are present
    # but >60% of collected items have label="?". One retry with a longer
    # wait is enough; if it's still skeletal after that, the page genuinely
    # has unlabeled controls and vision is the right fallback.
    label_coverage: float | None = None
    if is_web_target and items:
        labeled = sum(1 for it in items if it.get("label") and it["label"] != "?")
        coverage = labeled / len(items)
        if coverage < 0.4 and focused_window is not None:
            import time as _time
            _time.sleep(1.5)
            items.clear()
            handles.clear()
            _collect_actionable(AS, focused_window, items, handles, max_depth=max_depth, max_nodes=max_nodes)
            labeled = sum(1 for it in items if it.get("label") and it["label"] != "?")
            coverage = (labeled / len(items)) if items else 0.0
        label_coverage = round(coverage, 2)

    menu_payload = _menu_snapshot(AS, app_el)
    _store_handles(snapshot_id, handles)

    response: dict[str, Any] = {
        "snapshot_id": snapshot_id,
        "app": str(_copy_attr(AS, app_el, "AXTitle") or ""),
        "window": str(_copy_attr(AS, focused_window, "AXTitle") or "") if focused_window is not None else None,
        "items": items,
        "menu": menu_payload,
        "note": None if focused_window is not None else "no focused window — menu_select only",
    }
    if label_coverage is not None:
        response["label_coverage"] = label_coverage
    return response


def _collect_actionable(
    AS,
    element,
    out_items: list[dict[str, Any]],
    out_handles: dict[int, Any],
    *,
    max_depth: int,
    max_nodes: int,
    _depth: int = 0,
) -> None:
    if len(out_items) >= max_nodes or _depth > max_depth:
        return

    actions = _action_names(AS, element)
    role = _copy_attr(AS, element, "AXRole") or ""

    is_actionable = bool(_ACTIONABLE_ACTIONS.intersection(actions))
    is_fillable = role in _TEXTY_ROLES and _is_settable(AS, element, "AXValue")
    # Skip the root window itself; we want children only.
    if (is_actionable or is_fillable) and role != "AXWindow":
        summary = _node_summary(AS, element)
        label = (
            summary.get("title")
            or summary.get("description")
            or summary.get("placeholder")
            # AXHelp (tooltip / aria-describedby) — falls between user-visible
            # label sources and structural fallbacks. Better than emitting "?".
            or summary.get("help")
            or summary.get("label")
            or (summary.get("value") if role in _TEXTY_ROLES else None)
            or summary.get("identifier")
            or "?"
        )
        idx = len(out_items)
        item: dict[str, Any] = {
            "idx": idx,
            "role": role,
            "sub": summary.get("sub"),
            "label": str(label)[:140],
            "actions": [a for a in actions if a in _ACTIONABLE_ACTIONS],
            "enabled": _copy_attr(AS, element, "AXEnabled"),
        }
        if is_fillable:
            item["fillable"] = True
        b = _bounds(AS, element)
        if b is not None:
            item["bounds"] = b
        ident = summary.get("identifier")
        if ident:
            item["identifier"] = ident
        out_items.append(item)
        out_handles[idx] = element

    for child in (_copy_attr(AS, element, "AXChildren") or []):
        if len(out_items) >= max_nodes:
            break
        _collect_actionable(AS, child, out_items, out_handles, max_depth=max_depth, max_nodes=max_nodes, _depth=_depth + 1)


def _menu_snapshot(AS, app_el) -> dict[str, list[str]]:
    """Top-level + first-level menu items: {"File": ["New", "Open…", …], …}.

    Keeps menus shallow (one level) on purpose — the model can call
    menu_select with a deeper path even though we didn't enumerate it; the
    payload is for *discovery*. Deep menus blow up token count for no gain.
    """
    menu_bar = _copy_attr(AS, app_el, "AXMenuBar")
    if menu_bar is None:
        return {}
    out: dict[str, list[str]] = {}
    for top in (_copy_attr(AS, menu_bar, "AXChildren") or []):
        top_title = _copy_attr(AS, top, "AXTitle") or ""
        if not top_title or top_title == "Apple":
            continue  # Apple menu is uniform; skip it
        items: list[str] = []
        for sub_menu in (_copy_attr(AS, top, "AXChildren") or []):
            for mi in (_copy_attr(AS, sub_menu, "AXChildren") or []):
                t = _copy_attr(AS, mi, "AXTitle") or ""
                if t:
                    items.append(str(t)[:60])
        if items:
            out[str(top_title)[:40]] = items[:30]
    return out


# ─── Write actions ───────────────────────────────────────────────────────────


def _resolve(tool_input: dict[str, Any]) -> tuple[Any | None, str | None]:
    sid = str(tool_input.get("snapshot_id") or "").strip()
    if not sid:
        return None, "snapshot_id is required — call actionable_index first"
    try:
        idx = int(tool_input.get("idx"))
    except (TypeError, ValueError):
        return None, "idx is required and must be an integer"
    elem = _lookup_handle(sid, idx)
    if elem is None:
        return None, f"no handle for snapshot_id={sid!r} idx={idx} — snapshot may be stale, call actionable_index again"
    return elem, None


def _perform_axaction(tool_input: dict[str, Any], ax_action: str) -> dict[str, Any]:
    AS = _load_AS()
    if AS is None:
        return {"ok": False, "error": "ApplicationServices unavailable"}
    elem, err_msg = _resolve(tool_input)
    if elem is None:
        return {"ok": False, "error": err_msg}
    role = _copy_attr(AS, elem, "AXRole") or ""
    title = _copy_attr(AS, elem, "AXTitle") or _copy_attr(AS, elem, "AXDescription") or ""
    err = AS.AXUIElementPerformAction(elem, ax_action)
    return {"ok": err == 0, "ax_err": int(err), "role": str(role), "label": str(title)[:140], "action": ax_action}


def _set_focused(tool_input: dict[str, Any]) -> dict[str, Any]:
    AS = _load_AS()
    if AS is None:
        return {"ok": False, "error": "ApplicationServices unavailable"}
    elem, err_msg = _resolve(tool_input)
    if elem is None:
        return {"ok": False, "error": err_msg}
    err = AS.AXUIElementSetAttributeValue(elem, "AXFocused", True)
    return {"ok": err == 0, "ax_err": int(err)}


def _fill(tool_input: dict[str, Any]) -> dict[str, Any]:
    AS = _load_AS()
    if AS is None:
        return {"ok": False, "error": "ApplicationServices unavailable"}
    elem, err_msg = _resolve(tool_input)
    if elem is None:
        return {"ok": False, "error": err_msg}
    text = str(tool_input.get("text") or "")
    # Focus first if focusable — many fields ignore AXValue writes unless they
    # already hold keyboard focus. Tolerate non-settable AXFocused silently.
    if _is_settable(AS, elem, "AXFocused"):
        AS.AXUIElementSetAttributeValue(elem, "AXFocused", True)
    if not _is_settable(AS, elem, "AXValue"):
        return {
            "ok": False,
            "error": "AXValue not settable on this element — fall back to computer/type after focusing",
            "fillable": False,
        }
    err = AS.AXUIElementSetAttributeValue(elem, "AXValue", text)
    return {"ok": err == 0, "ax_err": int(err), "written_chars": len(text)}


def _menu_select(tool_input: dict[str, Any]) -> dict[str, Any]:
    """Walk AXMenuBar → AXMenu → AXMenuItem by title path; AXPress the leaf.

    Path is a list of menu titles, e.g. ["File", "Open Recent", "klo"]. We
    walk top-level AXMenuBarItem first (children of AXMenuBar), then each item
    has a single AXMenu child whose children are AXMenuItems. AXPress on the
    final item activates or opens its submenu — caller can chain another
    menu_select for deeper paths.
    """
    AS = _load_AS()
    if AS is None:
        return {"ok": False, "error": "ApplicationServices unavailable"}
    tcc = _check_ax_trusted(AS)
    if tcc is not None:
        return {"ok": False, **tcc}
    AppKit = _load_AppKit()

    raw_path = tool_input.get("path") or []
    if not isinstance(raw_path, list) or not raw_path:
        return {"ok": False, "error": "path must be a non-empty list of titles"}
    path = [str(p).strip() for p in raw_path if str(p).strip()]
    if not path:
        return {"ok": False, "error": "path is empty after normalization"}

    # Same skip-klo resolution as actionable_index — we want to drive
    # the user's actual app's menu bar, not klo's. Honor target_app
    # hint if the model passed one (deterministic targeting after
    # `shell open -a <browser>`).
    target_hint = tool_input.get("target_app")
    if isinstance(target_hint, str):
        target_hint = target_hint.strip() or None
    else:
        target_hint = None
    app_el, _bid, _pid = _resolve_target_app(AS, AppKit, target_hint=target_hint)
    if app_el is None:
        return {"ok": False, "error": "no non-klo app to drive"}
    menu_bar = _copy_attr(AS, app_el, "AXMenuBar")
    if menu_bar is None:
        return {"ok": False, "error": "this app exposes no menu bar"}

    current = menu_bar
    matched: list[str] = []
    for i, title in enumerate(path):
        children = _copy_attr(AS, current, "AXChildren") or []
        # AXMenuBarItems sit directly under AXMenuBar; deeper levels go AXMenu → AXMenuItem.
        # If the current node is a Menu/MenuItem, its single child AXMenu holds the actual items.
        if _copy_attr(AS, current, "AXRole") in ("AXMenuBarItem", "AXMenuItem") and children:
            # Descend into the AXMenu wrapper.
            sub = next((c for c in children if _copy_attr(AS, c, "AXRole") == "AXMenu"), None)
            if sub is not None:
                children = _copy_attr(AS, sub, "AXChildren") or []

        match = None
        for c in children:
            t = _copy_attr(AS, c, "AXTitle") or ""
            if t and t == title:
                match = c
                break
        if match is None:
            # Case-insensitive fallback for forgiving prompts.
            lower = title.lower()
            for c in children:
                t = (_copy_attr(AS, c, "AXTitle") or "").lower()
                if t and t == lower:
                    match = c
                    break
        if match is None:
            return {
                "ok": False,
                "error": f"no menu item matching {title!r} at depth {i}",
                "matched_so_far": matched,
                "candidates_at_failure": [str(_copy_attr(AS, c, "AXTitle") or "") for c in children][:20],
            }
        matched.append(title)
        current = match

    # Press the final element. AXPress on a leaf activates; on a parent it
    # opens the submenu (model can chain another menu_select for deeper).
    err = AS.AXUIElementPerformAction(current, "AXPress")
    return {"ok": err == 0, "ax_err": int(err), "matched_path": matched}


# ─── Module loaders ──────────────────────────────────────────────────────────


def _load_AS():
    try:
        import ApplicationServices as AS
        return AS
    except Exception:
        return None


def _load_AppKit():
    try:
        import AppKit
        return AppKit
    except Exception:
        return None
