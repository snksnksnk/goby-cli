#!/usr/bin/env python3
"""Compile an exact manifest of the already signed provider payload."""
import argparse, base64, hashlib, json, os, re
from pathlib import Path


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
            result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not result:
        raise ValueError('An empty distribution runtime is forbidden')
    return dict(sorted(result.items()))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('swift', type=Path)
    parser.add_argument('json', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?', args.version) or not re.fullmatch(r'[0-9a-f]{40}', args.commit):
        raise ValueError('Invalid release version or source identity')
    values = manifest(args.root)
    data = json.dumps(values, separators=(',', ':'), sort_keys=True).encode()
    encoded = base64.b64encode(data).decode()
    source = '''// Generated release input; never commit this file.
import Foundation
public enum GobyCLICompiledRuntime {
    public static let version = VERSION
    public static let sourceCommit = COMMIT
    public static var manifest: [String: String] {
        guard let data = Data(base64Encoded: MANIFEST) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
'''.replace('VERSION', json.dumps(args.version)).replace('COMMIT', json.dumps(args.commit)).replace('MANIFEST', json.dumps(encoded))
    args.swift.write_text(source)
    args.json.write_bytes(data + b'\n')
    print('Compiled provider manifest entries:', len(values))


if __name__ == '__main__':
    main()
