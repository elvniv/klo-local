"""Lock in the exception → stable-code mapping in agent2.agent.

Failure mode this guards against: a regression where an upstream error
(a Render WAF 403 HTML page, an Anthropic 529, an OpenAI 429) leaks
its raw text into result.error and gets rendered into the user's chat
surface. That actually shipped once — Render returned an HTML 403 and
the entire HTML body flowed through to the notch panel.

We assert two things:
  1. Known exception shapes map to the expected stable code.
  2. NO classification path ever returns raw HTML / vendor name /
     infrastructure leak text.
"""
from __future__ import annotations

import asyncio

from agent2.agent import _classify_run_error


# ─── Stable codes the classifier is allowed to produce ────────────────────────

_VALID_CODES = {
    "upstream_overloaded",
    "upstream_timeout",
    "upstream_billing",
    "upstream_blocked",
    "upstream_error",
}


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _exc_named(name: str, message: str = "") -> Exception:
    """Build an exception whose class name matches `name` so the classifier's
    type(exc).__name__ check fires (mirrors openai.RateLimitError etc.)."""
    cls = type(name, (Exception,), {})
    return cls(message)


# ─── Direct mapping tests ─────────────────────────────────────────────────────

def test_ratelimit_class_name_maps_to_overloaded():
    exc = _exc_named("RateLimitError", "rate limited at 3000 RPM")
    assert _classify_run_error(exc) == "upstream_overloaded"


def test_overloaded_text_maps_to_overloaded():
    exc = Exception("Anthropic returned: overloaded — please retry")
    assert _classify_run_error(exc) == "upstream_overloaded"


def test_529_text_maps_to_overloaded():
    exc = Exception("upstream HTTP 529")
    assert _classify_run_error(exc) == "upstream_overloaded"


def test_timeout_class_name_maps_to_timeout():
    assert _classify_run_error(asyncio.TimeoutError()) == "upstream_timeout"


def test_timeout_text_maps_to_timeout():
    assert _classify_run_error(Exception("request timed out")) == "upstream_timeout"


def test_billing_text_maps_to_billing():
    assert _classify_run_error(Exception("insufficient credit")) == "upstream_billing"
    assert _classify_run_error(Exception("you have exceeded your quota")) == "upstream_billing"


def test_forbidden_text_maps_to_blocked():
    assert _classify_run_error(Exception("HTTP 403 forbidden")) == "upstream_blocked"


def test_unknown_error_falls_back():
    assert _classify_run_error(ValueError("totally unrelated")) == "upstream_error"


# ─── No-leak invariants — the WAF-bug regression test ────────────────────────

def test_html_body_never_leaks_into_code():
    """Render WAF returned an HTML 403 page — entire HTML used to flow
    through result.error into the user's chat panel. The classifier must
    return one of the stable codes, NEVER raw HTML, regardless of body."""
    waf_html = (
        "<html><head><title>Forbidden</title></head>"
        "<body>Powered by Render. WAF blocked your request. "
        "request_id=abc-123-render</body></html>"
    )
    code = _classify_run_error(Exception(waf_html))
    assert code in _VALID_CODES
    # Belt and suspenders — no infrastructure leak in the code itself.
    for forbidden in ("<", ">", "render", "waf", "cloudflare", "request_id"):
        assert forbidden not in code.lower(), (
            f"classifier leaked '{forbidden}' into the error code: {code!r}"
        )


def test_anthropic_overload_html_classifies_as_overloaded():
    """Anthropic occasionally returns a 529 with vendor-branded body. Should
    classify as overloaded (because the body contains 'overloaded'), with
    no HTML leak in the resulting code."""
    body = (
        "<html><body>The API is currently overloaded. "
        "Status 529. Try again later.</body></html>"
    )
    code = _classify_run_error(Exception(body))
    assert code == "upstream_overloaded"
    assert "<" not in code and ">" not in code


def test_waf_403_with_base64_font_does_not_falsely_classify_as_overloaded():
    """Real regression: Render WAF 403 page embeds a base64-encoded WOFF2
    font in its HTML body. That font's base64 happens to contain the
    substring "529" (from the [A-Za-z0-9] base64 alphabet). The classifier's
    blanket `"529" in text` check would match → wrongly return
    `upstream_overloaded` instead of `upstream_blocked` → user sees
    "klo is overloaded right now" when the real problem is that the
    WAF is blocking us."""
    # Realistic payload: big chunk of base64 with literal "529" in the middle,
    # plus the actual WAF text. Mirrors the live Render 403 page.
    body = (
        '<!DOCTYPE html><html><head><title>Blocked</title>'
        '<style>@font-face { src: url("data:font/woff2;base64,'
        'd09GMgABAAAAALnMABMAAAACO+gAALljAAEAAAAAAAAAAAAAA'
        'yiohxuqalnsgnkn529x97bowtfwrd6zzpr8nszhy'
        'TGFKLOREMOREDATA");}</style></head><body>'
        '<h1>403 - Forbidden</h1>'
        '<p>Your request was blocked by this site\'s web application firewall.</p>'
        '</body></html>'
    )
    # Simulate openai.PermissionDeniedError
    exc = _exc_named("PermissionDeniedError", body)
    code = _classify_run_error(exc)
    assert code == "upstream_blocked", (
        f"Render WAF 403 with base64 font containing '529' must classify as "
        f"upstream_blocked, not {code!r}. The exception class name "
        f"'PermissionDeniedError' should be a strong-enough signal."
    )


def test_class_name_takes_priority_over_body_text():
    """A PermissionDeniedError MUST classify as blocked even if its body
    coincidentally contains overloaded-looking text — class name is the
    authoritative signal."""
    exc = _exc_named("PermissionDeniedError",
                     "529 overloaded ratelimit timed out — but actually a 403")
    assert _classify_run_error(exc) == "upstream_blocked"


def test_every_classifier_output_is_in_valid_set():
    """Sanity: stress a few unusual inputs and assert they all land in the
    valid-code set. No string can produce an unstable error code."""
    samples = [
        Exception(""),
        Exception("connection refused"),
        Exception("ssl handshake failed"),
        _exc_named("BadRequestError", "model_not_found: gpt-99"),
        _exc_named("APIConnectionError", "Failed to connect"),
        Exception("\x00\x01\x02 binary garbage"),
    ]
    for exc in samples:
        assert _classify_run_error(exc) in _VALID_CODES, (
            f"classifier returned unknown code for {exc!r}"
        )
