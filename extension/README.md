# KLO Local Chrome Extension

A Manifest V3 extension that exposes browser operations to the local KLO
sidecar over a localhost WebSocket. The agent loop runs in Python; the extension
does not store model API keys and does not call model providers.

## Why this exists

Browser tasks often need the page you are already using, including the tab,
profile, and login state you explicitly choose to work with. The extension gives
the local sidecar a controlled bridge into that browser session.

## What it can do (RPC methods)

| Method | What it does |
|---|---|
| `ping` | health check |
| `tabs.list` | inventory of every open tab |
| `tabs.active` | the foreground tab in the current window |
| `tabs.navigate(url, [tab_id])` | go to a URL |
| `tabs.create(url, [active])` | open a new tab |
| `tabs.read_text([tab_id], [max])` | innerText of a page (truncated) |
| `tabs.read_html([tab_id], [max])` | full HTML (truncated) |
| `tabs.click(selector, [tab_id])` | click a CSS selector inside the page |
| `tabs.fill(selector, text, [submit])` | fill an input/textarea |
| `tabs.evaluate(code, [tab_id])` | run JS in the page (read-only preferred) |
| `tabs.screenshot` | PNG data URL of active tab |

These are exposed to the model as browser tools through `agent2`.

## Install

### 1. Start KLO Local

From the repo root:

```bash
uv run python -m agent2.desktop_api
```

Leave this running.

### 2. Load the extension into your browser

Works in Chrome and Chromium-based browsers that support Manifest V3.

1. Open your browser
2. Go to `chrome://extensions`
3. Toggle **Developer mode** (top-right)
4. Click **Load unpacked**
5. Select this repo's `extension` directory
6. Make sure the extension is enabled

Click the extension icon to open the side panel — you'll see a green dot and
"connected" if everything is working.

### 3. Verify

```bash
curl http://127.0.0.1:8787/health
```

### 4. Try a browser task

```bash
uv run klo "what is the title of the tab I'm looking at?"
```

The agent can now use browser tools through the local bridge.

## Permissions the extension requests

| Permission | Why |
|---|---|
| `tabs` | List and identify your open tabs |
| `scripting` | Run small scripts in pages on demand (click, fill, read text) |
| `activeTab` | Read the foreground tab on user gesture |
| `storage` | Persist the bridge connection status |
| `sidePanel` | Show the connection status / reconnect button |
| `host_permissions: <all_urls>` | The agent could ask about any site you visit |

In local mode, the extension's bridge connection is localhost:

```text
ws://127.0.0.1:8767/extension
```

Hosted account and connector UI code is present because this extension shares
code with Hosted KLO, but the public local build points hosted fallbacks at
loopback by default.

## Troubleshooting

**Side panel shows red dot, "not connected"**
- Is `agent2.desktop_api` running? Check the terminal.
- Click "reconnect" in the side panel.
- If still red, reload the extension (chrome://extensions → reload icon).

**`/health` says the extension is disconnected**
- Make sure `uv run python -m agent2.desktop_api` is running.
- Reload the extension from `chrome://extensions`.

**Extension can't be loaded** ("Manifest version 2 is deprecated", etc.)
- This shouldn't happen — the extension is Manifest V3. If your browser is
  pre-2024 it might not support it.

**Bridge connects but RPCs fail**
- Run `uv run python -m agent2._smoke_bridge` — that runs a fake-extension
  client through core methods to verify the server side is healthy.

## Files

```
extension/
├── manifest.json     # Manifest V3, perms, side panel
├── background.js     # service worker + WebSocket bridge + RPC handlers
├── sidepanel.html    # tiny status UI
├── sidepanel.js      # connection status updates
└── icons/            # 16/32/48/128px
```

No build step is required for local development.
