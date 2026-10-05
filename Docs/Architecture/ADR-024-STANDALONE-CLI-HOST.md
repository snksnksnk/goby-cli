# ADR-024: Standalone `goby` command-line host for distribution

## Status

Proposed on 5 October 2026. Phases 0–5 are implemented in source; the local universal release candidate is signed and notarized. Public distribution and interactive friends-beta acceptance remain pending. Supersedes nothing; amends the product scope in `AGENTS.md` and `Docs/Product/UX_CONTRACT.md` once accepted.

## Context

Goby runs today as a signed macOS app plus an embedded background host (ADR-011). The host owns persistence, routing, Git worktrees, approvals, automations and the provider processes, and it uses the signed-in user's own Codex, Claude and GitHub Copilot subscriptions on the local Mac.

We want people outside the development machine — friends first — to install Goby with Homebrew and use it from a terminal on their own Macs, for their own projects, with their own provider subscriptions. Nothing in that setup involves the author's Mac, the relay, or remote pairing.

Facts from the current source that shape the decision:

- `GobyHostRuntime` is already a library. `Host/GobyHostServiceMain.swift` is only an XPC listener around `GADBackgroundHostRuntime.start(hostVersion:)`, which returns a `GADHostIPCRequestHandler`. The `GADHostIPCRequest` codec is transport-independent.
- `GADBackgroundHostRuntime` also implements the one-time move of persistence from the foreground app to the helper: transfer tickets, authority markers, pre-host backups and checkpoint comparison. A fresh standalone install has nothing to migrate.
- `CodexRuntimeIntegrityValidator` only launches Codex from `/Applications/ChatGPT.app`. The standalone Codex CLI (`~/.codex/packages/standalone/.../codex`) is signed with the same OpenAI Team ID `2DC432GLL2` and identifier `codex`.
- `ProviderRuntimeIntegrity` releases provider credentials only to a root-owned bundle in `/Applications`. Homebrew installs into a user-owned prefix.
- The shared Keychain access group `QKHTGD4FUR.com.demetrisgeorgiou.GobyShared` needs a provisioning profile, which a command-line binary cannot carry. Every `Keychain*Store` already accepts `accessGroup: nil`.
- Claude and Copilot already run through pinned Node bridges (`Helpers/`), with Node 24 and the SDKs pinned by integrity hash in `Scripts/prepare-provider-runtime.sh`.
- `Package.swift` targets macOS 26, so the CLI requires macOS 26 or later.

## Decision

### Product shape

Ship one universal binary, `goby`, that contains the full host engine and a terminal front end. It is the same product as the app — enter a request, confirm scope when needed, run, review one consolidated result — without the map or windows.

- The default command is the request itself: `goby "fix the flaky login test"`. The current Git repository is the scope. Subcommands are for everything else.
- First use is zero-config. `goby` detects installed and signed-in providers, offers to register the current repository, and imports existing `.codex` agent definitions through the existing previewable import flow. It never overwrites them.
- Status uses a symbol plus a word, not just colour, and honours `NO_COLOR`. Every command supports `--json` and has stable exit codes: 0 ok, 1 run failed, 2 needs a decision, 3 host unavailable, 4 policy rejected.
- The terminal front end follows the UX contract's progressive disclosure. It prints outcome, scope, risk, status and required action first. Raw events appear only under `--verbose` or `goby log <run>`.

```text
goby                              interactive prompt in this repo
goby "<request>"                  plan → confirm scope → run → result
goby status | watch [run] | result <run> | diff <run> | log <run>
goby approve <id> | deny <id>     shows the complete disclosure first
goby pause | resume | cancel <run>
goby follow-up <run> "<text>"
goby commit <run> | push <run>    separate approvals, per AGENTS.md
goby ask "<question>"             temporary chat
goby add [path] | projects | use <project…>
goby doctor | login <provider> | logout <provider>
goby host status | stop
```

### Process model: lazy per-user host

- `goby host run` is the host: the same core composition as the app's helper, served over a Unix-domain socket at `~/Library/Application Support/Goby CLI/run/host.sock`. The socket directory is `0700`, and every connection is checked with `getpeereid` against the current user.
- Any other `goby` command connects to that socket and starts the host if it isn't running. The host exits after an idle period with no active runs, pending approvals or due automations. `brew services start goby` is optional and only needed for automations while no terminal is open.
- Closing a terminal never stops a run. `goby "<request>"` attaches to the run and streams events. Ctrl-C detaches, and `goby cancel` cancels.
- Requests reuse the `GADHostIPCRequest` codec, its bounded frames, and version negotiation. If `brew upgrade` leaves an older host running, the new client asks it to drain and exit when idle, then starts the new one. This reuses the drain and checkpoint semantics of the existing in-place restart.

### Host core split

Split `GADHostComposition` and `GADBackgroundHostRuntime` into:

- **Core** (shared): store, provider adapters, routing, Git, approvals, automations, temporary chat, notifications port, and the IPC request handler. It can start in one of two ways:
  - **Fresh standalone:** take the ownership lease (ADR-011) on an empty or CLI-owned store. No transfer ticket, authority marker or pre-host backup.
  - **App helper:** today's migration-aware path, unchanged.
- **macOS app extras:** the XPC listener, `SMAppService`, Remote Access, relay provisioning, and app-update or removal maintenance.

The CLI links Core only. Remote Access is not available in the CLI.

