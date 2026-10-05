# Provider helper processes

This directory owns the typed process bridges for providers that do not use the Codex App Server.

- `ClaudeAgentSDK/` wraps the pinned Anthropic Agent SDK.
- `CopilotSDK/` wraps the pinned GitHub Copilot SDK.

Both helpers speak Goby bridge protocol 1.1 over bounded newline-delimited JSON. They translate provider authentication, sessions, approvals, usage, cancellation, and events; they do not own routing, Git policy, resources, verification, persistence, or recovery.

Each helper's `README.md` owns local development commands. Its `PROTOCOL.md` owns the wire contract. Package versions remain pinned in that helper's lockfile.
