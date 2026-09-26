#!/usr/bin/env python3
"""Build the direct distribution locally. Never submits or publishes anything."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

from release_common import ROOT, configure_info, release_configuration


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def signing_identity():
    if os.environ.get("SAYO_SIGNING_IDENTITY"):
        return os.environ["SAYO_SIGNING_IDENTITY"]
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture_output=True, text=True).stdout
    match = re.search(r'"(Developer ID Application:[^"]+)"', identities)
    if match:
        return match[1]
    print("Local direct build uses ad-hoc signing; not a submission artifact.", file=sys.stderr)
    return "-"


def sign(path, identity, entitlements=None):
    arguments = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        arguments += ["--options", "runtime", "--timestamp"]
    if entitlements:
        arguments += ["--entitlements", str(entitlements)]
    run(*arguments, path)


def build(channel, configuration, architectures):
    os.chdir(ROOT)
    config = release_configuration()
    with (ROOT / "Resources/Info.plist").open("rb") as source:
        info = configure_info(plistlib.load(source), channel, config,
                              os.environ.get("SAYO_VERSION"))
    arguments = ["swift", "build", "-c", configuration]
    for arch in architectures:
        arguments += ["--arch", arch]
    product = "SayoApp"
    run(*arguments, "--product", product)
    run(*arguments, "--product", "sayo")
    binary_dir = Path(run(*arguments, "--show-bin-path", capture_output=True, text=True).stdout.strip())
    channel_dir = ROOT / "dist" / channel
    channel_dir.mkdir(parents=True, exist_ok=True)
    app = channel_dir / "Sayo.app"
    staging = channel_dir / "Sayo-staging.app"
    if staging.exists():
        shutil.rmtree(staging)
    contents = staging / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    shutil.copy2(binary_dir / product, contents / "MacOS/SayoApp")
    shutil.copy2(binary_dir / "sayo", contents / "MacOS/sayo")
    with (contents / "Info.plist").open("wb") as target:
        plistlib.dump(info, target)
    for locale in ("en", "zh-Hans"):
        run("ditto", ROOT / "Resources" / (locale + ".lproj"), contents / "Resources" / (locale + ".lproj"))
    resources = ["Sayo_SayoUI.bundle", "Sayo_SayoLLM.bundle"]
    resources.append("Sayo_SayoTerminal.bundle")
    for name in resources:
        run("ditto", binary_dir / name, contents / "Resources" / name)
    run("swift", "scripts/make-icon.swift")
    shutil.copy2(ROOT / "Resources/AppIcon.icns", contents / "Resources/AppIcon.icns")
    identity = signing_identity()
    source = ROOT / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    framework = contents / "Frameworks/Sparkle.framework"
    run("ditto", source, framework)
    # Sign from the innermost helper outwards. No --deep signing.
    base = framework / "Versions/B"
    for relative in ("XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "Updater.app", "Autoupdate"):
        sign(base / relative, identity)
    sign(framework, identity)
    shutil.copy2(ROOT / ".build/artifacts/sparkle/Sparkle/LICENSE", contents / "Resources/Sparkle-LICENSE")
    shutil.copy2(ROOT / "LICENSE", contents / "Resources/Sayo-LICENSE")
    sign(contents / "MacOS/sayo", identity)
    sign(staging, identity)
    run("codesign", "--verify", "--deep", "--strict", staging)
    if app.exists():
        shutil.rmtree(app)
    staging.rename(app)
    run(sys.executable, ROOT / "scripts/verify_distribution.py", app, channel)
    print(f"Built {app} ({', '.join(architectures)}; {identity})")


def main():
    args = sys.argv[1:]
    # Keep the old release/debug invocation as an alias for the direct edition.
    if args and args[0] in ("release", "debug"):
        args.insert(0, "direct")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("channel", nargs="?", choices=("direct",), default="direct")
    parser.add_argument("configuration", nargs="?", choices=("release", "debug"), default="release")
    parser.add_argument("--arch", action="append", choices=("arm64", "x86_64"), help="Defaults to universal arm64 + x86_64")
    options = parser.parse_args(args)
    build(options.channel, options.configuration, options.arch or ["arm64", "x86_64"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
