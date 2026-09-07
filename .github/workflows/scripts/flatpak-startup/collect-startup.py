"""Host-root read-only observer. Never enters the Flatpak or changes confinement."""
import configparser
import fcntl
import hashlib
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

def read_info(path, outer_instance):
    # Retain the source text before parsing or validating any field. The file
    # names come only from our own numeric /proc/instance paths and its digest.
    raw = path.read_bytes()
    source = ('pid-' + path.parts[2]) if path.parts[1] == 'proc' else ('instance-' + path.parent.name)
    require(re.fullmatch(r'(pid|instance)-[0-9]+', source) is not None, f'Unexpected metadata source: {path}')
    digest = hashlib.sha256(raw).hexdigest()[:16]
    (output / f'flatpak-info-{source}-{digest}.txt').write_bytes(raw)
    cfg = configparser.ConfigParser(interpolation=None, strict=False)
    cfg.read_string(raw.decode('utf-8'))
    observed_app = cfg.get('Application', 'name', fallback='')
    observed_runtime = cfg.get('Application', 'runtime', fallback='')
    observed_instance = cfg.get('Instance', 'instance-id', fallback='')
    observed_path = cfg.get('Instance', 'app-path', fallback='')
    # Live .flatpak-info uses a typed ref (runtime/ID/ARCH/BRANCH), unlike
    # installed metadata's ID/ARCH/BRANCH. Compare the full canonical ref.
    require(observed_app == APP, f'{source}: Application.name={observed_app!r}, expected {APP!r}')
    expected_runtime = 'runtime/org.freedesktop.Platform/x86_64/25.08'
    require(observed_runtime == expected_runtime, f'{source}: Application.runtime={observed_runtime!r}, expected {expected_runtime!r}')
    require(observed_instance.isdecimal(), f'{source}: Instance.instance-id={observed_instance!r} is not numeric')
    items = cfg.items('Context') if cfg.has_section('Context') else []
    context = {key: {item for item in value.split(';') if item} for key, value in items}
    context = {key: values for key, values in context.items() if values}
    expected = {'shared': {'ipc'}, 'sockets': {'pulseaudio', 'x11'}, 'devices': {'dri'}}
    observed_context = {key: sorted(values) for key, values in context.items()}
    if observed_instance == outer_instance:
        require(context == expected, f'{source}: outer Context={observed_context!r}, expected qualified IPC/X11/PulseAudio/DRI without network')
    else:
        # Zypak Spawn creates another tighter Flatpak sandbox, not a copy of
        # the parent's instance ID and full graphical permissions. Namespace
        # ancestry below must independently bind a renderer to the outer app.
        observed_sandbox = cfg.get('Instance', 'sandbox', fallback='')
        require(observed_sandbox == 'true', f'{source}: child Instance.sandbox={observed_sandbox!r}, expected true')
        require(all(key in expected and values <= expected[key] for key, values in context.items()), f'{source}: child Context={observed_context!r} exceeds the offline parent permissions')
    policies = {section: dict(cfg.items(section)) for section in cfg.sections() if section.endswith('Bus Policy') and cfg.items(section)}
    require(not policies, f'{source}: unexpected explicit bus policy={policies!r}')
    require(bool(observed_path) and Path(observed_path).resolve() == installed / 'files', f'{source}: Instance.app-path={observed_path!r}, expected {str(installed / "files")!r}')
    return cfg

def processes(outer_instance):
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
            cfg = read_info(path / 'root/.flatpak-info', outer_instance)
            ns = {key: os.readlink(path / 'ns' / key) for key in host_ns}
            require(all(ns[key] != host_ns[key] for key in ns), 'Expected distinct Flatpak PID/mount/offline network namespaces')
            argv = (path / 'cmdline').read_bytes().decode(errors='replace').rstrip('\0').split('\0')
            # Zypak's normal argv is recorded, not reinterpreted as Chromium's
            # native sandbox. No flags are introduced or removed by this test.
            found[int(path.name)] = {'pid': int(path.name), 'namespacePids': [int(v) for v in status.get('NSpid', '').split()], 'argv': argv, 'namespaces': ns, 'instanceId': cfg.get('Instance', 'instance-id', fallback=''), 'sandbox': cfg.get('Instance', 'sandbox', fallback='false'), 'application': APP}
        except (FileNotFoundError, ProcessLookupError):
            continue
    return found

def renderer_ancestry(proc, parent_namespaces):
    # Linux nsfs NS_GET_PARENT = _IO(0xb7, 0x2): read-only descriptor query,
    # never setns(). Bound traversal and close every returned descriptor.
    fd = os.open(f'/proc/{proc["pid"]}/ns/pid', os.O_RDONLY | os.O_CLOEXEC)
    chain = []
    try:
        current = os.readlink(f'/proc/self/fd/{fd}')
        chain.append(current)
        require(current not in parent_namespaces, f'Renderer PID {proc["pid"]} shares the outer PID namespace; this collector has no observed share-pids-mode proof')
        for _ in range(8):
            try:
                parent_fd = fcntl.ioctl(fd, 0xb702)
            except OSError as error:
                raise RuntimeError(f'Renderer PID {proc["pid"]} namespace ancestry unverified: NS_GET_PARENT {error}; chain={chain!r}') from error
            os.close(fd)
            fd = parent_fd
            parent = os.readlink(f'/proc/self/fd/{fd}')
            chain.append(parent)
            if parent in parent_namespaces:
                return chain
        raise RuntimeError(f'Renderer PID {proc["pid"]} not proven below outer PID namespace within eight levels: {chain!r}')
    finally:
        os.close(fd)

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
            read_info(instance_info, instance_id)
            procs = processes(instance_id)
        except FileNotFoundError:
            time.sleep(0.5)
            continue
        main = {pid: proc for pid, proc in procs.items() if not any(a.startswith('--type=') for a in proc['argv']) and proc['instanceId'] == instance_id}
        parent_namespaces = {p['namespaces']['pid'] for p in main.values()}
        renderers = []
        if parent_namespaces:
            for proc in procs.values():
                if '--type=renderer' not in proc['argv']:
                    continue
                try:
                    proc['outerPidNamespaceAncestry'] = renderer_ancestry(proc, parent_namespaces)
                except (FileNotFoundError, ProcessLookupError):
                    continue
                renderers.append(proc)
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
