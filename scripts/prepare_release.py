#!/usr/bin/env python3
"""Prepare GitHub release assets and a Homebrew tap locally. Never uploads files."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from dmg_archive import mounted_dmg
from release_common import ROOT, feed_url, release_configuration, validate_repository, validate_version
from verify_distribution import verify

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"


def metadata(info, repository, preview):
    validate_repository(repository)
    if info.get("SayoDistributionChannel") != "direct":
        raise ValueError("Only the direct edition can be released through GitHub or Homebrew.")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    validate_version(version, build)
    feed = feed_url(repository)
    if info.get("SUFeedURL") and info["SUFeedURL"] != feed:
        raise ValueError("The app's embedded update repository differs from the release repository. Rebuild first.")
    if not preview and (info.get("SUFeedURL") != feed or not info.get("SUPublicEDKey")):
        raise ValueError("Configure the repository and Sparkle public key, then rebuild, or use --preview.")
    filename = f"Sayo-{version}-{build}.dmg"
    tag = f"v{version}"
    return {
        "channel": "direct", "version": version, "build": build,
        "repository": repository, "tag": tag, "filename": filename,
        "feedURL": feed,
        "downloadURL": f"https://github.com/{repository}/releases/download/{tag}/{filename}",
        "minimumSystemVersion": info["LSMinimumSystemVersion"],
        "publicKey": info.get("SUPublicEDKey", ""),
    }


def cask_text(release):
    if release["minimumSystemVersion"] != "14.0":
        raise ValueError("Update the Homebrew template's minimum macOS requirement to match the app before releasing.")
    template = (ROOT / "Distribution/homebrew/Casks/sayo.rb.in").read_text()
    for token, field in (("VERSION", "version"), ("BUILD", "build"), ("SHA256", "sha256"), ("REPOSITORY", "repository")):
        template = template.replace(f"@{token}@", release[field])
    return template


def write_preview(path, release):
    root = ET.Element("rss", version="2.0")
    root.append(ET.Comment(" UNSIGNED PREVIEW ONLY - DO NOT PUBLISH AS AN UPDATE FEED "))
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Sayo (local preview)"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Sayo {release['version']}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = release["build"]
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = release["version"]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = release["minimumSystemVersion"]
    ET.SubElement(item, "enclosure", url=release["downloadURL"], length=str(release["length"]), type="application/octet-stream")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def check_previous_appcast(path, build):
    for item in ET.parse(path).findall("./channel/item"):
        previous = item.findtext(f"{{{SPARKLE}}}version")
        if previous is None:
            enclosure = item.find("enclosure")
            previous = enclosure.get(f"{{{SPARKLE}}}version") if enclosure is not None else None
        if not previous or not previous.isdigit():
            raise ValueError("The previous appcast must use nonnegative integer build numbers.")
        if int(previous) >= int(build):
            raise ValueError("Increase SAYO_VERSION so its calculated build number exceeds every build in the previous appcast.")


def check_appcast(path, release, require_signature=True):
    items = ET.parse(path).findall("./channel/item")
    matching = [item for item in items if item.findtext(f"{{{SPARKLE}}}version") == release["build"]]
    if len(matching) != 1:
        raise ValueError("Appcast must contain exactly one item for this build.")
    item = matching[0]
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != release["downloadURL"] or enclosure.get("length") != str(release["length"]):
        raise ValueError("Appcast URL or size does not match the packaged DMG.")
    if item.findtext(f"{{{SPARKLE}}}shortVersionString") != release["version"]:
        raise ValueError("Appcast display version does not match the app.")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature")
    if require_signature and not signature:
        raise ValueError("Sparkle did not sign this update. Check that the signing key matches SUPublicEDKey.")
    return signature


def prepare(options):
    dmg = options.dmg.resolve()
    if not dmg.is_file() or dmg.suffix.lower() != ".dmg":
        raise ValueError("--dmg must be an existing DMG file.")
    repository = options.repository or release_configuration().get("githubRepository", "")
    if not repository:
        raise ValueError("Set githubRepository in the release configuration, or pass --repository (use example/sayo for a local preview).")
    validate_repository(repository)
    with mounted_dmg(dmg) as mount:
        app = mount / "Sayo.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        release = metadata(info, repository, options.preview)
        verify(app, "direct")
        architectures = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS" / info["CFBundleExecutable"])], text=True).split()
        if set(architectures) != {"arm64", "x86_64"}:
            raise ValueError("Release DMGs must contain a Universal 2 app. Build without --arch.")

    output = (options.output or ROOT / "dist/releases" / (release["tag"] + ("-preview" if options.preview else ""))).resolve()
    if output.exists():
        raise ValueError(f"Output already exists; use a new --output directory: {output}")
    if options.previous_appcast:
        check_previous_appcast(options.previous_appcast, release["build"])
    notarized = False
    if not options.preview:
        subprocess.run(["codesign", "--verify", "--strict", str(dmg)], check=True)
        notarized = subprocess.run(["xcrun", "stapler", "validate", str(dmg)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if not notarized and not options.allow_unnotarized:
            raise ValueError("The DMG has no valid stapled notarization ticket. Notarize and staple it before preparing a release. For local tests only, use --allow-unnotarized.")
    release.update({"sha256": sha256_file(dmg),
                    "length": dmg.stat().st_size, "preview": options.preview, "notarized": notarized})
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sayo-release-", dir=output.parent) as temporary:
        staging = Path(temporary) / "assets"
        staging.mkdir()
        archive = staging / release["filename"]
        shutil.copyfile(dmg, archive)
        if options.preview:
            appcast = staging / "appcast.preview.xml"
            write_preview(appcast, release)
            check_appcast(appcast, release, require_signature=False)
        else:
            appcast = staging / "appcast.xml"
            if options.previous_appcast:
                shutil.copyfile(options.previous_appcast, appcast)
            key_arguments = ["--ed-key-file", str(options.key_file.resolve())] if options.key_file else ["--account", options.account]
            subprocess.run([str(TOOLS / "generate_appcast"), *key_arguments,
                            "--download-url-prefix", release["downloadURL"].rsplit("/", 1)[0] + "/",
                            "--maximum-deltas", "0", "-o", str(appcast), str(staging)], check=True)
            signature = check_appcast(appcast, release)
            subprocess.run([str(TOOLS / "sign_update"), *key_arguments, "--verify", str(archive), signature], check=True)
        cask = staging / "homebrew-tap/Casks/sayo.rb"
        cask.parent.mkdir(parents=True)
        cask.write_text(cask_text(release))
        (staging / "SHA256SUMS").write_text(f"{release['sha256']}  {release['filename']}\n")
        (staging / "release.json").write_text(json.dumps(release, indent=2) + "\n")
        warning = "本目录是未签名清单的演示，不可发布。" if options.preview else ("本目录尚未公证，仅供本地测试，不可发布。" if not notarized else "本目录已生成签名更新清单，尚未上传。")
        (staging / "README.md").write_text(f"""# Sayo {release['version']} ({release['build']})

