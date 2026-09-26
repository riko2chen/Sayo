import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_common import build_number_for_version, configure_info, feed_url, release_configuration, validate_version


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.info = {'CFBundleShortVersionString': '0.1.0'}
        self.config = {'githubRepository': 'example/sayo', 'sparklePublicKey': base64.b64encode(bytes(32)).decode()}

    def test_store_channel_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Only direct builds'):
            configure_info(self.info, 'app-store', self.config)

    def test_unpublished_build_has_no_network_destination(self):
        info = configure_info(self.info, 'direct', {})
        self.assertNotIn('SUFeedURL', info)
        self.assertNotIn('SUPublicEDKey', info)
        self.assertFalse(info['SUEnableAutomaticChecks'])

    def test_feed_is_stable_across_versions_and_builds(self):
        one = configure_info(self.info, 'direct', self.config, '0.2.0')
        two = configure_info(self.info, 'direct', self.config, '0.3.0')
        self.assertEqual(one['SUFeedURL'], two['SUFeedURL'])
        self.assertEqual(one['SUFeedURL'], feed_url('example/sayo'))
        self.assertTrue(one['SUVerifyUpdateBeforeExtraction'])

    def test_rejects_partial_configuration_and_invalid_public_key(self):
        for config in [dict(self.config, sparklePublicKey=''), dict(self.config, sparklePublicKey='invalid'), dict(self.config, githubRepository='https://github.com/example/sayo?token=secret')]:
            with tempfile.TemporaryDirectory() as temporary:
                file = Path(temporary) / 'config.json'
                file.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    release_configuration(file)

    def test_rejects_invalid_versions_before_generating_a_bundle(self):
        for version in ('', 'v1.0.0', '1.0', '1.0.0.0', '-1.0.0', '1.-1.0',
                        '1.0.-1', '1.100.0', '0.0.1000', '1.0.0-beta', '1.0.0;bad'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                configure_info(self.info, 'direct', {}, version)

    def test_build_number_is_calculated_from_version_components(self):
        for version, build in [('0.0.0', '0'), ('0.0.1', '1'), ('0.1.0', '1000'),
                               ('0.99.999', '99999'), ('1.0.0', '100000'),
                               ('1.2.3', '102003'), ('12.99.999', '1299999')]:
            with self.subTest(version=version):
                self.assertEqual(build_number_for_version(version), build)
                info = configure_info(self.info, 'direct', {}, version)
                self.assertEqual(info['CFBundleShortVersionString'], version)
                self.assertEqual(info['CFBundleVersion'], build)
                validate_version(version, build)

    def test_build_numbers_increase_at_component_rollovers(self):
        for before, after in [('0.0.999', '0.1.0'), ('0.99.999', '1.0.0'),
                              ('1.99.999', '2.0.0')]:
            with self.subTest(before=before, after=after):
                self.assertEqual(int(build_number_for_version(after)),
                                 int(build_number_for_version(before)) + 1)

    def test_build_uses_version_even_when_template_contains_a_stale_build(self):
        template = dict(self.info, CFBundleVersion='1')
        info = configure_info(template, 'direct', {})
        self.assertEqual(info['CFBundleVersion'], '1000')
        self.assertEqual(template['CFBundleVersion'], '1')

    def test_embedded_build_must_match_the_version(self):
        for build in ('1', '0', '100001', '0100000', '1;bad'):
            with self.subTest(build=build), self.assertRaisesRegex(ValueError, 'must be 100000'):
                validate_version('1.0.0', build)

    def test_direct_target_links_updater(self):
        package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], cwd=ROOT))
        targets = {target['name']: target for target in package['targets']}
        self.assertNotIn('SayoAppStore', targets)
        self.assertIn('SayoUpdates', str(targets['SayoApp']['dependencies']))


if __name__ == '__main__':
    unittest.main()
