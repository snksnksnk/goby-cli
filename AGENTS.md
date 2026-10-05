# Goby CLI repository instructions

- This repository contains only the standalone `goby` CLI and the host modules it
  needs. The Goby macOS app lives in a separate private repository and shares the
  host Core with this one. Keep changes to shared modules (Domain, Application,
  Infrastructure, Experience, Operations, HostCore) compatible with the app, and
  note any change that must be ported there.
- Treat `Docs/Architecture/ADR-024-STANDALONE-CLI-HOST.md` as the design
  contract, and update `Docs/Beta/CLI_GUIDE.md` when user-visible behavior changes.
- Swift 6 language mode with complete strict concurrency and no new warnings.
  `@MainActor` for the store, actors for shared mutable state, processes and Git.
  No SwiftUI or AppKit imports anywhere in this repository.
- Use Swift Testing. Run `Scripts/test-swift-package.sh` before committing.
- Never weaken provider trust: Codex is accepted only with OpenAI's signature,
  the bundled runtime only against the compiled manifest. Claude subscription
  credentials stay disabled until the provider-terms question in ADR-024 is resolved.
- The CLI's store, Keychain services (`com.goby.cli.*`) and defaults stay separate
  from the app. Never read, migrate or delete app data.
- Never commit secrets, credentials, signing material, build products or local state.
- Pushing, tagging and publishing releases or the Homebrew tap need explicit
  approval from the maintainer.
