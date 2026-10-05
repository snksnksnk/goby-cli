# Goby GitHub Copilot SDK helper

This pinned Node.js helper isolates the official `@github/copilot-sdk` behind Goby's typed, newline-delimited JSON-RPC protocol.

Requirements:

- Node.js 22.12 or newer for the packaged helper
- A GitHub OAuth user, GitHub App user, or fine-grained token explicitly stored by Goby

Local checks:

```sh
npm ci
npm run check
npm test
```

The `initialize` handshake and missing-credential account check never contact GitHub. Live account and assignment checks are opt-in and require a user-provided credential.
