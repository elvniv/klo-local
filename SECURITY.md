# Security Policy

KLO Local can see and control sensitive parts of your computer. Treat it like a
developer tool with macOS Accessibility and Screen Recording privileges.

## What Leaves Your Device

In default local mode (`KLO_MODE=local`):

- Model requests are sent directly to the provider configured in `.env`.
- The local sidecar listens on loopback only.
- The Chrome extension connects to `ws://127.0.0.1:8767/extension`.
- No KLO-hosted cloud account is required.

If you set `KLO_MODE=hosted`, you are opting into hosted KLO behavior. Hosted
mode is outside the default KLO Local trust boundary.

## Permissions

KLO uses macOS permissions only for actions you initiate:

- Accessibility: click, type, press keys, and drive apps.
- Screen Recording: inspect the visible screen.
- Apple Events: interact with scriptable apps.

Run `klo-doctor` to verify the actual runtime permission state.

## Reporting Vulnerabilities

Please open a GitHub security advisory or email the maintainers listed in the
repository profile. Do not file public issues for active vulnerabilities.

Useful reports include:

- permission bypasses
- unsafe default tool behavior
- secret leakage in traces/logs
- prompt/tool injection that causes unauthorized action
- extension privilege escalation
