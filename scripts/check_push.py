#!/usr/bin/env python3
"""Installed as a local hook: never publish archived history or internal files."""
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

LOCAL_TOOL_PATHS = {'.agent', '.agents', '.claude', '.codex'}


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def check(lines, remote_url):
    common = Path(git('rev-parse', '--git-common-dir')).resolve()
    if (common / 'sayo-push-lock').exists():
        raise ValueError('Push is locked. Obtain explicit approval before removing the local push lock.')
    if remote_url not in {'git@github.com:riko2chen/Sayo.git', 'https://github.com/riko2chen/Sayo.git'}:
        raise ValueError('This checkout may only push to the public Sayo repository')
    archive = common / 'sayo-local-archive.json'
    roots = json.loads(archive.read_text())['roots'] if archive.exists() else []
    visited = set()
    for line in lines:
        local_ref, sha, remote_ref, remote_sha = line.split()
        if local_ref == 'refs/heads/local' or not re.fullmatch(r'refs/(?:heads/(?:main|dev)|tags/v\d+\.\d+\.\d+)', remote_ref):
            raise ValueError('Only main, dev, and version tags may be pushed; local is permanently private')
        if set(sha) == {'0'}:
            raise ValueError('Deleting remote branches or release tags requires a separate manual decision')
        if remote_ref.startswith('refs/tags/') and set(remote_sha) != {'0'} and sha != remote_sha:
            raise ValueError('Published version tags must not be moved')
        commit = git('rev-parse', f'{sha}^{{commit}}')
        for root in roots:
            if subprocess.run(['git', 'merge-base', '--is-ancestor', root, commit], stdout=subprocess.DEVNULL).returncode == 0:
                raise ValueError('Ref contains archived private history, even if pushed under a different name')
        for revision in git('rev-list', commit).splitlines():
            if revision in visited:
                continue
            visited.add(revision)
            names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', '-z', revision]).decode().split('\0')
            for name in names:
                path = PurePosixPath(name)
                if (name.startswith(('docs/', 'Exports/', 'Resources/LogoCandidates/')) or
                        any(part.lower() in LOCAL_TOOL_PATHS for part in path.parts) or
                        path.suffix in {'.p12', '.p8', '.pem', '.key', '.bundle'}):
                    raise ValueError('Ref history contains an internal or credential file: ' + name)
    print('Public push guard passed; archived local history remains private.')


if __name__ == '__main__':
    try:
        check(sys.stdin.read().splitlines(), sys.argv[2])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
