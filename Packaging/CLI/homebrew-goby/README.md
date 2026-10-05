# Goby Homebrew tap source

The signed release pipeline renders `Formula/goby.rb.in` with the exact release
version and verified archive checksum. Its output is `homebrew-goby/Formula/goby.rb`
beside the release artifacts. Publish that reviewed file in `snksnksnk/homebrew-goby`
after release approval. Do not publish this template as a formula or substitute a
placeholder checksum. No external tap has been created by this branch.

The formula installs the universal signed payload without rewriting executable
bytes or wrapping `goby`, preserving the compiled provider hashes. It exposes a
user LaunchAgent via `brew services`; `--stay-alive` prevents ordinary idle exit.
Stopping a service checkpoints the host. Store and CLI Keychain items are retained.
