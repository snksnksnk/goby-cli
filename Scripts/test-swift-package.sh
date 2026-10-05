#!/bin/zsh

set -euo pipefail

scratch_root=$(mktemp -d "${TMPDIR:-/private/tmp}/goby-swift-tests.XXXXXX")

cleanup() {
    case "$scratch_root" in
        */goby-swift-tests.*) rm -rf -- "$scratch_root" ;;
    esac
}
trap cleanup EXIT INT TERM

swift test \
    --scratch-path "$scratch_root" \
    --no-parallel \
    -Xswiftc -strict-concurrency=complete \
    "$@"