### Trust by signature, not by location

Replace the location checks with an injectable `ProviderRuntimeTrustPolicy`:

- **Codex:** use any regular, non-symlinked executable whose code signature is valid, has Team ID `2DC432GLL2` and identifier `codex`. Locations searched: `/Applications/ChatGPT.app` (preferred), the standalone installer path, Homebrew and `npm -g`. Validate again just before launch and against the running process, as today.
- **Bundled Node and bridges:** verify against a SHA-256 manifest compiled into the Developer-ID-signed `goby` binary. Refuse to launch on any mismatch. This replaces the root-owned `/Applications` requirement for the CLI.
- **The app keeps its stricter policy.** Using signature-based Codex discovery in the app too is a separate decision.

Accepted consequence: a Homebrew prefix can be written by the user. The defence becomes signature and hash checks immediately before every launch, not a root-owned installation. Record this in `Remote/THREAT_MODEL.md` and `SECURITY.md`.

### Credentials and storage

- **Store:** `~/Library/Application Support/Goby CLI/`, separate from the app's store.
- **Keychain:** the user's login Keychain with no access group, and service names prefixed `com.goby.cli.`. No credential is ever written to a file, environment dump or log.
- **Provider sign-in reuses each provider's own login:**
  - **Codex:** the app server uses the user's existing `codex login`, and `goby login codex` hands off to it.
  - **Claude:** `goby login claude` defaults to an Anthropic API key. A subscription token from `claude setup-token` is offered only after the provider-terms check below is resolved.
  - **Copilot:** the Copilot SDK's device flow.
- `goby logout <provider>` removes only Goby's copy.

### Coexistence with the app

App and CLI are independent hosts with separate stores. To stop both working the same repository at once, each host takes an advisory lock in the repository's Git common directory before preparing a worktree. A run that hits the lock waits and says which host holds it. Attaching the CLI to a running app host is out of scope for v1.

### Distribution

- **Homebrew tap** `<owner>/homebrew-goby`. Its formula installs a universal, Developer-ID-signed, hardened-runtime, notarized tarball containing:
  - `bin/goby`
  - `libexec/provider-runtime/`: the pinned Node 24 and the Claude and Copilot bridges already built for the app
  - shell completions
  - a `service do` block
- **Not redistributed:** Codex and Claude Code. `goby doctor` gives exact install commands.
- **Release pipeline:** `release-beta.sh` builds `goby` with `swift build -c release --arch arm64 --arch x86_64`, signs, notarizes, publishes to GitHub Releases, and updates the formula checksum.
- **Platform:** macOS 26+ only. Linux would need `swift-crypto`, a non-Keychain secret store, and replacements for the Darwin and signature checks. It needs its own ADR.

## Open questions to resolve before the friends beta

1. **Provider terms.** Using a personal Claude or ChatGPT subscription through a third-party tool that other people install is governed by each provider's current terms. The Claude Agent SDK documentation has asked third-party products to use API-key authentication unless Anthropic approves otherwise. Confirm the current terms. Until then, default Claude to API keys in the distributed CLI.
2. **Codex signatures.** Confirm that the Homebrew and npm distributions of `codex` carry the same OpenAI Developer ID signature as the standalone installer.
3. **Headless `@MainActor` store.** `AppStore` must run on a plain `dispatchMain()` run loop without SwiftUI. Phase 0 tests this first.

## Implementation phases

Each phase leaves the app's behaviour and tests unchanged.

0. **Feasibility check (smallest end-to-end slice).** An internal executable target builds the existing store in-process against a temporary directory, registers the current repo, and runs one Codex request to a consolidated result. Pass/fail evidence: a headless main-actor store, nil-access-group Keychain, standalone Codex launch, and clean shutdown with a checkpoint. If this fails, revisit the decision before building anything else.
1. **Core split.** Core and app-extras composition, the fresh-standalone start path, `ProviderRuntimeTrustPolicy`, the storage and Keychain namespace, and the repository advisory lock. App tests stay green.
2. **Host and transport.** `goby host run`, the Unix-socket listener with the peer user-ID check, lazy start, idle exit, version handshake with drain-and-replace, and SIGTERM/SIGINT checkpoint.
3. **Terminal workflow.** Default request command, plan confirmation, live activity, approvals with full disclosure, result and diff, pause/resume/cancel, follow-up, `--json`, exit codes. Plan, disclosure and result wording come from shared formatters in `GobyExperience`, so the app and CLI explain things identically.
4. **Packaging.** Release target, signing, notarization, tap and formula, completions, `doctor`, and an uninstall that keeps the store with a pointer to it.
5. **Friends beta.** Install guide, `goby diagnostics` (the existing redacted export), then `commit`/`push`, `ask` and automations through `brew services`.

## Verification

### Phase 0 results (5 October 2026)

**Passed after correcting two headless-composition assumptions.** The temporary
`GobyCLISpike` target is internal and not a package product. It uses a system
temporary store, a plain `dispatchMain()` loop, a silent injected notifier,
`accessGroup: nil`, and Keychain services under `com.goby.cli.spike.*`.
Repeated ad-hoc release builds inject a temporary identifier-alias codec in
the spike to avoid reopening an alias Keychain item created by a differently
signed test binary; the normal standalone runtime persists that key in the
CLI namespace.

