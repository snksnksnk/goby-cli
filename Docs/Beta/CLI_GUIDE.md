# Goby CLI friends beta

Goby CLI requires macOS 26 or later. It runs on your Mac with your own provider
account. It does not contact the author's Mac or enable Remote Access.

## Release status

The CLI lives in its own repository, `snksnksnk/goby-cli`. A local universal
candidate has passed Developer ID signing, Apple notarization, stapling,
runtime-manifest verification and a real Codex workflow. Public GitHub assets
and the `snksnksnk/homebrew-goby` tap require release approval and publication.
Until then, use a locally verified artifact or the source build; the Homebrew
command below becomes available only after publication. Provider terms question
1 in ADR-024 remains a friends-beta gate. Claude subscription credentials are
disabled; use an Anthropic API key.

## Install and first request

After the signed release and tap are published:

```sh
brew install snksnksnk/goby/goby
goby doctor
goby login codex
cd /path/to/your/repository
goby "Summarize the README without changing any files."
```

Goby offers to register the repository in its separate CLI store, shows its
plan, asks for a scope decision when required, and prints one result. A subfolder
invocation uses the enclosing Git repository. Default requests use the current
repository; `goby use <project-id> [<project-id> ...]` explicitly overrides that
scope until `goby use cwd`. Find IDs with `goby projects`.

Goby prefers a connected Codex account, then a single connected provider. If
several other providers are connected, choose `--provider claude|copilot|codex`.
Existing `.codex/agents` definitions are offered for review. `goby import-agents`
prints the complete importable instruction bodies and previews the effects;
macOS device-owner authentication authorizes the instruction-only copies.
Source definitions and their tool configuration are never overwritten.

### Provider sign-in

- **Codex:** install the provider's signed executable (`brew install --cask codex`),
  then `goby login codex`. Goby hands off to `codex login`, validates the executable
  before launch and checks the running process. Unsigned distributions are refused.
- **Claude:** `goby login claude` reads an API key with echo disabled and saves it
  only in the login Keychain. No key argument or environment dump is accepted.
  Existing Claude.ai or Claude Code sign-in cannot substitute for an API key.
- **Copilot:** install GitHub CLI (`brew install gh`), then `goby login copilot`.
  The supported SDK authentication uses GitHub CLI's OAuth browser/device flow;
  Goby saves its own token copy in CLI Keychain. This uses the SDK's documented
  GitHub CLI credential source instead of inventing an OAuth client registration.

Sign-in needs an interactive terminal. `goby logout <provider>` removes only
Goby's credential copies; it does not log out Codex, Claude Code or GitHub CLI.
The app's store and shared Keychain group are never used by the CLI.

## Review and control

```sh
goby status
goby run <plan-id>
goby watch <run-id>
goby result <run-id>
goby diff <run-id>
goby log <run-id>
goby approve <approval-id>
goby deny <approval-id>
goby pause <run-id>
goby resume <run-id>
goby cancel <run-id>
goby follow-up <run-id> "Explain that step."
```

Ctrl-C detaches the client. Closing the terminal leaves the host-owned run
running. `--yes` confirms the printed repository/plan or the named administrative
operation; it never grants blanket runtime approvals or skips native owner
authentication. `approve` fetches the full current disclosure and binds an
allow-once response to its digest. `--verbose` adds activity detail; `log` exposes
journal detail explicitly. `--json` emits versioned JSON lines with no raw
journals in ordinary result output. Exit codes: 0 success, 1 failed, 2 decision
needed, 3 host unavailable, 4 policy rejected. `NO_COLOR` is supported; status
always has a symbol and a word.

`diff` shows current tracked workspace changes against HEAD. It does not capture
untracked or already committed historical patches.

### Commit and push

```sh
goby commit <completed-run-id>
goby push <completed-run-id>
```

Each command has a separate review. Only a completed run with one unchanged
working-copy identity and a named branch qualifies. The review binds tracked
and untracked file bytes, the index, HEAD and remote; a change invalidates it.
Commit includes all reviewed nonignored changes. Push targets the reviewed
branch on `origin`, or the sole remote, without force or tags. Embedded remote
credentials are refused. A push never authorizes a commit. No merge, reset,
rebase, tag, branch deletion or history rewrite command is provided. Review
limits are 10,000 files, 16 MiB per file and 256 MiB total; symlinked delivery
files are refused. Multiple-project delivery requires separate work before it
can be exposed safely. A failed push retains any completed commit for review.

### Temporary questions and diagnostics

```sh
goby ask "What does a Git worktree do?"
goby ask end
goby diagnostics --json
```

Temporary chat uses the existing no-tools, ephemeral service. It is outside any
project, not stored in run history, and ends on explicit clear, idle expiry or
host restart. Its disposable cache is in the CLI's Caches namespace outside the
store. Diagnostics use the existing redacted export, excluding prompts, names,
paths, outcomes, credential values and raw provider logs. Review the export
before voluntarily sharing it.

