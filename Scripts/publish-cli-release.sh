#!/bin/zsh -f
# Explicit publication only: packaging never invokes this script.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
if (( $# != 2 )) || [[ $1 != --publish ]]; then
  print -u2 'Usage: publish-cli-release.sh --publish <verified-release-directory>'
  print -u2 'Requires separate publication approval and an existing pushed goby-v<version> tag.'
  exit 64
fi
artifacts=${2:A}
formula="${artifacts}/homebrew-goby/Formula/goby.rb"
version=$(sed -n 's/^  version "\([^"]*\)"$/\1/p' "${formula}")
[[ ${version} =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$' ]] || exit 64
tag="goby-v${version}"
archive="goby-${version}-universal.tar.gz"
dmg="goby-${version}-universal.dmg"
(cd "${artifacts}"; shasum -a 256 -c SHA256SUMS)
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted"' "${artifacts}/notary.json"
xcrun stapler validate "${artifacts}/${dmg}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${artifacts}/${dmg}"
staging=$(mktemp -d "${TMPDIR:-/private/tmp}/goby-cli-publish.XXXXXX")
trap '/bin/rm -rf -- "${staging}"' EXIT INT TERM
/usr/bin/tar -xzf "${artifacts}/${archive}" -C "${staging}"
script_directory=${0:A:h}
python3 "${script_directory}/verify-cli-release.py" "${staging}"
codesign --verify --verbose=4 --strict --check-notarization -R=notarized "${staging}/bin/goby"
commit=$(cat "${staging}/SourceCommit.txt")
# Refuse GitHub's implicit tag creation. The separately approved tag must
# already point at the exact immutable source recorded in this artifact.
ref=$(gh api "repos/snksnksnk/goby-cli/git/ref/tags/${tag}" --jq '.object.sha')
kind=$(gh api "repos/snksnksnk/goby-cli/git/ref/tags/${tag}" --jq '.object.type')
if [[ ${kind} == tag ]]; then
  ref=$(gh api "repos/snksnksnk/goby-cli/git/tags/${ref}" --jq '.object.sha')
fi
[[ ${ref} == ${commit} ]] || { print -u2 'The existing release tag does not identify this artifact source.'; exit 69; }
gh release create "${tag}" --repo snksnksnk/goby-cli --verify-tag --prerelease \
  --title "Goby CLI ${version}" --notes-file "${staging}/README.md" \
  "${artifacts}/${archive}" "${artifacts}/${dmg}" "${artifacts}/SHA256SUMS"
print 'CLI assets published. Publish the reviewed homebrew-goby directory to the separately approved tap repository.'
