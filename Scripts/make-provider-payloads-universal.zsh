#!/bin/zsh -f
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

provider=${1:-}
helper_root=${2:-}

if [[ ${provider} != "claude" && ${provider} != "copilot" ]]; then
  print -u2 "Usage: $0 <claude|copilot> <staged-helper-directory>"
  exit 64
fi
if [[ -z ${helper_root} || ! -d ${helper_root} || -L ${helper_root} ]]; then
  print -u2 "A real staged provider-helper directory is required."
  exit 64
fi
helper_root=${helper_root:A}

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/goby-provider-universal.XXXXXX")
cleanup() {
  /bin/rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT

make_universal_pair() {
  local arm_payload=${1:?arm64 payload required}
  local intel_payload=${2:?x86_64 payload required}
  shift 2
  local -a destinations=("$@")
  local arm_slice="${temporary_directory}/arm64.$RANDOM"
  local intel_slice="${temporary_directory}/x86_64.$RANDOM"
  local universal_payload="${temporary_directory}/universal.$RANDOM"
  local destination
  local destination_mode
  local architectures

  if [[ ! -f ${arm_payload} || ! -f ${intel_payload} ]]; then
    print -u2 "A provider payload pair is incomplete: ${arm_payload} | ${intel_payload}"
    return 69
  fi
  architectures=" $(lipo -archs "${arm_payload}") "
  if [[ ${architectures} != *" arm64 "* ]]; then
    print -u2 "Provider payload is missing arm64: ${arm_payload}"
    return 69
  fi
  if [[ ${architectures} == *" x86_64 "* ]]; then
    lipo -thin arm64 "${arm_payload}" -output "${arm_slice}"
  else
    /bin/cp "${arm_payload}" "${arm_slice}"
  fi
  architectures=" $(lipo -archs "${intel_payload}") "
  if [[ ${architectures} != *" x86_64 "* ]]; then
    print -u2 "Provider payload is missing x86_64: ${intel_payload}"
    return 69
  fi
  if [[ ${architectures} == *" arm64 "* ]]; then
    lipo -thin x86_64 "${intel_payload}" -output "${intel_slice}"
  else
    /bin/cp "${intel_payload}" "${intel_slice}"
  fi

  lipo -create "${arm_slice}" "${intel_slice}" -output "${universal_payload}"
  architectures=" $(lipo -archs "${universal_payload}") "
  if [[ ${architectures} != *" arm64 "* || ${architectures} != *" x86_64 "* ]]; then
    print -u2 "Failed to create a universal provider payload from ${arm_payload:t}."
    return 70
  fi

  for destination in ${destinations}; do
    if [[ ! -f ${destination} ]]; then
      print -u2 "Universal provider payload destination is missing: ${destination}"
      return 69
    fi
    destination_mode=$(stat -f '%Lp' "${destination}")
    /bin/cp -f "${universal_payload}" "${destination}"
    chmod "${destination_mode}" "${destination}"
  done
}

if [[ ${provider} == "claude" ]]; then
  claude_arm64="${helper_root}/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude"
  claude_x86_64="${helper_root}/node_modules/@anthropic-ai/claude-agent-sdk-darwin-x64/claude"
  make_universal_pair \
    "${claude_arm64}" \
    "${claude_x86_64}" \
    "${claude_arm64}" \
    "${claude_x86_64}"
else
  copilot_arm64="${helper_root}/node_modules/@github/copilot-sdk-darwin-arm64"
  copilot_x86_64="${helper_root}/node_modules/@github/copilot-sdk-darwin-x64"
  koffi_arm64="${helper_root}/node_modules/@koromix/koffi-darwin-arm64/darwin_arm64/koffi.node"
  koffi_x86_64="${helper_root}/node_modules/@koromix/koffi-darwin-x64/darwin_x64/koffi.node"

  make_universal_pair \
    "${copilot_arm64}/plugins/computer-use/Copilot Computer Use.app/Contents/MacOS/Copilot Computer Use" \
    "${copilot_x86_64}/plugins/computer-use/Copilot Computer Use.app/Contents/MacOS/Copilot Computer Use" \
    "${copilot_arm64}/plugins/computer-use/Copilot Computer Use.app/Contents/MacOS/Copilot Computer Use" \
    "${copilot_x86_64}/plugins/computer-use/Copilot Computer Use.app/Contents/MacOS/Copilot Computer Use"
  make_universal_pair \
    "${copilot_arm64}/plugins/computer-use/computer-use-mcp" \
    "${copilot_x86_64}/plugins/computer-use/computer-use-mcp" \
    "${copilot_arm64}/plugins/computer-use/computer-use-mcp" \
    "${copilot_x86_64}/plugins/computer-use/computer-use-mcp"
  make_universal_pair \
    "${copilot_arm64}/prebuilds/darwin-arm64/runtime.node" \
    "${copilot_x86_64}/prebuilds/darwin-x64/runtime.node" \
    "${copilot_arm64}/prebuilds/darwin-arm64/runtime.node" \
    "${copilot_x86_64}/prebuilds/darwin-x64/runtime.node"
  make_universal_pair \
    "${copilot_arm64}/prebuilds/darwin-arm64/copilot-runtime" \
    "${copilot_x86_64}/prebuilds/darwin-x64/copilot-runtime" \
    "${copilot_arm64}/prebuilds/darwin-arm64/copilot-runtime" \
    "${copilot_x86_64}/prebuilds/darwin-x64/copilot-runtime"
  make_universal_pair \
    "${copilot_arm64}/ripgrep/bin/darwin-arm64/rg" \
    "${copilot_x86_64}/ripgrep/bin/darwin-x64/rg" \
    "${copilot_arm64}/ripgrep/bin/darwin-arm64/rg" \
    "${copilot_x86_64}/ripgrep/bin/darwin-arm64/rg" \
    "${copilot_x86_64}/ripgrep/bin/darwin-x64/rg"
  make_universal_pair \
    "${copilot_arm64}/tgrep/bin/darwin-arm64/tgrep" \
    "${copilot_x86_64}/tgrep/bin/darwin-x64/tgrep" \
    "${copilot_arm64}/tgrep/bin/darwin-arm64/tgrep" \
    "${copilot_x86_64}/tgrep/bin/darwin-arm64/tgrep" \
    "${copilot_x86_64}/tgrep/bin/darwin-x64/tgrep"
  make_universal_pair \
    "${koffi_arm64}" \
    "${koffi_x86_64}" \
    "${koffi_arm64}" \
    "${koffi_x86_64}"
fi

native_files=("${helper_root}"/**/*(.N))
for native_file in ${native_files}; do
  if /usr/bin/file -b "${native_file}" | /usr/bin/grep -q 'Mach-O'; then
    architectures=" $(lipo -archs "${native_file}") "
    if [[ ${architectures} != *" arm64 "* || ${architectures} != *" x86_64 "* ]]; then
      print -u2 "Provider helper still contains a thin Mach-O payload: ${native_file} (${architectures})"
      exit 70
    fi
  fi
done

print "Made every ${provider} Mach-O payload universal."
