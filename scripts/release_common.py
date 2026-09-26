"""Shared local build/release metadata. No publishing or credential access."""
import base64
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def release_configuration(path=None):
    path = Path(path or os.environ.get("SAYO_RELEASE_CONFIG", ROOT / "Distribution/release.json"))
    config = json.loads(path.read_text())
    repo = config.get("githubRepository", "")
    key = config.get("sparklePublicKey", "")
    if bool(repo) != bool(key):
        raise ValueError("Set both githubRepository and sparklePublicKey, or leave both empty for an unpublished build.")
    if repo:
        validate_repository(repo)
        try:
            decoded = base64.b64decode(key, validate=True)
        except (ValueError, TypeError) as error:
            raise ValueError("sparklePublicKey must be a base64 Ed25519 public key.") from error
        if len(decoded) != 32:
            raise ValueError("sparklePublicKey must contain exactly 32 bytes.")
    return config


def validate_repository(repo):
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9_.-]*", repo):
        raise ValueError("Use a public GitHub repository in owner/repository form.")
    return repo


def feed_url(repo):
    return f"https://github.com/{validate_repository(repo)}/releases/latest/download/appcast.xml"


def build_number_for_version(version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Version must use major.minor.patch, for example 0.1.0.")
    major, minor, patch = map(int, version.split("."))
    if minor > 99 or patch > 999:
        raise ValueError("Version minor must be between 0 and 99, and patch between 0 and 999.")
    return str(major * 100000 + minor * 1000 + patch)


def validate_version(version, build):
    expected = build_number_for_version(version)
    if build != expected:
        raise ValueError(f"Build number for version {version} must be {expected}; rebuild from the version number.")


def configure_info(info, channel, config, version=None):
    info = dict(info)
    info["CFBundleShortVersionString"] = version if version is not None else info["CFBundleShortVersionString"]
    info["CFBundleVersion"] = build_number_for_version(info["CFBundleShortVersionString"])
    if channel != "direct":
        raise ValueError("Only direct builds are supported.")
    # Discard stale update settings from the template before adding this build's configuration.
    for key in list(info):
        if key.startswith("SU"):
            del info[key]
    info["SayoDistributionChannel"] = channel
    info["SUEnableAutomaticChecks"] = False
    info["SUAutomaticallyUpdate"] = False
    info["SUEnableInstallerLauncherService"] = False
    info["SUEnableDownloaderService"] = False
    info["SUVerifyUpdateBeforeExtraction"] = True
    repo = config.get("githubRepository", "")
    if repo:
        info["SUFeedURL"] = feed_url(repo)
        info["SUPublicEDKey"] = config["sparklePublicKey"]
    return info
