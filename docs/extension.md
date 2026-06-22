# Chrome Extension

The extension gives the local agent a browser surface. It connects to the
sidecar over a local WebSocket and does not require the Chrome Web Store.

## Load Unpacked

1. Start the sidecar:

   ```bash
   klo-api
   ```

2. Open `chrome://extensions`.
3. Enable Developer Mode.
4. Click Load unpacked.
5. Select the `extension` directory.

## Local Bridge

The extension connects to:

```text
ws://127.0.0.1:8767/extension
```

The sidecar reports extension state at:

```bash
curl http://127.0.0.1:8787/health
```

## Permissions

The extension requests broad browser permissions because computer-use tasks can
span many websites. The important trust boundary is that the extension forwards
browser state to the local sidecar only when KLO is running a user-initiated
task.

Review `extension/background.js` before installing if you want to inspect the
bridge behavior.