| Gate | Result | Evidence |
| --- | --- | --- |
| Headless main-actor store | Pass | `AppStore.load` completed under `dispatchMain()` with no SwiftUI or AppKit import; the spike printed `HEADLESS_STORE=PASS`. |
| nil-access-group Keychain | Pass | The complete fresh-store activation and run used the spike service namespace with `accessGroup: nil`; project registration printed `REGISTERED_PROJECT=PASS`. No app store or app Keychain service was opened by the spike composition. |
| Codex launch | Pass | With DEBUG-only `GOBY_DEVELOPMENT_CODEX_EXECUTABLE`, the installed standalone Codex completed a read-only README summary. The later release spike completed the same run with the standalone signature policy and no override. |
| Clean shutdown with checkpoint | Pass | Both runs reached `ACTIVITY: completed`, printed a consolidated result, flushed operational and coordinator checkpoints, and exited 0 after releasing the lease. |

Commands run and output summaries:

```text
swift build --product GobyCLISpike -j 4
  Build complete! (30.15 sec).
GOBY_DEVELOPMENT_CODEX_EXECUTABLE="$HOME/.codex/packages/standalone/releases/0.157.1-aarch64-apple-darwin/bin/codex" .build/debug/GobyCLISpike
  Initial exit 134: UNUserNotificationCenter.current() required an app bundle.
swift build --product GobyCLISpike -j 4 && GOBY_DEVELOPMENT_CODEX_EXECUTABLE="$HOME/.codex/packages/standalone/releases/0.157.1-aarch64-apple-darwin/bin/codex" .build/debug/GobyCLISpike
  Build complete! (1.21 sec); interrupted after AppStore.load blocked in SecItemCopyMatching.
sample 8873 1 1 -file /tmp/goby-spike-sample.txt
  Main thread: AppStore.load -> KeychainProviderCredentialStore.credential -> SecItemCopyMatching.
```

The first failure was resolved through the existing notifier injection point.
The Keychain failure required a typed namespace parameter in composition;
passing `accessGroup: nil` alone preserved app service names. After this
correction, the DEBUG spike completed the read-only run and checkpoint. The
worktree's Desktop file-provider metadata caused an unrelated SwiftPM resource
signing failure on a subsequent incremental build, so verification used an
external build scratch directory (not a second source checkout):

```text
swift build --scratch-path /tmp/goby-cli-spike-build --product GobyCLISpike -j 4
  Build complete! (27.12 sec).
GOBY_DEVELOPMENT_CODEX_EXECUTABLE="$HOME/.codex/packages/standalone/releases/0.157.1-aarch64-apple-darwin/bin/codex" /tmp/goby-cli-spike-build/debug/GobyCLISpike
  HEADLESS_STORE=PASS; REGISTERED_PROJECT=PASS; readOnly plan with one route;
  ready -> running -> completed; consolidated README summary; CHECKPOINT=PASS; exit 0.
swift build -c release --scratch-path /tmp/goby-cli-release-build --product GobyCLISpike -j 4
  Build complete! (88.53 sec).
/tmp/goby-cli-release-build/release/GobyCLISpike
  HEADLESS_STORE=PASS; REGISTERED_PROJECT=PASS; readOnly plan with one route;
  four succeeded activity steps; completed README summary; CHECKPOINT=PASS; exit 0.
```

### Phase 1 implementation decisions

`GobyHostCore` contains the shared store composition, provider-neutral command
handler, and fresh standalone activation. It has no SwiftUI, AppKit, or app
lifecycle import. `GobyHostRuntime` retains the app helper's migration path,
Remote Access lifecycle, and existing XPC-facing behavior. The fresh mode
acquires the ADR-011 ownership lease before loading its separate CLI store,
then creates an IPC coordinator and flushes its checkpoint; it never reads a
transfer ticket, authority marker, or pre-host backup. The app helper still
uses the original migration-aware path and app Keychain services.

Composition injects a typed Keychain namespace and a runtime trust policy. The
app policy keeps the existing canonical Codex and root-owned `/Applications`
checks. The standalone policy requires the OpenAI `codex` identifier and Team
ID `2DC432GLL2`, rejects symlinked paths, and compares file identity before
launch and again against the running process. Provider Node and bridge files
require an exact compiled-in SHA-256 manifest. The Phase 1 source manifest is
empty and fails closed because Phase 4 has not produced the pinned distributable
runtime; filling and verifying it is a packaging gate, not a release-ready
claim. Core accepts an explicit provider-runtime root; fresh standalone mode
derives the future installed `libexec/provider-runtime` location from its own
executable, while the app helper retains its bundle lookup. The repository
lock is a stable advisory file in the Git common
directory, held from worktree preparation through the run.

The CLI store path is `~/Library/Application Support/Goby CLI/`; CLI Keychain
services use `com.goby.cli.*` with no access group. The temporary spike uses
`com.goby.cli.spike.*`. Local trust and activity preferences use a separate
`com.goby.cli` defaults suite, so the CLI cannot inherit the app's trusted
project decisions. No app store or app Keychain migration occurs.

Provider-terms question 1 remains open for Phase 2 and later. Claude
subscription-token use is not enabled by this work.

### Phase 2 and Phase 3 decisions

The `goby` executable links `GobyCLIKit` and Core. The socket listener uses the
existing bounded `GADHostIPCCodec` with a four-byte big-endian length prefix.
The run directory is created atomically with mode 0700; the listener publishes
its mode-0600 socket only after it is ready. Both endpoints use `getpeereid`.
Partial or oversize connections are closed without entering semantic dispatch.
Blocking socket I/O runs off the main actor with connection and frame bounds.

