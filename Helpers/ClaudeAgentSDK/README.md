# Goby Claude Agent SDK bridge

This private helper is the process boundary between the native Swift app and
Anthropic's TypeScript Agent SDK. It speaks newline-delimited JSON-RPC 2.0 on
standard input/output. Diagnostic logging belongs on standard error so it can
never corrupt the protocol stream.

The bridge deliberately keeps provider-specific behavior outside Goby's core:

- Claude sessions become provider task IDs; they are never shared with Codex
  or GitHub Copilot.
- Tool permission requests become Goby approvals and remain suspended until
  the native app responds.
- A `PreToolUse` hook enforces non-negotiable local safety checks before the
  interactive approval callback.
- Result cost is reported as an estimate, never as a subscription quota.
- Settings sources are disabled for an execution unless Goby explicitly sends
  reviewed settings in a future protocol revision.

Development commands:

```sh
npm ci
npm run check
npm test
npm run build
```

The packaged macOS app must include a pinned, built copy of this helper and its
runtime dependencies. Production packaging must not fetch packages from the
network.
