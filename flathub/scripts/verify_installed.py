"""Compare installed extra-data to the original DEB without executing application code."""
import hashlib
import json
import os
import struct
import sys
from pathlib import Path

if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('HT_RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('RUNNER_OS') != 'Linux':
    raise RuntimeError('Only an isolated GitHub-hosted Linux runner is permitted')
if os.environ.get('GITHUB_REPOSITORY') != 'alltimehiddentunes-gif/hidden-tunes-packaging':
    raise RuntimeError('Unexpected qualification repository')
candidate = Path(__file__).resolve().parents[1]
installed = Path(sys.argv[1]).resolve()
owned = Path(os.environ['XDG_DATA_HOME']).resolve() / 'flatpak' / 'app' / 'com.hiddentunes.HiddenTunes'
if not installed.is_relative_to(owned):
    raise RuntimeError('Installed ref is outside the isolated Flatpak installation')
record = json.loads((candidate / 'release-inspection.json').read_text())
lock = json.loads((candidate / 'release-lock.json').read_text())
if record['iconSha256'] != lock['originalDebIconSha256']:
    raise RuntimeError('Original DEB icon evidence differs from the release lock')
app = installed / 'files' / 'extra' / 'hidden-tunes'
actual_names = {str(p.relative_to(app)).replace('\\', '/') for p in app.rglob('*') if p.is_file()}
if actual_names != set(record['payloadHashes']):
    raise RuntimeError('Installed application file inventory differs from the official DEB')
for name, expected in record['payloadHashes'].items():
    path = app / name
    if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f'Original application bytes changed: {name}')
executable = app / 'hidden-tunes-desktop'
with executable.open('rb') as stream:
    header = stream.read(64)
if header[:4] != b'\x7fELF' or header[4] != 2 or struct.unpack_from('<H', header, 18)[0] != 62:
    raise RuntimeError('Expected original ELF64 x86_64 executable')
metadata = installed / 'files' / 'share'
icon = metadata / 'icons' / 'hicolor' / '512x512' / 'apps' / 'com.hiddentunes.HiddenTunes.png'
icon_bytes = icon.read_bytes()
if hashlib.sha256(icon_bytes).hexdigest() != lock['integrationIconSha256']:
    raise RuntimeError('Exported integration icon differs from the approved existing website asset')
if list(struct.unpack_from('>II', icon_bytes, 16)) != lock['integrationIconDimensions']:
    raise RuntimeError('Exported integration icon dimensions differ from the release lock')
for relative in ['applications/com.hiddentunes.HiddenTunes.desktop', 'metainfo/com.hiddentunes.HiddenTunes.metainfo.xml']:
    if not (metadata / relative).is_file():
        raise RuntimeError(f'Missing integration metadata: {relative}')
print(json.dumps({
    'applicationVersion': record['packageMetadata']['version'],
    'payloadFilesVerified': len(actual_names),
    'payloadByteParity': 'PASS',
    'architecture': 'ELF64 x86_64',
    'originalApplicationIconParity': 'PASS (included in all original payload file hashes)',
    'integrationIconParity': 'PASS (unchanged approved website asset)',
    'integrationIconDimensions': lock['integrationIconDimensions'],
    'applicationExecution': 'NOT RUN BY DESIGN',
}, indent=2))
