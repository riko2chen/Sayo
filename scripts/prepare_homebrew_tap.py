#!/usr/bin/env python3
"""Export the public tap files into a new directory. No network or Git writes."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def prepare(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    source = ROOT / "Distribution/homebrew"
    for origin, destination in (
        (source / "Casks/sayo.rb.in", "Casks/sayo.rb.in"),
        (source / "update_cask.py", "update_cask.py"),
        (source / "update.yml", ".github/workflows/update.yml"),
        (source / "README.md", "README.md"),
        (source / "tests/test_update_cask.py", "tests/test_update_cask.py"),
        (ROOT / "LICENSE", "LICENSE"),
    ):
        target = output / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, target)
    (output / ".gitignore").write_text("__pycache__/\n*.tmp\n.DS_Store\n")
    print(f"Prepared public tap files at {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New directory; existing directories are never overwritten")
    args = parser.parse_args()
    try:
        prepare(args.output)
    except OSError as error:
        parser.exit(1, f"{error}\n")
