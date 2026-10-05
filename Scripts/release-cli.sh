#!/bin/zsh -f
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
script_directory=${0:A:h}
project_root=${script_directory:h}
mode=${1:-release}
version=${GOBY_CLI_VERSION:-0.2.0-beta.1}
notary_profile=${GOBY_NOTARY_PROFILE:-goby-notary}
output=${GOBY_CLI_RELEASE_DIRECTORY:-${project_root}/.build/cli-releases}
identity=${GOBY_SIGNING_IDENTITY:-}
if [[ ${mode} != release && ${mode} != --local && ${mode} != --preflight && ${mode} != --signed-only ]]; then
  print -u2 'Usage: release-cli.sh [--preflight|--local|--signed-only]'; exit 64
fi
if [[ ${mode} == --local ]]; then
  identity=-
elif [[ -z ${identity} ]]; then
  identities=("${(@f)$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p')}")
  if (( ${#identities[@]} != 1 )) || [[ -z ${identities[1]} ]]; then
    print -u2 'Select exactly one Developer ID Application identity with GOBY_SIGNING_IDENTITY.'; exit 69
  fi
  identity=${identities[1]}
fi
if [[ ${mode} == release || ${mode} == --preflight ]]; then
  if ! xcrun notarytool history --keychain-profile "${notary_profile}" >/dev/null 2>&1; then
    print -u2 'The configured notarization profile is unavailable.'; exit 69
  fi
fi
if [[ ${mode} == --preflight ]]; then
  print 'CLI preflight passed: Developer ID Application and notary profile available; no provisioning profile required.'; exit 0
fi
source_commit=$("${script_directory}/verify-release-source.zsh" "${project_root}")
if [[ -L ${output} || ${output:A} == / || ${output:A} == ${project_root} ]]; then
  print -u2 'Select a safe release artifact directory.'; exit 64
fi
mkdir -p "${output}"
output=${output:A}
staging=$(mktemp -d "${TMPDIR:-/private/tmp}/goby-cli-package.XXXXXX")
generated="${project_root}/Sources/GobyInfrastructure/GeneratedCLIProviderManifest.swift"
if [[ -e ${generated} ]]; then
  print -u2 'Remove the previous ignored CLI manifest after checking no release build is using it.'; exit 69
fi
cleanup() {
  /bin/rm -f -- "${generated}"
  /bin/rm -rf -- "${staging}"
}
trap cleanup EXIT INT TERM
payload="${staging}/payload"
mkdir -p "${payload}/bin" "${payload}/libexec/provider-runtime"
"${script_directory}/prepare-provider-runtime.sh"
GOBY_RELEASE_STAGING=1 "${script_directory}/stage-claude-helper.sh" "${payload}/libexec/provider-runtime/ClaudeAgentSDKBridge"
GOBY_RELEASE_STAGING=1 "${script_directory}/stage-copilot-helper.sh" "${payload}/libexec/provider-runtime/CopilotSDKBridge"
# Sign inside out before computing any hashes. Native Node modules and nested
# apps are part of the manifest too. Only Node gets the existing V8 exceptions.
python3 "${script_directory}/sign-cli-runtime.py" "${payload}/libexec/provider-runtime" "${identity}" "${project_root}/Packaging/ProviderNode.entitlements"
python3 "${script_directory}/generate-cli-manifest.py" "${payload}/libexec/provider-runtime" "${generated}" "${payload}/ProviderRuntime.sha256.json" --version "${version}" --commit "${source_commit}"
swift build --package-path "${project_root}" --scratch-path "${staging}/build" -c release --arch arm64 --arch x86_64 --product goby -j 4 -Xswiftc -strict-concurrency=complete -Xswiftc -DGOBY_CLI_DISTRIBUTION
# Recheck the same source after compilation, before producing signed assets.
"${script_directory}/verify-release-source.zsh" "${project_root}" "${source_commit}" >/dev/null
binary_directory=$(swift build --package-path "${project_root}" --scratch-path "${staging}/build" -c release --arch arm64 --arch x86_64 --show-bin-path)
/bin/cp "${binary_directory}/goby" "${payload}/bin/goby"
resource_bundles=("${binary_directory}"/*.bundle(N/))
for bundle in ${resource_bundles}; do
  ditto --norsrc --noextattr "${bundle}" "${payload}/bin/${bundle:t}"
  codesign --force --options runtime --sign "${identity}" "${payload}/bin/${bundle:t}"
done
sign_arguments=(--force --options runtime --identifier com.goby.cli --sign "${identity}")
if [[ ${mode} != --local ]]; then sign_arguments+=(--timestamp); fi
codesign ${sign_arguments} "${payload}/bin/goby"
ditto --norsrc --noextattr "${project_root}/Packaging/CLI/completions" "${payload}/completions"
/bin/cp "${project_root}/Docs/Beta/CLI_GUIDE.md" "${payload}/README.md"
/bin/cp "${project_root}/LICENSE" "${payload}/LICENSE"
print -r -- "${source_commit}" > "${payload}/SourceCommit.txt"
verify_arguments=()
if [[ ${mode} == --local ]]; then verify_arguments+=(--ad-hoc); fi
python3 "${script_directory}/verify-cli-release.py" "${payload}" ${verify_arguments}
# A bare executable and tar archive cannot be stapled. The companion signed
# DMG carries the offline ticket; the tar uses the same notarized code bytes.
archive_name="goby-${version}-universal.tar.gz"
dmg_name="goby-${version}-universal.dmg"
if [[ ${mode} == release ]]; then
  hdiutil create -quiet -volname "Goby CLI ${version}" -srcfolder "${payload}" -format UDZO "${staging}/${dmg_name}"
  codesign --force --timestamp --sign "${identity}" "${staging}/${dmg_name}"
  xcrun notarytool submit "${staging}/${dmg_name}" --keychain-profile "${notary_profile}" --wait --output-format json > "${staging}/notary.json"
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Notarization was not accepted"' "${staging}/notary.json"
  xcrun stapler staple "${staging}/${dmg_name}"
  xcrun stapler validate "${staging}/${dmg_name}"
  # Apple DTS recommends codesign for non-app code and spctl's open
  # assessment for the DMG; execute assessment expects an app bundle.
  codesign --verify --verbose=4 --strict --check-notarization -R=notarized "${payload}/bin/goby"
  spctl --assess --type open --context context:primary-signature --verbose=2 "${staging}/${dmg_name}"
  /bin/cp "${staging}/${dmg_name}" "${output}/${dmg_name}"
  /bin/cp "${staging}/notary.json" "${output}/notary.json"
fi
COPYFILE_DISABLE=1 tar -czf "${staging}/${archive_name}" -C "${payload}" .
archive_hash=$(shasum -a 256 "${staging}/${archive_name}" | awk '{print $1}')
if [[ ${mode} == --local ]]; then
  # Local verification cannot produce a publishable Homebrew formula.
  /bin/cp "${staging}/${archive_name}" "${output}/local-${archive_name}"
elif [[ ${mode} == --signed-only ]]; then
  /bin/cp "${staging}/${archive_name}" "${output}/signed-unnotarized-${archive_name}"
  print 'Signed local candidate only. Notarization and public distribution remain blocked.'
else
  /bin/cp "${staging}/${archive_name}" "${output}/${archive_name}"
  mkdir -p "${output}/homebrew-goby/Formula"
  python3 "${script_directory}/render-cli-formula.py" "${project_root}/Packaging/CLI/homebrew-goby/Formula/goby.rb.in" "${output}/homebrew-goby/Formula/goby.rb" "${version}" "${archive_hash}"
  /bin/cp "${project_root}/Packaging/CLI/homebrew-goby/README.md" "${output}/homebrew-goby/README.md"
  (cd "${output}"; shasum -a 256 "${archive_name}" "${dmg_name}" > SHA256SUMS)
fi
print 'CLI packaging passed. Artifacts are local; nothing was pushed, tagged or published.'
