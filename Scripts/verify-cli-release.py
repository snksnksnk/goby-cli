#!/usr/bin/env python3
"""Verify payload signatures, architecture, sidecar and compiled runtime trust."""
import argparse, importlib.util, json, plistlib, subprocess, tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('payload', type=Path)
parser.add_argument('--ad-hoc', action='store_true')
args = parser.parse_args()
root = args.payload.resolve()
spec = importlib.util.spec_from_file_location('manifest', Path(__file__).with_name('generate-cli-manifest.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
runtime = root / 'libexec/provider-runtime'
expected = json.loads((root / 'ProviderRuntime.sha256.json').read_text())
assert module.manifest(runtime) == expected, 'Runtime sidecar mismatch'
assert not (root / 'bin/codex').exists(), 'Codex must not be redistributed'
assert not list(root.rglob('*.provisionprofile')), 'CLI payload must not require provisioning profiles'
for path in [root / 'bin/goby', runtime / 'ClaudeAgentSDKBridge/bin/node', runtime / 'CopilotSDKBridge/bin/node']:
    result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(path)], capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    if path.name == 'goby':
        assert not entitlements.get('keychain-access-groups') and not entitlements.get('com.apple.security.application-groups'), 'CLI shares an app group'
    else:
        assert entitlements.get('com.apple.security.cs.allow-jit') and entitlements.get('com.apple.security.cs.allow-unsigned-executable-memory'), 'Node V8 entitlements missing'
files = [root / 'bin/goby'] + list(runtime.rglob('*'))
for path in files:
    if not path.is_file():
        continue
    kind = subprocess.check_output(['/usr/bin/file', '-b', str(path)], text=True)
    if 'Mach-O' not in kind:
        continue
    arch = set(subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split())
    assert arch == {'arm64', 'x86_64'}, 'Thin runtime payload'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
    if not args.ad_hoc:
        details = subprocess.check_output(['/usr/bin/codesign', '-dvvv', str(path)], stderr=subprocess.STDOUT, text=True)
        assert 'Authority=Developer ID Application:' in details and 'runtime' in details, 'Distribution signing missing: ' + str(path.relative_to(root))
for path in runtime.rglob('*.app'):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)], check=True, capture_output=True)
with tempfile.TemporaryDirectory(prefix='goby-cli-verify-') as store:
    result = subprocess.run([str(root / 'bin/goby'), 'doctor', '--json', '--store', store], text=True, capture_output=True, timeout=60)
    row = json.loads(result.stdout)
    assert row['type'] == 'doctor'
    assert any(check['name'] == 'Pinned provider runtime' and check['passed'] for check in row['data']), 'Compiled manifest rejection'
with tempfile.TemporaryDirectory(prefix='goby-cli-handshake-') as home:
    environment = {'HOME': home, 'TMPDIR': home, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
    for helper, provider in [('ClaudeAgentSDKBridge', 'claude'), ('CopilotSDKBridge', 'github-copilot')]:
        folder = runtime / helper
        for architecture in ['arm64', 'x86_64']:
            requests = [
                {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'goby-cli-release-check', 'version': '0.2.0-beta.1'}}},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'shutdown', 'params': {}},
            ]
            result = subprocess.run(['/usr/bin/arch', '-' + architecture, str(folder / 'bin/node'), str(folder / 'index.js')],
                input='\n'.join(json.dumps(row) for row in requests) + '\n', capture_output=True, text=True, env=environment, timeout=60)
            assert result.returncode == 0, 'Signed helper did not initialize'
            rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            assert any(row.get('result', {}).get('providerId') == provider for row in rows), 'Signed bridge protocol mismatch'
            assert any(row.get('result', {}).get('stopped') for row in rows), 'Signed helper did not shut down'
print('CLI payload verified: universal signatures, compiled manifest and signed architecture handshakes')
