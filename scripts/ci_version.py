#!/usr/bin/env python3
"""CI-only: commit pending versions on main, then merge the result back into dev."""
import os
import subprocess
import sys

from release_notes import bump, check


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('This write/push command is only for GitHub Actions')
    git('config', 'user.name', 'sayo-release[bot]')
    git('config', 'user.email', 'sayo-release[bot]@users.noreply.github.com')
    for attempt in range(3):
        git('fetch', 'origin', 'main', 'dev')
        git('checkout', '-B', 'main', 'origin/main')
        version = bump()
        if version:
            check()
            subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'Tests/ReleaseTests', '-v'], check=True)
            git('add', 'Resources/Info.plist', 'Distribution/versions.json', 'UPDATE_NOTES.md')
            git('commit', '-m', f'chore(release): version {version}')
        result = subprocess.run(['git', 'push', 'origin', 'HEAD:refs/heads/main'])
        if result.returncode == 0:
            break
    else:
        raise ValueError('main kept advancing; retry this workflow (no force push was used)')
    version_commit = git('rev-parse', 'HEAD')
    for attempt in range(3):
        git('fetch', 'origin', 'dev')
        git('checkout', '-B', 'dev', 'origin/dev')
        try:
            git('merge', '--no-edit', version_commit)
        except subprocess.CalledProcessError as error:
            git('merge', '--abort')
            raise ValueError('Version committed on main, but dev has a conflict. Merge main into dev and retry.') from error
        if subprocess.run(['git', 'push', 'origin', 'HEAD:refs/heads/dev']).returncode == 0:
            print('Version metadata synchronized to dev; no tag or release was created.')
            return
    raise ValueError('dev kept advancing; merge main into dev or retry this workflow')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
