# Goby CLI

`goby` runs Goby's agent host on your own Mac, from the terminal, for your own
repositories, with your own Codex, Claude or GitHub Copilot account.
It does not need the Goby app, the relay, or anyone else's Mac.

Requires macOS 26 or later.

## Install

```sh
brew tap snksnksnk/goby
brew install goby
```

Then `goby doctor` and `goby login codex` (or `claude` / `copilot`). Update with
`brew upgrade goby`. The one-line form `brew install snksnksnk/goby/goby` does
both steps at once.

Without Homebrew: download `goby-<version>.pkg` from the
[latest release](https://github.com/snksnksnk/goby-cli/releases/latest) and
double-click it. It installs to `/usr/local/goby` and links `/usr/local/bin/goby`;
remove it later with `/usr/local/goby/uninstall-goby.sh`.

Run `goby` on its own for an interactive session with Goby, a small lookout
fish that keeps watch while your provider digs:

```text
╭──────────────────────────────────────────────────────────╮
│ ><(((º>  Goby                                     v0.2.0 │
│                                                          │
│ Afternoon! Good currents today.                          │
│ I keep watch while Codex digs. I'll scout                │
│ your repo, plan the work, and check with you             │
│ before anything risky.                                   │
╰──────────────────────────────────────────────────────────╯
› fix the flaky login test
⠹ Keeping watch while Codex digs… (12s · ctrl-c detaches)
```

```sh
goby doctor                         # check providers and runtimes
goby login codex                    # or: claude (plan token or API key) | copilot
cd ~/code/my-app
goby "fix the flaky login test"     # plan → confirm scope → run → one result
goby status | watch | result <run> | diff <run>
goby approve <id> | deny <id>
goby pause | resume | cancel <run>
```

The full user guide is in [Docs/Beta/CLI_GUIDE.md](Docs/Beta/CLI_GUIDE.md).
The design and its verification history are in
[Docs/Architecture/ADR-024-STANDALONE-CLI-HOST.md](Docs/Architecture/ADR-024-STANDALONE-CLI-HOST.md).

## Build from source

```sh
swift build -c release --product goby
Scripts/test-swift-package.sh
```

A source build runs with Codex. Claude and Copilot runtimes are separate,
signed release packages that goby downloads on demand and verifies against
hashes compiled into release builds, so source builds can't install them.

The Homebrew package is about 14 MB. Claude (about 130 MB) and Copilot (about
85 MB) runtimes download once, for your Mac's architecture, when you sign in.

## Release

```sh
Scripts/release-cli.sh --preflight     # signing identity and notary profile
Scripts/release-cli.sh                 # signed, notarized universal artifacts + formula
Scripts/publish-cli-release.sh --publish <artifact-directory>
```

Packaging never publishes. Publishing needs an already-pushed `goby-v<version>`
tag that matches the artifact's source commit. The open release gates are in
[Docs/Beta/CLI_RELEASE_CHECKLIST.md](Docs/Beta/CLI_RELEASE_CHECKLIST.md).

## Layout

| Path | Contents |
|---|---|
| `Sources/GobyCLI`, `Sources/GobyCLIKit` | the `goby` executable, terminal workflow, socket host |
| `Sources/GobyHostCore` | the headless host engine shared with the Goby app |
| `Sources/GobyDomain` … `GobyOperations` | domain, use cases, providers, Git, persistence |
| `Helpers/` | Claude and Copilot Node bridges (pinned) |
| `Packaging/CLI/` | Homebrew formula template and shell completions |
| `Scripts/` | release, signing, manifest and verification scripts |

## License

MIT. See [LICENSE](LICENSE). Codex, ChatGPT, Claude, GitHub Copilot and macOS
are trademarks of their owners; Goby is an independent project.
