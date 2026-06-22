# PyInstaller spec — bundles agent2.desktop_api into a single-folder Mac
# binary that lives inside KLO.app at Contents/Resources/klo-sidecar/.
#
# Output:
#   desktop-mac/sidecar-build/klo-sidecar/
#     ├── klo-sidecar          (executable entry point)
#     ├── _internal/           (Python interpreter + bundled deps)
#     └── ...
#
# Run via:
#   bin/build-klo-sidecar
#
# Once built, the Xcode "Copy Sidecar Bundle" run-script phase copies the
# folder into the .app on each Debug+Release build.

# ── Hidden imports ────────────────────────────────────────────────────────────
# Modules that PyInstaller's static analysis misses because they're loaded
# dynamically (importlib, getattr, plugin discovery, etc.). Add new entries
# when the bundle starts up but throws ModuleNotFoundError on the Mac app's
# console.

import os
import sys
from PyInstaller.utils.hooks import collect_submodules

# Make `agent2` importable from the repo root so collect_submodules below
# can introspect the package. SPECPATH is the dir containing this .spec
# file (desktop-mac/), so the repo root is one level up.
_REPO_ROOT = os.path.abspath(os.path.join(SPECPATH, ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

# Pull in EVERY submodule of agent2 — its modules import each other via
# relative imports, and PyInstaller's static analysis doesn't always follow
# relative imports through a top-level wrapper script.
agent2_submodules = collect_submodules("agent2")

# agent2's accessibility tool delegates to api.core.accessibility's
# AccessibilityExecutor (the AX walker + actionable_index + write actions).
# The import is function-local in agent2/tools.py:_tool_accessibility, so
# static analysis misses it. Include ONLY the narrow transitive set —
# screenshot + redact. collect_submodules("api.core") pulls browser/web/
# actions/loop/etc. and drags in heavier HTTP-stack deps that altered
# the bundled httpx's TLS fingerprint enough to trip Render's WAF.
api_core_submodules = [
    "api.core.accessibility",
    "api.core.screenshot",
    "api.core.redact",
]

hiddenimports = agent2_submodules + api_core_submodules + [
    # Anthropic SDK uses tiktoken-style dynamic registry imports
    "anthropic._streaming",
    "anthropic.types",
    # OpenAI SDK ditto
    "openai._streaming",
    "openai.types",
    # FastAPI / Starlette use plugin-style discovery
    "uvicorn.lifespan",
    "uvicorn.lifespan.on",
    "uvicorn.lifespan.off",
    "uvicorn.loops",
    "uvicorn.loops.auto",
    "uvicorn.loops.uvloop",
    "uvicorn.protocols",
    "uvicorn.protocols.http",
    "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl",
    "uvicorn.protocols.http.httptools_impl",
    "uvicorn.protocols.websockets",
    "uvicorn.protocols.websockets.auto",
    "uvicorn.protocols.websockets.websockets_impl",
    "uvicorn.protocols.websockets.wsproto_impl",
    # PyJWT crypto backends
    "jwt.algorithms",
    "cryptography.hazmat.backends.openssl",
    # Our own modules — defensive; PyInstaller usually finds them
    "agent2.cloud_auth",
    "agent2.cloud_config",
    "agent2.voice_brain",
    "agent2.bridge",
    "agent2.tools",
    "agent2.agent",
    "agent2.prompts",
    "agent2.memory",
    "agent2.tasks",
    "agent2.system_info",
]

# ── Excludes ──────────────────────────────────────────────────────────────────
# Big deps in pyproject.toml that this sidecar doesn't actually use. Cuts
# ~80MB off the bundle. Add an entry here when `du -sh desktop-mac/sidecar-build`
# crosses 200 MB and you've found the culprit with `pyi-makespec --debug imports`.

excludes = [
    "browser_use",        # heavy LangChain stack, not used by desktop_api
    "langchain",
    "langchain_core",
    "langchain_openai",
    "youtube_transcript_api",
    "playwright",
    "ollama",
    "groq",
    "google",             # google-genai / google-api-* from browser_use chain
    "googleapiclient",
    "google_auth",
    "tensorflow",
    "torch",
    "scipy",
    "matplotlib",
    "PIL.ImageQt",
    "tkinter",
]


# ── Analysis ──────────────────────────────────────────────────────────────────

block_cipher = None

a = Analysis(
    # Top-level entry — see klo_sidecar_entry.py for the why. Pointing
    # PyInstaller directly at agent2/desktop_api.py breaks relative
    # imports inside the agent2 package.
    [os.path.join(SPECPATH, 'klo_sidecar_entry.py')],
    pathex=[_REPO_ROOT, SPECPATH],
    binaries=[],
    datas=[],
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=excludes,
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)


# ── Single-file vs single-folder ──────────────────────────────────────────────
# We use one-folder (BUNDLE_FOLDER below). Why:
#   • Faster startup — no extracting to /tmp on every launch.
#   • Cleaner code-signing — Apple's notary scans all binaries; one giant
#     blob would still need the embedded .so files signed individually.
#   • Smaller per-launch disk churn.

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='klo-sidecar',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                  # don't UPX — Apple notary rejects
    console=True,               # writes to stderr; AppDelegate captures
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,           # build for the host arch; Mac app is arm64
    codesign_identity=None,     # signing happens at the .app level
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='klo-sidecar',
)
