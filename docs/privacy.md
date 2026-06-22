# Privacy

KLO Local is designed around an explicit local/hosted boundary.

## Local Mode

Default local mode is enabled by:

```bash
KLO_MODE=local
```

In local mode:

- The sidecar binds to loopback.
- The Mac app talks to `127.0.0.1:8787`.
- The extension talks to the local WebSocket bridge.
- Model traffic goes directly to the provider configured in `.env`.
- Run artifacts are written under the local `ARTIFACTS_DIR`.

KLO Local does not require Supabase, Stripe, APNs, hosted schedules, hosted
memory, or a KLO account.

## What The Model May See

During a run you start, the model may receive:

- the prompt you typed
- screenshots or text snapshots needed for the task
- tool results
- browser DOM/text requested by tools
- recent conversation context

Do not ask KLO to work on sensitive material unless you are comfortable sending
that material to your configured model provider.

## Hosted Boundary

Hosted KLO is a separate product surface. Set `KLO_MODE=hosted` only if you are
developing official hosted integrations. Hosted features can involve account
auth, sync, billing, mobile handoff, hosted connectors, or managed model proxying.

See `docs/local-vs-hosted.md` for the full boundary.

## Local Artifacts

Local traces/screenshots are controlled by:

```bash
ARTIFACTS_DIR=.klo/runs
DATABASE_PATH=klo.sqlite3
```

Both are ignored by git. Delete them whenever you want a clean local state.
