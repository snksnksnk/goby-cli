# CLI friends-beta release gates

## Automated, local evidence

- [x] Complete Swift package suite and GobyHostRuntimeTests are green.
- [x] Existing macOS app builds with its original activation/trust policies.
- [x] Pinned helper preparation, type checks, tests, and arm64/x86_64 handshakes pass.
- [x] Every Mach-O is universal, hardened-runtime Developer-ID signed and verified.
- [x] Node has the existing V8 entitlements; goby has no shared-Keychain group or provisioning profile.
- [x] Compiled manifest validates every runtime file; tampered bytes and symlinks fail closed.
- [x] Signed release completes a real provider request, diagnostics, ephemeral chat and checkpoint/restart using only temporary CLI stores.
- [x] Notarization is Accepted; the DMG's stapled ticket validates.
- [x] Formula has the actual archive hash and passes Ruby syntax checks.
- [ ] Formula loads through current Homebrew (local older Homebrew rejects macOS 27.2 before loading).

## External or interactive gates before distributing to friends

- [ ] Maintainer confirms ADR-024 provider-terms question 1. Claude stays API-key only.
- [ ] Confirm Codex signatures on the exact Homebrew/npm distributions being recommended; unsigned variants remain refused.
- [ ] Install the final formula on a clean macOS 26 account and exercise native Keychain/device-owner prompts and provider sign-in.
- [ ] Test upgrade while a run is active; verify old-host drain, preserved approvals and a single replacement writer.
- [ ] Test `brew services` scheduling across logout/login and recover an interrupted occurrence.
- [ ] Test uninstall/reinstall retains CLI data and leaves the macOS app state untouched.
- [ ] Receive explicit permission for branch publication, the release tag/assets, and the separate Homebrew tap. The implementation session's original no-push/no-tag rule still applies.

Do not infer a completed clean-account test or a public release from local source
or notarization success. Record real evidence in ADR-024 when each gate is run.

Local evidence is recorded in ADR-024, Phase 4/5 verification results. The
Accepted candidate records source `f5612ce`; it is not a published release.
CLI notarization is checked with `codesign -R=notarized --check-notarization`;
the stapled DMG passes `spctl --type open --context context:primary-signature`.
