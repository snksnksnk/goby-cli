#!/bin/zsh -f
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

script_directory=${0:A:h}
project_root=${script_directory:h}
source "${script_directory}/release-environment.zsh"
runtime_root="${project_root}/Helpers/ProviderRuntime"
copilot_root="${project_root}/Helpers/CopilotSDK"
claude_root="${project_root}/Helpers/ClaudeAgentSDK"
node_version=24.20.0
node_arm_archive="node-v${node_version}-darwin-arm64.tar.gz"
node_x64_archive="node-v${node_version}-darwin-x64.tar.gz"
node_arm_sha256=40e5607e5ecb3db9192723776da2d75d966260fc74a7a9e731c1bd67dda96bc8
node_x64_sha256=9e5b2644cf107befb6aefca676b96d3296bc10138096f022ed378d6233ed81f4
copilot_version=1.0.13
copilot_arm_integrity='sha512-AvBV5dzjNWpGwgoCnttrETnt7rLI4pTFQsRSM7GU5TK+YqShauffdMU06Bn/d+IDX2fj1Z4ThH7yl/gHCDvoNQ=='
copilot_x64_integrity='sha512-ZNQmTnHwk8bO/E514k0sFBsuCVNpFj8jMH4jeLncASQM4RRdOqYhXlYLW7H/ts7ANjdfMJjJY29NUqzEWaADOA=='
koffi_version=3.2.1
koffi_arm_integrity='sha512-Vj4h+xcjc5+Cn0DhPHjgRX4omKAv96Kehtcd+1YgYuY2W7FvQn9vS+3SmzVwhC5Qmg9bIwUZObYQ8T/4hBqQqA=='
koffi_x64_integrity='sha512-gFCWxNBTZIvxo1p+PURWfsy2Ctj5FGnVVs1f03lTLhBvmxEto70pdIiFztdFLDFkAJ1pmtQmruRKapeK+E8YPA=='
claude_version=0.3.263
claude_arm_integrity='sha512-H4eLd4Tkx3rJkt739CHb+9AcaKiiOpibU4tYsmma47mV+2zAPjUyFxpuE2N57VSmpAgbLQxu44du0TFN+UH5dg=='
claude_x64_integrity='sha512-jKwmfkem1s/TcK7u83cJf2zLHMz846irV4vqYGUlo74uX2qfX57R4UsrCMlcTUMou/U9vQyNCc/Kk0s+zSxYRg=='
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/goby-provider-runtime.XXXXXX")
provider_npm_cache="${runtime_root}/npm-cache"

