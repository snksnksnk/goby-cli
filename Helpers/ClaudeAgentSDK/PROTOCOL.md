# Claude bridge protocol 1.1

All messages are JSON-RPC 2.0 objects separated by a newline.

Requests from Goby:

- `initialize`: negotiate protocol and helper/SDK versions.
- `account/read`: return truthful authentication hints, `credentialRoute` (`subscription`, `apiKey` or `claudeCodeLogin`), `subscriptionConfigured`, `apiKeyConfigured`, `subscriptionPausedUntil` (ISO 8601, only while a subscription limit is in effect), `subscriptionType` (`pro`, `max`, …), `usage.rateLimits` with the plan's `five_hour`, `seven_day` and per-model windows (utilization as a 0–1 fraction, `resetsAt` in epoch seconds) read like Claude's `/usage` from a prompt-less session at most once a minute, last observed usage and `availableModels`, the model ids Claude lists for this account. The list comes from a session opened with no prompt and closed once it answers, so no model request is made; it is kept for ten minutes, and an empty or failed answer is retried after a minute.
- `tasks/list`: list resumable Claude sessions for registered project roots.
- `assignment/start`: start one Claude query in an exact project working copy.
- `assignment/interrupt`: interrupt one active assignment.
- `approval/respond`: resolve one suspended SDK permission callback only when its provider-native ID, assignment ID, and exact operation digest still match.
- `chat/ask`: answer one temporary-chat question (`prompt`, optional `model`) and return `{ text }`. Runs with no built-in tools, MCP servers, settings or saved session, one turn, in a fresh empty folder that the sandbox may read but not write, and denies every tool request. Advertised as the `temporaryChat` capability.
- `shutdown`: deny unresolved approvals, interrupt work, and exit cleanly.

Protocol 1.1 requires every project root, assignment working directory and shared resource to carry its reviewed filesystem device/inode/kind using decimal strings. Local file attachments additionally carry their reviewed SHA-256 digest. The signed helper opens each object without following the final link, compares the exact identity before handing its canonical path to the provider, retains the verified descriptor for the assignment lifetime, and rechecks both pathname identity and attachment bytes before tool callbacks and permission release. Missing 1.1 identity fields fail closed; Swift does not negotiate a path-only 1.0 execution session. The opaque SDK still consumes pathnames, so a kernel-atomic descriptor handoff is not available; any drift detected at the helper boundary interrupts the assignment.

Notifications from the bridge:

- `assignment/started`
- `assignment/progress`
- `approval/required`
- `command/completed`
- `usage/updated`
- `assignment/completed`
- `assignment/failed`
- `credential/changed`: a subscription usage limit moved work to the API key; carries `credentialRoute` and `subscriptionPausedUntil`.

Credentials: Goby passes a Claude Pro/Max subscription token as `GOBY_CLAUDE_SUBSCRIPTION_TOKEN` and an Anthropic API key as `GOBY_CLAUDE_API_KEY`. Each query receives exactly one of them, as `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`. The subscription is the default. When it reports a usage limit (a rejected `rate_limit_event` without extra usage, a `rate_limit` or `billing_error` assistant error, or a usage-limit failure), the bridge pauses it until the reported reset (an hour when none is given). If an API key is saved, the running assignment resumes its Claude session on the API key instead of failing, and new work uses the API key until the reset. With neither credential, Claude Code's own sign-in on the Mac is used.

Every `approval/required` notification carries the complete deterministic JSON operation, its SHA-256 `operationDigest`, and `disclosureComplete`. Requests that cannot be serialized without loss or fit within 8,000 UTF-8 bytes are decline-only. An accepting `approval/respond` must echo the digest; the helper recomputes and constant-time compares it immediately before releasing the retained input. Provider descriptions may summarize the operation but never replace its canonical details.

The bridge accepts at most one active query for an assignment ID. Duplicate
starts are rejected. Approval IDs are one-shot and decisions for unknown or
already resolved approvals are rejected.
