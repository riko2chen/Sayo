import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("update_cask", ROOT / "update_cask.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class HomebrewUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Casks").mkdir()
        shutil.copyfile(ROOT / "Casks/sayo.rb.in", self.root / "Casks/sayo.rb.in")
        self.path = self.root / "Casks/sayo.rb"
        self.payload = b"Test DMG bytes"
        self.sha = hashlib.sha256(self.payload).hexdigest()
        self.prefix = "https://github.com/riko2chen/Sayo/releases/download/v0.2.0/"
        self.filename = "Sayo-0.2.0-2000.dmg"
        self.release = {"tag_name": "v0.2.0", "draft": False, "prerelease": False,
                        "published_at": "2026-09-28T00:00:00Z", "assets": []}
        for name in (self.filename, "SHA256SUMS", "appcast.xml"):
            self.release["assets"].append({"name": name, "state": "uploaded",
                                           "browser_download_url": self.prefix + name,
                                           "size": len(self.payload), "digest": "sha256:" + self.sha})
        self.manifest = f"{self.sha}  {self.filename}\n"
        self.feed = f'''<rss xmlns:sparkle="{updater.SPARKLE}"><channel><item>
<sparkle:version>2000</sparkle:version><sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{self.prefix}{self.filename}" length="{len(self.payload)}" sparkle:edSignature="test-signature"/>
</item></channel></rss>'''

    def read(self, url):
        if url == f"https://api.github.com/repos/{updater.REPOSITORY}/releases/latest":
            return json.dumps(self.release).encode()
        return {self.prefix + "SHA256SUMS": self.manifest.encode(),
                self.prefix + "appcast.xml": self.feed.encode()}[url]

    def update(self, payload=None):
        with patch.object(updater, "read_url", side_effect=self.read), \
             patch.object(updater, "urlopen", return_value=io.BytesIO(self.payload if payload is None else payload)) as download:
            result = updater.update(self.root)
        return result, download

    def seed(self):
        self.update()
        return self.path.read_bytes()

    def test_new_release_downloads_and_validates_bytes_then_repeated_run_is_a_noop(self):
        changed, download = self.update()
        self.assertTrue(changed)
        self.assertEqual(download.call_args.args[0].full_url, self.prefix + self.filename)
        text = self.path.read_text()
        self.assertIn('version "0.2.0,2000"', text)
        self.assertIn(f'sha256 "{self.sha}"', text)
        self.assertNotIn("@VERSION@", text)
        changed, download = self.update()
        self.assertFalse(changed)
        download.assert_not_called()

    def test_draft_prerelease_unpublished_and_missing_assets_never_create_a_cask(self):
        original = copy.deepcopy(self.release)
        for change in ({"draft": True}, {"prerelease": True}, {"published_at": None}, {"assets": []}):
            with self.subTest(change=change):
                self.release = dict(original, **change)
                with self.assertRaises(ValueError):
                    self.update()
                self.assertFalse(self.path.exists())

    def test_download_size_or_hash_failure_never_creates_a_cask(self):
        for payload in (b"bad", b"x" * len(self.payload), self.payload + b"extra"):
            with self.subTest(payload=payload), self.assertRaisesRegex(ValueError, "mismatch"):
                self.update(payload)
            self.assertFalse(self.path.exists())

    def test_downgrades_and_changed_checksums_preserve_the_existing_cask(self):
        original = self.seed().decode()
        for previous, message in ((original.replace("0.2.0,2000", "0.3.0,3000"), "downgrade"),
                                  (original.replace(self.sha, "a" * 64), "checksum")):
            self.path.write_text(previous)
            with self.assertRaisesRegex(ValueError, message):
                self.update()
            self.assertEqual(self.path.read_text(), previous)

    def test_asset_urls_and_github_digest_must_match(self):
        original = copy.deepcopy(self.release)
        for field, value in (("browser_download_url", "https://example.com/other.dmg"),
                             ("digest", "sha256:" + "a" * 64)):
            self.release = copy.deepcopy(original)
            self.release["assets"][0][field] = value
            with self.assertRaises(ValueError):
                self.update()
            self.assertFalse(self.path.exists())

    def test_manifest_and_appcast_mismatches_preserve_an_existing_cask(self):
        original = self.seed()
        manifest, feed = self.manifest, self.feed
        variants = [(manifest + manifest, feed), (manifest.replace(self.filename, "other.dmg"), feed)]
        for before, after in ((">2000<", ">2001<"), (">0.2.0<", ">0.2.1<"),
                              (">14.0<", ">15.0<"), (f'length="{len(self.payload)}"', 'length="99"'),
                              ('sparkle:edSignature="test-signature"', ''),
                              (self.prefix + self.filename, "https://example.com/other.dmg")):
            variants.append((manifest, feed.replace(before, after)))
        for self.manifest, self.feed in variants:
            with self.subTest(feed=self.feed, manifest=self.manifest), self.assertRaises(ValueError):
                self.update()
            self.assertEqual(self.path.read_bytes(), original)

    def test_network_failure_keeps_the_installed_recipe(self):
        original = self.seed()
        with patch.object(updater, "read_url", side_effect=OSError("unavailable")):
            with self.assertRaises(OSError):
                updater.update(self.root)
        self.assertEqual(self.path.read_bytes(), original)

    def test_newer_release_replaces_previous_recipe_only_after_download_verification(self):
        original = self.seed()
        self.release = json.loads(json.dumps(self.release).replace("0.2.0", "0.2.1").replace("2000", "2001"))
        self.prefix = self.prefix.replace("0.2.0", "0.2.1")
        self.filename = self.filename.replace("0.2.0", "0.2.1").replace("2000", "2001")
        self.manifest = self.manifest.replace("0.2.0", "0.2.1").replace("2000", "2001")
        self.feed = self.feed.replace("0.2.0", "0.2.1").replace("2000", "2001")
        with self.assertRaisesRegex(ValueError, "mismatch"):
            self.update(b"corrupt")
        self.assertEqual(self.path.read_bytes(), original)
        changed, _ = self.update()
        self.assertTrue(changed)
        self.assertIn('version "0.2.1,2001"', self.path.read_text())

    def test_version_bounds_and_unexpected_template_tokens_are_rejected(self):
        for version in ("0.100.0", "0.1.1000", "0.2.0-beta", "00.2.0", "0.2.0/other"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                updater.version_build(version)
        template = self.root / "Casks/sayo.rb.in"
        template.write_text(template.read_text() + "\n@UNEXPECTED@\n")
        with self.assertRaisesRegex(ValueError, "Unresolved"):
            self.update()
        self.assertFalse(self.path.exists())

    def test_token_is_only_used_for_github_api_requests(self):
        for url, authenticated in (("https://api.github.com/repos/riko2chen/Sayo/releases/latest", True),
                                   (self.prefix + "SHA256SUMS", False)):
            with patch.dict(os.environ, {"GH_TOKEN": "test-token"}), \
                 patch.object(updater, "urlopen", return_value=io.BytesIO(b"{}")) as request:
                updater.read_url(url)
            self.assertEqual(request.call_args.args[0].get_header("Authorization") is not None, authenticated)


if __name__ == "__main__":
    unittest.main()
