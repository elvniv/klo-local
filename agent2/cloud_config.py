"""Cloud-config fetcher for the desktop sidecar.

Pulls signed config from klo-cloud, verifies the Ed25519 signature
against an embedded public key, caches the result to disk, and refreshes
in the background. Sidecar code reads the current values via
`get_config()` at call time — no restart required when the cloud config
changes.

Trust + offline story:
  1. Cloud reachable + signature valid  →  apply, cache to disk
  2. Cloud unreachable, cache exists    →  use cache (last good config)
  3. Cloud unreachable, no cache        →  use bundled defaults
                                            (the constants this module
                                            shipped with at build time)

The bundled defaults intentionally MIRROR the canonical values in the
cloud's `klo_cloud/config.py`. They're a safety net for first-run
offline boots — once a cloud fetch succeeds, the cached version takes
over and the bundled defaults are never read again on that machine.

Public-key handling:
  * Dev: read from KLO_LICENSE_PUBLIC_KEY env var (which the same .env
    sets for the cloud server).
  * Prod (PyInstaller bundle): the build script embeds the PEM into a
    string literal in this module. Until then, prod can also read from
    env, just from a different secret store.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from pathlib import Path
from typing import Any

import httpx
import jwt
from dotenv import load_dotenv

# Explicit .env load so KLO_CLOUD_URL etc. are picked up regardless of
# how the sidecar is launched (uv run, direct python -m, PyInstaller
# bundle). dotenv's default find_dotenv walks the call stack and can
# miss the file when the sidecar is started from outside its repo dir.
_REPO_ENV = Path(__file__).resolve().parents[1] / ".env"
if _REPO_ENV.exists():
    load_dotenv(_REPO_ENV, override=False)


log = logging.getLogger("agent2.cloud_config")


CLOUD_URL = os.environ.get("KLO_CLOUD_URL", "http://127.0.0.1:8788").rstrip("/")
CACHE_PATH = Path(os.environ.get(
    "KLO_CLOUD_CACHE_PATH",
    str(Path.home() / ".klo" / "cloud_config.json"),
))
REFRESH_INTERVAL_SEC = float(os.environ.get("KLO_CLOUD_REFRESH_SEC", "300"))
FETCH_TIMEOUT_SEC = float(os.environ.get("KLO_CLOUD_FETCH_TIMEOUT_SEC", "5"))


# Bundled defaults — last-resort fallback when cloud is unreachable AND
# no cache exists. Mirror of `klo_cloud/config.py:DEFAULT_CONFIG`. Keep
# this in sync with that file at build time.
BUNDLED_DEFAULTS: dict[str, Any] = {
    "version": "bundled",
    "agent": {
        "model": "gpt-5.1",
        "voice_model": "gpt-5.1",
        "max_turns": 90,
    },
    "realtime": {
        "model": "gpt-realtime",
        "voice": "marin",
        # `system_prompt` left None here so the cloud-config-served
        # value takes effect when present. The Mac client falls back to
        # a hardcoded persona string if both are absent.
        "system_prompt": None,
    },
    "coalescer": {
        "complete_grace_sec": 0.8,
        "incomplete_grace_sec": 3.5,
    },
    "feature_flags": {
        "voice_disabled": False,
        "maintenance_message": None,
    },
}


# ─── singleton state ──────────────────────────────────────────────────────────
#
# The current best-known config + provenance. `_current_source` is one of
# 'bundled', 'cache', 'cloud' — useful for `/health` diagnostics.

_current: dict[str, Any] = json.loads(json.dumps(BUNDLED_DEFAULTS))  # deep copy
_current_source: str = "bundled"
_last_fetch_at: float = 0.0
_last_fetch_error: str | None = None


def get_config() -> dict[str, Any]:
    """Return the current config dict. Read by sidecar code at call time."""
    return _current


def get_config_status() -> dict[str, Any]:
    """Diagnostic snapshot of the cloud-config layer."""
    return {
        "source": _current_source,
        "version": _current.get("version"),
        "last_fetch_at": _last_fetch_at,
        "last_fetch_age_sec": (
            round(time.time() - _last_fetch_at, 1)
            if _last_fetch_at
            else None
        ),
        "last_fetch_error": _last_fetch_error,
        "cloud_url": CLOUD_URL,
        "cache_path": str(CACHE_PATH),
    }


def get_value(*path: str, default: Any = None) -> Any:
    """Convenience: dotted-path lookup with safe defaults.

    Example: get_value("voice_brain", "model", default="claude-haiku-4-5")
    """
    node: Any = _current
    for key in path:
        if not isinstance(node, dict):
            return default
        node = node.get(key)
        if node is None:
            return default
    return node


# ─── key loading ──────────────────────────────────────────────────────────────

def _public_key_pem() -> str:
    """Embedded Ed25519 public key.

    For dev/this-binary, read from env. For production builds we'll bake
    the PEM into a string literal here at build time.
    """
    pem = os.environ.get("KLO_LICENSE_PUBLIC_KEY", "").strip()
    if "\\n" in pem and "\n" not in pem:
        pem = pem.replace("\\n", "\n")
    return pem


# ─── cache I/O ────────────────────────────────────────────────────────────────

def load_cached_config() -> dict[str, Any] | None:
    if not CACHE_PATH.exists():
        return None
    try:
        return json.loads(CACHE_PATH.read_text())
    except Exception as exc:  # noqa: BLE001
        log.warning("failed to load cached cloud config: %s", exc)
        return None


def write_cached_config(config: dict[str, Any]) -> None:
    try:
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        CACHE_PATH.write_text(json.dumps(config, indent=2))
    except Exception as exc:  # noqa: BLE001
        log.warning("failed to write cloud config cache: %s", exc)


# ─── fetch + apply ────────────────────────────────────────────────────────────

async def fetch_and_apply_remote_config() -> bool:
    """Fetch /config, verify the JWT, apply + cache. Returns True on success."""
    global _current, _current_source, _last_fetch_at, _last_fetch_error

    pub = _public_key_pem()
    if not pub:
        _last_fetch_error = "KLO_LICENSE_PUBLIC_KEY not configured"
        log.warning("cloud config disabled — %s", _last_fetch_error)
        return False

    try:
        # Recognizable UA so Render's WAF doesn't 403 our config-fetch
        # by mistaking the default `python-httpx/...` for bot traffic.
        from .cloud_auth import SIDECAR_UA
        async with httpx.AsyncClient(
            timeout=FETCH_TIMEOUT_SEC,
            headers={"User-Agent": SIDECAR_UA},
        ) as client:
            resp = await client.get(f"{CLOUD_URL}/config")
        if resp.status_code != 200:
            _last_fetch_error = f"HTTP {resp.status_code}"
            log.warning("cloud config fetch — %s", _last_fetch_error)
            return False
        payload = resp.json()
    except Exception as exc:  # noqa: BLE001
        _last_fetch_error = f"{type(exc).__name__}: {exc}"
        log.warning("cloud config fetch failed — %s", _last_fetch_error)
        return False

    token = payload.get("token", "")
    if not token:
        _last_fetch_error = "response missing token"
        log.error("cloud config — %s", _last_fetch_error)
        return False

    try:
        decoded = jwt.decode(
            token,
            pub,
            algorithms=["EdDSA"],
            issuer="klo-cloud",
            options={"require": ["iss", "sub", "iat", "exp", "config"]},
        )
    except Exception as exc:  # noqa: BLE001
        _last_fetch_error = f"signature INVALID: {exc}"
        # Refuse to apply — a bad signature could be a MITM attempt.
        log.error("cloud config — %s — REFUSING to apply", _last_fetch_error)
        return False

    config = decoded.get("config")
    if not isinstance(config, dict):
        _last_fetch_error = "config claim not a dict"
        log.error("cloud config — %s", _last_fetch_error)
        return False

    _current = config
    _current_source = "cloud"
    _last_fetch_at = time.time()
    _last_fetch_error = None
    write_cached_config(config)
    log.info(
        "cloud config applied (version=%s, agent.model=%s)",
        config.get("version"),
        config.get("agent", {}).get("model"),
    )
    return True


# ─── lifecycle ────────────────────────────────────────────────────────────────

def bootstrap() -> None:
    """Synchronous startup: prefer cache, fall back to bundled defaults.

    Called once at sidecar startup BEFORE the asyncio loop runs the first
    fetch. Means even if the cloud is unreachable, the sidecar comes up
    with the last known good config.
    """
    global _current, _current_source

    cached = load_cached_config()
    if cached is not None:
        _current = cached
        _current_source = "cache"
        log.info(
            "loaded cached cloud config from %s (version=%s)",
            CACHE_PATH,
            cached.get("version"),
        )
    else:
        _current = json.loads(json.dumps(BUNDLED_DEFAULTS))
        _current_source = "bundled"
        log.info("using bundled defaults (no cache at %s yet)", CACHE_PATH)


async def refresh_loop() -> None:
    """Background task — periodic refresh + fail-open on errors."""
    # Initial fetch ASAP after bootstrap, then sleep.
    while True:
        try:
            await fetch_and_apply_remote_config()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("refresh loop unexpected error: %s", exc)
        await asyncio.sleep(REFRESH_INTERVAL_SEC)