A per-user startup flock serializes lazy launch. The host starts in a separate
process group with stdio redirected to `/dev/null`, so terminal Ctrl-C cannot
terminate it. Host SIGINT/SIGTERM close admission, drain already admitted
commands, checkpoint Core, release its lease, and remove its socket. Idle
shutdown waits for active/recoverable runs, approvals, pending automation
occurrences, and schedules due within a minute. The source idle timeout is five
minutes; a continuously needed automation host still needs the later service
packaging.

The CLI uses an executable-content fingerprint for exact source-build version
matching. A mismatched client requests the existing permanent-shutdown command,
which the CLI router interprets as drain-when-idle. It preserves run controls
and approval decisions while rejecting new work. If active work prevents
replacement, the client reports host-unavailable (3) and can retry after that
work finishes. No process is forcibly killed. `host status` and `host stop`
inspect an existing host without starting one; this is an intentional exception
to lazy start for other commands.

Core now exposes same-user project inspection/registration and bounded run
inspection. Local IPC advances to version 12 for run-diff inspection; the app
helper rejects that CLI-only command. The shared alias space and approval
receipt checks remain unchanged. Core publishes live store changes to its
coordinator, so client detachment never transfers execution ownership.

The terminal implements the Phase 3 command set, plus `add` and `projects` for
repository registration. `--yes` covers the printed repository and plan only;
it does not auto-accept runtime operations. An explicit `approve <id> --yes`
still fetches and prints the full current disclosure and returns its bound
digest. Raw journal detail is opt-in; normal JSON results contain outcome and
status without embedded journals. Wording for risk, disclosure and result is
shared through `GobyExperience`, with existing app wording retained.

Diff deliberately reports current tracked workspace changes against HEAD,
not a historical patch across earlier commits or untracked contents. It uses
the existing hardened Git boundary and persisted workspace identities, and
redacts credential values before transport. Historical/untracked diff capture
is a remaining limitation. Authentication, doctor, commit/push subcommands,
chat, service integration and packaging stay in their specified later phases.
The empty provider-runtime manifest still fails closed. Provider-terms
question 1 remains unresolved; Claude subscription tokens are not enabled.

A custom `--store` derives an isolated `com.goby.cli.store.<digest>.*`
Keychain namespace and defaults suite from the canonical store path. The
default CLI namespace stays `com.goby.cli.*`. An initial source-build smoke
run blocked in `KeychainRemoteIdentifierAliasKeyStore.load` /
`SecItemCopyMatching` on an alias item created by a different ad-hoc binary.
Only that empty test host was stopped; no existing Keychain item was deleted
or migrated. A fresh custom-store namespace completed the release scenario.
The startup timeout now explains the possible native Keychain dialog and
foreground diagnostic command. Developer-ID signing in Phase 4 remains
necessary for stable access across upgrades.

First-use repository registration preserves native agent definitions. The
product-shape promise of first-use provider selection and agent import is not
yet a terminal command: native-definition trust must retain the existing
preview hashes and device-owner authentication requirement. That work remains
before the friends beta; this phase implements the explicit Phase 3 command
list without claiming the complete zero-config product shape.

Tests use an injected test authenticator and identifier codec to avoid ad-hoc
binary Keychain ACL prompts, while production retains the login Keychain. The
internal `GobyCLIHostFixture` executable exercises process signals with a
system-temporary store. The fake provider test speaks the real app-server
stdio protocol through Core and the socket, without a subscription.

### Phase 2 and Phase 3 verification (5 October 2026)

All commands below ran from the isolated `feature/cli-host` worktree. Build
scratch directories, stores and raw verification logs stayed under system
temporary storage. The original `v3-beta` checkout remained clean.

| Check | Result and output summary |
| --- | --- |
| Complete Swift package suite | Pass, **1,145 tests** in nine test bundles; no test failures. Includes 25 CLI tests and 36 host-runtime tests. |
| CLI contract/integration tests | Pass, **25 tests in six suites**: framed socket bounds, UID check, interrupted clients, startup race, upgrade drain/replacement, idle rules, SIGTERM/SIGINT checkpoint and lease release, text/JSON/exit codes, approval digest binding, controls, fake stdio provider, and linked-worktree diff. |
| Host-runtime target | Pass, **36 tests in three suites**, including fresh standalone activation and preserved app-helper migration behavior. |
| Release CLI build | Pass, `Build complete! (47.77 sec)` with complete strict concurrency and no new warnings. |
| macOS app build | Pass, `** BUILD SUCCEEDED **`; existing app wording and helper activation remain unchanged. |
| Real release Codex request | Pass, exit 0: repository review/registration → read-only plan → activity → completed consolidated README summary, using the standalone release signature policy. |
| Result, diff, restart and shutdown | Pass, each command exit 0. Socket removed after checkpoint; coordinator, operational, catalog, runs and automation files written. A lazy restart restored the completed result, then drained and removed its socket again. |

