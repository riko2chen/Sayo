#!/usr/bin/env python3
"""Opt-in local integration: real Sparkle signing, tamper rejection and Homebrew DSL.

Run after building the universal direct app:
    python3 Tests/ReleaseTests/integration_release.py
Uses a disposable signing key and app copy, never the user's Keychain or installed app.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from prepare_release import SPARKLE, TOOLS, sha256_file
from release_common import configure_info


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="sayo-release-test-") as temporary:
    directory = Path(temporary)
    seed, public = directory / "private-key", directory / "public-key"
    key_script = directory / "create-key.swift"
    key_script.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let secret = key.rawRepresentation.base64EncodedData()
precondition(FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: secret, attributes: [.posixPermissions: 0o600]))
try key.publicKey.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
''')
    run("swift", key_script, seed, public)
    assert seed.stat().st_mode & 0o777 == 0o600
    config = {"githubRepository": "example/sayo", "sparklePublicKey": public.read_text()}
    source = directory / "source"
    source.mkdir()
    app = source / "Sayo.app"
    run("ditto", ROOT / "dist/direct/Sayo.app", app)
    info_path = app / "Contents/Info.plist"
    info = configure_info(plistlib.loads(info_path.read_bytes()), "direct", config)
    info_path.write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", app)
    dmg = directory / "test.dmg"
    run("hdiutil", "create", "-quiet", "-srcfolder", source, "-format", "UDZO", "-volname", "Sayo Release Test", dmg)
    run("codesign", "--force", "--sign", "-", dmg)
    output = directory / "release"
    arguments = [sys.executable, ROOT / "scripts/prepare_release.py", "--dmg", dmg,
                 "--repository", "example/sayo", "--key-file", seed, "--output", output]
    # A normal release must reject an unnotarized archive.
    rejected = subprocess.run([str(arg) for arg in arguments], capture_output=True, text=True)
    assert rejected.returncode != 0 and "notarization ticket" in rejected.stderr, rejected.stderr
    assert not output.exists()
    run(*arguments, "--allow-unnotarized")
    release = json.loads((output / "release.json").read_text())
    archive = output / release["filename"]
    assert release["sha256"] == sha256_file(archive)
    assert not release["preview"] and not release["notarized"]
    assert not any("private" in path.name for path in output.rglob("*"))
    enclosure = ET.parse(output / "appcast.xml").find("./channel/item/enclosure")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature")
    assert signature
    tampered = directory / "tampered.dmg"
    tampered.write_bytes(archive.read_bytes() + b"tampered")
    rejected = subprocess.run([str(TOOLS / "sign_update"), "--ed-key-file", str(seed), "--verify", str(tampered), signature], capture_output=True, text=True)
    assert rejected.returncode != 0, "A modified archive was accepted"
    # Parse the generated Cask with Homebrew itself, without tapping or installing.
    environment = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_ANALYTICS="1", HOMEBREW_DEVELOPER="1")
    run("brew", "ruby", ROOT / "scripts/verify_cask.rb", output, env=environment)
    # A different signing key must never result in a usable release directory.
    other_seed, other_public = directory / "other-private-key", directory / "other-public-key"
    run("swift", key_script, other_seed, other_public)
    mismatch_output = directory / "mismatched"
    rejected = subprocess.run([sys.executable, str(ROOT / "scripts/prepare_release.py"), "--dmg", str(dmg),
                               "--repository", "example/sayo", "--key-file", str(other_seed),
                               "--output", str(mismatch_output), "--allow-unnotarized"], capture_output=True, text=True)
    assert rejected.returncode != 0, "A mismatched signing key was accepted"
    assert not mismatch_output.exists()
    # Prepare the next version against the previous feed: preserve its immutable URL.
    next_major = int(info["CFBundleShortVersionString"].split(".")[0]) + 1
    info = configure_info(info, "direct", config, f"{next_major}.0.0")
    info_path.write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", app)
    next_dmg = directory / "next.dmg"
    run("hdiutil", "create", "-quiet", "-srcfolder", source, "-format", "UDZO", "-volname", "Sayo Release Test", next_dmg)
    run("codesign", "--force", "--sign", "-", next_dmg)
    next_output = directory / "next-release"
    run(sys.executable, ROOT / "scripts/prepare_release.py", "--dmg", next_dmg,
        "--repository", "example/sayo", "--key-file", seed, "--output", next_output,
        "--allow-unnotarized", "--previous-appcast", output / "appcast.xml")
    items = ET.parse(next_output / "appcast.xml").findall("./channel/item")
    assert len(items) == 2, "The previous release was not preserved"
    assert items[0].findtext(f"{{{SPARKLE}}}version") == info["CFBundleVersion"]
    assert items[1].find("enclosure").get("url") == release["downloadURL"]
    run("brew", "ruby", ROOT / "scripts/verify_cask.rb", next_output, env=environment)
    print("PASS: signed appcast, actual Cask DSL, checksum, notarization gate, tamper rejection, mismatched-key rejection, previous release preservation. Disposable keys removed on exit.")
