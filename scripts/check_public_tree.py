#!/usr/bin/env python3
"""Reject internal files and obvious credentials in the public snapshot."""
import argparse
from pathlib import PurePosixPath
import re
import subprocess

FORBIDDEN = ('docs/', 'Exports/', 'Resources/LogoCandidates/', '.build/', 'dist/')
LOCAL_TOOL_PATHS = {'.agent', '.agents', '.claude', '.codex'}
SECRET_PATTERNS = [
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})',
    rb'\bAKIA[0-9A-Z]{16}\b',
    rb'\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}',
]


def forbidden_path(name):
    path = PurePosixPath(name)
    return (name.startswith(FORBIDDEN) or any(part.lower() in LOCAL_TOOL_PATHS for part in path.parts) or
            path.name == '.env' or
            path.suffix.lower() in {'.p12', '.p8', '.pem', '.key', '.bundle'})


def check(ref=None, history=False):
    refs = subprocess.check_output(['git', 'rev-list', ref or 'HEAD'], text=True).split() if history else [ref]
    seen = set()
    for revision in refs:
        command = ['git', 'ls-tree', '-r', '-z', revision] if revision else ['git', 'ls-files', '--stage', '-z']
        for item in subprocess.check_output(command).split(b'\0'):
            if not item:
                continue
            meta, raw_name = item.split(b'\t', 1)
            name = raw_name.decode()
            if forbidden_path(name):
                raise ValueError(f'Internal or credential file in public tree: {name}')
            blob = meta.split()[2 if revision else 1].decode()
            if blob in seen:
                continue
            seen.add(blob)
            data = subprocess.check_output(['git', 'cat-file', 'blob', blob])
            if b'\0' not in data and any(re.search(pattern, data) for pattern in SECRET_PATTERNS):
                raise ValueError(f'Credential-shaped content in {name}; inspect locally (value not printed)')
    print('Public tree check passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref')
    parser.add_argument('--history', action='store_true')
    args = parser.parse_args()
    try:
        check(args.ref, args.history)
    except ValueError as error:
        parser.exit(1, f'{error}\n')