```sh
Scripts/test-swift-package.sh > /tmp/goby-cli-phase23-full-final.log 2>&1
swift test --scratch-path /tmp/goby-cli-spike-build -j 4 -Xswiftc -strict-concurrency=complete --filter GobyHostRuntimeTests > /tmp/goby-cli-phase23-host-final.log 2>&1
swift build -c release --scratch-path /tmp/goby-cli-release-build --product goby -j 4 > /tmp/goby-cli-phase23-release-verified.log 2>&1
xcodebuild -project "Goby Agentic Dashboard.xcodeproj" -scheme "Goby Agentic Dashboard" -destination platform=macOS -derivedDataPath /tmp/goby-cli-xcode-build CODE_SIGNING_ALLOWED=NO build > /tmp/goby-cli-phase23-xcode-final.log 2>&1

task_store_path=$(mktemp -d /private/tmp/goby-cli-release-verified.XXXXXX)
printf '%s' "$task_store_path" > /tmp/goby-cli-release-verified-store
/tmp/goby-cli-release-build/release/goby 'Summarize this repository README. Do not edit any files.' --yes --json --store "$task_store_path" > /tmp/goby-cli-phase23-live-verified.log 2>&1
```

The verification harness then invoked the same release binary with
`result <returned-run-id>`, `diff <returned-run-id>`, `host status`, and
`host stop`, each with `--json --store <the-same-temporary-store>`. After socket
removal, `result <returned-run-id>` lazily restarted the host and returned
`status: completed`; a final `host stop` removed that socket too. Raw output
is in `/tmp/goby-cli-phase23-live-controls-verified.log`.

The package run reports existing `UnnecessaryEffectMarker` warnings in
`Tests/GobyInfrastructureTests/InfrastructureTests.swift:5299` and macro
expansions of existing test expressions. No new warning or concurrency
warning was introduced. These are the Phase 2/3 results; the later Phase 4/5 release evidence is recorded below.

- **Swift Testing:**
  - socket transport: foreign user ID rejected, oversize frame, version skew, a client crashing partway through a request
  - lazy-start race between two `goby` invocations
  - idle exit blocked by an active run or a pending approval
  - SIGTERM checkpoint
  - trust policy: wrong Team ID, symlink, binary replaced between checks, manifest mismatch
  - repository lock shared between two hosts
  - golden text and JSON output, plus exit-code mapping
- **End to end:** a fake provider bridge speaking the existing bridge protocol, so CI runs `goby "<request>"` without a subscription.
- **Release checks:** universal binary, notarization ticket, formula install on a clean macOS 26 account, `brew upgrade` while a run is active.

## Consequences

- Goby gains a second distribution channel that needs no app install, provisioning profile or `/Applications` placement.
- The host core must stay free of AppKit, SwiftUI and app-lifecycle assumptions. That is enforced by the CLI target linking Core only.
- The trust model for provider runtimes gains a signature-and-hash variant, which needs its own security review.
- `AGENTS.md` and `UX_CONTRACT.md` must be amended. Goby stays an agent-operations product, not a terminal replacement or IDE, and the CLI exposes the same workflow without becoming a general shell.
- `Docs/Product/FUNCTIONALITY.md` gains a CLI section once Phase 3 ships.

### Phase 4 and Phase 5 implementation decisions (5 October 2026)

The remaining source implementation is on `feature/cli-host`. Status remains
**Proposed**. A public friends beta requires the unchecked gates in
`Docs/Beta/CLI_RELEASE_CHECKLIST.md`; source completion does not resolve
provider-terms question 1 or imply clean-account acceptance.

- `release-beta.sh --cli` stages the existing checksum-pinned universal Node,
  Claude SDK and Copilot SDK payloads, runs helper tests and both architecture
  handshakes, signs native files inside out, then generates an ignored Swift
  constant containing every runtime file's SHA-256. The distribution flag
  requires that compiled constant. Source builds still fail closed. The JSON
  sidecar is verification material, never runtime authority. No Codex binary is
  redistributed. CLI signing needs no app provisioning profile or shared
  Keychain entitlement.
- A bare executable or tar archive cannot carry a stapled ticket. Packaging
  therefore submits a signed companion DMG, staples and validates it, checks the CLI notarization requirement with
  `codesign`, and assesses the DMG with `spctl --type open`. Homebrew's universal tar contains the same
  notarized code bytes. This adds a companion artifact to the ADR's tar-only
  description for offline ticket delivery.
- The rendered `homebrew-goby` formula contains the actual archive checksum,
  macOS 26 minimum, bash/zsh/fish completions, and a user service running
  `goby host run --stay-alive`. Lazy hosts retain their five-minute idle exit;
  the explicitly installed service stays available for future schedules.
  Packaging never publishes. `publish-cli-release.sh --publish` requires a
  separately approved, already-pushed tag matching the artifact's recorded
  source commit; it refuses implicit tag creation. The original no-push/no-tag
  session restriction remains in force.
- `doctor` works before host startup. Codex discovery orders standalone
  releases numerically and resolves known Homebrew installer aliases only to
  discover their native payload. Validation and launch use the regular,
  non-symlinked native executable. npm JavaScript launchers cannot satisfy the
  OpenAI code-signature policy. The exact Homebrew/npm signature question
  remains an external beta gate.
- `login` uses verified Codex login, hidden Claude API-key entry, or GitHub
  CLI's documented device sign-in credential source. Only CLI Keychain copies
  are saved. Credentials never enter command arguments, logs or socket IPC.
  Claude's fresh-standalone composition refuses saved subscription tokens and
  ambient Claude sign-in; the app retains its existing policy. Copilot is
  eligible in the standalone composition without changing the app's parked
  providers. This implements the API-key default while carrying question 1
  forward, without settling provider terms for distribution.
