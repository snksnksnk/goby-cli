#!/bin/zsh -f

# Release commands run with a deliberately empty ambient environment. This
# prevents repository, Xcode, Node, and npm configuration inherited from the
# caller from changing reviewed inputs or executing code during packaging.

goby_release_git() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local repository=${1:?repository root is required}
  shift
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/var/empty \
    TMPDIR=/private/tmp \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    /usr/bin/git \
      -c core.fsmonitor=false \
      -c core.hooksPath=/dev/null \
      -c core.attributesFile=/dev/null \
      -c core.excludesFile=/dev/null \
      -c diff.external= \
      -C "${repository}" "$@"
}

goby_release_developer_directory() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local selected_directory canonical_directory xcode_bundle
  selected_directory=$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/var/empty \
    /usr/bin/xcode-select -p)
  canonical_directory=${selected_directory:A}
  xcode_bundle=${canonical_directory:h:h}

  if [[ ${selected_directory} != /* \
     || ${selected_directory} != ${canonical_directory} \
     || ${canonical_directory} != */Contents/Developer \
     || ! -d ${canonical_directory} \
     || ! -d ${xcode_bundle} \
     || ${xcode_bundle} != *.app \
     || ! -f "${xcode_bundle}/Contents/Info.plist" ]]; then
    print -u2 "The active developer directory is not a canonical Xcode application bundle."
    return 69
  fi
  print -r -- "${canonical_directory}"
}

