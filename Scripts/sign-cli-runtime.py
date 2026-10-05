#!/usr/bin/env python3
import os, subprocess, sys
from pathlib import Path
root, identity, entitlements = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
for current, directories, files in os.walk(root, followlinks=False):
    for name in directories + files:
        if Path(current, name).is_symlink():
            raise ValueError('Symlinked runtime input')
    for name in files:
        path = Path(current, name)
        if 'Mach-O' not in subprocess.check_output(['/usr/bin/file', '-b', str(path)], text=True):
            continue
        assert set(subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split()) == {'arm64', 'x86_64'}, 'Thin native dependency'
        args = ['/usr/bin/codesign', '--force', '--options', 'runtime', '--sign', identity]
        if identity != '-':
            args += ['--timestamp']
        if path.name == 'node' and path.parent.name == 'bin':
            args += ['--entitlements', entitlements]
        subprocess.run(args + [str(path)], check=True, capture_output=True)
for path in sorted(root.rglob('*.app'), key=lambda p: len(p.parts), reverse=True):
    args = ['/usr/bin/codesign', '--force', '--options', 'runtime', '--sign', identity]
    if identity != '-':
        args += ['--timestamp']
    subprocess.run(args + [str(path)], check=True, capture_output=True)
print('Signed universal provider payloads inside out')