- `use` persists explicit project scope in a CLI-only defaults suite. Native
  agent import shows the complete discovered instruction copies and uses the
  existing hash-bound host-admin preview plus device-owner authentication.
  Original definitions are preserved. Registration offers import instead of
  copying silently. The shared automation validator refuses definitions with
  no eligible provider agent.
- Completed-run `commit` and `push` are separate local-only typed commands.
  Their one-use, expiring reviews bind repository identity, all nonignored
  file bytes, HEAD, index, branch and remote; any stale value invalidates the
  review. Delivery takes the repository advisory lock and reuses the hardened
  Git execution/approval policy. Only one unchanged completed workspace is
  accepted; no force, tags, merge, reset, rebase or branch deletion is exposed.
  Remote destinations are identified without printing credential values or
  full local paths. The app helper rejects these CLI-only commands.
- `ask`, `diagnostics` and automation controls use existing shared contracts.
  Temporary chat cache moves to the CLI Caches namespace outside its backed-up
  store. New daily automations start paused, retain manual runtime approvals,
  and mutations bind definition revisions. Occurrence review shows the shared
  full plan and authenticates sensitive changes. Draining permits existing
  occurrence review/cancellation and pausing, but rejects new work.
- `uninstall` reviews retention, drains the host, refuses busy teardown,
  stops the Homebrew service and removes the package. The separate CLI store,
  Keychain items and caches survive. It never opens or migrates the app store.

The product inventory and terminal UX contract now describe these implemented
commands and the pending public distribution gates. An install guide and
maintainer checklist are included in the package. New Swift Testing coverage
uses temporary repositories and a local bare remote only; no production push
or provider credential changes were performed by the tests.


### Phase 4 and Phase 5 verification results (5 October 2026)

The final candidate records source commit
`f5612cec3b16e2913d1fb5052eab7bfe445dd8ab` in `SourceCommit.txt`.
Later changes correct the release assessment command and record this evidence;
they do not change that candidate's Swift or runtime bytes. Verification and
artifacts are outside Git. The main `v3-beta` checkout remains clean at
`1898f85`; all implementation commits are local on `feature/cli-host`.
No branch, tag, GitHub release or tap was published.

| Gate | Result | Evidence/output |
| --- | --- | --- |
| Complete package suite | Pass | **1,158 tests**, nine bundles, zero failures: 29 + 24 + 246 + 446 + 36 + 66 + 69 + 38 + 204. `/tmp/goby-cli-phase45-full-final.log`. |
| CLI Swift Testing | Pass | **38 tests in seven suites**, including real fixture commits/local-remote pushes, stale delivery reviews, hidden credential entry, API-only Claude, import preservation, temporary chat, diagnostics, automation revisions, transport and drain/replacement. `/tmp/goby-cli-phase45-tests-final.log`. |
| Host-runtime target | Pass | **36 tests in three suites**, including fresh activation and the original app-helper ownership/migration path. `/tmp/goby-cli-phase45-host-final.log`. |
| Existing macOS app | Pass | `** BUILD SUCCEEDED **`. No app store/Keychain migration or provider policy change. `/tmp/goby-cli-phase45-xcode-final.log`. |
| Pinned bridges | Pass | Node **24.20.0**, Claude SDK **0.3.263**, Copilot SDK **1.0.13**; **39 Claude + 16 Copilot tests**, zero failures; type checks and both architecture handshakes before and after signing. `/tmp/goby-cli-phase45-final-candidate.log`. |
| Universal release and signatures | Pass | `Build complete! (115.50 sec)`. Every runtime Mach-O and `goby` is arm64/x86_64, strict Developer-ID signed with hardened runtime. Node retains its V8 exceptions; `goby` has no shared Keychain/app group, and no provisioning profile is packaged. |
| Compiled manifest | Pass | **1,238 exact runtime entries**. Extracted archive verifies; a changed bridge plus rewritten sidecar returns 4, a symlinked bridge returns 4, and restored original bytes pass. Doctor does not start a host. `/tmp/goby-cli-phase45-final-extracted-check.log`, `/tmp/goby-cli-phase45-final-tamper.log`. |
| Real signed Codex workflow | Pass | Plan, streamed activity and consolidated README result; diagnostics; temporary chat answer/clear; diff; checkpoint/socket removal; lazy restart restores completed result. All commands exit 0 with a temporary CLI store and standalone signature policy. `/tmp/goby-cli-phase45-final-live-summary.log`. |
| Notarization and assessment | Pass | Apple status **Accepted**; `The staple and validate action worked!`; `The validate action worked!`; CLI `explicit requirement satisfied`; DMG `accepted`, `source=Notarized Developer ID`. `/tmp/goby-cli-phase45-staple.log`, `/tmp/goby-cli-phase45-code-notarization.log`, `/tmp/goby-cli-phase45-dmg-gatekeeper.log`. |
| Archive/formula consistency | Pass | Both `SHA256SUMS` entries report `OK`; rendered formula contains the actual archive SHA-256; Ruby reports `Syntax OK`. |
| Homebrew formula loading/install | Not passed here | Installed older Homebrew rejects host macOS 27.2 before formula loading. Clean macOS 26/current Homebrew acceptance remains required. |
| Friends-beta acceptance | Pending | Real provider sign-in/native prompts, clean-account installation, service logout/login recovery, active-run upgrade and uninstall/reinstall remain unchecked. Provider-terms question 1 and exact Homebrew/npm Codex signature question 2 remain open. |

