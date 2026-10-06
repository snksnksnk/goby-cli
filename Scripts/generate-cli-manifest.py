#!/usr/bin/env python3
"""Compile the signed runtime manifests and package hashes into goby.

For each architecture, every file of every provider runtime is hashed, and so
is each downloadable runtime package. The result becomes a generated Swift
constant compiled into the signed binary, which is the only thing goby trusts.
"""
import argparse, base64, hashlib, json, os, re
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def manifest(root):
    result = {}
    if root.is_symlink() or not root.is_dir():
        raise ValueError('A regular runtime directory is required')
    for current, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(current, name)
            if path.is_symlink():
                raise ValueError('Runtime symlinks are forbidden')
        for name in files:
            path = Path(current, name)
            if not path.is_file():
                raise ValueError('Nonregular runtime input')
            result[path.relative_to(root).as_posix()] = digest(path)
    if not result:
        raise ValueError('An empty distribution runtime is forbidden')
    return dict(sorted(result.items()))


def pair(value):
    key, _, path = value.partition('=')
    if not key or not path:
        raise argparse.ArgumentTypeError('Use name=path')
    return key, Path(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--swift', type=Path, required=True)
    parser.add_argument('--json', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--download-base', required=True)
    parser.add_argument('--runtime', type=pair, action='append', default=[], help='arch=folder of provider runtimes')
    parser.add_argument('--archive', type=pair, action='append', default=[], help='component-arch=package file')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?', args.version) or not re.fullmatch(r'[0-9a-f]{40}', args.commit):
        raise ValueError('Invalid release version or source identity')
    if not args.download_base.startswith('https://'):
        raise ValueError('Runtime downloads must use https')
    manifests = {arch: manifest(folder) for arch, folder in args.runtime}
    if not manifests or set(manifests) - {'arm64', 'x86_64'}:
        raise ValueError('Manifests are needed for arm64 and/or x86_64 only')
    archives = {name: digest(path) for name, path in args.archive}
    for name in archives:
        if not re.fullmatch(r'(claude|copilot)-(arm64|x86_64)', name):
            raise ValueError('Unexpected runtime package name: ' + name)
    sidecar = {'version': args.version, 'commit': args.commit, 'downloadBase': args.download_base,
               'manifests': manifests, 'archives': archives}
    data = json.dumps(sidecar, separators=(',', ':'), sort_keys=True).encode()
    encoded = base64.b64encode(json.dumps(manifests, separators=(',', ':'), sort_keys=True).encode()).decode()
    if archives:
        archive_literal = '[\n' + ''.join(f'        {json.dumps(k)}: {json.dumps(v)},\n' for k, v in sorted(archives.items())) + '    ]'
    else:
        archive_literal = '[:]'
    source = '''// Generated release input; never commit this file.
import Foundation
public enum GobyCLICompiledRuntime {
    public static let version = VERSION
    public static let sourceCommit = COMMIT
    public static let downloadBase = BASE
    public static var manifests: [String: [String: String]] {
        guard let data = Data(base64Encoded: MANIFESTS) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }
    public static let archives: [String: String] = ARCHIVES
}
'''.replace('VERSION', json.dumps(args.version)).replace('COMMIT', json.dumps(args.commit)) \
   .replace('BASE', json.dumps(args.download_base)).replace('MANIFESTS', json.dumps(encoded)) \
   .replace('ARCHIVES', archive_literal)
    args.swift.write_text(source)
    args.json.write_bytes(data + b'\n')
    print('Compiled runtime manifests:', {arch: len(values) for arch, values in manifests.items()}, 'packages:', len(archives))


if __name__ == '__main__':
    main()
