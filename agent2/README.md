# agent2

`agent2` is KLO Local's Python sidecar and agent loop. It owns the local HTTP
API, WebSocket event stream, browser bridge, prompts, tool schemas, tool
dispatch, and safety boundaries.

## Runtime Shape

```text
Mac app / CLI
  -> agent2.desktop_api on 127.0.0.1:8787
  -> agent2.agent
  -> agent2.tools
  -> BYOK model provider
```

The Chrome extension connects separately over the local browser bridge:

```text
extension/background.js -> ws://127.0.0.1:8767/extension
```

## Important Files

- `desktop_api.py`: FastAPI sidecar used by the Mac app and CLI.
- `agent.py`: model loop and turn orchestration.
- `prompts.py`: system prompt and safety instructions.
- `tools.py`: local tools, browser tools, approval checks, and dispatch.
- `bridge.py`: in-process extension bridge state.
- `bridge_server.py`: standalone bridge server for extension development.
- `cloud_auth.py`: provider client factories; local mode uses direct BYOK keys.

## Local Mode

KLO Local defaults to:

```bash
KLO_MODE=local
```

In local mode, the sidecar does not start hosted config refresh or hosted device
bridge tasks. Model clients are created directly from `OPENAI_API_KEY` or
`ANTHROPIC_API_KEY`.

## Run

From the repository root:

```bash
cp .env.example .env
uv sync --extra dev
uv run python -m agent2.desktop_api
```

Then, in another terminal:

```bash
uv run klo "summarize what is on my screen"
```

## Tests

```bash
uv run pytest tests/ -q
```

The public CI runs this test suite on macOS because several modules import
Apple frameworks.
