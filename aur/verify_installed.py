"""Package compatibility checks only: no application process is started."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

if not __debug__:
    raise SystemExit('Validation must run with Python assertions enabled.')
if (not Path('/.dockerenv').exists()
        or os.environ.get('GITHUB_ACTIONS') != 'true'
        or os.environ.get('HT_RUNNER_ENVIRONMENT') != 'github-hosted'
        or os.environ.get('GITHUB_REPOSITORY') != 'alltimehiddentunes-gif/hidden-tunes-packaging'):
    raise SystemExit('Validation is confined to the dedicated GitHub-hosted CI container.')

parser = argparse.ArgumentParser()
parser.add_argument('mode', choices=['installed', 'uninstalled'])
parser.add_argument('audit', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
audit = json.loads(args.audit.read_text())
assert all(item['architecture'] == 'x86_64' for item in audit['elf'].values())
result = {'mode': args.mode, 'payloadFiles': len(audit['files']), 'applicationLaunched': False, 'sourceRebuilt': False, 'checks': []}
extra = ['/usr/bin/hidden-tunes-desktop', '/usr/share/licenses/hiddentunes/EULA.md', '/usr/share/licenses/hiddentunes/LICENSE.electron.txt', '/usr/share/licenses/hiddentunes/LICENSES.chromium.html']
if args.mode == 'uninstalled':
    for name in list(audit['files']) + [p.removeprefix('/') for p in extra]:
        path = Path('/') / name
        assert not path.exists() and not path.is_symlink(), f'leftover package file: {path}'
    result['checks'].append('all tracked payload, launcher and license files removed')
else:
    for name, expected in audit['files'].items():
        path = Path('/') / name
        if 'symlink' in expected:
            assert path.is_symlink() and os.readlink(path) == expected['symlink']
        else:
            with path.open('rb') as stream:
                actual = hashlib.file_digest(stream, 'sha256').hexdigest()
            assert actual == expected['sha256'], f'payload bytes changed: {path}'
    result['checks'].append('every original application payload file is byte-identical')
    app = Path('/opt/Hidden Tunes Desktop')
    assert (app / 'chrome-sandbox').stat().st_mode & 0o7777 == 0o755
    assert os.readlink('/usr/bin/hidden-tunes-desktop') == str(app / 'hidden-tunes-desktop')
    assert hashlib.sha256(Path(extra[1]).read_bytes()).hexdigest() == 'db525424eb2152b7da2a2313efe6644ab4ae6fee9cbcd887b03b9abbbadecfae'
    result['checks'].append('sandbox remains 0755; launcher and pinned EULA match')
    result['elfDependencyTrees'] = {}
    result['libraryOwners'] = {}
    for name in audit['elf']:
        path = str(Path('/') / name)
        # lddtree parses ELF metadata; it does not invoke the application.
        tree = subprocess.run(['lddtree', path], text=True, capture_output=True)
        result['elfDependencyTrees'][name] = tree.stdout + tree.stderr
        assert tree.returncode == 0, f'lddtree failed: {name}'
        assert '=> None' not in tree.stdout and 'not found' not in tree.stdout.lower(), f'unresolved ELF dependency: {name}'
        libs = subprocess.run(['lddtree', '-l', path], check=True, text=True, capture_output=True)
        for lib in libs.stdout.splitlines():
            if lib.startswith('/usr/lib/') and lib not in result['libraryOwners']:
                owner = subprocess.run(['pacman', '-Qo', lib], check=True, text=True, capture_output=True)
                result['libraryOwners'][lib] = owner.stdout.strip()
    result['checks'].append('all eight ELF files resolve dependencies using installed Arch packages')
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'mode': args.mode, 'checks': result['checks'], 'applicationLaunched': False}, indent=2))
