#!/usr/bin/env python3
"""Thin a universal provider runtime folder to one architecture.

Removes npm packages built for the other architecture (…-darwin-x64 or
…-darwin-arm64, and darwin-<other> folders inside packages), thins universal
Mach-O files with lipo, and deletes Mach-O files built only for the other
architecture. Sign the result afterwards: thinning invalidates signatures.
"""
import os, shutil, subprocess, sys
from pathlib import Path

root, arch = Path(sys.argv[1]), sys.argv[2]
assert arch in ('arm64', 'x86_64'), 'Choose arm64 or x86_64'
npm_other = 'darwin-x64' if arch == 'arm64' else 'darwin-arm64'
lipo_other = 'x86_64' if arch == 'arm64' else 'arm64'

removed_packages = 0
for current, directories, _ in os.walk(root, topdown=True, followlinks=False):
    for name in list(directories):
        path = Path(current, name)
        if path.is_symlink():
            raise ValueError('Symlinked runtime input: ' + str(path))
        if 'node_modules' in path.parts and (name.endswith('-' + npm_other) or name == npm_other):
            shutil.rmtree(path)
            directories.remove(name)
            removed_packages += 1

thinned = deleted = 0
for current, _, files in os.walk(root, followlinks=False):
    for name in files:
        path = Path(current, name)
        if 'Mach-O' not in subprocess.check_output(['/usr/bin/file', '-b', str(path)], text=True):
            continue
        archs = set(subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split())
        if archs == {arch}:
            continue
        if arch not in archs:
            path.unlink()
            deleted += 1
            continue
        mode = path.stat().st_mode
        temporary = path.with_name(path.name + '.thin')
        subprocess.run(['/usr/bin/lipo', str(path), '-thin', arch, '-output', str(temporary)], check=True)
        os.replace(temporary, path)
        os.chmod(path, mode)
        thinned += 1
print(f'Thinned runtime to {arch}: {removed_packages} other-architecture packages removed, {thinned} binaries thinned, {deleted} deleted')
