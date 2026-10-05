#!/bin/zsh -f
set -euo pipefail
if [[ ${GOBY_RELEASE_STAGING:-0} == 1 ]]; then
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
fi

script_directory=${0:A:h}
project_root=${script_directory:h}
source "${script_directory}/release-environment.zsh"
helper_root="${project_root}/Helpers/ClaudeAgentSDK"
prepared_node="${project_root}/Helpers/ProviderRuntime/node-universal"
prepared_npm_cli="${project_root}/Helpers/ProviderRuntime/npm/bin/npm-cli.js"
prepared_npm_cache="${project_root}/Helpers/ProviderRuntime/npm-cache"
output_directory=${1:-}
if [[ ${GOBY_RELEASE_STAGING:-0} == 1 ]]; then
  node_executable=${prepared_node}
elif [[ -n ${GOBY_PROVIDER_NODE_EXECUTABLE:-} ]]; then
  node_executable=${GOBY_PROVIDER_NODE_EXECUTABLE}
elif [[ -n ${GOBY_NODE_EXECUTABLE:-} ]]; then
  node_executable=${GOBY_NODE_EXECUTABLE}
elif [[ -x ${prepared_node} ]]; then
  node_executable=${prepared_node}
else
  node_executable=$(command -v node || true)
fi
if [[ ${GOBY_RELEASE_STAGING:-0} == 1 \
   && ( -n ${GOBY_PROVIDER_NODE_EXECUTABLE:-} || -n ${GOBY_NODE_EXECUTABLE:-} ) ]]; then
  print -u2 "Release staging refuses provider Node path overrides."
  exit 64
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
  print -u2 "Refusing to replace a symlinked Claude helper staging directory."
  exit 64
fi
output_directory=${output_directory:A}
if [[ ${output_directory} == / || ${output_directory} == ${project_root} || ${output_directory} == ${helper_root} ]]; then
  print -u2 "Refusing to replace an unsafe Claude helper staging directory."
  exit 64
fi
if [[ ! -x ${node_executable} ]]; then
  print -u2 "A Node.js executable is required to stage the Claude helper."
  exit 69
fi
node_architectures="$(lipo -archs "${node_executable}")"
for architecture in ${required_architectures}; do
  if [[ " ${node_architectures} " != *" ${architecture} "* ]]; then
    print -u2 "The provider Node runtime is missing required architecture ${architecture}."
    exit 69
  fi
done
if [[ ! -d "${helper_root}/node_modules/@anthropic-ai/claude-agent-sdk" ]]; then
  print -u2 "Claude dependencies are missing. Run npm ci in Helpers/ClaudeAgentSDK before packaging."
  exit 69
fi

build_root=$(mktemp -d "${TMPDIR:-/tmp}/goby-claude-build.XXXXXX")
cleanup() {
  /bin/rm -rf -- "${build_root}"
}
trap cleanup EXIT

# Desktop-managed workspaces may evict generated dependency files. Recreate the
# pinned build tree from npm's verified local cache outside Desktop so a release
# cannot stall halfway through a dataless declaration file. The runtime-prep
# step seeds that cache and supplies both architecture-specific native packages.
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
  print -u2 "The pinned Claude build cache is incomplete. Run Scripts/prepare-provider-runtime.sh."
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

# The agent SDK's JavaScript runtime is a self-contained bundle. Its peer
# packages are needed by TypeScript declarations, not by sdk.mjs at runtime.
# Stage the bundle and both native Claude executables so the same signed app
# can run natively on Apple silicon and Intel Macs.
runtime_packages=(
  "@anthropic-ai/claude-agent-sdk"
  "@anthropic-ai/claude-agent-sdk-darwin-arm64"
  "@anthropic-ai/claude-agent-sdk-darwin-x64"
)
for relative_path in ${runtime_packages}; do
  dependency="${build_root}/node_modules/${relative_path}"
  if [[ ! -d ${dependency} ]]; then
    dependency="${helper_root}/node_modules/${relative_path}"
  fi
  if [[ ! -d ${dependency} ]]; then
    print -u2 "Required Claude runtime package is missing: ${relative_path}"
    exit 69
  fi
  destination="${output_directory}/node_modules/${relative_path}"
  mkdir -p "${destination:h}"
  if [[ ${relative_path} == @anthropic-ai/claude-agent-sdk-darwin-* ]]; then
    # Desktop file providers can leave collision copies such as `claude 2`
    # beside npm's canonical payload. Stage the package's declared files only
    # so a stale thin duplicate cannot enter an otherwise universal app.
    mkdir -p "${destination}"
    for package_file in claude package.json README.md LICENSE.md; do
      if [[ ! -f "${dependency}/${package_file}" ]]; then
        print -u2 "Required Claude runtime file is missing: ${relative_path}/${package_file}"
        exit 69
      fi
      ditto --norsrc --noextattr \
        "${dependency}/${package_file}" \
        "${destination}/${package_file}"
    done
  else
    ditto --norsrc --noextattr "${dependency}" "${destination}"
  fi
done

# macOS 26.4 warns when any nested executable still requires Rosetta, even
# when the outer app and its Node runtime are universal. Fuse the SDK's paired
# native payloads before signing so every Mach-O in the app can run natively.
"${script_directory}/make-provider-payloads-universal.zsh" \
  claude \
  "${output_directory}"

for architecture in ${required_architectures}; do
  handshake=$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/var/empty \
    TMPDIR="${build_root}" \
    /usr/bin/arch "-${architecture}" \
    "${output_directory}/bin/node" "${output_directory}/index.js" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"goby-package-check","version":"0.2.0-beta.1"}}}
{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}
EOF
  )
  if [[ ${handshake} != *'"providerId":"claude"'* || ${handshake} != *'"stopped":true'* ]]; then
    print -u2 "The staged Claude helper failed its ${architecture} JSON-RPC handshake."
    exit 70
  fi
done

print "${output_directory}"
