#!/usr/bin/env python3
"""Update this tap from a published Sayo release. Never publishes or installs."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
REPOSITORY = "riko2chen/Sayo"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def read_url(url):
    headers = {"User-Agent": "Sayo-Homebrew"}
    if url.startswith("https://api.github.com/"):
        headers["Accept"] = "application/vnd.github+json"
        if token := os.environ.get("GH_TOKEN"):
            headers["Authorization"] = f"Bearer {token}"
    with urlopen(Request(url, headers=headers), timeout=60) as response:
        return response.read()


def version_build(version):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Expected a stable major.minor.patch version")
    major, minor, patch = map(int, version.split("."))
    if minor > 99 or patch > 999:
        raise ValueError("Version components exceed Sayo's build-number bounds")
    return major * 100000 + minor * 1000 + patch


def published_metadata(release):
    if release.get("draft") is not False or release.get("prerelease") is not False or not release.get("published_at"):
        raise ValueError("Only published stable releases can update Homebrew")
    tag = release["tag_name"]
    if not tag.startswith("v"):
        raise ValueError("Expected a version tag")
    version = tag[1:]
    build = version_build(version)
    filename = f"Sayo-{version}-{build}.dmg"
    prefix = f"https://github.com/{REPOSITORY}/releases/download/{tag}/"
    assets = {}
    for name in (filename, "SHA256SUMS", "appcast.xml"):
        matches = [asset for asset in release["assets"] if asset["name"] == name]
        if len(matches) != 1 or matches[0].get("state") != "uploaded":
            raise ValueError(f"Missing or duplicate published asset: {name}")
        asset = matches[0]
        if asset.get("browser_download_url") != prefix + name:
            raise ValueError("Release asset URL does not match the official versioned URL")
        assets[name] = asset
    return version, build, filename, assets


def verify_download(url, expected_size, expected_hash):
    digest = hashlib.sha256()
    size = 0
    request = Request(url, headers={"User-Agent": "Sayo-Homebrew"})
    with urlopen(request, timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            if size > expected_size:
                raise ValueError("Published DMG size mismatch")
            digest.update(chunk)
    if size != expected_size or digest.hexdigest() != expected_hash:
        raise ValueError("Published DMG checksum or size mismatch")


def update(root=ROOT):
    release = json.loads(read_url(f"https://api.github.com/repos/{REPOSITORY}/releases/latest"))
    version, build, filename, assets = published_metadata(release)
    dmg = assets[filename]
    checksum_text = read_url(assets["SHA256SUMS"]["browser_download_url"]).decode()
    checksums = re.findall(r"^([a-f0-9]{64})  " + re.escape(filename) + r"$", checksum_text, re.MULTILINE)
    if len(checksums) != 1:
        raise ValueError("Checksum manifest must contain exactly one matching DMG")
    checksum = checksums[0]
    if dmg.get("digest") and dmg["digest"] != "sha256:" + checksum:
        raise ValueError("GitHub asset digest and checksum manifest disagree")
    size = dmg["size"]
    if not isinstance(size, int) or size <= 0:
        raise ValueError("Invalid published DMG size")

    feed = ET.fromstring(read_url(assets["appcast.xml"]["browser_download_url"]))
    items = [item for item in feed.findall("./channel/item")
             if item.findtext(f"{{{SPARKLE}}}version") == str(build)]
    if len(items) != 1:
        raise ValueError("Appcast must contain exactly one item for this build")
    item = items[0]
    enclosure = item.find("enclosure")
    if (item.findtext(f"{{{SPARKLE}}}shortVersionString") != version or
            item.findtext(f"{{{SPARKLE}}}minimumSystemVersion") != "14.0" or
            enclosure is None or enclosure.get("url") != dmg["browser_download_url"] or
            enclosure.get("length") != str(size) or not enclosure.get(f"{{{SPARKLE}}}edSignature")):
        raise ValueError("Appcast metadata does not match the supported release")

    path = root / "Casks/sayo.rb"
    previous = path.read_text() if path.exists() else ""
    if previous:
        old_version = re.search(r'^  version "([0-9.]+),([0-9]+)"$', previous, re.MULTILINE)
        old_hash = re.search(r'^  sha256 "([a-f0-9]{64})"$', previous, re.MULTILINE)
        if not old_version or not old_hash or version_build(old_version[1]) != int(old_version[2]):
            raise ValueError("Existing Cask metadata is invalid")
        if int(old_version[2]) > build:
            raise ValueError("Refusing to downgrade the Cask")
        if int(old_version[2]) == build and old_hash[1] != checksum:
            raise ValueError("Refusing to change the checksum of a published version")

    rendered = (root / "Casks/sayo.rb.in").read_text()
    for token, value in {"VERSION": version, "BUILD": str(build), "SHA256": checksum, "REPOSITORY": REPOSITORY}.items():
        rendered = rendered.replace(f"@{token}@", value)
    if re.search(r"@[A-Z_]+@", rendered):
        raise ValueError("Unresolved Cask template token")
    if previous == rendered:
        print(f"Sayo {version} is already current")
        return False

    # Verify the actual bytes before writing any new version or checksum.
    verify_download(dmg["browser_download_url"], size, checksum)
    temporary = path.with_suffix(".rb.tmp")
    temporary.write_text(rendered)
    temporary.replace(path)
    print(f"Updated Sayo to {version} ({build})")
    return True


if __name__ == "__main__":
    try:
        update()
    except (ValueError, KeyError, OSError, ET.ParseError) as error:
        sys.exit(str(error))
