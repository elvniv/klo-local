"""Catch the stale-PyInstaller-bundle trap before it ships.

Failure mode this guards against: someone edits agent2/*.py, runs
xcodebuild without first running bin/build-klo-sidecar, and the .app
ships the OLD bundled binary while the source tree shows the new code.
We'd silently believe the fix is live when it isn't.

Mirrors the freshness check in the Xcode "Copy Sidecar Bundle" build
phase (desktop-mac/KLO.xcodeproj/project.pbxproj). Having the same
check in pytest means CI catches it even before xcodebuild runs, and
local devs can `pytest tests/test_sidecar_freshness.py` to verify
without a full Xcode build.

Skips if the bundle isn't built yet (CI runs source-only most of the
time; the bundle is only present after a local `bin/build-klo-sidecar`).
"""
from __future__ import annotations

import pathlib

import pytest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "desktop-mac/sidecar-build/klo-sidecar/klo-sidecar"
AGENT2 = ROOT / "agent2"


@pytest.mark.skipif(not BUNDLE.exists(), reason="sidecar bundle not built yet")
def test_sidecar_bundle_newer_than_sources():
    bundle_mtime = BUNDLE.stat().st_mtime
    stale = [
        str(src.relative_to(ROOT))
        for src in AGENT2.rglob("*.py")
        if src.stat().st_mtime > bundle_mtime
    ]
    assert not stale, (
        "agent2 sources are newer than the bundled sidecar — "
        "run bin/build-klo-sidecar before shipping. Newer sources:\n  "
        + "\n  ".join(stale[:8])
    )
