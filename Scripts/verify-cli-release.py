#!/usr/bin/env python3
"""Verify the base payload, the per-architecture runtimes and their packages.

The base payload holds only goby. Each provider runtime is thinned to one
architecture, signed, packaged, and bound into goby by file and package hash.
"""
import argparse, hashlib, importlib.util, json, os, plistlib, subprocess, tarfile, tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('payload', type=Path)
parser.add_argument('--runtimes', type=Path, required=True, help='folder with arm64/ and x86_64/ runtime trees')
parser.add_argument('--packages', type=Path, required=True, help='folder with goby-runtime-*.tar.gz packages')
parser.add_argument('--ad-hoc', action='store_true')
args = parser.parse_args()
root = args.payload.resolve()
spec = importlib.util.spec_from_file_location('manifest', Path(__file__).with_name('generate-cli-manifest.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sidecar = json.loads((root / 'ProviderRuntime.sha256.json').read_text())
version = sidecar['version']
components = {'claude': 'ClaudeAgentSDKBridge', 'copilot': 'CopilotSDKBridge'}


def entitlements(path):
    result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(path)], capture_output=True, check=True)
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def signed(path):
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
    if not args.ad_hoc:
        details = subprocess.check_output(['/usr/bin/codesign', '-dvvv', str(path)], stderr=subprocess.STDOUT, text=True)
        assert 'Authority=Developer ID Application:' in details and 'runtime' in details, 'Distribution signing missing: ' + str(path)


# Base payload: goby only.
assert not (root / 'libexec').exists(), 'The base package must not carry provider runtimes'
assert not (root / 'bin/codex').exists(), 'Codex must not be redistributed'
assert not list(root.rglob('*.provisionprofile')), 'CLI payload must not require provisioning profiles'
goby = root / 'bin/goby'
assert set(subprocess.check_output(['/usr/bin/lipo', '-archs', str(goby)], text=True).split()) == {'arm64', 'x86_64'}, 'goby must be universal'
signed(goby)
values = entitlements(goby)
assert not values.get('keychain-access-groups') and not values.get('com.apple.security.application-groups'), 'CLI shares an app group'

# Per-architecture runtimes.
for arch, expected in sidecar['manifests'].items():
    tree = args.runtimes / arch
    assert module.manifest(tree) == expected, f'Runtime manifest mismatch for {arch}'
    for path in tree.rglob('*'):
        if not path.is_file() or 'Mach-O' not in subprocess.check_output(['/usr/bin/file', '-b', str(path)], text=True):
            continue
        assert set(subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split()) == {arch}, f'Not thinned to {arch}: {path}'
        signed(path)
    for app in tree.rglob('*.app'):
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    for folder in components.values():
        node = tree / folder / 'bin/node'
        node_entitlements = entitlements(node)
        assert node_entitlements.get('com.apple.security.cs.allow-jit') and node_entitlements.get('com.apple.security.cs.allow-unsigned-executable-memory'), 'Node V8 entitlements missing'

# Packages: hashes match what goby carries, and contents match the manifest.
for name, digest in sidecar['archives'].items():
    component, arch = name.split('-')
    package = args.packages / f'goby-runtime-{component}-{version}-{arch}.tar.gz'
    assert hashlib.sha256(package.read_bytes()).hexdigest() == digest, 'Package hash mismatch: ' + package.name
    with tempfile.TemporaryDirectory(prefix='goby-cli-package-') as unpacked, tarfile.open(package) as archive:
        members = archive.getmembers()
        assert all((member.isfile() or member.isdir()) and not member.name.startswith('/') and '..' not in Path(member.name).parts for member in members), 'Unsafe package entry'
        assert {Path(member.name).parts[0] for member in members} == {components[component]}, 'Package holds more than one runtime'
        # Entries were checked above (no links, absolute or parent paths); the
        # system Python predates tarfile's extraction filters.
        archive.extractall(unpacked)
        wanted = {key: value for key, value in sidecar['manifests'][arch].items() if key.startswith(components[component] + '/')}
        assert module.manifest(Path(unpacked)) == wanted, 'Package contents differ from the manifest: ' + package.name

# Each thinned runtime starts and speaks the bridge protocol on its architecture.
with tempfile.TemporaryDirectory(prefix='goby-cli-handshake-') as home:
    environment = {'HOME': home, 'TMPDIR': home, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
    for arch in sidecar['manifests']:
        for provider_id, folder in [('claude', components['claude']), ('github-copilot', components['copilot'])]:
            bridge = args.runtimes / arch / folder
            requests = [
                {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'goby-cli-release-check', 'version': version}}},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'shutdown', 'params': {}},
            ]
            result = subprocess.run(['/usr/bin/arch', '-' + arch, str(bridge / 'bin/node'), str(bridge / 'index.js')],
                input='\n'.join(json.dumps(row) for row in requests) + '\n', capture_output=True, text=True, env=environment, timeout=60)
            assert result.returncode == 0, f'{folder} ({arch}) did not initialize'
            rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            assert any(row.get('result', {}).get('providerId') == provider_id for row in rows), 'Bridge protocol mismatch'
            assert any(row.get('result', {}).get('stopped') for row in rows), 'Bridge did not shut down'

# End to end: the built goby installs a runtime from these packages and
# accepts it, in a throwaway home folder. It runs through a symlink, the way
# Homebrew puts goby on the PATH.
with tempfile.TemporaryDirectory(prefix='goby-cli-install-') as home:
    linked = Path(home, 'bin/goby')
    linked.parent.mkdir()
    linked.symlink_to(goby)
    environment = dict(os.environ, CFFIXED_USER_HOME=home, HOME=home,
                       GOBY_RUNTIME_DOWNLOAD_BASE=args.packages.resolve().as_uri())
    store = Path(home, 'store')
    run = lambda *command: subprocess.run([str(linked), *command, '--json', '--store', str(store)], text=True, capture_output=True, env=environment, timeout=600)
    result = run('runtime', 'install', 'claude')
    assert result.returncode == 0, 'goby could not install its Claude runtime: ' + result.stdout + result.stderr
    status = json.loads(run('runtime', 'status').stdout.splitlines()[-1])
    assert status['data']['claude'] == 'installed', 'Installed Claude runtime was not accepted'
    doctor = json.loads(run('doctor').stdout.splitlines()[-1])
    assert any(check['name'] == 'Claude runtime' and check['action'].startswith('Installed') for check in doctor['data']), 'Doctor rejected the runtime'
print('CLI release verified: universal goby, thinned signed runtimes, package hashes, handshakes and on-demand install')
