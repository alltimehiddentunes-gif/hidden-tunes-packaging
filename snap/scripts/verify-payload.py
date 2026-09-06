"""Compare every original application file with a packaged copy. No app execution."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

original, packaged = (Path(p).resolve() for p in sys.argv[1:3])
def entries(root):
    return {p.relative_to(root).as_posix(): p for p in root.rglob('*')}
sources, targets = entries(original), entries(packaged)
if sources.keys() != targets.keys():
    raise SystemExit('Application directory entry sets differ')
records = []
mode_changes = []
for relative, source in sorted(sources.items()):
    target = targets[relative]
    if source.lstat().st_mode != target.lstat().st_mode:
        # Real pack evidence shows only this non-executable icon losing group
        # write permission. Byte identity and all other file modes remain gates.
        if (relative == 'resources/brand/icon.png'
                and source.lstat().st_mode == (stat.S_IFREG | 0o664)
                and target.lstat().st_mode == (stat.S_IFREG | 0o644)):
            mode_changes.append({'path': relative, 'original': '0664', 'packaged': '0644'})
        else:
            raise SystemExit(f'Application file kind/mode changed: {relative}')
    if source.is_symlink():
        if os.readlink(source) != os.readlink(target):
            raise SystemExit(f'Application symlink changed: {relative}')
        continue
    if source.is_dir():
        continue
    with source.open('rb') as stream:
        a = hashlib.file_digest(stream, 'sha256').hexdigest()
    with target.open('rb') as stream:
        b = hashlib.file_digest(stream, 'sha256').hexdigest()
    if a != b:
        raise SystemExit(f'Application file changed: {relative}')
    records.append({'path': relative, 'sha256': a})
if len(records) != 75:
    raise SystemExit('Expected exactly 75 original application files')
if stat.S_IMODE((packaged / 'chrome-sandbox').stat().st_mode) != 0o755:
    raise SystemExit('Sandbox file mode differs from original 0755')
print(json.dumps({'status': 'PASS', 'files': records, 'nonExecutableIconModeNormalization': mode_changes}, indent=2))