cleanup() {
  /bin/rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT

download_and_verify_sha256() {
  local url=${1:?url required}
  local destination=${2:?destination required}
  local expected=${3:?sha256 required}
  curl --fail --location --proto '=https' --tlsv1.2 --output "${destination}" "${url}"
  local actual
  actual=$(shasum -a 256 "${destination}" | awk '{print $1}')
  if [[ ${actual} != ${expected} ]]; then
    print -u2 "SHA-256 verification failed for ${destination:t}."
    return 65
  fi
}

download_and_verify_sha512_sri() {
  local url=${1:?url required}
  local destination=${2:?destination required}
  local expected=${3:?integrity required}
  curl --fail --location --proto '=https' --tlsv1.2 --output "${destination}" "${url}"
  local actual
  actual="sha512-$(openssl dgst -sha512 -binary "${destination}" | openssl base64 -A)"
  if [[ ${actual} != ${expected} ]]; then
    print -u2 "SHA-512 integrity verification failed for ${destination:t}."
    return 65
  fi
}

install_npm_archive() {
  local url=${1:?url required}
  local integrity=${2:?integrity required}
  local destination=${3:?destination required}
  local archive_name=${4:?archive name required}
  download_and_verify_sha512_sri \
    "${url}" \
    "${temporary_directory}/${archive_name}" \
    "${integrity}"
  /bin/rm -rf -- "${destination}"
  mkdir -p "${destination}"
  tar -xzf "${temporary_directory}/${archive_name}" \
    -C "${destination}" \
    --strip-components=1
}

download_and_verify_sha256 \
  "https://nodejs.org/download/release/v${node_version}/${node_arm_archive}" \
  "${temporary_directory}/${node_arm_archive}" \
  "${node_arm_sha256}"
download_and_verify_sha256 \
  "https://nodejs.org/download/release/v${node_version}/${node_x64_archive}" \
  "${temporary_directory}/${node_x64_archive}" \
  "${node_x64_sha256}"

tar -xzf "${temporary_directory}/${node_arm_archive}" -C "${temporary_directory}"
tar -xzf "${temporary_directory}/${node_x64_archive}" -C "${temporary_directory}"
mkdir -p "${runtime_root}"
lipo -create \
  "${temporary_directory}/node-v${node_version}-darwin-arm64/bin/node" \
  "${temporary_directory}/node-v${node_version}-darwin-x64/bin/node" \
  -output "${runtime_root}/node-universal"
chmod 0755 "${runtime_root}/node-universal"
/bin/rm -rf -- "${runtime_root}/npm"
ditto --norsrc --noextattr \
  "${temporary_directory}/node-v${node_version}-darwin-arm64/lib/node_modules/npm" \
  "${runtime_root}/npm"
if [[ "$(lipo -archs "${runtime_root}/node-universal")" != *arm64* \
   || "$(lipo -archs "${runtime_root}/node-universal")" != *x86_64* ]]; then
  print -u2 "The prepared Node runtime is not universal."
  exit 65
fi

mkdir -p "${temporary_directory}/bin"
ln -s "${runtime_root}/node-universal" "${temporary_directory}/bin/node"
npm_cli="${runtime_root}/npm/bin/npm-cli.js"
if [[ ! -f ${npm_cli} ]]; then
  print -u2 "The verified Node archive did not contain its pinned npm client."
  exit 69
fi
mkdir -p "${provider_npm_cache}"
GOBY_NPM_CACHE="${provider_npm_cache}" goby_release_node \
  "${runtime_root}/node-universal" "${copilot_root}" "${temporary_directory}" \
  "${npm_cli}" ci --include=optional --ignore-scripts --no-audit --no-fund
GOBY_NPM_CACHE="${provider_npm_cache}" goby_release_node \
  "${runtime_root}/node-universal" "${claude_root}" "${temporary_directory}" \
  "${npm_cli}" ci --include=optional --ignore-scripts --no-audit --no-fund

for architecture in arm64 x64; do
  if [[ ${architecture} == arm64 ]]; then
    copilot_integrity=${copilot_arm_integrity}
    koffi_integrity=${koffi_arm_integrity}
    claude_integrity=${claude_arm_integrity}
  else
    copilot_integrity=${copilot_x64_integrity}
    koffi_integrity=${koffi_x64_integrity}
    claude_integrity=${claude_x64_integrity}
  fi

  copilot_archive="copilot-sdk-darwin-${architecture}-${copilot_version}.tgz"
  install_npm_archive \
    "https://registry.npmjs.org/@github/copilot-sdk-darwin-${architecture}/-/${copilot_archive}" \
    "${copilot_integrity}" \
    "${copilot_root}/node_modules/@github/copilot-sdk-darwin-${architecture}" \
    "${copilot_archive}"

  koffi_archive="koffi-darwin-${architecture}-${koffi_version}.tgz"
  install_npm_archive \
    "https://registry.npmjs.org/@koromix/koffi-darwin-${architecture}/-/${koffi_archive}" \
    "${koffi_integrity}" \
    "${copilot_root}/node_modules/@koromix/koffi-darwin-${architecture}" \
    "${koffi_archive}"

  claude_archive="claude-agent-sdk-darwin-${architecture}-${claude_version}.tgz"
  install_npm_archive \
    "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk-darwin-${architecture}/-/${claude_archive}" \
    "${claude_integrity}" \
    "${claude_root}/node_modules/@anthropic-ai/claude-agent-sdk-darwin-${architecture}" \
    "${claude_archive}"
done

goby_release_node "${runtime_root}/node-universal" "${project_root}" "${temporary_directory}" --version
print "Prepared universal provider runtime at ${runtime_root}."