## Automations

```sh
goby automation add "Daily README review" 09:00 "Summarize the README"
goby automations
goby automation resume <automation-id>
brew services start goby
```

Schedules use the current time zone and a daily HH:MM. New definitions are
paused and have manual runtime approvals. Pause/resume/run/delete commands
revalidate the displayed revision. `automation review <occurrence-id>` reviews
the current bound action plan; medium/high risk and Git work require native
owner authentication. Pending provider approvals still use `goby approve`.
`automation cancel <occurrence-id>` cancels that occurrence. The shared planner
and approval policy determine whether an action can run automatically; push
and history-changing work cannot be authorized through the occurrence review.

`brew services` runs `goby host run --stay-alive` as a per-user LaunchAgent.
Without the service, lazy hosting exits after five idle minutes and will not
wake itself for distant schedules. `goby host stop` requests a drain. Stop the
Homebrew service when you intend to keep it stopped, because launchd otherwise
restarts it. `brew services stop goby` sends termination; the host checkpoints
recoverable work. Approvals and provider recovery can still need attention on
restart.

## Upgrade, recovery and uninstall

Finish active work before service upgrades. A source/build mismatch requests
an idle drain and replacement; a busy older host is preserved and the client
returns 3. The source test covers this handshake; a real Homebrew upgrade and
clean-account beta installation remain release checklist items.

```sh
goby host status
goby uninstall
```

Uninstall reviews removal, requests a drain and refuses while the host still
has work preventing exit. It stops the Homebrew service and removes only the
CLI package. Storage remains at `~/Library/Application Support/Goby CLI/`;
CLI Keychain items and CLI caches remain too. Reinstall and reuse that same
store to recover. Plain `brew uninstall goby` also retains the store, but stop
its service first. `--store <path>` uses a separate store and a digest-specific
`com.goby.cli.store.*` Keychain namespace. It refuses the app store or a child of
it. Never delete a store to troubleshoot an approval or interrupted run.

## Maintainer build

```sh
Scripts/test-swift-package.sh
Scripts/release-beta.sh --cli --preflight
Scripts/release-beta.sh --cli
```

The last command requires a clean reviewed commit, prepares the pinned universal
Node/SDK bridges, signs them, generates ignored Swift manifest constants, builds
universal `goby`, signs it, verifies signatures and the compiled manifest, and
notarizes a companion DMG. The DMG receives a stapled offline ticket. The tarball
contains the same notarized code bytes; a bare executable/tar cannot be stapled.
Artifacts and a formula with the exact checksum are local under `.build/cli-releases`
(or `GOBY_CLI_RELEASE_DIRECTORY`); nothing is pushed, tagged or published.
`--local` is ad-hoc verification only and never produces a publishable formula.
Notarization secrets stay in Keychain, never source or artifacts. The release
checks the bare CLI with `codesign -R=notarized --check-notarization` and the DMG
with `spctl --type open --context context:primary-signature`, following
[Apple DTS guidance](https://developer.apple.com/forums/thread/130560). A fresh
Mac test with a quarantined download remains a separate beta gate.

Publication must follow review of the artifact checksum, source commit and
notarization evidence, plus the gates in `CLI_RELEASE_CHECKLIST.md`.

Automation creation requires an eligible agent in the registered provider plane.
Run `goby import-agents` first when the repository has native definitions. If no
agent is eligible, the shared automation validator refuses the definition.

Publication is a separate maintainer step after release gates and approval:
`Scripts/publish-cli-release.sh --publish <release-directory>` validates the
artifacts and requires an existing pushed `goby-v<version>` tag matching
`SourceCommit.txt`; it cannot create a tag. Publish the rendered `homebrew-goby`
repository separately after its own approval. Packaging never publishes.

If the notarization profile is unavailable, maintainers can run
`Scripts/release-beta.sh --cli --signed-only` to verify a Developer-ID-signed
local candidate. Its filename is prefixed `signed-unnotarized-`, no public
formula is emitted, and the publication script refuses it. This diagnostic
mode does not satisfy the notarization or friends-beta release gates.

Run packaging separately from other Swift/Xcode builds: its ignored generated
manifest is a temporary compiler input and is removed on exit. Use an up-to-date
Homebrew on supported macOS; an older Homebrew can reject newer macOS versions
before loading the formula.

Homebrew [automatically removes older formula versions during upgrades](https://docs.brew.sh/FAQ).
The socket handshake preserves a busy old host, but cannot preserve SDK files
that an external package-manager cleanup deletes. Finish and drain active work
before upgrading. For the pending active-run upgrade acceptance test, set
`HOMEBREW_NO_INSTALL_CLEANUP=1` and retain the old keg until its host exits; a
normal cleanup while old provider processes are active is an open beta risk.
