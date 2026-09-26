"""Read-only DMG inspection shared by verification and release preparation."""
from contextlib import contextmanager
from pathlib import Path
import subprocess
import tempfile


@contextmanager
def mounted_dmg(dmg):
    with tempfile.TemporaryDirectory(prefix="sayo-inspect-") as directory:
        mount = Path(directory) / "volume"
        mount.mkdir()
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(dmg)], check=True, stdout=subprocess.DEVNULL)
        try:
            yield mount
        finally:
            subprocess.run(["hdiutil", "detach", str(mount), "-quiet"], check=True)
