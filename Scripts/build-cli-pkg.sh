#!/bin/zsh -f
# Builds a signed, notarized macOS installer package (.pkg) from a finished,
# notarized goby release folder, for people who don't use Homebrew.
#
#   Scripts/build-cli-pkg.sh <version> <release-folder>
#
# Installs goby to /usr/local/goby and links /usr/local/bin/goby, which is on
# every Mac's PATH. Needs a "Developer ID Installer" certificate; use --unsigned
# only to inspect the layout locally.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

version=${1:?Usage: build-cli-pkg.sh <version> <release-folder> [--unsigned]}
release=${2:?Usage: build-cli-pkg.sh <version> <release-folder> [--unsigned]}
unsigned=${3:-}
release=${release:A}
notary_profile=${GOBY_NOTARY_PROFILE:-goby-notary}
archive="${release}/goby-${version}-universal.tar.gz"
package="${release}/goby-${version}.pkg"
[[ -f ${archive} ]] || { print -u2 "Missing ${archive}. Build the release first."; exit 66; }

installer_identity=${GOBY_INSTALLER_IDENTITY:-}
if [[ ${unsigned} != --unsigned && -z ${installer_identity} ]]; then
  identities=("${(@f)$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p')}")
  if (( ${#identities[@]} != 1 )) || [[ -z ${identities[1]} ]]; then
    print -u2 'A "Developer ID Installer" certificate is required. Create it in Xcode → Settings → Accounts → Manage Certificates.'
    exit 69
  fi
  installer_identity=${identities[1]}
fi

staging=$(mktemp -d "${TMPDIR:-/private/tmp}/goby-pkg.XXXXXX")
trap '/bin/rm -rf -- "${staging}"' EXIT INT TERM
payload="${staging}/payload"
root="${staging}/root"
scripts="${staging}/scripts"
resources="${staging}/resources"
mkdir -p "${payload}" "${root}/usr/local/goby" "${root}/usr/local/bin" "${scripts}" "${resources}"
tar -xzf "${archive}" -C "${payload}"

# The notarized release bytes, unchanged.
codesign --verify --strict --check-notarization -R=notarized "${payload}/bin/goby"
ditto --norsrc --noextattr "${payload}/bin" "${root}/usr/local/goby/bin"
ditto --norsrc --noextattr "${payload}/completions" "${root}/usr/local/goby/completions"
cp "${payload}/README.md" "${payload}/LICENSE" "${root}/usr/local/goby/"
ln -s ../goby/bin/goby "${root}/usr/local/bin/goby"
cat > "${root}/usr/local/goby/uninstall-goby.sh" <<'UNINSTALL'
#!/bin/zsh -f
# Removes the goby installed by its .pkg. Your Goby data, saved sign-ins and
# downloaded runtimes are kept in ~/Library/Application Support.
set -euo pipefail
if [[ -x /usr/local/goby/bin/goby ]]; then /usr/local/goby/bin/goby host stop >/dev/null 2>&1 || true; fi
sudo /bin/rm -f /usr/local/bin/goby
sudo /bin/rm -rf /usr/local/goby
sudo /usr/sbin/pkgutil --forget com.goby.cli >/dev/null 2>&1 || true
print "goby removed. Your data and sign-ins are kept; delete ~/Library/Application Support/Goby CLI* to remove them too."
UNINSTALL
chmod 755 "${root}/usr/local/goby/uninstall-goby.sh"

# Refuse to overwrite a Homebrew-managed goby link.
cat > "${scripts}/preinstall" <<'PRE'
#!/bin/sh
if [ -L /usr/local/bin/goby ]; then
  case "$(readlink /usr/local/bin/goby)" in
    *Cellar*) echo "goby is already installed with Homebrew; use brew upgrade goby." >&2; exit 1 ;;
  esac
fi
exit 0
PRE
chmod 755 "${scripts}/preinstall"

cat > "${resources}/welcome.txt" <<WELCOME
goby ${version}

Installs the goby command-line tool to /usr/local/goby and links it as
/usr/local/bin/goby. Requires macOS 26 or later.

After installing, open Terminal and run:

    goby doctor
    goby login codex      (or claude, or copilot)
    cd ~/code/my-project && goby

Claude and Copilot runtimes download once, on demand, when you sign in.
To remove goby later: /usr/local/goby/uninstall-goby.sh
WELCOME
cp "${payload}/LICENSE" "${resources}/LICENSE.txt"

sign_component=()
sign_product=()
if [[ ${unsigned} != --unsigned ]]; then
  sign_component=(--sign "${installer_identity}" --timestamp)
  sign_product=(--sign "${installer_identity}" --timestamp)
fi
# No extended attributes, so no AppleDouble (._) files land in the payload.
xattr -rc "${root}"
COPYFILE_DISABLE=1 pkgbuild --root "${root}" --identifier com.goby.cli --version "${version}" --install-location / \
  --scripts "${scripts}" ${sign_component} "${staging}/goby-component.pkg" >/dev/null

cat > "${staging}/distribution.xml" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>goby ${version}</title>
    <welcome file="welcome.txt" mime-type="text/plain"/>
    <license file="LICENSE.txt" mime-type="text/plain"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
    <choices-outline><line choice="goby"/></choices-outline>
    <choice id="goby" visible="false"><pkg-ref id="com.goby.cli"/></choice>
    <pkg-ref id="com.goby.cli" version="${version}" onConclusion="none">goby-component.pkg</pkg-ref>
</installer-gui-script>
DIST
productbuild --distribution "${staging}/distribution.xml" --resources "${resources}" --package-path "${staging}" \
  ${sign_product} "${package}" >/dev/null

if [[ ${unsigned} == --unsigned ]]; then
  print "Unsigned package for inspection only: ${package}"
  exit 0
fi
# Notarization credentials can't be read while the screen is locked.
waited=0
until xcrun notarytool history --keychain-profile "${notary_profile}" >/dev/null 2>&1; do
  (( waited == 0 )) && print -u2 'Waiting for the notarization credentials: unlock this Mac to continue.'
  (( waited += 15 )); (( waited <= 1800 )) || { print -u2 'Notarization credentials stayed unreadable.'; exit 69; }
  sleep 15
done
xcrun notarytool submit "${package}" --keychain-profile "${notary_profile}" --wait --output-format json > "${staging}/notary.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Notarization was not accepted"' "${staging}/notary.json"
xcrun stapler staple "${package}" >/dev/null
xcrun stapler validate "${package}" >/dev/null
spctl --assess --type install --verbose=2 "${package}"
(cd "${release}"; shasum -a 256 "${package:t}") >> "${release}/SHA256SUMS"
print "Signed, notarized installer: ${package}"