The complete suite already includes the CLI and host counts; the filtered runs
are additional verification, not additional distinct tests. No new warnings
or strict-concurrency warnings remain. Existing package warnings are
`UnnecessaryEffectMarker` in `InfrastructureTests.swift:5299` and its test macro
expansions. Xcode emits its existing AppIntents metadata-skipped notices.

Commands run (from the isolated worktree unless an absolute path is shown):

```sh
Scripts/test-swift-package.sh -j 4 > /tmp/goby-cli-phase45-full-final.log 2>&1
swift test --scratch-path /tmp/goby-cli-spike-build -j 4 -Xswiftc -strict-concurrency=complete --filter GobyCLIKitTests > /tmp/goby-cli-phase45-tests-final.log 2>&1
swift test --scratch-path /tmp/goby-cli-spike-build -j 4 -Xswiftc -strict-concurrency=complete --filter GobyHostRuntimeTests > /tmp/goby-cli-phase45-host-final.log 2>&1
xcodebuild -project 'Goby Agentic Dashboard.xcodeproj' -scheme 'Goby Agentic Dashboard' -configuration Debug -derivedDataPath /tmp/goby-cli-xcode-build CODE_SIGNING_ALLOWED=NO build > /tmp/goby-cli-phase45-xcode-final.log 2>&1
GOBY_CLI_RELEASE_DIRECTORY=/tmp/goby-cli-phase45-final-candidate Scripts/release-beta.sh --cli --signed-only > /tmp/goby-cli-phase45-final-candidate.log 2>&1
python3 Scripts/verify-cli-release.py /tmp/goby-cli-phase45-final-installed > /tmp/goby-cli-phase45-final-extracted-check.log 2>&1
python3 /tmp/goby-cli-release-smoke.py /tmp/goby-cli-phase45-final-installed/bin/goby > /tmp/goby-cli-phase45-final-live-summary.log 2>&1
python3 /tmp/goby-cli-final-manifest-tamper.py > /tmp/goby-cli-phase45-final-tamper.log 2>&1
```

The temporary smoke harness executes the signed binary with `--provider codex
--json --store <short-system-temp-directory>` for a README summary (`--yes`),
`diagnostics`, `ask`, `ask end`, `diff <returned-run-id>`, `host stop`, and
`result <returned-run-id>`, followed by final shutdown. It writes the full output
to `/tmp/goby-cli-phase45-live.log`. Coordinator and operational checkpoints,
catalog, runs, automations and previous checkpoint files were present before
restart; the final socket was removed. This is a real provider request, not the
fake bridge used by automated tests.

The notarization profile was intermittently unavailable during packaging, so
`--signed-only` produced the verified candidate first. Once the existing profile
was available again, the exact extracted candidate was placed into a signed
DMG and promoted without rebuilding or changing code bytes:

```sh
hdiutil create -quiet -volname 'Goby CLI 0.2.0-beta.1' -srcfolder /tmp/goby-cli-phase45-final-installed -format UDZO /tmp/goby-cli-phase45-notarized/goby-0.2.0-beta.1-universal.dmg
codesign --force --timestamp --sign '<existing Developer ID Application identity>' /tmp/goby-cli-phase45-notarized/goby-0.2.0-beta.1-universal.dmg
xcrun notarytool submit /tmp/goby-cli-phase45-notarized/goby-0.2.0-beta.1-universal.dmg --keychain-profile goby-notary --wait --output-format json > /tmp/goby-cli-phase45-notarized/notary.json
xcrun stapler staple /tmp/goby-cli-phase45-notarized/goby-0.2.0-beta.1-universal.dmg
xcrun stapler validate /tmp/goby-cli-phase45-notarized/goby-0.2.0-beta.1-universal.dmg
codesign --verify --verbose=4 --strict --check-notarization -R=notarized /tmp/goby-cli-phase45-final-installed/bin/goby
spctl --assess --type open --context context:primary-signature --verbose=2 /tmp/goby-cli-phase45-notarized/goby-0.2.0-beta.1-universal.dmg
ruby -c /tmp/goby-cli-phase45-notarized/homebrew-goby/Formula/goby.rb
```

The signing identity is intentionally omitted from documentation; it was the
existing Developer ID Application identity, not a new credential. The tar was
copied unchanged from the final signed candidate, the formula rendered with its
actual hash, and both hashes verified using `shasum -a 256 -c SHA256SUMS` from
`/tmp/goby-cli-phase45-notarized`. That directory contains the tar, stapled DMG,
notary receipt, hash list and rendered tap. The corrected `release-beta.sh --cli`
and explicit publication script now perform these assessments directly. The
publication script itself was not executed. The entire normal-mode pipeline was
not rerun after promotion; each corrected assessment passed against the same
Accepted candidate. No Gatekeeper bypass or quarantine removal was used.

#### Failures encountered and corrections

