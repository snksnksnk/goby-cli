#!/bin/zsh -f
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
script_directory=${0:A:h}
project_root=${script_directory:h}
mode=${1:-release}
version=${GOBY_CLI_VERSION:-0.2.0-beta.1}
repository=${GOBY_CLI_REPOSITORY:-snksnksnk/goby-cli}
notary_profile=${GOBY_NOTARY_PROFILE:-goby-notary}
output=${GOBY_CLI_RELEASE_DIRECTORY:-${project_root}/.build/cli-releases}
identity=${GOBY_SIGNING_IDENTITY:-}
architectures=(arm64 x86_64)
components=(claude:ClaudeAgentSDKBridge copilot:CopilotSDKBridge)
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
    print -u2 "The notarization profile ${notary_profile} is unavailable. Save it with: xcrun notarytool store-credentials ${notary_profile}"; exit 69
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
universal="${staging}/runtime-universal"
runtimes="${staging}/runtimes"
packages="${staging}/packages"
mkdir -p "${payload}/bin" "${universal}" "${runtimes}" "${packages}"

# 1. Universal provider runtimes, built and tested exactly as before.
"${script_directory}/prepare-provider-runtime.sh"
GOBY_RELEASE_STAGING=1 "${script_directory}/stage-claude-helper.sh" "${universal}/ClaudeAgentSDKBridge"
GOBY_RELEASE_STAGING=1 "${script_directory}/stage-copilot-helper.sh" "${universal}/CopilotSDKBridge"

# 2. One thinned, signed copy per architecture, packaged per provider. Each
#    Mac downloads only the provider runtime it uses, for its architecture.
package_arguments=()
for arch in ${architectures}; do
  ditto --norsrc --noextattr "${universal}" "${runtimes}/${arch}"
  python3 "${script_directory}/thin-cli-runtime.py" "${runtimes}/${arch}" "${arch}"
  # Sign inside out before hashing. Only Node gets the existing V8 exceptions.
  python3 "${script_directory}/sign-cli-runtime.py" "${runtimes}/${arch}" "${identity}" "${project_root}/Packaging/ProviderNode.entitlements" "${arch}"
  for entry in ${components}; do
    component=${entry%%:*}; folder=${entry#*:}
    package="${packages}/goby-runtime-${component}-${version}-${arch}.tar.gz"
    COPYFILE_DISABLE=1 tar -czf "${package}" -C "${runtimes}/${arch}" "${folder}"
    package_arguments+=(--archive "${component}-${arch}=${package}")
  done
done

# 3. Compile every runtime file hash and package hash into goby.
python3 "${script_directory}/generate-cli-manifest.py" --swift "${generated}" --json "${payload}/ProviderRuntime.sha256.json" \
  --version "${version}" --commit "${source_commit}" \
  --download-base "https://github.com/${repository}/releases/download/goby-v${version}" \
  --runtime "arm64=${runtimes}/arm64" --runtime "x86_64=${runtimes}/x86_64" ${package_arguments}
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
verify_arguments=(--runtimes "${runtimes}" --packages "${packages}")
if [[ ${mode} == --local ]]; then verify_arguments+=(--ad-hoc); fi
python3 "${script_directory}/verify-cli-release.py" "${payload}" ${verify_arguments}

archive_name="goby-${version}-universal.tar.gz"
dmg_name="goby-${version}-universal.dmg"
if [[ ${mode} == release ]]; then
  # Notarize goby and every runtime binary together. The DMG carries the
  # stapled ticket; the tarballs carry the same notarized code bytes.
  notarize_root="${staging}/notarize"
  mkdir -p "${notarize_root}"
  ditto --norsrc --noextattr "${payload}" "${notarize_root}/goby"
  ditto --norsrc --noextattr "${runtimes}" "${notarize_root}/runtimes"
  hdiutil create -quiet -volname "Goby CLI ${version}" -srcfolder "${notarize_root}" -format UDZO "${staging}/${dmg_name}"
  codesign --force --timestamp --sign "${identity}" "${staging}/${dmg_name}"
  xcrun notarytool submit "${staging}/${dmg_name}" --keychain-profile "${notary_profile}" --wait --output-format json > "${staging}/notary.json"
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Notarization was not accepted"' "${staging}/notary.json"
  xcrun stapler staple "${staging}/${dmg_name}"
  xcrun stapler validate "${staging}/${dmg_name}"
  # Apple DTS recommends codesign for non-app code and spctl's open
  # assessment for the DMG; execute assessment expects an app bundle.
  codesign --verify --verbose=4 --strict --check-notarization -R=notarized "${payload}/bin/goby"
  for arch in ${architectures}; do
    for entry in ${components}; do
      codesign --verify --strict --check-notarization -R=notarized "${runtimes}/${arch}/${entry#*:}/bin/node"
    done
  done
  spctl --assess --type open --context context:primary-signature --verbose=2 "${staging}/${dmg_name}"
  /bin/cp "${staging}/${dmg_name}" "${output}/${dmg_name}"
  /bin/cp "${staging}/notary.json" "${output}/notary.json"
fi
COPYFILE_DISABLE=1 tar -czf "${staging}/${archive_name}" -C "${payload}" .
archive_hash=$(shasum -a 256 "${staging}/${archive_name}" | awk '{print $1}')
if [[ ${mode} == --local ]]; then
  # Local verification cannot produce a publishable Homebrew formula.
  /bin/cp "${staging}/${archive_name}" "${output}/local-${archive_name}"
  /bin/cp "${packages}"/*.tar.gz "${output}/"
elif [[ ${mode} == --signed-only ]]; then
  /bin/cp "${staging}/${archive_name}" "${output}/signed-unnotarized-${archive_name}"
  print 'Signed local candidate only. Notarization and public distribution remain blocked.'
else
  /bin/cp "${staging}/${archive_name}" "${output}/${archive_name}"
  /bin/cp "${packages}"/*.tar.gz "${output}/"
  /bin/cp "${payload}/ProviderRuntime.sha256.json" "${output}/ProviderRuntime.sha256.json"
  mkdir -p "${output}/homebrew-goby/Formula"
  python3 "${script_directory}/render-cli-formula.py" "${project_root}/Packaging/CLI/homebrew-goby/Formula/goby.rb.in" "${output}/homebrew-goby/Formula/goby.rb" "${version}" "${archive_hash}"
  /bin/cp "${project_root}/Packaging/CLI/homebrew-goby/README.md" "${output}/homebrew-goby/README.md"
  (cd "${output}"; shasum -a 256 "${archive_name}" goby-runtime-*-"${version}"-*.tar.gz "${dmg_name}" > SHA256SUMS)
fi
print 'CLI packaging passed. Artifacts are local; nothing was pushed, tagged or published.'
