#!/usr/bin/env python3
"""Install archive push protection. Existing push locks are intentionally preserved."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
common = Path(subprocess.check_output(['git', 'rev-parse', '--git-common-dir'], text=True).strip()).resolve()
custom = subprocess.run(['git', 'config', '--get', 'core.hooksPath'], capture_output=True, text=True)
if custom.returncode == 0 and custom.stdout.strip():
    raise SystemExit('Custom hooksPath exists; integrate this guard with it instead of overwriting it.')
folder = common / 'sayo-hooks'
folder.mkdir(exist_ok=True)
shutil.copy2(root / 'scripts/check_push.py', folder / 'check_push.py')
hook = common / 'hooks/pre-push'
if hook.exists() and not any(marker in hook.read_text() for marker in ('sayo-hooks/check_push.py', 'Push is locked while local open-source preparation')):
    raise SystemExit('An unrelated pre-push hook exists; integrate it manually without overwriting it.')
hook.write_text('''#!/bin/sh
# Sayo archive protection survives branch switches and linked worktrees.
common=$(git rev-parse --git-common-dir)
exec python3 "$common/sayo-hooks/check_push.py" "$@"
''')
hook.chmod(0o755)
subprocess.run(['git', 'config', 'branch.local.pushRemote', 'local-archive-disabled'], check=True)
print('Installed local archive push guard; any existing push lock is unchanged.')
