#!/bin/zsh -f
set -euo pipefail
if [[ ${GOBY_RELEASE_STAGING:-0} == 1 ]]; then
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
fi

script_directory=${0:A:h}
project_root=${script_directory:h}
source "${script_directory}/release-environment.zsh"
helper_root="${project_root}/Helpers/CopilotSDK"
prepared_node="${project_root}/Helpers/ProviderRuntime/node-universal"
prepared_npm_cli="${project_root}/Helpers/ProviderRuntime/npm/bin/npm-cli.js"
prepared_npm_cache="${project_root}/Helpers/ProviderRuntime/npm-cache"
output_directory=${1:-}
if [[ ${GOBY_RELEASE_STAGING:-0} == 1 ]]; then
  if [[ -n ${GOBY_PROVIDER_NODE_EXECUTABLE:-} ]]; then
    print -u2 "Release staging refuses provider Node path overrides."
    exit 64
  fi
  node_executable=${prepared_node}
else
  node_executable=${GOBY_PROVIDER_NODE_EXECUTABLE:-${prepared_node}}
fi
if [[ -n ${GOBY_REQUIRED_HELPER_ARCHS:-} ]]; then
  required_architectures=(${=GOBY_REQUIRED_HELPER_ARCHS})
else
  required_architectures=(arm64 x86_64)
fi

if [[ -z ${output_directory} ]]; then
  print -u2 "Usage: $0 <output-directory>"
  exit 64
fi
if [[ -L ${output_directory} ]]; then
  print -u2 "Refusing to replace a symlinked Copilot helper staging directory."
  exit 64
fi
output_directory=${output_directory:A}
if [[ ${output_directory} == / || ${output_directory} == ${project_root} || ${output_directory} == ${helper_root} ]]; then
  print -u2 "Refusing to replace an unsafe Copilot helper staging directory."
  exit 64
fi
if [[ ! -x ${node_executable} ]]; then
  print -u2 "Run Scripts/prepare-provider-runtime.sh before staging provider helpers."
  exit 69
fi
node_architectures="$(lipo -archs "${node_executable}")"
for architecture in ${required_architectures}; do
  if [[ " ${node_architectures} " != *" ${architecture} "* ]]; then
    print -u2 "The provider Node runtime is missing required architecture ${architecture}."
    exit 69
  fi
done
if [[ ! -d "${helper_root}/node_modules/@github/copilot-sdk" ]]; then
  print -u2 "Copilot dependencies are missing. Run npm ci in Helpers/CopilotSDK first."
  exit 69
fi
for architecture in arm64 x64; do
  if [[ ! -d "${helper_root}/node_modules/@github/copilot-sdk-darwin-${architecture}" ]]; then
    print -u2 "The Copilot ${architecture} runtime is missing. Run Scripts/prepare-provider-runtime.sh."
    exit 69
  fi
done

build_root=$(mktemp -d "${TMPDIR:-/tmp}/goby-copilot-build.XXXXXX")
cleanup() {
  /bin/rm -rf -- "${build_root}"
}
trap cleanup EXIT

# Recreate the pinned build tree from npm's verified local cache outside the
# Desktop file provider. This keeps clean packaging deterministic even when the
# workspace has evicted generated dependency files.
ditto --norsrc --noextattr "${helper_root}/package.json" "${build_root}/package.json"
ditto --norsrc --noextattr "${helper_root}/package-lock.json" "${build_root}/package-lock.json"
ditto --norsrc --noextattr "${helper_root}/tsconfig.json" "${build_root}/tsconfig.json"
ditto --norsrc --noextattr "${helper_root}/src" "${build_root}/src"
ditto --norsrc --noextattr "${helper_root}/tests" "${build_root}/tests"
if [[ ${GOBY_RELEASE_STAGING:-0} == 1 ]]; then
  if [[ ! -f ${prepared_npm_cli} ]]; then
    print -u2 "The verified provider runtime is missing its pinned npm client."
    exit 69
  fi
  npm_command=("${node_executable}" "${prepared_npm_cli}")
