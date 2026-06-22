"""Sidecar → klo-cloud auth helpers.

The sidecar no longer holds vendor API keys. Every Anthropic + OpenAI
request is proxied through klo-cloud, authenticated with the user's
Supabase access token.

Where the token comes from:
  1. KLO_SESSION_TOKEN env var (Mac app may inject when launching the
     sidecar as a subprocess in production builds).
  2. `~/.klo/session.json` written by the Mac app's AccountManager on
     every sign-in / token refresh.

Why the file (not just the Keychain): the sidecar is a child process
launched independently from the Mac app. macOS Keychain ACL keys to a
specific signed binary path; the Python interpreter and the Mac app
have different paths and would each get their own ACL row. A file in
`~/.klo/` (filesystem-permission scoped to the user account) sidesteps
that without losing security — both processes belong to the same user.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path


log = logging.getLogger("agent2.cloud_auth")

KLO_MODE = (os.environ.get("KLO_MODE") or "local").strip().lower()
KLO_CLOUD_URL = os.environ.get("KLO_CLOUD_URL", "").rstrip("/")

SESSION_PATH = Path(
    os.environ.get(
        "KLO_SESSION_PATH",
        str(Path.home() / ".klo" / "session.json"),
    )
)

# Recognizable User-Agent for outbound calls from the sidecar to
# klo-cloud. Render's WAF tends to flag the SDK defaults
# ("OpenAI/Python 1.x.x", "anthropic-sdk-python/...", bare
# "python-httpx/0.x") as bot-like on naked /v1/* proxy paths and
# returns a Render-branded 403 HTML page. A plain klo-* UA reads as
# our own app and passes through. Override per-deploy via
# KLO_SIDECAR_UA if needed.
SIDECAR_UA = os.environ.get(
    "KLO_SIDECAR_UA",
    "klo-sidecar/0.1.0 (klo-mac)",
)


class NotSignedIn(RuntimeError):
    """Raised when the sidecar tries to use a klo-cloud-backed API but
    no session token is available. The voice brain catches this and
    surfaces a "please sign in" prompt to the user."""


class TrialExhausted(RuntimeError):
    """Raised when /usage/task_start returns 402 trial_exhausted.

    Carries the counters from the response so the desktop_api layer can
    relay them to the Mac client (which renders the upgrade modal with
    "10/10 used"). subscription_status is included so the Mac side can
    distinguish "never subscribed" from "lapsed subscriber" if we ever
    surface different copy for the two.
    """
    def __init__(self, trial_runs_used: int, trial_runs_limit: int,
                 subscription_status: str = "none"):
        super().__init__("trial_exhausted")
        self.trial_runs_used = trial_runs_used
        self.trial_runs_limit = trial_runs_limit
        self.subscription_status = subscription_status


class CloudUnreachable(RuntimeError):
    """Raised when /usage/task_start can't reach klo-cloud at all
    (DNS, TLS, timeout). Distinct from upstream errors so the desktop_api
    can fail open vs. fail closed deliberately."""


def is_local_mode() -> bool:
    """True when KLO is running as a fully local BYOK app."""
    return KLO_MODE != "hosted"


def get_session_token() -> str | None:
    """Return the current Supabase access token, or None if not signed in.

    Reads in priority order:
      1. KLO_SESSION_TOKEN env var
      2. ~/.klo/session.json {"access_token": "..."}
    """
    env_tok = os.environ.get("KLO_SESSION_TOKEN", "").strip()
    if env_tok:
        return env_tok
    if SESSION_PATH.exists():
        try:
            data = json.loads(SESSION_PATH.read_text())
            tok = (data.get("access_token") or "").strip()
            return tok or None
        except Exception as exc:  # noqa: BLE001
            log.warning("failed to read %s: %s", SESSION_PATH, exc)
            return None
    return None


def get_refresh_token() -> str | None:
    """Return the Supabase refresh token from session.json, or None.

    Used by the sidecar's self-refresh path (refresh_session_token) when
    the WS bridge gets a 403 and the Mac app isn't responsive enough to
    rewrite session.json. The Mac app's AccountManager writes this on
    sign-in + every successful refresh.
    """
    if SESSION_PATH.exists():
        try:
            data = json.loads(SESSION_PATH.read_text())
            tok = (data.get("refresh_token") or "").strip()
            return tok or None
        except Exception:  # noqa: BLE001
            return None
    return None


def get_session_mtime() -> float:
    """Return session.json's mtime in epoch seconds, or 0.0 if it doesn't
    exist. Used by the cloud bridge to watch for token updates without
    polling content."""
    try:
        return SESSION_PATH.stat().st_mtime
    except (FileNotFoundError, OSError):
        return 0.0


def _is_jwt_likely_expired(token: str, leeway_seconds: int = 30) -> bool:
    """Decode a Supabase JWT's payload and compare `exp` to now.

    Doesn't verify the signature — that's klo-cloud's job. Used as a
    cheap pre-check before posting /auth/refresh: if we just acquired
    the refresh lock and discover session.json was already refreshed by
    another process, skip the POST.
    """
    try:
        import base64
        import time as _time
        parts = token.split(".")
        if len(parts) != 3:
            return True
        padded = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
        exp = int(payload.get("exp", 0))
        return exp < int(_time.time()) + leeway_seconds
    except Exception:  # noqa: BLE001
        return True  # if we can't decode, assume expired


def require_session_token() -> str:
    tok = get_session_token()
    if not tok:
        raise NotSignedIn(
            "klo isn't signed in. Open Settings (⌘⇧,) and complete the "
            "magic-link flow."
        )
    return tok


# ─── Sidecar self-refresh (Lakshita fix, 2026-06-19) ─────────────────────────
#
# Diagnosis: orphan sidecars that survive a Mac app crash / force-quit
# hammered klo-cloud's /ws/devices with a token they couldn't refresh.
# `cloud_bridge` got 403, looped, re-read the same session.json, got the
# same expired token, hit 403 again — at 2-3s intervals, indefinitely.
#
# Fix: the sidecar can refresh its own access token by reading the
# refresh_token from session.json and POSTing to /auth/refresh. A file
# lock at ~/.klo/refresh.lock coordinates with the Mac app's
# AccountManager so they don't both refresh concurrently — Supabase
# rotates refresh tokens on every call, and a double-fire would burn
# whichever response arrives second.

class AuthRefreshDead(Exception):
    """Refresh token is permanently dead. User must sign back in. Caller
    should clear session.json and surface a sign-in prompt rather than
    retrying."""


class AuthRefreshFailed(Exception):
    """Transient refresh failure (network, 401, server hiccup). Caller
    should back off and retry later."""


_REFRESH_LOCK_PATH = SESSION_PATH.parent / "refresh.lock"


def _write_session_atomic(access_token: str, refresh_token: str) -> None:
    """Rewrite session.json with new tokens. Atomic via tmpfile + rename
    so a concurrent reader (the Mac app or the next bridge loop) never
    sees a half-written file. Permissions match what the Mac app writes
    (0600 — owner only).
    """
    SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "access_token": access_token,
        "refresh_token": refresh_token,
    }
    tmp = SESSION_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    try:
        tmp.chmod(0o600)
    except OSError:
        pass
    tmp.replace(SESSION_PATH)


async def refresh_session_token() -> str | None:
    """Try to refresh the access token via klo-cloud /auth/refresh.

    Coordinates with any other process that might also be refreshing
    (Mac app's AccountManager) via a non-blocking POSIX file lock at
    ~/.klo/refresh.lock. Whichever process gets the lock does the POST;
    the other returns None and lets the caller wait for session.json to
    update.

    Returns:
        The new access token on a successful refresh. None if the lock
        was held by another process (caller should wait for session.json
        to change).

    Raises:
        AuthRefreshDead: cloud returned 410. session.json has been
        cleared. User must sign back in.
        AuthRefreshFailed: any other failure. Caller should back off.
    """
    import asyncio
    import fcntl
    import httpx

    refresh_tok = get_refresh_token()
    if not refresh_tok:
        # No refresh_token in session.json. Either the user is signed
        # out, OR they're running an old Mac app that doesn't write the
        # refresh half. Either way the sidecar can't recover on its
        # own — surface dead so the bridge stops hammering.
        raise AuthRefreshDead("no refresh_token in session.json")

    SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(str(_REFRESH_LOCK_PATH), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.info("auth refresh: another process holds the lock; deferring")
            return None

        # Double-check: another process may have refreshed between when
        # we got 403 and when we acquired the lock. If session.json's
        # current access_token is still alive, skip the POST.
        current = get_session_token()
        if current and not _is_jwt_likely_expired(current):
            log.info("auth refresh: session.json already fresh; skipping POST")
            return current

        try:
            async with httpx.AsyncClient(timeout=12) as client:
                resp = await client.post(
                    f"{KLO_CLOUD_URL}/auth/refresh",
                    json={"refresh_token": refresh_tok},
                    headers={"User-Agent": SIDECAR_UA},
                )
        except httpx.HTTPError as exc:
            raise AuthRefreshFailed(f"network error: {exc}")

        if resp.status_code == 410:
            # Refresh token permanently dead — clear session.json so a
            # restart can't loop on the same dead tokens.
            log.info("auth refresh: 410 dead refresh_token; clearing session.json")
            try:
                SESSION_PATH.unlink()
            except FileNotFoundError:
                pass
            raise AuthRefreshDead("refresh_token rejected by cloud (410)")
        if resp.status_code != 200:
            raise AuthRefreshFailed(f"cloud returned {resp.status_code}")

        body = resp.json()
        new_access = (body.get("access_token") or "").strip()
        new_refresh = (body.get("refresh_token") or refresh_tok).strip()
        if not new_access:
            raise AuthRefreshFailed("cloud returned no access_token")
        _write_session_atomic(new_access, new_refresh)
        log.info("auth refresh: succeeded; wrote new tokens to session.json")
        return new_access
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)


# ─── /usage/task_start ────────────────────────────────────────────────────────

async def request_task_start() -> dict:
    """POST /usage/task_start. Returns {allowed, mode, ...counters} on
    success. Raises NotSignedIn if no token, TrialExhausted on 402,
    CloudUnreachable on transport failure.

    Called by desktop_api.create_run before kicking off any agent loop.
    The cloud side atomically claims one trial run (or no-ops for paid
    subs) — see klo_cloud/usage.py.
    """
    if is_local_mode():
        return {"allowed": True, "mode": "local"}
    if not KLO_CLOUD_URL:
        raise CloudUnreachable("KLO_CLOUD_URL is required in hosted mode")
    import httpx
    token = require_session_token()
    url = f"{KLO_CLOUD_URL}/usage/task_start"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": SIDECAR_UA,
    }
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(url, headers=headers)
    except httpx.HTTPError as exc:
        raise CloudUnreachable(f"task_start unreachable: {exc}")

    if resp.status_code == 402:
        # Pull counters from the error envelope so the caller can echo
        # them to the Mac client. usage.py returns a JSON body shaped
        # `{"detail": {"error": "trial_exhausted", ...}}` (FastAPI
        # wraps the HTTPException detail under `detail`).
        try:
            detail = resp.json().get("detail") or {}
        except Exception:  # noqa: BLE001
            detail = {}
        raise TrialExhausted(
            trial_runs_used=int(detail.get("trial_runs_used", 0)),
            trial_runs_limit=int(detail.get("trial_runs_limit", 0)),
            subscription_status=str(detail.get("subscription_status", "none")),
        )
    if resp.status_code == 401:
        # Session token rejected — Mac app's AccountManager will refresh
        # on the next /auth/me call and rewrite session.json.
        raise NotSignedIn("session rejected by klo-cloud")
    if resp.status_code >= 400:
        raise CloudUnreachable(f"task_start HTTP {resp.status_code}: {resp.text[:200]}")
    try:
        return resp.json()
    except Exception as exc:  # noqa: BLE001
        raise CloudUnreachable(f"task_start returned non-JSON: {exc}")


# ─── client factories ─────────────────────────────────────────────────────────

# ─── fast-brain override (launch-config) ─────────────────────────────────────
#
# Routes "easy" LLM tasks (classification, parsing, summarization, short reply
# drafts) to a cheap or free provider instead of the full Anthropic stack.
#
# At launch volume (10s to low 100s of DAU), Groq's free tier of Llama 3.3 70B
# (1,000 requests/day, $0 cost) handles these tasks competently and saves the
# full Anthropic Haiku bill for them. When KLO_FAST_BRAIN_URL is unset, the
# factory falls back to make_openai_client (klo-cloud proxy) so production
# environments that don't opt in see no behavior change.
#
# Setup recipe:
#   export KLO_FAST_BRAIN_URL=https://api.groq.com/openai/v1
#   export KLO_FAST_BRAIN_KEY=<your Groq key from console.groq.com>
#   # optional, defaults to Groq's llama-3.3-70b-versatile
#   export KLO_FAST_BRAIN_MODEL=llama-3.3-70b-versatile

def _fast_brain_url() -> str | None:
    url = (os.environ.get("KLO_FAST_BRAIN_URL") or "").strip().rstrip("/")
    return url or None


def make_fast_client():
    """AsyncOpenAI pointed at the fast brain (Groq Llama 3.3 70B by default).
    Falls back to make_openai_client() when KLO_FAST_BRAIN_URL is unset, so
    environments that don't opt in see no change.

    Why a separate factory: the agent loop needs Anthropic Sonnet for tool-use
    accuracy on long chains, but one-shot classification / parsing /
    summarization doesn't need that capability. Routing those calls to Groq's
    free tier eliminates their cost entirely at launch volume.

    Note the SDK is OpenAI's AsyncOpenAI even when pointed at Groq — Groq
    exposes an OpenAI-compatible API at /v1, so the same SDK works.
    """
    url = _fast_brain_url()
    if not url:
        return make_openai_client()
    from openai import AsyncOpenAI
    base = url if url.endswith("/v1") else f"{url}/v1"
    return AsyncOpenAI(
        base_url=base,
        api_key=(os.environ.get("KLO_FAST_BRAIN_KEY") or "fast").strip(),
    )


def fast_brain_model() -> str:
    """Model name to pass to make_fast_client() calls. Defaults to Groq's
    Llama 3.3 70B; override via KLO_FAST_BRAIN_MODEL for other providers
    (e.g. `qwen3:8b` on local Ollama, `Meta-Llama-3.1-70B-Instruct` on
    DeepInfra, etc.)."""
    return (os.environ.get("KLO_FAST_BRAIN_MODEL")
            or "llama-3.3-70b-versatile").strip()


def make_openai_client():
    """AsyncOpenAI for local BYOK mode or hosted KLO proxy mode."""
    from openai import AsyncOpenAI
    if is_local_mode():
        key = (os.environ.get("OPENAI_API_KEY") or "").strip()
        if not key:
            raise NotSignedIn("OPENAI_API_KEY is required for local OpenAI mode")
        base_url = (os.environ.get("OPENAI_BASE_URL") or "").strip()
        kwargs = {"api_key": key}
        if base_url:
            kwargs["base_url"] = base_url
        return AsyncOpenAI(**kwargs)
    if not KLO_CLOUD_URL:
        raise CloudUnreachable("KLO_CLOUD_URL is required in hosted mode")
    token = require_session_token()
    return AsyncOpenAI(
        base_url=f"{KLO_CLOUD_URL}/api/llm/openai",
        api_key=token,
        default_headers={"User-Agent": SIDECAR_UA},
    )


class _AnthropicPathRewriteTransport:
    """klo-cloud mounts its Anthropic proxy at /api/llm/anthropic and the
    actual route for Messages is /api/llm/anthropic/messages — no /v1/.
    The Anthropic SDK hard-codes /v1/messages relative to base_url, so
    out-of-the-box requests land at /api/llm/anthropic/v1/messages and
    404. This transport sits in front of the SDK's httpx client and
    rewrites the path on the fly so the SDK's request reaches the
    cloud's actual route. Probe verified: /api/llm/anthropic/messages
    returns 200 with a valid Messages response.
    """

    def __init__(self, inner):
        self._inner = inner

    async def handle_async_request(self, request):
        import httpx
        path = request.url.path
        # Strip a /v1/ that immediately follows the proxy mount so
        # `/v1/messages` becomes `/messages`. Same for /v1/messages
        # inside the openai mount, defensive.
        if "/api/llm/anthropic/v1/" in path:
            new_path = path.replace("/api/llm/anthropic/v1/", "/api/llm/anthropic/")
            request = httpx.Request(
                method=request.method,
                url=request.url.copy_with(path=new_path),
                headers=request.headers,
                content=request.content,
                extensions=request.extensions,
            )
        return await self._inner.handle_async_request(request)

    async def aclose(self):
        await self._inner.aclose()


def make_anthropic_client():
    """AsyncAnthropic for local BYOK mode or hosted KLO proxy mode."""
    import httpx
    from anthropic import AsyncAnthropic, DefaultAsyncHttpxClient

    if is_local_mode():
        key = (os.environ.get("ANTHROPIC_API_KEY") or "").strip()
        if not key:
            raise NotSignedIn("ANTHROPIC_API_KEY is required for local Anthropic mode")
        base_url = (os.environ.get("ANTHROPIC_BASE_URL") or "").strip()
        kwargs = {"api_key": key}
        if base_url:
            kwargs["base_url"] = base_url
        return AsyncAnthropic(**kwargs)

    if not KLO_CLOUD_URL:
        raise CloudUnreachable("KLO_CLOUD_URL is required in hosted mode")
    token = require_session_token()
    inner_transport = httpx.AsyncHTTPTransport()
    rewrite_transport = _AnthropicPathRewriteTransport(inner_transport)
    http_client = DefaultAsyncHttpxClient(transport=rewrite_transport)

    return AsyncAnthropic(
        base_url=f"{KLO_CLOUD_URL}/api/llm/anthropic",
        api_key="proxied-via-klo-cloud",  # SDK requires a non-empty value
        default_headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": SIDECAR_UA,
        },
        http_client=http_client,
    )
