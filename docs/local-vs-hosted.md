# Local vs Hosted

KLO Local and Hosted KLO share some product code, but they have different
runtime boundaries.

## KLO Local

Default mode:

```bash
KLO_MODE=local
```

Local mode:

- runs the sidecar on loopback
- connects the Mac app to `127.0.0.1:8787`
- connects the Chrome extension to `ws://127.0.0.1:8767/extension`
- sends model requests directly to your configured provider key
- does not require a KLO account
- does not require Supabase, Stripe, APNs, schedules, memory sync, or hosted
  connectors

## Hosted KLO

Hosted KLO is the managed product. It adds signed builds, updates, managed
models, sync, memory, schedules, mobile/cloud handoff, hosted connectors, teams,
support, and reliability.

Some hosted UI surfaces are present in this repository because the native app
and extension share product code. They are not part of the default local path.
Hosted calls require explicit hosted configuration such as `KLO_MODE=hosted` and
`KLO_CLOUD_URL`.

## Contributor Rule

New public contributions should keep local mode complete without hosted KLO.
Hosted integrations should be optional and clearly guarded.
