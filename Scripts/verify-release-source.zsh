#!/bin/zsh -f
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

script_directory=${0:A:h}
project_root=${1:-${script_directory:h}}
expected_commit=${2:-}
source_scope=${3:-all}
source "${script_directory}/release-environment.zsh"

case ${source_scope} in
  all)
    source_pathspecs=(.)
    scope_description="repository"
    ;;
  ios-v1)
    # The iOS beta is a coordinated iPhone/iPad, Mac-host, and relay release.
    # Android is a separate product surface and must neither satisfy nor block
    # this source-freeze gate.
    source_pathspecs=(. ':(top,exclude)android')
    scope_description="iOS v1 source scope (Android excluded)"
    ;;
  *)
    print -u2 "Unknown release source scope: ${source_scope}."
    exit 64
    ;;
esac

if ! repository_root=$(goby_release_git "${project_root}" rev-parse --show-toplevel 2>/dev/null); then
  print -u2 "A beta release must be built from a Git repository."
  exit 69
fi
if [[ ${repository_root:A} != ${project_root:A} ]]; then
  print -u2 "The release source must be the repository root: ${repository_root}."
  exit 69
fi
if ! source_commit=$(goby_release_git "${project_root}" rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
  print -u2 "The beta release source has no valid HEAD commit."
  exit 69
fi
if [[ -n ${expected_commit} && ${source_commit} != ${expected_commit} ]]; then
  print -u2 "The release source moved after review; expected ${expected_commit}, found ${source_commit}."
  exit 69
fi
if [[ -n $(goby_release_git "${project_root}" status \
    --porcelain=v1 \
    --untracked-files=all \
    -- "${source_pathspecs[@]}") ]]; then
  print -u2 "The ${scope_description} is not clean. Commit or remove every in-scope tracked and untracked change, review that commit, then retry."
  exit 69
fi

# Finder and editor conflict copies can compile through broad source globs while
# reviewers and runtime imports inspect only the canonical sibling. Refuse the
# common `Name 2.ext` form when the unsuffixed build input is also tracked.
duplicate_pattern='^(.+) [0-9]+(\.(c|cc|cpp|h|hpp|js|jsx|m|mm|swift|ts|tsx))$'
ambiguous_duplicate=''
while IFS= read -r -d '' tracked_path; do
  tracked_name=${tracked_path:t}
  if [[ ${tracked_name} =~ ${duplicate_pattern} ]]; then
    original_name="${match[1]}${match[2]}"
    tracked_directory=${tracked_path:h}
    if [[ ${tracked_directory} == '.' ]]; then
      original_path=${original_name}
    else
      original_path="${tracked_directory}/${original_name}"
    fi
    if goby_release_git "${project_root}" \
      ls-files --error-unmatch -- "${original_path}" >/dev/null 2>&1; then
      ambiguous_duplicate="${tracked_path} (canonical sibling: ${original_path})"
      break
    fi
  fi
done < <(goby_release_git "${project_root}" ls-files -z -- "${source_pathspecs[@]}")
if [[ -n ${ambiguous_duplicate} ]]; then
  print -u2 "The beta release source contains an ambiguous copy-suffixed build input: ${ambiguous_duplicate}."
  exit 69
fi
if [[ -n $(goby_release_git "${project_root}" \
    ls-files --stage -- "${source_pathspecs[@]}" \
    | /usr/bin/grep '^160000 ') ]]; then
  print -u2 "The beta release source contains an in-scope Git submodule. Release inputs must be self-contained in the reviewed commit."
  exit 69
fi

print -r -- "${source_commit}"