{warning}

正式发行准备完成后，由维护者手动创建 `{repository}` 的 GitHub Release，tag 使用 `{release['tag']}`，并上传 `{release['filename']}`、`appcast.xml` 和 `SHA256SUMS`。该 Release 需标记为 latest（非 draft / prerelease），供应用读取固定更新地址。

将 `homebrew-tap/Casks/sayo.rb` 放入自己公开的 `homebrew-sayo` 仓库的 `Casks/sayo.rb`。用户届时可通过 `brew install --cask OWNER/sayo/sayo` 安装，也可在应用内检查更新。Homebrew 的 `auto_updates true` 表示应用有自更新能力；要让 Homebrew 也检查此类应用，使用 `brew upgrade --cask --greedy sayo`。

本地生成命令没有上传、创建 Release、推送仓库或安装 Homebrew 软件的动作。不要把私钥或证书放入这些产物中。
""")
        staging.rename(output)
    print(f"Prepared local {'preview' if options.preview else 'signed release'}: {output}\nNothing was uploaded or published.")


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--repository", help="Public owner/repo; defaults to SAYO_RELEASE_CONFIG / Distribution/release.json")
    parser.add_argument("--output", type=Path, help="New directory; never overwrites existing release assets")
    parser.add_argument("--preview", action="store_true", help="Generate an unsigned appcast.preview.xml and sample Cask without accessing signing keys")
    parser.add_argument("--account", default="sayo", help="Sparkle signing key's Keychain account")
    parser.add_argument("--key-file", type=Path, help="Use a Sparkle private key file instead of Keychain; never copied into outputs")
    parser.add_argument("--allow-unnotarized", action="store_true", help="Allow signed local test assets without a notarization ticket")
    parser.add_argument("--previous-appcast", type=Path, help="Retain previous feed entries and require an increasing build number")
    options = parser.parse_args()
    if options.preview and (options.key_file or options.allow_unnotarized or options.previous_appcast):
        parser.error("--preview cannot be combined with signing or previous-appcast options.")
    prepare(options)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