else
  npm_executable=$(command -v npm || true)
  npm_command=("${npm_executable}")
fi
if [[ -z ${npm_command[1]} ]]; then
  npm_install_succeeded=0
elif [[ ${GOBY_RELEASE_STAGING:-0} == 1 ]]; then
  if GOBY_NPM_CACHE="${prepared_npm_cache}" goby_release_node \
      "${node_executable}" "${build_root}" "${build_root}" \
      "${prepared_npm_cli}" ci --include=optional --ignore-scripts --offline --no-audit --no-fund; then
    npm_install_succeeded=1
  else
    npm_install_succeeded=0
  fi
elif (cd "${build_root}" && "${npm_command[@]}" ci --include=optional --ignore-scripts --offline --no-audit --no-fund); then
  npm_install_succeeded=1
else
  npm_install_succeeded=0
fi
if (( ! npm_install_succeeded )); then
  print -u2 "The pinned Copilot build cache is incomplete. Run Scripts/prepare-provider-runtime.sh."
  exit 69
fi
goby_release_node "${node_executable}" "${build_root}" "${build_root}" \
  "${build_root}/node_modules/typescript/bin/tsc" -p "${build_root}/tsconfig.json" --noEmit
goby_release_node "${node_executable}" "${build_root}" "${build_root}" \
  "${build_root}/node_modules/typescript/bin/tsc" -p "${build_root}/tsconfig.json"
goby_release_node "${node_executable}" "${build_root}" "${build_root}" \
  --test "${build_root}"/dist/tests/*.test.js

/bin/rm -rf -- "${output_directory}"
mkdir -p "${output_directory}/bin" "${output_directory}/node_modules"
ditto --norsrc --noextattr "${build_root}/dist/src" "${output_directory}"
ditto --norsrc --noextattr "${build_root}/package.json" "${output_directory}/package.json"
ditto --norsrc --noextattr "${node_executable}" "${output_directory}/bin/node"
chmod 0755 "${output_directory}/bin/node"

runtime_packages=(
  "@github/copilot-sdk"
  "@github/copilot-sdk-darwin-arm64"
  "@github/copilot-sdk-darwin-x64"
  "koffi"
  "@koromix/koffi-darwin-arm64"
  "@koromix/koffi-darwin-x64"
  "vscode-jsonrpc"
  "zod"
)
for relative_path in ${runtime_packages}; do
  dependency="${build_root}/node_modules/${relative_path}"
  if [[ ! -d ${dependency} ]]; then
    dependency="${helper_root}/node_modules/${relative_path}"
  fi
  if [[ ! -d ${dependency} ]]; then
    print -u2 "Required Copilot runtime package is missing: ${relative_path}"
    exit 69
  fi
  destination="${output_directory}/node_modules/${relative_path}"
  mkdir -p "${destination:h}"
  ditto --norsrc --noextattr "${dependency}" "${destination}"
done

# Keep architecture-specific package paths for SDK resolution, but make every
# native file at those paths universal. This prevents Rosetta retirement alerts
# caused by nested Intel-only components in an otherwise universal app.
"${script_directory}/make-provider-payloads-universal.zsh" \
  copilot \
  "${output_directory}"

for architecture in ${required_architectures}; do
  handshake=$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/var/empty \
    TMPDIR="${build_root}" \
    /usr/bin/arch "-${architecture}" \
    "${output_directory}/bin/node" "${output_directory}/index.js" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"goby-package-check","version":"0.2.0-beta.1"}}}
{"jsonrpc":"2.0","id":2,"method":"account/read","params":{}}
{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}
EOF
  )
  if [[ ${handshake} != *'"providerId":"github-copilot"'* \
     || ${handshake} != *'"connectionState":"needsAuthentication"'* \
     || ${handshake} != *'"stopped":true'* ]]; then
    print -u2 "The staged GitHub Copilot helper failed its ${architecture} no-credential JSON-RPC handshake."
    exit 70
  fi
done

print "${output_directory}"
