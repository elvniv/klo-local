# Contributing

KLO Local is a local-first Mac/browser agent. Contributions should make it more
trustworthy, inspectable, reliable, or extensible.

## Development Setup

```bash
cp .env.example .env
python3.11 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
uv run pytest tests/ -q
uv run python -m agent2.desktop_api
```

## Useful Areas

- Local tools in `agent2/tools.py`
- Agent loop and prompts in `agent2/agent.py` and `agent2/prompts.py`
- Chrome bridge in `extension/background.js`
- Native Mac UI in `desktop-mac/KLO`
- Diagnostics in `cli/doctor.py`
- Docs and examples under `docs`

## Pull Requests

Keep changes small and reviewable. Include:

- what changed
- why it matters
- how you tested it
- any permission, privacy, or safety impact

Do not commit `.env`, browser profiles, screenshots of private desktops,
generated sidecar bundles, DMGs, signing keys, or extension private keys.

## Safety Expectations

New mutating tools must:

- declare intent clearly
- avoid destructive defaults
- return enough state for verification
- preserve user control and cancellation
- avoid sending secrets to logs or traces
