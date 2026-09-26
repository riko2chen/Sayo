import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import ci_release


def release(tag, draft=False, prerelease=False):
    return {'tag_name': tag, 'draft': draft, 'prerelease': prerelease}


class CIReleaseTests(unittest.TestCase):
    def test_previous_release_is_highest_published_version_not_latest_created_tag(self):
        releases = [release('v0.1.3', draft=True), release('v0.1.2'), release('v0.1.1'), release('v0.1.4', prerelease=True)]
        self.assertEqual(ci_release.select_previous(releases, 'v0.1.3'), 'v0.1.2')
        self.assertIsNone(ci_release.select_previous([], 'v0.1.0'))
        with self.assertRaisesRegex(ValueError, 'downgrade'):
            ci_release.select_previous([release('v0.2.0')], 'v0.1.3')

    def test_already_published_release_is_a_noop_before_credentials_or_asset_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            with patch.object(ci_release, 'verify_tag'), patch.object(ci_release, 'gh', return_value=json.dumps([[release('v0.1.0')]])), \
                 patch.dict(os.environ, {'GITHUB_OUTPUT': str(output), 'GITHUB_REPOSITORY': 'riko2chen/Sayo'}):
                ci_release.prepare('v0.1.0')
            self.assertEqual(output.read_text(), 'published=true\n')

    def test_tag_on_side_branch_or_unversioned_commit_is_rejected(self):
        def git(*args):
            if args[0] == 'rev-parse':
                return 'a' * 40
            return 'b' * 40
        with patch.object(ci_release, 'git', side_effect=git):
            with self.assertRaisesRegex(ValueError, 'first-parent'):
                ci_release.verify_tag('v0.1.0')
        with patch.object(ci_release, 'git', return_value='a' * 40), patch.object(ci_release, 'check'), \
             patch.object(ci_release, 'load', return_value=({}, [{'version': '0.1.0'}], ['pending'])):
            with self.assertRaisesRegex(ValueError, 'pending'):
                ci_release.verify_tag('v0.1.0')

    def test_preview_and_unnotarized_assets_cannot_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for preview, notarized in [(True, True), (False, False)]:
                (root / 'release.json').write_text(json.dumps({'tag': 'v0.1.0', 'version': '0.1.0', 'repository': 'riko2chen/Sayo',
                                                            'notarized': notarized, 'preview': preview}))
                with self.assertRaisesRegex(ValueError, 'notarized'):
                    ci_release.validate_assets(root, 'v0.1.0')

    def test_ci_mutation_commands_refuse_local_execution(self):
        for script, args in [('ci_version.py', []), ('ci_release.py', ['prepare', '--tag', 'v0.1.0'])]:
            result = subprocess.run([sys.executable, str(ROOT / 'scripts' / script), *args],
                                    env={**os.environ, 'GITHUB_ACTIONS': 'false'}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('only for GitHub Actions', result.stderr)

    def test_version_workflow_commits_once_and_merges_back_to_dev_using_a_local_remote(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bare, work = root / 'remote.git', root / 'work'
            def run(*args):
                return subprocess.check_output(args, cwd=work if work.exists() else root, stderr=subprocess.DEVNULL, text=True).strip()
            run('git', 'init', '--bare', '--initial-branch=main', str(bare))
            run('git', 'clone', str(bare), str(work))
            run('git', 'config', 'user.name', 'Test')
            run('git', 'config', 'user.email', 'test@example.com')
            for path in ('scripts/ci_version.py', 'scripts/release_notes.py', 'scripts/release_common.py', 'Resources/Info.plist',
                         'Distribution/versions.json', 'UPDATE_NOTES.md', 'updates/initial.json'):
                target = work / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / path, target)
            # Seed a fixed baseline independent of whichever version CI is currently bumping.
            info_path = work / 'Resources/Info.plist'
            info = plistlib.loads(info_path.read_bytes())
            info['CFBundleShortVersionString'] = '0.1.0'
            info_path.write_bytes(plistlib.dumps(info))
            ledger = [{'version': '0.1.0', 'updates': ['initial']}]
            (work / 'Distribution/versions.json').write_text(json.dumps(ledger))
            from release_notes import render
            initial = json.loads((work / 'updates/initial.json').read_text())
            (work / 'UPDATE_NOTES.md').write_text('# Sayo update notes\n\n' + render(ledger, {'initial': initial}))
            (work / 'Tests/ReleaseTests').mkdir(parents=True)
            (work / 'Tests/ReleaseTests/test_metadata.py').write_text(
                "import unittest, sys\nsys.path.insert(0, 'scripts')\nfrom release_notes import check\n"
                'class MetadataTests(unittest.TestCase):\n    def test_versioned_metadata(self):\n        check()\n')
            run('git', 'add', '.')
            run('git', 'commit', '-m', 'Initial')
            run('git', 'push', 'origin', 'main')
            run('git', 'switch', '-c', 'dev')
            note = work / 'updates/new-fix.json'
            note.write_text(json.dumps({'bump': 'patch', 'en': ['Fix'], 'zh-CN': ['修复']}))
            run('git', 'add', '.')
            run('git', 'commit', '-m', 'Fix')
            run('git', 'push', 'origin', 'dev')
            run('git', 'switch', 'main')
            run('git', 'merge', '--no-ff', 'dev', '-m', 'Merge tested dev')
            run('git', 'push', 'origin', 'main')
            command = [sys.executable, 'scripts/ci_version.py']
            env = {**os.environ, 'GITHUB_ACTIONS': 'true'}
            result = subprocess.run(command, cwd=work, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            commit = run('git', 'rev-parse', 'origin/main')
            self.assertIn('chore(release): version', run('git', 'log', '-1', '--format=%s', 'origin/main'))
            run('git', 'merge-base', '--is-ancestor', 'origin/main', 'origin/dev')
            again = subprocess.run(command, cwd=work, env=env, capture_output=True, text=True)
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertEqual(commit, run('git', 'rev-parse', 'origin/main'))


if __name__ == '__main__':
    unittest.main()
