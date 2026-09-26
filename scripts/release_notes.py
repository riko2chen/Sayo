#!/usr/bin/env python3
"""Validate immutable update notes, version them, and render bounded release notes."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

from release_common import ROOT, build_number_for_version

VERSION = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
BUMP_ORDER = ('patch', 'minor', 'major')


def parse_version(value):
    if not isinstance(value, str) or not re.fullmatch(VERSION, value):
        raise ValueError(f'Invalid canonical version: {value!r}')
    build_number_for_version(value)
    return tuple(map(int, value.split('.')))


def version_from_tag(tag):
    if not isinstance(tag, str) or not tag.startswith('v'):
        raise ValueError('Release tags must be vX.Y.Z')
    parse_version(tag[1:])
    return tag[1:]


def next_version(current, bump):
    major, minor, patch = parse_version(current)
    if bump == 'major':
        return f'{major + 1}.0.0'
    if bump == 'minor':
        minor, patch = minor + 1, 0
    elif bump == 'patch':
        patch += 1
        if patch > 999:
            minor, patch = minor + 1, 0
    else:
        raise ValueError('Bump must be patch, minor, or major')
    if minor > 99:
        major, minor = major + 1, 0
    return f'{major}.{minor}.{patch}'


def load(root=ROOT):
    notes = {}
    for path in sorted((root / 'updates').glob('*.json')):
        if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', path.stem):
            raise ValueError(f'Invalid update note filename: {path.name}')
        note = json.loads(path.read_text())
        if set(note) != {'bump', 'en', 'zh-CN'} or note['bump'] not in BUMP_ORDER:
            raise ValueError(f'Invalid update note fields: {path.name}')
        for language in ('en', 'zh-CN'):
            if not isinstance(note[language], list) or not note[language] or any(
                not isinstance(line, str) or not line.strip() or '\n' in line or '\r' in line
                for line in note[language]
            ):
                raise ValueError(f'{path.name} needs nonempty single-line notes in {language}')
        notes[path.stem] = note
    ledger = json.loads((root / 'Distribution/versions.json').read_text())
    if not isinstance(ledger, list) or not ledger:
        raise ValueError('The version ledger must contain the initial release')
    used, previous = set(), -1
    for entry in ledger:
        if set(entry) != {'version', 'updates'}:
            raise ValueError('Invalid version ledger fields')
        parse_version(entry['version'])
        build = int(build_number_for_version(entry['version']))
        if build <= previous:
            raise ValueError('Versions must strictly increase')
        previous = build
        if not isinstance(entry['updates'], list) or not entry['updates']:
            raise ValueError('Each version must contain update notes')
        for note_id in entry['updates']:
            if note_id not in notes or note_id in used:
                raise ValueError(f'Missing or duplicated update note: {note_id}')
            used.add(note_id)
    version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    if version != ledger[-1]['version']:
        raise ValueError('Info.plist and version ledger disagree')
    return notes, ledger, sorted(notes.keys() - used)


def render(entries, notes):
    sections = []
    for entry in reversed(entries):
        sections.append(f"## {entry['version']}")
        for language, title in [('en', 'English'), ('zh-CN', '简体中文')]:
            lines = [line for key in entry['updates'] for line in notes[key][language]]
            sections.append(f'### {title}\n\n' + '\n'.join('- ' + line for line in lines))
    return '\n\n'.join(sections) + '\n'


def check(root=ROOT, base=None, require_pending=False):
    notes, ledger, pending = load(root)
    expected = '# Sayo update notes\n\n' + render(ledger, notes)
    if (root / 'UPDATE_NOTES.md').read_text() != expected:
        raise ValueError('UPDATE_NOTES.md must match the version ledger; run release_notes.py render')
    if base:
        changed = subprocess.check_output(['git', '-C', str(root), 'diff', '--name-status', '--no-renames', base, '--', 'updates'], text=True)
        if any(line.split('\t')[0] != 'A' for line in changed.splitlines()):
            raise ValueError('Published update notes are immutable; add a new note instead')
        for path in ('Resources/Info.plist', 'Distribution/versions.json'):
            old = subprocess.check_output(['git', '-C', str(root), 'show', f'{base}:{path}'])
            if path.endswith('Info.plist'):
                if plistlib.loads(old)['CFBundleShortVersionString'] != ledger[-1]['version']:
                    raise ValueError('Only the version workflow may bump Info.plist')
            elif json.loads(old) != ledger:
                raise ValueError('Sync the version ledger from main before merging')
    if require_pending and not pending:
        raise ValueError('A dev-to-main PR needs at least one new update note')
    return pending


def bump(root=ROOT):
    check(root)
    notes, ledger, pending = load(root)
    if not pending:
        return None
    kind = max((notes[key]['bump'] for key in pending), key=BUMP_ORDER.index)
    version = next_version(ledger[-1]['version'], kind)
    ledger.append({'version': version, 'updates': pending})
    info_path = root / 'Resources/Info.plist'
    info = info_path.read_text()
    info, count = re.subn(r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)',
                          lambda m: m[1] + version + m[2], info)
    if count != 1:
        raise ValueError('Expected exactly one version in Info.plist')
    info_path.write_text(info)
    (root / 'Distribution/versions.json').write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n')
    (root / 'UPDATE_NOTES.md').write_text('# Sayo update notes\n\n' + render(ledger, notes))
    return version


def release_body(tag, previous=None, root=ROOT):
    notes, ledger, pending = load(root)
    versions = [entry['version'] for entry in ledger]
    current = version_from_tag(tag)
    if current not in versions:
        raise ValueError('Tag version is missing from the ledger')
    end = versions.index(current) + 1
    start = 0
    if previous:
        version = version_from_tag(previous)
        if version not in versions:
            raise ValueError('Previous release is missing from the ledger')
        start = versions.index(version) + 1
        if start >= end:
            raise ValueError('Previous release must precede the current tag')
    return render(ledger[start:end], notes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'bump', 'render', 'body'])
    parser.add_argument('--base')
    parser.add_argument('--require-pending', action='store_true')
    parser.add_argument('--tag')
    parser.add_argument('--previous')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'check':
            check(base=args.base, require_pending=args.require_pending)
            print('Update notes and version ledger verified')
        elif args.command == 'bump':
            print(bump() or 'unchanged')
        elif args.command == 'render':
            notes, ledger, _ = load()
            (ROOT / 'UPDATE_NOTES.md').write_text('# Sayo update notes\n\n' + render(ledger, notes))
        else:
            body = release_body(args.tag, args.previous)
            if args.output:
                args.output.write_text(body)
            else:
                print(body, end='')
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
