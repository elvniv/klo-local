# Vendored: swift-realtime-openai

Upstream: <https://github.com/m1guelpf/swift-realtime-openai>
Pinned commit: `46f393d9e2e60724aadc30062f75ee73bbcdb8fc` (main as of 2026-05-17)
License: MIT (Copyright © Miguel Piedrafita) — see `LICENSE-swift-realtime-openai`.

## Why this is vendored

klo's voice path uses this library to talk to OpenAI's Realtime API
over WebRTC. Vendoring it (rather than pulling from GitHub via SPM)
gives us:
  - supply-chain control: every byte that ships in klo passes through
    code review on this repo
  - reproducible builds independent of upstream availability
  - the ability to patch fast when OpenAI changes the protocol without
    waiting for the upstream maintainer

## Updating

When upstream ships a fix we want, the upgrade path is:
  1. Diff upstream `main` against our pinned commit
  2. Cherry-pick the relevant Swift changes into `Sources/`
  3. Bump the pinned-commit reference at the top of this file
  4. `xcodebuild -resolvePackageDependencies` and confirm the build
