#!/usr/bin/env python3
"""Verify the direct distribution bundle, including its real Mach-O links."""
import plistlib
from pathlib import Path
import subprocess
import sys

from release_common import validate_version


def output(*args):
    return subprocess.check_output([str(x) for x in args], stderr=subprocess.DEVNULL)


def verify(app, channel):
    app = Path(app)
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    validate_version(info["CFBundleShortVersionString"], info["CFBundleVersion"])
    executable = contents / "MacOS" / info["CFBundleExecutable"]
    assert info["SayoDistributionChannel"] == channel, "Incorrect channel metadata"
    links = output("otool", "-L", executable).decode()
    framework = contents / "Frameworks/Sparkle.framework"
    assert not info.get("NSServices"), "Bundle must not register macOS Services"
    for locale in ("en", "zh-Hans"):
        assert not (contents / "Resources" / (locale + ".lproj") / "ServicesMenu.strings").exists()
    assert framework.exists(), "Direct bundle is missing Sparkle"
    for license_name in ("Sayo-LICENSE", "Sparkle-LICENSE"):
        assert (contents / "Resources" / license_name).is_file(), f"Missing bundled license: {license_name}"
    assert "@rpath/Sparkle.framework/" in links, "Direct executable does not load bundled Sparkle"
    assert not (contents / "_MASReceipt").exists(), "Direct bundle contains a store receipt"
    assert bool(info.get("SUFeedURL")) == bool(info.get("SUPublicEDKey")), "Incomplete update configuration"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(f"Verified {channel}: {app}")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[2] != "direct":
        sys.exit("Usage: verify_distribution.py <Sayo.app> direct")
    verify(sys.argv[1], sys.argv[2])
