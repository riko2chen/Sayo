import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_notes import bump, check, load, next_version, release_body, render, version_from_tag


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('Resources', 'Distribution', 'updates'):
            (self.root / directory).mkdir()
        (self.root / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.0'}))
        (self.root / 'Distribution/versions.json').write_text(json.dumps([{'version': '0.1.0', 'updates': ['initial']}]))
        (self.root / 'updates/initial.json').write_bytes((ROOT / 'updates/initial.json').read_bytes())
        notes, ledger, _ = load(self.root)
        (self.root / 'UPDATE_NOTES.md').write_text('# Sayo update notes\n\n' + render(ledger, notes))

    def note(self, name, kind='patch'):
        (self.root / f'updates/{name}.json').write_text(json.dumps({'bump': kind, 'en': [name], 'zh-CN': [f'更新 {name}']}))

    def test_rollovers_preserve_the_build_number_order(self):
        for old, kind, expected in [('0.1.0', 'patch', '0.1.1'), ('0.1.999', 'patch', '0.2.0'),
                                    ('0.99.999', 'patch', '1.0.0'), ('0.99.2', 'minor', '1.0.0'),
                                    ('0.1.9', 'minor', '0.2.0'), ('0.1.9', 'major', '1.0.0')]:
            self.assertEqual(next_version(old, kind), expected)

    def test_tag_format_and_bounds(self):
        self.assertEqual(version_from_tag('v0.1.0'), '0.1.0')
        for bad in ['0.1.0', 'v00.1.0', 'v0.100.0', 'v0.1.1000', 'v0.1.0-1000', 'v1.0.0\n']:
            with self.assertRaises(ValueError):
                version_from_tag(bad)

    def test_bump_consumes_notes_once_and_uses_highest_requested_kind(self):
        self.note('fix')
        self.note('feature', 'minor')
        self.assertEqual(bump(self.root), '0.2.0')
        self.assertIsNone(bump(self.root))
        self.assertEqual(load(self.root)[2], [])
        self.assertEqual(plistlib.loads((self.root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString'], '0.2.0')
        check(self.root)

    def test_release_notes_aggregate_multiple_merges_but_exclude_previous_and_future(self):
        for name in ('first-fix', 'second-fix', 'future-fix'):
            self.note(name)
            bump(self.root)
        body = release_body('v0.1.2', 'v0.1.0', self.root)
        self.assertIn('first-fix', body)
        self.assertIn('更新 second-fix', body)
        self.assertNotIn('future-fix', body)
        self.assertNotIn('## 0.1.0', body)
        self.assertIn('## 0.1.0', release_body('v0.1.0', root=self.root))
        for previous in ['v0.1.2', 'v0.1.3', 'v0.0.9']:
            with self.assertRaises(ValueError):
                release_body('v0.1.2', previous, self.root)

    def test_missing_and_duplicate_notes_are_rejected(self):
        ledger_path = self.root / 'Distribution/versions.json'
        original = ledger_path.read_text()
        for ids in [['missing'], ['initial', 'initial']]:
            ledger = json.loads(original)
            ledger[0]['updates'] = ids
            ledger_path.write_text(json.dumps(ledger))
            with self.assertRaises(ValueError):
                load(self.root)

    def test_missing_notes_and_manual_version_changes_block_a_release_pr(self):
        with self.assertRaisesRegex(ValueError, 'needs at least one'):
            check(self.root, require_pending=True)
        info = self.root / 'Resources/Info.plist'
        info.write_text(info.read_text().replace('0.1.0', '0.1.1'))
        with self.assertRaisesRegex(ValueError, 'disagree'):
            load(self.root)

    def test_existing_note_cannot_be_rewritten(self):
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.DEVNULL)
        git('init', '-b', 'main')
        git('add', '.')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'Initial')
        self.note('new-fix')
        git('add', '.')
        check(self.root, base='HEAD', require_pending=True)
        self.note('initial')
        notes, ledger, _ = load(self.root)
        (self.root / 'UPDATE_NOTES.md').write_text('# Sayo update notes\n\n' + render(ledger, notes))
        with self.assertRaisesRegex(ValueError, 'immutable'):
            check(self.root, base='HEAD')


if __name__ == '__main__':
    unittest.main()
