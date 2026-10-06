# Goby CLI friends beta

Goby CLI requires macOS 26 or later. It runs on your Mac with your own provider
account. It does not contact the author's Mac or enable Remote Access.

## Release status

goby is published as a beta: source at https://github.com/snksnksnk/goby-cli,
signed and notarized releases on its Releases page, and the Homebrew tap
`snksnksnk/homebrew-goby`. Claude accepts your plan token (from
`claude setup-token`) or an API key; check each provider's terms before
sharing builds that sign in with a plan (ADR-024 question 1).

## Install and first request

```sh
brew tap snksnksnk/goby
brew install goby
goby doctor
goby login codex
cd /path/to/your/repository
goby "Summarize the README without changing any files."
```

Without Homebrew, download `goby-<version>.pkg` from the release page and
double-click it. The signed, notarized installer puts goby in `/usr/local/goby`
and links `/usr/local/bin/goby`. Update by installing a newer package; remove it
with `/usr/local/goby/uninstall-goby.sh`, which keeps your data and sign-ins.
The installer refuses to replace a Homebrew-managed goby.

Adding the tap is a one-time step; after it, `brew install goby`,
`brew upgrade goby` and `brew uninstall goby` work by name. `brew install
snksnksnk/goby/goby` does both steps in one command.

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

Each provider can use a login or plan you already have:

- **Codex:** install the provider's signed executable (`brew install --cask codex`).
  If Codex is already signed in with your ChatGPT plan or an API key, Goby uses
  that login and `goby login codex` just confirms it. Otherwise it hands off to
  `codex login`. `--device` signs in with a code, for a remote or headless Mac;
  `--api-key` pastes an OpenAI API key into Codex's own login through stdin.
  Goby validates the executable before launch and checks the running process.
- **Claude:** run `claude setup-token` to get a token for your Claude plan, then
  `goby login claude` and paste it. An Anthropic API key pasted at the same
  prompt works too; the prefix (`sk-ant-oat…` or `sk-ant-api…`) decides which.
  `--plan` and `--api-key` insist on one. Input is hidden, saved only in Goby's
  login-Keychain item, and replaces the other kind, so one Claude credential is
  active at a time. Sign-ins inherited from your shell or Claude Code are never
  used; only what you saved with `goby login` is.
- **Copilot:** `goby login copilot` reuses an existing GitHub CLI login if there
  is one, and otherwise runs GitHub CLI's browser sign-in. `--token` pastes a
  GitHub token with Copilot access instead. Goby saves its own token copy in the
  CLI Keychain.

Claude and Copilot each need a runtime that is downloaded once, on demand:
`goby login claude` or `goby login copilot` offers it (about 130 MB for Claude
and 85 MB for Copilot, for your Mac's architecture only), or run
`goby runtime install claude|copilot`. `goby runtime status` shows what is
installed and `goby runtime remove …` deletes it. Codex needs no runtime. Each
download must match a hash built into the signed goby, and every file is
checked again before it runs. Runtimes live in
`~/Library/Application Support/Goby CLI Runtime/<version>/`, and older
versions are removed after an upgrade.

Plan sign-in is meant for your own Mac. Each provider's terms govern using a
personal plan through third-party software; check them before sharing a build
with others, and prefer API keys for anything shared (ADR-024 question 1).

Sign-in needs an interactive terminal. `goby logout <provider>` removes only
Goby's credential copies; it does not log out Codex, Claude Code or GitHub CLI.
The app's store and shared Keychain group are never used by the CLI.

## Talking to Goby

Run `goby` with no request to open an interactive session. Goby greets you,
shows the repository and provider, and keeps taking requests at the `›` prompt
until you type `/exit` (or press Ctrl-D). `/status` and `/help` work inside the
session. Leaving the session never stops the host or a running request.

Session commands mirror the Goby app's screens. Each is also a subcommand
(`goby map`, `goby runs --json`, and so on):

| Command | App equivalent |
| --- | --- |
| `/status` | Home: providers, active work, approvals, pending plan, next automation |
| `/map` | Map and List: groups → projects → agents, each with a status symbol and word |
| `/projects`, `/agents [project]` | Projects and Agents catalogs |
| `/runs [project]`, `/show [run]` | Runs and a run's conversation |
| `/diff [run]`, `/branches [project]` | A run's working-tree changes; Git branches and uncommitted changes |
| `/automations` | Automations, with recent occurrences |
| `/providers`, `/provider <name>`, `/model [name\|default]` | Provider Connections and the composer's provider and model choice for this session |
| `/instructions`, `/resources`, `/groups`, `/handoffs`, `/health` | Instructions, Shared Folders, Project Groups, Handoffs and System Health |
| `/approve`, `/deny`, `/pause`, `/resume`, `/cancel`, `/follow-up` | Run controls and approvals |
| `/commit`, `/push`, `/ask`, `/use` | Delivery, Temporary Chat and default scope |
| `/login`, `/logout`, `/doctor`, `/logs`, `/config` | Provider Connections sign-in, setup checks, the local log and report preference |

Type `/` at the prompt to see matching commands as you type. Tab or → accepts
the highlighted one, ↑ ↓ move through the list, Esc closes it, and Enter runs
it. Suggestions continue after the command: `/login ` offers the providers,
`/login claude ` offers `--plan` and `--api-key`, and `/use`, `/agents`, `/runs`
and `/branches` offer your project names. Without a list, ↑ ↓ walk back through earlier requests in the session.

Run IDs can be shortened to any unambiguous prefix, such as the eight
characters `/runs` shows. Without an ID, `/show` and `/diff` use the active run,
or the most recent one. An unknown `/word` is never sent to the provider as a
request; a path such as `/Users/me/notes.md` inside a request still is.

Creating projects from templates, editing agents and instruction packs, the
spider-web map's layout, live previews and Remote Access pairing remain in the
Goby app.

Goby's character is a goby fish. In nature a goby keeps watch at the burrow
while its partner shrimp digs; here Codex, Claude or Copilot do the digging and
Goby scouts the repository, plans the work and stops to check with you before
anything risky. While a request runs, a status line shows what Goby is doing,
how long it has taken, and a one-line preview of each provider message; the
complete text appears in the final result. Plans, approvals and errors stay
plain and exact.

The colours, box and animation appear only in an interactive terminal. Set
`NO_COLOR=1` for plain text, or `GOBY_NO_ANIMATION=1` (or turn on macOS Reduce
Motion) for a still status line. `--json`, pipes and `TERM=dumb` always get the
plain contract output, and provider text is cleaned of terminal control
characters before any styling is added.

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

## Logs and error reports

goby keeps a detailed local log at `~/Library/Logs/Goby CLI/goby.log`: each
command with its exit code and duration, errors, and failed runs. It is
redacted, rotated at 5 MB, and never leaves the Mac by itself. `goby logs`
shows the newest entries.

The first time goby is used interactively it asks whether to send anonymous
error reports to its maintainer. With consent, failures (error messages and
failed-run reasons, goby and macOS version, Mac type, and an anonymous
installation ID) are sent in the background with a short timeout and queued
when offline. Prompts, code, file paths and keys are never included.
`goby config reports on|off|status` changes the choice; turning reports off
deletes anything still queued. The receiving service is in `Reporting/`.

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
