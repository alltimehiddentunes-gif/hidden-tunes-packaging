"""Host-root read-only observer. Never enters the Flatpak or changes confinement."""
import configparser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

APP = 'com.hiddentunes.HiddenTunes'
USER = 'ht-flatpak-smoke'
HOME = Path('/home/ht-flatpak-smoke')

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

require(os.geteuid() == 0, 'Host root is required for read-only process inspection')
require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('HT_RUNNER_ENVIRONMENT') == 'github-hosted', 'Disposable hosted runner required')
require(os.environ.get('GITHUB_REPOSITORY') == 'alltimehiddentunes-gif/hidden-tunes-packaging', 'Unexpected repository')
uid, installed_arg, output_arg = sys.argv[1:]
require(uid.isdecimal() and int(uid) >= 1000, 'Invalid fresh UID')
uid = int(uid)
import pwd
account = pwd.getpwnam(USER)
require(account.pw_uid == uid and account.pw_dir == str(HOME), 'Disposable account identity mismatch')
installed = Path(installed_arg).resolve()
require(str(installed).startswith('/var/tmp/ht-flatpak-startup-') and f'/app/{APP}/' in str(installed), 'Unexpected installed location')
output = Path(output_arg).resolve()
require(output.name == 'flatpak-startup-evidence' and output.is_dir(), 'Unexpected evidence directory')
original = (installed / 'files/extra/hidden-tunes/hidden-tunes-desktop').stat()
exe_identity = (original.st_dev, original.st_ino)
host_ns = {key: os.readlink(f'/proc/self/ns/{key}') for key in ('pid', 'mnt', 'net')}
user_env = [f'HOME={HOME}', f'USER={USER}', f'LOGNAME={USER}', 'PATH=/usr/bin:/bin', 'DISPLAY=:97', f'XAUTHORITY={HOME}/.Xauthority', f'XDG_RUNTIME_DIR=/run/user/{uid}', f'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus']
fatal = re.compile(r'FATAL:|No usable sandbox|error while loading shared libraries|Missing X server|Failed to move to new namespace', re.I)

def xquery(*args):
    return subprocess.run(['runuser', '-u', USER, '--', 'env', '-i', *user_env, *args], capture_output=True, text=True, timeout=3)

def read_info(path):
    cfg = configparser.ConfigParser(interpolation=None, strict=False)
    cfg.read_string(path.read_text())
    require(cfg.get('Application', 'name', fallback='') == APP, 'Running sandbox application identity mismatch')
    require(cfg.get('Application', 'runtime', fallback='') == 'org.freedesktop.Platform/x86_64/25.08', 'Unexpected runtime')
    context = {key: {item for item in value.split(';') if item} for key, value in cfg.items('Context')}
    context = {key: values for key, values in context.items() if values}
    expected = {'shared': {'ipc'}, 'sockets': {'pulseaudio', 'x11'}, 'devices': {'dri'}}
    require(context == expected, 'Effective permissions differ from qualified IPC/X11/PulseAudio/DRI with network removed')
    require(not any(cfg.items(section) for section in cfg.sections() if section.endswith('Bus Policy')), 'Unexpected effective bus policy')
    require(Path(cfg.get('Instance', 'app-path', fallback='')).resolve() == installed / 'files', 'Running instance app-path differs from verified installation')
    return cfg

def processes():
    found = {}
    for path in Path('/proc').iterdir():
        if not path.name.isdecimal():
            continue
        try:
            # Non-dumpable processes may have root-owned /proc directories.
            # Real UID in status is authoritative; ownership would skip renderers.
            status = dict(line.split(':', 1) for line in (path / 'status').read_text().splitlines() if ':' in line)
            real_uid = int(status.get('Uid', '-1').split()[0])
            if real_uid != uid:
                continue
            stat = (path / 'exe').stat()
            if (stat.st_dev, stat.st_ino) != exe_identity:
                continue
            cfg = read_info(path / 'root/.flatpak-info')
            ns = {key: os.readlink(path / 'ns' / key) for key in host_ns}
            require(all(ns[key] != host_ns[key] for key in ns), 'Expected distinct Flatpak PID/mount/offline network namespaces')
            argv = (path / 'cmdline').read_bytes().decode(errors='replace').rstrip('\0').split('\0')
            # Zypak's normal argv is recorded, not reinterpreted as Chromium's
            # native sandbox. No flags are introduced or removed by this test.
            found[int(path.name)] = {'pid': int(path.name), 'namespacePids': [int(v) for v in status.get('NSpid', '').split()], 'argv': argv, 'namespaces': ns, 'instanceId': cfg.get('Instance', 'instance-id', fallback=''), 'application': APP}
        except (FileNotFoundError, ProcessLookupError):
            continue
    return found