- A bare CLI assessed with the app-oriented `spctl --type execute` returned:
  `rejected (the code is valid but does not seem to be an app)`.
  The release script now uses Apple's documented non-app `codesign` notarization
  requirement and DMG open assessment; both passed. See
  [Apple DTS: Testing a Notarised Product](https://developer.apple.com/forums/thread/130560).
  These local checks do not replace a quarantined download on a fresh Mac.
- The existing notarization profile temporarily returned:
  `Error: No Keychain password item found for profile: goby-notary`.
  Signed-only verification proceeded without fabricating credentials. The
  existing profile later became available and Apple accepted the same candidate.
- One overlapping Swift test/build saw a missing generated manifest compiler
  input when packaging's exit cleanup removed it. The diagnostic was:
  `Build input file cannot be found: '<worktree>/Sources/GobyInfrastructure/GeneratedCLIProviderManifest.swift'. Did you forget to declare this file as an output of a script phase or custom build rule which produces it?`
  (Only the private source-root path is redacted.) The sequential rerun passed;
  the maintainer guide requires packaging to run separately from Swift/Xcode
  builds. A future build-isolated generated-source mechanism could remove this
  restriction.
- Earlier installed Homebrew returned:
  `unknown or unsupported macOS version: "27.2" (MacOSVersion::Error)`.
  Ruby parsing passed, but Homebrew formula loading was not claimed. Its
  automatic developer-mode side effect was restored to the original off state.
- The first smoke harness used a long default system-temporary path and hit the
  existing Unix socket length bound. Its store was moved to a short directory
  under `/private/tmp`; the signed workflow passed. This was a harness correction,
  not a transport boundary change.

#### Files grouped by target/responsibility (Phases 4–5)

| Target/responsibility | Added or changed files |
| --- | --- |
| Application contracts | `CLIDeliveryContract.swift`, `HostIPCContract.swift` (local IPC 13). |
| Host Core | `GADHostComposition.swift`, `GADFreshStandaloneRuntime.swift`, `StandaloneLocalAdministration.swift`. |
| Infrastructure | `RunDeliveryService.swift`, `GitWorkspaceManager.swift`, `ProviderRuntimeTrustPolicy.swift`, `ClaudeAgentSDKRuntimeAdapter.swift`. |
| CLI kit / experience | `SetupCommands.swift`, `ProjectPreferences.swift`, `TerminalWorkflow.swift`, `CLIEntrypoint.swift`, `HostLifecycle.swift`, `WorkflowTextFormatter.swift`. |
| App boundary | `App/RemoteAccessController.swift` explicitly refuses CLI-only delivery commands; app workflows/policies are retained. |
| Swift Testing | `Tests/GobyCLIKitTests/CLIBetaTests.swift`, `CLIWorkflowTests.swift`. Existing trust, repository-lock, activation, app-helper, transport and recovery tests remain green. |
| Build/release | `.gitignore`; `Scripts/release-beta.sh`, `release-cli.sh`, `publish-cli-release.sh`, `generate-cli-manifest.py`, `sign-cli-runtime.py`, `verify-cli-release.py`, `render-cli-formula.py`. Generated manifest Swift is ignored, temporary and absent after packaging. |
| Packaging | `Packaging/CLI/homebrew-goby/Formula/goby.rb.in`, tap `README.md`, bash/zsh/fish completions. |
| Documentation | This ADR, `Docs/Beta/CLI_GUIDE.md`, `CLI_RELEASE_CHECKLIST.md`, `Docs/Product/FUNCTIONALITY.md`, `UX_CONTRACT.md`, `CHANGELOG.md`, `SECURITY.md`, `Remote/THREAT_MODEL.md`. |

`FUNCTIONALITY.md` was verified against implemented CLI commands and explicitly
marks distribution pending. No macOS app functionality was added or removed by
these phases. Remaining beta risks are the unresolved provider terms and Codex
distribution signatures, real native credential/owner prompts, the clean-account
install, per-user service recovery and retained-store uninstall. Homebrew's
cleanup can remove an old keg's SDK files while its preserved host is busy;
finish/drain before upgrading, and retain the old keg with
`HOMEBREW_NO_INSTALL_CLEANUP=1` for the pending active-run acceptance test.

Final release-script validation also passed: `zsh -n` separately for
`Scripts/release-cli.sh`, `Scripts/publish-cli-release.sh` and
`Scripts/release-beta.sh`; `bash -n Packaging/CLI/completions/goby.bash`;
`zsh -n Packaging/CLI/completions/_goby`; Python `compile` for all four CLI
packaging helpers; and `git diff --check`. The notarization requirement, DMG
assessment and stapler validation were repeated after manifest fixtures restored
the payload and passed. The final temporary host is stopped, its coordinator
checkpoint remains, and the ignored generated Swift manifest has been removed.

### Repository split (5 October 2026)

The CLI moved to its own repository, `goby-cli`, so release assets can be
published without exposing the private app repository. It was created from
`feature/cli-host` at `4fff867` with only the modules the `goby` executable
needs: Domain, Application, Infrastructure, Remote Contract, Remote Transport,
Experience, Operations, Host Core, CLI Kit, the CLI and its test fixture host.
The app UI, design system, app helper runtime, iOS, Android, relay and the
temporary `GobyCLISpike` target were left out. Earlier verification evidence
above refers to the original worktree and paths.

The same change fixed the repository advisory lock. One host now holds one
lease per repository and shares it across its runs, releasing it with the last
run. Separate hosts still exclude each other. Previously each run opened its
own lock, so parallel requests in the same repository (ADR-020) waited 60
seconds and then failed, in both the CLI and the app. The app repository needs
the same fix before `feature/cli-host` is merged there.
