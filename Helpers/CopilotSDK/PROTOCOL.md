# Goby GitHub Copilot bridge protocol

The helper uses newline-delimited JSON-RPC 2.0 over standard input and output. Swift requires exact protocol `1.1` for provider execution and task discovery.

Methods:

- `initialize` negotiates helper, SDK, and protocol versions without starting the Copilot runtime or authenticating.
- `account/read` reports explicit Goby credential and GitHub Copilot account state.
- `tasks/list` returns read-only persisted Copilot session metadata for reviewed project roots.
- `assignment/start` creates a local SDK session using Goby's immutable assignment inputs.
- `assignment/interrupt` aborts the active message without deleting persisted session history.
- `approval/respond` resolves one pending Copilot permission request only when its provider-native ID, assignment ID, and exact operation digest still match.
- `shutdown` aborts active work, rejects pending permissions, and stops the SDK runtime.

Protocol 1.1 requires every project root, assignment working directory and shared resource to carry its reviewed filesystem device/inode/kind using decimal strings. Local file attachments additionally carry their reviewed SHA-256 digest. The signed helper opens each object without following the final link, compares the exact identity before handing its canonical path to the provider, retains the verified descriptor for the assignment lifetime, and rechecks both pathname identity and attachment bytes before tool callbacks and permission release. Missing 1.1 identity fields fail closed; path-only 1.0 helpers are incompatible. The opaque SDK still consumes pathnames, so a kernel-atomic descriptor handoff is not available; any drift detected at the helper boundary aborts the session.

The helper accepts a GitHub token only through `GOBY_COPILOT_GITHUB_TOKEN`, which the signed Swift host supplies from Keychain. It creates the SDK client with `useLoggedInUser: false`, removes ambient GitHub token variables from the child-runtime environment, disables session telemetry, remote export, memory, discovered configuration, file hooks, skills, and scheduling, and never writes the credential into protocol messages or diagnostics.

Assignments emit `assignment/started`, `assignment/progress`, `approval/required`, `command/completed`, `usage/updated`, `assignment/completed`, and `assignment/failed` notifications. The Swift runtime adapter converts those messages into the provider-neutral Goby contracts.

Every `approval/required` notification carries the complete deterministic JSON permission request, its SHA-256 `operationDigest`, and `disclosureComplete`. Requests that cannot be serialized without loss or fit within 8,000 UTF-8 bytes are decline-only. An accepting `approval/respond` must echo the digest; the helper recomputes and constant-time compares it immediately before releasing the retained request.
