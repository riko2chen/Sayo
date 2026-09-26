import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from check_push import check
import check_public_tree as public_tree


class PushGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.previous)
        self.git('init', '-b', 'local')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.com')
        (self.root / 'private.txt').write_text('Archived source')
        self.git('add', '.')
        self.git('commit', '-m', 'Private history')
        self.old = self.git('rev-parse', 'HEAD')
        self.git('checkout', '--orphan', 'main')
        self.git('rm', '-rf', '.')
        (self.root / 'README.md').write_text('Public source')
        self.git('add', '.')
        self.git('commit', '-m', 'Public root')
        self.new = self.git('rev-parse', 'HEAD')
        (self.root / '.git/sayo-local-archive.json').write_text(json.dumps({'roots': [self.old]}))

    def git(self, *args):
        return subprocess.check_output(['git', *args], text=True, stderr=subprocess.DEVNULL).strip()

    def line(self, sha, source='refs/heads/main', target='refs/heads/main'):
        return f'{source} {sha} {target} ' + '0' * 40

    def test_clean_public_root_allowed_but_archive_aliases_are_rejected(self):
        url = 'git@github.com:riko2chen/Sayo.git'
        check([self.line(self.new)], url)
        with self.assertRaisesRegex(ValueError, 'archived private history'):
            check([self.line(self.old, target='refs/tags/v0.1.0')], url)
        with self.assertRaisesRegex(ValueError, 'local is permanently private'):
            check([self.line(self.old, source='refs/heads/local')], url)
        with self.assertRaisesRegex(ValueError, 'must not be moved'):
            check([f'refs/tags/v0.1.0 {self.new} refs/tags/v0.1.0 {self.old}'], url)

    def test_push_lock_and_private_remote_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'public Sayo repository'):
            check([self.line(self.new)], 'git@github.com:riko2chen/Sayo-private.git')
        (self.root / '.git/sayo-push-lock').write_text('Await approval')
        with self.assertRaisesRegex(ValueError, 'Push is locked'):
            check([self.line(self.new)], 'git@github.com:riko2chen/Sayo.git')

    def test_internal_files_are_rejected_even_after_they_are_deleted(self):
        (self.root / 'docs').mkdir()
        (self.root / 'docs/internal.md').write_text('Internal')
        self.git('add', '.')
        self.git('commit', '-m', 'Accidental internal file')
        self.git('rm', '-r', 'docs')
        self.git('commit', '-m', 'Remove internal file')
        with self.assertRaisesRegex(ValueError, 'internal or credential'):
            check([self.line(self.git('rev-parse', 'HEAD'))], 'git@github.com:riko2chen/Sayo.git')

    def test_local_agent_paths_are_rejected_in_index_tree_and_push(self):
        for name in ('.agent', '.agents', '.claude', '.codex'):
            for parent in ('', 'nested/'):
                with self.subTest(name=name, parent=parent):
                    self.git('reset', '--hard', self.new)
                    relative = f'{parent}{name}/settings.json'
                    path = self.root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('{}')
                    self.git('add', relative)
                    with self.assertRaisesRegex(ValueError, 'Internal or credential'):
                        public_tree.check()
                    self.git('commit', '-m', 'Accidental agent configuration')
                    with self.assertRaisesRegex(ValueError, 'Internal or credential'):
                        public_tree.check('HEAD')
                    with self.assertRaisesRegex(ValueError, 'internal or credential'):
                        check([self.line(self.git('rev-parse', 'HEAD'))], 'git@github.com:riko2chen/Sayo.git')

    def test_deleted_agent_paths_remain_blocked_in_public_history(self):
        path = self.root / 'nested/.claude/settings.json'
        path.parent.mkdir(parents=True)
        path.write_text('{}')
        self.git('add', '.')
        self.git('commit', '-m', 'Accidental agent configuration')
        self.git('rm', '-r', 'nested')
        self.git('commit', '-m', 'Remove agent configuration')
        public_tree.check('HEAD')
        with self.assertRaisesRegex(ValueError, 'Internal or credential'):
            public_tree.check('HEAD', history=True)
        with self.assertRaisesRegex(ValueError, 'internal or credential'):
            check([self.line(self.git('rev-parse', 'HEAD'))], 'git@github.com:riko2chen/Sayo.git')

    def test_agent_path_matching_uses_whole_components(self):
        for name in ('nested/.CLAUDE/settings.json', '.agent', '.agents', '.claude', '.codex'):
            with self.subTest(name=name):
                self.assertTrue(public_tree.forbidden_path(name))
        for name in ('AGENTS.md', 'Sources/Agent.swift', 'nested/.claude-example.json'):
            with self.subTest(name=name):
                self.assertFalse(public_tree.forbidden_path(name))


if __name__ == '__main__':
    unittest.main()
