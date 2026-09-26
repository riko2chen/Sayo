#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys
from dmg_archive import mounted_dmg
from verify_distribution import verify


def verify_dmg(path):
    with mounted_dmg(Path(path).resolve()) as mount:
        verify(mount / "Sayo.app", "direct")
        assert (mount / "Applications").is_symlink()
        assert os.readlink(mount / "Applications") == "/Applications"
        assert (mount / ".DS_Store").exists(), "Missing installation layout"
        subprocess.run(["swift", str(Path(__file__).with_name("verify-dmg-background.swift")),
                        str(mount / ".background.tiff")], check=True)
    print(f"Verified DMG contents: {path}")


if __name__ == "__main__":
    verify_dmg(sys.argv[1])
