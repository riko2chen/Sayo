import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ci_signing.sh'


class CISigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        binaries = self.root / 'bin'
        binaries.mkdir()
        stub = binaries / 'security'
        stub.write_text(f'#!{sys.executable}\n' + '''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['TEST_COMMANDS'], 'a') as stream:
    stream.write(json.dumps([name, *sys.argv[1:]]) + '\\n')
if name == 'openssl':
    print('temporary-keychain-password')
elif name == 'security':
    if sys.argv[1] == 'create-keychain':
        pathlib.Path(sys.argv[-1]).touch()
    elif sys.argv[1] == 'delete-keychain':
        pathlib.Path(sys.argv[-1]).unlink(missing_ok=True)
    elif sys.argv[1] == 'find-identity':
        print('  1) ABCDEF "Developer ID Application: Test (TESTTEAM)"')
elif name == 'xcrun':
    sys.exit(int(os.environ.get('TEST_NOTARY_STATUS', '0')))
''')
        stub.chmod(0o700)
        for name in ('openssl', 'xcrun'):
            (binaries / name).symlink_to(stub)
        self.env = {
            'PATH': f'{binaries}:/usr/bin:/bin',
            'HOME': str(self.root),
            'GITHUB_ACTIONS': 'true',
            'RUNNER_TEMP': str(self.root),
            'GITHUB_ENV': str(self.root / 'github-env'),
            'TEST_COMMANDS': str(self.root / 'commands'),
            'SIGNING_CERTIFICATE_P12_BASE64': base64.b64encode(b'test certificate').decode(),
            'SIGNING_CERTIFICATE_PASSWORD': 'test-certificate-password',
            'SPARKLE_PRIVATE_KEY': 'test-update-key',
            'NOTARY_APPLE_ID': 'release@example.invalid',
            'NOTARY_APP_PASSWORD': 'test-app-specific-password',
            'NOTARY_TEAM_ID': 'TESTTEAM',
        }

    def run_script(self, *args):
        return subprocess.run(['/bin/bash', str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True)

    def commands(self):
        path = self.root / 'commands'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_apple_account_credentials_are_validated_and_confined_to_temporary_keychain(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        keychain = self.root / 'sayo-signing.keychain-db'
        self.assertIn(['xcrun', 'notarytool', 'store-credentials', 'sayo-release',
                       '--apple-id', self.env['NOTARY_APPLE_ID'], '--password', self.env['NOTARY_APP_PASSWORD'],
                       '--team-id', 'TESTTEAM', '--keychain', str(keychain), '--validate'], self.commands())
        exported = (self.root / 'github-env').read_text()
        self.assertEqual(exported, 'SAYO_SIGNING_IDENTITY=Developer ID Application: Test (TESTTEAM)\n')
        for secret in ('NOTARY_APPLE_ID', 'NOTARY_APP_PASSWORD', 'SIGNING_CERTIFICATE_PASSWORD', 'SPARKLE_PRIVATE_KEY'):
            self.assertNotIn(self.env[secret], result.stdout + result.stderr + exported)
        self.assertFalse((self.root / 'sayo-signing.p12').exists())
        self.assertFalse((self.root / 'sayo-notary.p8').exists())
        self.assertEqual((self.root / 'sayo-sparkle.key').stat().st_mode & 0o777, 0o600)
        self.env = {key: self.env[key] for key in ('PATH', 'HOME', 'GITHUB_ACTIONS', 'GITHUB_ENV', 'RUNNER_TEMP', 'TEST_COMMANDS')}
        self.assertEqual(self.run_script('cleanup').returncode, 0)
        self.assertFalse(keychain.exists())
        self.assertFalse((self.root / 'sayo-sparkle.key').exists())

    def test_missing_credentials_and_local_execution_fail_before_accessing_keychain(self):
        original = dict(self.env)
        for variable in ('NOTARY_APPLE_ID', 'NOTARY_APP_PASSWORD', 'NOTARY_TEAM_ID'):
            with self.subTest(variable=variable):
                self.env = {**original, variable: ''}
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(variable, result.stderr)
                self.assertEqual(self.commands(), [])
        self.env = {**original, 'GITHUB_ACTIONS': 'false'}
        self.assertIn('only for GitHub Actions', self.run_script().stderr)
        self.assertEqual(self.commands(), [])

    def test_wrong_team_is_rejected_before_sending_credentials_to_apple(self):
        self.env['NOTARY_TEAM_ID'] = 'OTHERTEAM'
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('team must match', result.stderr)
        self.assertFalse(any(command[0] == 'xcrun' for command in self.commands()))
        self.assertFalse((self.root / 'github-env').exists())

    def test_apple_rejection_stops_setup_and_cleanup_removes_material(self):
        self.env['TEST_NOTARY_STATUS'] = '1'
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse((self.root / 'github-env').exists())
        self.assertEqual(self.run_script('cleanup').returncode, 0)
        for name in ('sayo-signing.p12', 'sayo-signing.keychain-db', 'sayo-sparkle.key'):
            self.assertFalse((self.root / name).exists())


if __name__ == '__main__':
    unittest.main()
