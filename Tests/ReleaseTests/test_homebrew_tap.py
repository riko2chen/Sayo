import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("test_tap_update", ROOT / "Distribution/homebrew/tests/test_update_cask.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
HomebrewUpdateTests = module.HomebrewUpdateTests

sys.path.insert(0, str(ROOT / "scripts"))
from prepare_homebrew_tap import prepare


class HomebrewExportTests(unittest.TestCase):
    def test_export_contains_only_public_tap_sources_and_refuses_to_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "tap"
            prepare(output)
            self.assertEqual({str(path.relative_to(output)) for path in output.rglob("*") if path.is_file()}, {
                ".gitignore", ".github/workflows/update.yml", "Casks/sayo.rb.in", "update_cask.py",
                "README.md", "LICENSE", "tests/test_update_cask.py"})
            self.assertFalse((output / "Casks/sayo.rb").exists(), "A recipe needs verified release bytes first")
            with self.assertRaises(FileExistsError):
                prepare(output)
