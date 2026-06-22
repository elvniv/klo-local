"""PyInstaller entry point for the bundled Mac sidecar.

This file gets compiled by PyInstaller into the `klo-sidecar` binary
that ships inside KLO.app. PyInstaller treats the spec entry as a
top-level standalone script — meaning `from .agent import ...` style
relative imports inside the `agent2` package would fail. This wrapper
side-steps that by importing the package via its full dotted path,
which Python loads through its normal import machinery + relative
imports inside `agent2` resolve correctly.

Why a separate file (vs. just running `agent2.desktop_api` directly):
PyInstaller's analysis follows the entry script's imports. Pointing it
at `agent2/desktop_api.py` directly causes a runtime error because the
file's `from .agent import ...` statements look up a parent package
that doesn't exist in PyInstaller's flattened script context. Pointing
it at this top-level file works because `import agent2.desktop_api`
goes through the package importer.
"""
from agent2.desktop_api import main


if __name__ == "__main__":
    main()