def observe():
    deadline = time.monotonic() + 85
    signature = None
    since = None
    observations = []
    while time.monotonic() < deadline:
        log = HOME / 'evidence/application.log'
        if log.exists():
            require(not fatal.search(log.read_text(errors='replace')), 'Fatal startup diagnostic; inspect application.log')
        instance_file = HOME / 'evidence/instance-id.txt'
        instance_id = instance_file.read_text().strip() if instance_file.exists() else ''
        if not instance_id:
            time.sleep(0.5)
            continue
        require(instance_id.isdecimal(), 'Unexpected Flatpak instance ID')
        instance_info = Path(f'/run/user/{uid}/.flatpak/{instance_id}/info')
        try:
            read_info(instance_info)
            procs = processes()
        except FileNotFoundError:
            time.sleep(0.5)
            continue
        main = {pid: proc for pid, proc in procs.items() if not any(a.startswith('--type=') for a in proc['argv']) and proc['instanceId'] == instance_id}
        renderers = [p for p in procs.values() if '--type=renderer' in p['argv'] and p['instanceId'] == instance_id]
        listing = xquery('wmctrl', '-lp')
        visible = []
        if listing.returncode == 0:
            for line in listing.stdout.splitlines():
                parts = line.split(None, 4)
                if len(parts) < 4 or not parts[2].isdecimal():
                    continue
                window_pid = int(parts[2])
                owners = [p for p in main.values() if window_pid in p['namespacePids']]
                if len(owners) != 1:
                    continue
                info = xquery('xwininfo', '-id', parts[0])
                if info.returncode != 0 or 'Map State: IsViewable' not in info.stdout:
                    continue
                props = xquery('xprop', '-id', parts[0], '_NET_WM_PID', 'WM_CLASS', '_NET_WM_NAME')
                require(props.returncode == 0 and re.search(r'_NET_WM_PID\([^)]*\) = ' + str(window_pid) + r'\b', props.stdout), 'Window PID ownership evidence missing')
                visible.append({'window': parts[0], 'hostPid': owners[0]['pid'], 'windowNamespacePid': window_pid, 'properties': props.stdout})
        current = (tuple(sorted((v['window'], v['hostPid']) for v in visible)), tuple(sorted(p['pid'] for p in renderers)))
        if visible and renderers:
            if current != signature:
                since, observations = time.monotonic(), []
            signature = current
            observations.append({'seconds': round(time.monotonic() - since, 2), 'windows': visible, 'processes': list(procs.values())})
            if time.monotonic() - since >= 8:
                (output / 'effective-flatpak-info.txt').write_text(instance_info.read_text())
                return {'status': 'PASS', 'observationSeconds': round(time.monotonic() - since, 2), 'observations': observations, 'claim': 'Offline visible X11 window mapped through namespace PID to the original installed executable; renderer present; effective Flatpak app/runtime identity and distinct PID/mount/network namespaces observed. No functional, portal, secure-store or complete Chromium/Zypak sandbox qualification.'}
        else:
            signature, since, observations = None, None, []
        time.sleep(2)
    raise RuntimeError('No sustained owned visible application window and renderer within 85 seconds')

try:
    result = observe()
except Exception as error:
    result = {'status': 'FAIL', 'reason': str(error), 'classification': 'UNRESOLVED_STARTUP_OR_FIXTURE_FAILURE', 'claim': 'Failure is not proof of application incompatibility; inspect text evidence.'}
(output / 'startup-result.json').write_text(json.dumps(result, indent=2) + '\n')
sys.exit(0 if result['status'] == 'PASS' else 1)
