import base64
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from prepare_release import SPARKLE, cask_text, check_appcast, check_previous_appcast, metadata, sha256_file, write_preview
from release_common import configure_info


class ReleaseAssetsTests(unittest.TestCase):
    def setUp(self):
        self.config = {"githubRepository": "example/sayo", "sparklePublicKey": base64.b64encode(bytes(32)).decode()}
        self.info = configure_info({"CFBundleShortVersionString": "0.2.0", "LSMinimumSystemVersion": "14.0"}, "direct", self.config)
        self.release = metadata(self.info, "example/sayo", preview=False)
        self.release.update({"sha256": "a" * 64, "length": 1234})

    def test_store_edition_cannot_enter_the_release_pipeline(self):
        with self.assertRaisesRegex(ValueError, "Only the direct edition"):
            metadata(dict(self.info, SayoDistributionChannel="app-store"), "example/sayo", preview=True)

    def test_feed_mismatch_is_rejected_even_in_preview(self):
        for preview in (True, False):
            with self.assertRaisesRegex(ValueError, "differs"):
                metadata(self.info, "someone/else", preview)

    def test_mismatched_build_is_rejected_even_in_preview(self):
        for preview in (True, False):
            with self.assertRaisesRegex(ValueError, "must be 2000"):
                metadata(dict(self.info, CFBundleVersion="12"), "example/sayo", preview)

    def test_unconfigured_build_requires_explicit_preview(self):
        info = {key: value for key, value in self.info.items() if not key.startswith("SU")}
        with self.assertRaisesRegex(ValueError, "Configure"):
            metadata(info, "example/sayo", preview=False)
        self.assertEqual(metadata(info, "example/sayo", preview=True)["publicKey"], "")

    def test_cask_uses_same_immutable_asset_and_checksum_as_the_feed(self):
        text = cask_text(self.release)
        self.assertIn('version "0.2.0,2000"', text)
        self.assertIn('sha256 "' + "a" * 64 + '"', text)
        resolved = text.replace("#{version.csv.first}", "0.2.0").replace("#{version.csv.second}", "2000")
        self.assertIn(f'url "{self.release["downloadURL"]}"', resolved)
        self.assertIn(f'url "{self.release["feedURL"]}"', text)
        self.assertIn('app "Sayo.app"', text)
        self.assertIn('binary "#{appdir}/Sayo.app/Contents/MacOS/sayo"', text)
        self.assertIn("auto_updates true", text)
        with self.assertRaisesRegex(ValueError, "minimum macOS"):
            cask_text(dict(self.release, minimumSystemVersion="15.0"))

    def test_preview_is_explicitly_unsigned_and_fails_signed_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.preview.xml"
            write_preview(path, self.release)
            self.assertIn("DO NOT PUBLISH", path.read_text())
            self.assertIsNone(check_appcast(path, self.release, require_signature=False))
            with self.assertRaisesRegex(ValueError, "did not sign"):
                check_appcast(path, self.release)

    def test_appcast_cannot_point_at_a_different_archive_or_build(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            for change in ({"downloadURL": "https://example.org/other.dmg"}, {"length": 0}, {"version": "0.3.0"}, {"build": "13"}):
                write_preview(path, dict(self.release, **change))
                with self.assertRaises(ValueError):
                    check_appcast(path, self.release, require_signature=False)

    def test_reusing_or_decreasing_build_numbers_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "previous.xml"
            write_preview(path, self.release)
            check_previous_appcast(path, "2001")
            for build in ("2000", "1999"):
                with self.assertRaisesRegex(ValueError, "Increase"):
                    check_previous_appcast(path, build)
            # Older Sparkle feeds can store the build as an enclosure attribute.
            tree = ET.parse(path)
            item = tree.find("./channel/item")
            item.remove(item.find(f"{{{SPARKLE}}}version"))
            item.find("enclosure").set(f"{{{SPARKLE}}}version", "2002")
            tree.write(path)
            with self.assertRaisesRegex(ValueError, "Increase"):
                check_previous_appcast(path, "2001")

    def test_checksum_covers_archive_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "archive.dmg"
            path.write_bytes(b"abc")
            self.assertEqual(sha256_file(path), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


if __name__ == "__main__":
    unittest.main()