goby_verify_apple_tool() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local executable=${1:?tool executable is required}
  local expected_identifier=${2:?tool signing identifier is required}
  local expected_contents_root=${3:?Xcode contents root is required}
  local canonical_executable=${executable:A}
  local canonical_contents_root=${expected_contents_root:A}
  local requirement

  case ${expected_identifier} in
    com.apple.dt.xcodebuild|com.apple.itunes.altoolShim) ;;
    *)
      print -u2 "Refusing an unreviewed Apple tool identifier: ${expected_identifier}"
      return 69
      ;;
  esac
  if [[ ${canonical_executable} != ${canonical_contents_root}/* \
     || ! -f ${canonical_executable} \
     || ! -x ${canonical_executable} \
     || -L ${canonical_executable} ]]; then
    print -u2 "The selected Xcode tool is outside the canonical application bundle or has an unsafe file type."
    return 69
  fi
  requirement="identifier \"${expected_identifier}\" and anchor apple"
  if ! /usr/bin/codesign --verify --strict -R="${requirement}" \
      "${canonical_executable}" >/dev/null 2>&1; then
    print -u2 "The selected Xcode tool is not the expected Apple-signed ${expected_identifier} executable."
    return 69
  fi
}

goby_release_xcodebuild() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local developer_directory xcode_contents_root
  developer_directory=$(goby_release_developer_directory)
  xcode_contents_root=${developer_directory:h}
  local xcodebuild="${developer_directory}/usr/bin/xcodebuild"

  if [[ ! -x ${xcodebuild} || -L ${xcodebuild} ]]; then
    print -u2 "The active developer directory does not contain a safe xcodebuild executable."
    return 69
  fi
  goby_verify_apple_tool \
    "${xcodebuild}" \
    com.apple.dt.xcodebuild \
    "${xcode_contents_root}" || return $?

  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/var/empty \
    TMPDIR=/private/tmp \
    LANG=C \
    LC_ALL=C \
    DEVELOPER_DIR="${developer_directory}" \
    "${xcodebuild}" "$@"
}

goby_local_development_xcodebuild() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local current_user current_uid configured_home canonical_home home_owner
  local developer_directory xcode_contents_root xcodebuild

  current_user=$(/usr/bin/id -un)
  current_uid=$(/usr/bin/id -u)
  [[ ${current_user} =~ '^[A-Za-z0-9._-]+$' ]] || {
    print -u2 "The local development-signing account name is invalid."
    return 69
  }
  configured_home=$(/usr/bin/dscl . -read "/Users/${current_user}" NFSHomeDirectory 2>/dev/null \
    | /usr/bin/sed -n 's/^NFSHomeDirectory: //p')
  canonical_home=${configured_home:A}
  home_owner=$(/usr/bin/stat -f '%u' "${canonical_home}" 2>/dev/null || true)
  if [[ -z ${configured_home} \
     || ${configured_home} != /* \
     || ${configured_home} != ${canonical_home} \
     || ! -d ${canonical_home} \
     || -L ${canonical_home} \
     || ${home_owner} != ${current_uid} ]]; then
    print -u2 "The authenticated local development-signing home directory is invalid."
    return 69
  fi

  developer_directory=$(goby_release_developer_directory)
  xcode_contents_root=${developer_directory:h}
  xcodebuild="${developer_directory}/usr/bin/xcodebuild"
  if [[ ! -x ${xcodebuild} || -L ${xcodebuild} ]]; then
    print -u2 "The active developer directory does not contain a safe xcodebuild executable."
    return 69
  fi
  goby_verify_apple_tool \
    "${xcodebuild}" \
    com.apple.dt.xcodebuild \
    "${xcode_contents_root}" || return $?

  # Automatic development signing requires the login Keychain and Xcode's
  # installed provisioning profiles. Distribution never uses this wrapper.
  # All inherited build/configuration variables remain removed, and the
  # caller verifies the exact embedded profile, signer and entitlements.
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="${canonical_home}" \
    XDG_CONFIG_HOME=/var/empty \
    TMPDIR=/private/tmp \
    LANG=C \
    LC_ALL=C \
    DEVELOPER_DIR="${developer_directory}" \
    "${xcodebuild}" "$@"
}

goby_validate_sha256() {
  emulate -L zsh
  setopt local_options no_unset
  local value=${1:-}
  local label=${2:-SHA-256}
  if [[ ! ${value} =~ '^[0-9a-f]{64}$' ]]; then
    print -u2 "${label} must be an exact lowercase SHA-256 value."
    return 64
  fi
}

goby_verify_file_sha256() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local file=${1:?file is required}
  local expected=${2:-}
  local label=${3:-File}
  local actual
  goby_validate_sha256 "${expected}" "${label} SHA-256"
  if [[ ! -f ${file} || -L ${file} ]]; then
    print -u2 "${label} must be a regular non-symbolic-link file."
    return 66
  fi
  actual=$(/usr/bin/shasum -a 256 "${file}" | /usr/bin/awk '{print $1}')
  if [[ ${actual} != ${expected} ]]; then
    print -u2 "${label} does not match its owner-approved SHA-256."
    return 65
  fi
}

goby_file_descriptor_identity() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local descriptor_path=${1:?file descriptor path is required}
  if [[ ${descriptor_path} != /dev/fd/<-> || ! -r ${descriptor_path} ]]; then
    print -u2 "The release artifact descriptor is invalid or unreadable."
    return 66
  fi
  /usr/bin/stat -f '%d:%i:%z' "${descriptor_path}"
}

goby_verify_file_descriptor_sha256() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local descriptor_path=${1:?file descriptor path is required}
  local expected=${2:-}
  local label=${3:-File descriptor}
  local actual
  goby_validate_sha256 "${expected}" "${label} SHA-256" || return $?
  goby_file_descriptor_identity "${descriptor_path}" >/dev/null || return $?
  actual=$(/usr/bin/shasum -a 256 "${descriptor_path}" | /usr/bin/awk '{print $1}')
  if [[ ${actual} != ${expected} ]]; then
    print -u2 "${label} does not match its owner-approved SHA-256."
    return 65
  fi
}

goby_validate_app_store_connect_private_key() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local key_path=${1:-}
  local key_id=${2:-}
  local issuer_id=${3:-}
  local repository_root=${4:?repository root is required}
  local canonical_key_path key_mode key_owner current_user

  if [[ ! ${key_id} =~ '^[A-Z0-9]{10,64}$' \
     || ! ${issuer_id} =~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
     || -z ${key_path} ]]; then
    print -u2 "Set the bounded App Store Connect API key ID, issuer UUID, and external private-key path."
    return 64
  fi
  canonical_key_path=${key_path:A}
  key_mode=$(/usr/bin/stat -f '%Lp' "${canonical_key_path}" 2>/dev/null || true)
  key_owner=$(/usr/bin/stat -f '%u' "${canonical_key_path}" 2>/dev/null || true)
  current_user=$(/usr/bin/id -u)
  if [[ ! -f ${canonical_key_path} || -L ${canonical_key_path} \
     || ${canonical_key_path} == ${repository_root:A}/* \
     || ${#canonical_key_path} -gt 1024 \
     || ${canonical_key_path} == *$'\r'* \
     || ${canonical_key_path} == *$'\n'* \
     || ! ${key_mode} =~ '^[0-7]{3,4}$' \
     || ${key_owner} != ${current_user} \
     || $(/usr/bin/sed -n '1p' "${canonical_key_path}") != '-----BEGIN PRIVATE KEY-----' \
     || $(/usr/bin/sed -n '$p' "${canonical_key_path}") != '-----END PRIVATE KEY-----' ]]; then
    print -u2 "The App Store Connect private key must be a bounded owner-only regular external PKCS#8 PEM file."
    return 69
  fi
  if (( (8#${key_mode} & 8#177) != 0 )) \
     || /bin/ls -lde "${canonical_key_path}" 2>/dev/null \
        | /usr/bin/awk 'NR > 1 && $1 ~ /^[0-9]+:$/ { found = 1 } END { exit !found }'; then
    print -u2 "The App Store Connect private key must not be executable or grant ACL, group, or other permissions."
    return 69
  fi
  if ! /usr/bin/openssl pkey -in "${canonical_key_path}" -noout >/dev/null 2>&1; then
    print -u2 "The App Store Connect private key is not a valid unencrypted PKCS#8 private key."
    return 69
  fi
  print -r -- "${canonical_key_path}"
}

goby_verify_ios_entitlements_plist() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local plist=${1:?entitlements plist is required}
  local team_identifier=${2:?team identifier is required}
  local bundle_identifier=${3:?bundle identifier is required}
  local aps_environment=${4:?APNs environment is required}
  local get_task_allow=${5:?get-task-allow value is required}
  local distribution_mode=${6:-development}
  local application_identifier="${team_identifier}.${bundle_identifier}"
  local entitlement_size entitlement_remainder remaining_node_count keychain_value

  if [[ ! -f ${plist} || -L ${plist} ]] \
     || ! /usr/bin/plutil -lint "${plist}" >/dev/null 2>&1; then
    print -u2 "The signed iOS entitlement document is not a valid regular plist."
    return 65
  fi
  entitlement_size=$(/usr/bin/stat -f '%z' "${plist}" 2>/dev/null || true)
  if [[ ! ${entitlement_size} =~ '^[0-9]+$' ]] || (( entitlement_size > 1048576 )); then
    print -u2 "The signed iOS entitlement document exceeds the reviewed size budget."
    return 65
  fi

  # Delete every reviewed root key from a private copy, then ask an XML parser
  # whether any root nodes remain. This avoids line-oriented PlistBuddy output,
  # which can hide a key containing a newline or other display separator.
  entitlement_remainder=$(mktemp "${TMPDIR%/}/goby-ios-entitlement-remainder.XXXXXX.plist")
  /bin/cp "${plist}" "${entitlement_remainder}"
  for key in \
    application-identifier \
    aps-environment \
    'com\.apple\.developer\.team-identifier' \
    get-task-allow \
    keychain-access-groups \
    beta-reports-active; do
    /usr/bin/plutil -remove "${key}" "${entitlement_remainder}" >/dev/null 2>&1 || true
  done
  if ! /usr/bin/plutil -convert xml1 "${entitlement_remainder}" >/dev/null 2>&1; then
    /bin/rm -f -- "${entitlement_remainder}"
    print -u2 "The signed iOS entitlement document could not be normalized safely."
    return 65
  fi
  remaining_node_count=$(
    /usr/bin/xmllint --nonet --xpath 'count(/plist/dict/*)' \
      "${entitlement_remainder}" 2>/dev/null || true
  )
  /bin/rm -f -- "${entitlement_remainder}"
  if [[ ${remaining_node_count} != 0 ]]; then
    print -u2 "The signed iOS entitlement document contains an unreviewed root key."
    return 65
  fi

  if [[ $(/usr/bin/plutil -type application-identifier "${plist}" 2>/dev/null) != string \
     || $(/usr/bin/plutil -extract application-identifier raw -o - "${plist}" 2>/dev/null) != ${application_identifier} \
     || $(/usr/bin/plutil -type aps-environment "${plist}" 2>/dev/null) != string \
     || $(/usr/bin/plutil -extract aps-environment raw -o - "${plist}" 2>/dev/null) != ${aps_environment} \
     || $(/usr/bin/plutil -type 'com\.apple\.developer\.team-identifier' "${plist}" 2>/dev/null) != string \
     || $(/usr/bin/plutil -extract 'com\.apple\.developer\.team-identifier' raw -o - "${plist}" 2>/dev/null) != ${team_identifier} \
     || $(/usr/bin/plutil -type get-task-allow "${plist}" 2>/dev/null) != bool \
     || $(/usr/bin/plutil -extract get-task-allow raw -o - "${plist}" 2>/dev/null) != ${get_task_allow} ]]; then
    print -u2 "The signed iOS entitlement document does not exactly bind the reviewed app, team, APNs, and debugging policy."
    return 65
  fi

  if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "${plist}" >/dev/null 2>&1; then
    if [[ $(/usr/bin/plutil -type keychain-access-groups "${plist}" 2>/dev/null) != array ]]; then
      print -u2 "The signed iOS Keychain entitlement has the wrong type."
      return 65
    fi
    keychain_value=$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "${plist}" 2>/dev/null || true)
    if [[ ${keychain_value} != ${application_identifier} ]] \
       || /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:1' "${plist}" >/dev/null 2>&1; then
      print -u2 "The signed iOS Keychain entitlement is not the single reviewed application group."
      return 65
    fi
  fi

  if [[ ${distribution_mode} == app-store ]]; then
    if [[ $(/usr/bin/plutil -type beta-reports-active "${plist}" 2>/dev/null) != bool \
       || $(/usr/bin/plutil -extract beta-reports-active raw -o - "${plist}" 2>/dev/null) != true ]]; then
      print -u2 "The signed iOS beta entitlement is missing or does not match the reviewed App Store policy."
      return 65
    fi
  elif /usr/libexec/PlistBuddy -c 'Print :beta-reports-active' "${plist}" >/dev/null 2>&1; then
    print -u2 "The signed iOS entitlement document contains an App Store-only entitlement in ${distribution_mode} mode."
    return 65
  fi
}

goby_verify_ios_signed_entitlements() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local app_bundle=${1:?signed app bundle is required}
  local temporary_directory entitlements_file result
  temporary_directory=$(mktemp -d "${TMPDIR%/}/goby-ios-entitlements.XXXXXX")
  entitlements_file="${temporary_directory}/Entitlements.plist"
  if ! /usr/bin/codesign -d --entitlements :- "${app_bundle}" \
      > "${entitlements_file}" 2>/dev/null; then
    /bin/rm -rf -- "${temporary_directory}"
    print -u2 "Could not extract the signed iOS entitlement document."
    return 65
  fi
  goby_verify_ios_entitlements_plist \
    "${entitlements_file}" "${2}" "${3}" "${4}" "${5}" "${6:-development}"
  result=$?
  /bin/rm -rf -- "${temporary_directory}"
  return ${result}
}

goby_release_node() {
  emulate -L zsh
  setopt local_options no_unset pipe_fail
  local node=${1:?Node executable is required}
  local working_directory=${2:?working directory is required}
  local temporary_directory=${3:?temporary directory is required}
  shift 3
  (
    cd "${working_directory}"
    /usr/bin/env -i \
      PATH="${node:h}:/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME=/var/empty \
      TMPDIR="${temporary_directory}" \
      npm_config_cache="${GOBY_NPM_CACHE:-${temporary_directory}/npm-cache}" \
      npm_config_userconfig=/dev/null \
      npm_config_globalconfig=/var/empty/.npmrc \
      npm_config_update_notifier=false \
      "${node}" "$@"
  )
}

goby_validate_public_https_url() {
  emulate -L zsh
  setopt local_options no_unset
  local value=${1:-}
  local label=${2:-Public URL}
  local remainder authority

  if [[ -z ${value} || ${value} != https://* \
     || ${value} == *[[:space:]]* || ${value} == *'?'* || ${value} == *'#'* ]]; then
    print -u2 "${label} must be a public HTTPS URL without whitespace, a query, or a fragment."
    return 64
  fi
  remainder=${value#https://}
  authority=${remainder%%/*}
  if [[ -z ${authority} || ${authority} == *'@'* || ${authority} == *':'* \
     || ${authority} == .* || ${authority} == *. || ${authority} != *.* \
     || ${authority} == *[^A-Za-z0-9.-]* ]]; then
    print -u2 "${label} must use a plain public hostname without credentials or a custom port."
    return 64
  fi
}

goby_ios_profile_application_identifier_is_eligible() {
  emulate -L zsh
  setopt local_options no_unset
  local profile_kind=${1:-}
  local application_identifier=${2:-}
  local expected_application_identifier=${3:-}
  local expected_team_identifier=${4:-}

  case ${profile_kind} in
    development)
      [[ ${application_identifier} == ${expected_application_identifier} \
        || ${application_identifier} == "${expected_team_identifier}.*" ]]
      ;;
    app-store)
      [[ ${application_identifier} == ${expected_application_identifier} ]]
      ;;
    *)
      return 1
      ;;
  esac
}
