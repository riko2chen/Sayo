#!/usr/bin/env python3
"""CI release checks and draft-first publication. Never publishes outside Actions."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from release_common import ROOT, build_number_for_version, release_configuration
from release_notes import check, load, release_body, version_from_tag
from prepare_release import check_appcast, sha256_file


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def select_previous(releases, tag):
    current = int(build_number_for_version(version_from_tag(tag)))
    stable = []
    for release in releases:
        if release['draft'] or release['prerelease'] or release['tag_name'] == tag:
            continue
        version = version_from_tag(release['tag_name'])
        build = int(build_number_for_version(version))
        if build >= current:
            raise ValueError('This tag would downgrade or reuse a published version')
        stable.append((build, release['tag_name']))
    return max(stable)[1] if stable else None


def verify_tag(tag):
    version = version_from_tag(tag)
    if git('rev-parse', f'refs/tags/{tag}^{{commit}}') != git('rev-parse', 'HEAD'):
        raise ValueError('Checkout must match the exact tag commit')
    if git('rev-parse', 'HEAD') not in git('rev-list', '--first-parent', 'origin/main').splitlines():
        raise ValueError('Release tag must point to a commit on the main first-parent history')
    check()
    _, ledger, pending = load()
    if ledger[-1]['version'] != version or pending:
        raise ValueError('Tag must match a versioned commit with no pending update notes')


def output(name, value):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(f'{name}={value}\n')


def prepare(tag):
    verify_tag(tag)
    repository = release_configuration()['githubRepository']
    if repository != os.environ.get('GITHUB_REPOSITORY'):
        raise ValueError('Release repository does not match the app update feed')
    pages = json.loads(gh('api', '--paginate', '--slurp', f'repos/{repository}/releases?per_page=100'))
    releases = [release for page in pages for release in page]
    existing = next((release for release in releases if release['tag_name'] == tag), None)
    if existing and not existing['draft']:
        if existing['prerelease']:
            raise ValueError('Tag already belongs to a prerelease')
        output('published', 'true')
        print('This release is already public; leaving it unchanged.')
        return
    previous = select_previous(releases, tag)
    if previous:
        git('merge-base', '--is-ancestor', f'refs/tags/{previous}^{{commit}}', 'HEAD')
    directory = ROOT / '.build/release-ci'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'notes.md').write_text(release_body(tag, previous))
    if previous:
        subprocess.run(['gh', 'release', 'download', previous, '--repo', repository,
                        '--pattern', 'appcast.xml', '--dir', str(directory)], check=True)
        (directory / 'appcast.xml').rename(directory / 'previous-appcast.xml')
    output('published', 'false')
    output('version', version_from_tag(tag))
    output('previous', previous or '')


def validate_assets(directory, tag):
    release = json.loads((directory / 'release.json').read_text())
    if release['tag'] != tag or release['version'] != version_from_tag(tag):
        raise ValueError('Release assets do not match the tag')
    if release['repository'] != release_configuration()['githubRepository'] or not release['notarized'] or release['preview']:
        raise ValueError('Only notarized, signed production assets may be published')
    expected_name = f"Sayo-{release['version']}-{build_number_for_version(release['version'])}.dmg"
    if release['filename'] != expected_name:
        raise ValueError('Unexpected release filename')
    archive = directory / expected_name
    if sha256_file(archive) != release['sha256'] or archive.stat().st_size != release['length']:
        raise ValueError('Release archive checksum or size changed')
    if (directory / 'SHA256SUMS').read_text() != f"{release['sha256']}  {expected_name}\n":
        raise ValueError('Checksum manifest mismatch')
    check_appcast(directory / 'appcast.xml', release)
    return release, [archive, directory / 'appcast.xml', directory / 'SHA256SUMS']


def publish(tag, directory):
    verify_tag(tag)
    release, assets = validate_assets(directory, tag)
    repository = release['repository']
    if repository != os.environ.get('GITHUB_REPOSITORY'):
        raise ValueError('Publication repository mismatch')
    pages = json.loads(gh('api', '--paginate', '--slurp', f'repos/{repository}/releases?per_page=100'))
    releases = [release for page in pages for release in page]
    existing = next((r for r in releases if r['tag_name'] == tag), None)
    if existing and not existing['draft']:
        raise ValueError('Refusing to modify an already-published release')
    previous = select_previous(releases, tag)
    notes = ROOT / '.build/release-ci/notes.md'
    if notes.read_text() != release_body(tag, previous):
        raise ValueError('Previous release changed while building; rerun before publishing')
    if not existing:
        subprocess.run(['gh', 'release', 'create', tag, '--repo', repository, '--verify-tag', '--draft',
                        '--title', f'Sayo {release["version"]}', '--notes-file', str(notes)], check=True)
    else:
        subprocess.run(['gh', 'release', 'edit', tag, '--repo', repository, '--title', f'Sayo {release["version"]}',
                        '--notes-file', str(notes)], check=True)
    subprocess.run(['gh', 'release', 'upload', tag, '--repo', repository, '--clobber', *map(str, assets)], check=True)
    # Verify the draft's uploaded asset bytes before making the release public.
    import tempfile
    with tempfile.TemporaryDirectory() as temporary:
        subprocess.run(['gh', 'release', 'download', tag, '--repo', repository, '--dir', temporary], check=True)
        for asset in assets:
            if sha256_file(Path(temporary) / asset.name) != sha256_file(asset):
                raise ValueError('Uploaded release asset differs from the verified local file')
    subprocess.run(['gh', 'release', 'edit', tag, '--repo', repository, '--draft=false', '--latest'], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'publish'])
    parser.add_argument('--tag', required=True)
    parser.add_argument('--directory', type=Path, default=ROOT / 'dist/release-ci')
    args = parser.parse_args()
    try:
        if os.environ.get('GITHUB_ACTIONS') != 'true':
            raise ValueError('This command is only for GitHub Actions; use release_notes.py body for a local preview')
        if args.command == 'prepare':
            prepare(args.tag)
        else:
            publish(args.tag, args.directory)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')
