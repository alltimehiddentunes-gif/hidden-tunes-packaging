"""Host-root read-only observer. Never enters the Flatpak or changes confinement."""
import configparser
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
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
require(len(sys.argv) in (4, 5), 'Unexpected observer arguments')
uid, installed_arg, output_arg = sys.argv[1:4]
mode = sys.argv[4] if len(sys.argv) == 5 else 'observe'
require(mode in ('observe', 'final-diagnostics'), 'Unexpected observer mode')
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

def timestamp():
    return {'unixSeconds': time.time(), 'monotonicSeconds': time.monotonic()}

def timeline(event, **details):
    with (output / 'observation-timeline.jsonl').open('a') as stream:
        stream.write(json.dumps({**timestamp(), 'event': event, **details}) + '\n')

def process_type(argv):
    # Chromium can rewrite /proc/cmdline into one space-separated argument.
    # Match complete ASCII-whitespace/NUL-delimited flags, never substrings.
    joined = '\0'.join(argv)
    flags = re.findall(r'(?:^|[\x00\t\n\v\f\r ])--type(?:=([^\x00\t\n\v\f\r ]*))?(?=$|[\x00\t\n\v\f\r ])', joined)
    require(len(flags) <= 1 and all(flags), f'Ambiguous or empty Chromium --type flags: {flags!r}')
    return flags[0] if flags else None

diagnostic_seen = set()
diagnostic_records = 0
diagnostic_bytes = 0
diagnostic_capped = False

def process_diagnostics():
    # Supplementary observations only: helpers never satisfy the app gate.
    global diagnostic_records, diagnostic_bytes, diagnostic_capped
    if diagnostic_capped:
        return
    for path in Path('/proc').iterdir():
        if not path.name.isdecimal():
            continue
        try:
            status = dict(line.split(':', 1) for line in (path / 'status').read_text().splitlines() if ':' in line)
            if int(status.get('Uid', '-1').split()[0]) != uid:
                continue
            record = {'pid': int(path.name), 'realUid': uid, 'ppid': status.get('PPid', '').strip(), 'comm': status.get('Name', '').strip(), 'expectedExecutable': {'device': exe_identity[0], 'inode': exe_identity[1]}}
            try:
                record['startTicks'] = (path / 'stat').read_text().rsplit(')', 1)[1].split()[19]
                stat = (path / 'exe').stat()
                record['executable'] = {'path': os.readlink(path / 'exe'), 'device': stat.st_dev, 'inode': stat.st_ino}
                record['matchesOriginalExecutable'] = (stat.st_dev, stat.st_ino) == exe_identity
                with (path / 'cmdline').open('rb') as stream:
                    raw = stream.read(8193)
                record['argv'] = raw[:8192].decode(errors='replace').rstrip('\0').split('\0')
                record['argvTruncated'] = len(raw) > 8192
                info_path = path / 'root/.flatpak-info'
                if info_path.exists():
                    with info_path.open('rb') as stream:
                        info = stream.read(32769)
                    if len(info) > 32768:
                        record['flatpakInfoError'] = 'Metadata exceeds diagnostic size limit'
                    else:
                        cfg = configparser.ConfigParser(interpolation=None, strict=False)
                        cfg.read_string(info.decode('utf-8'))
                        record['flatpak'] = {'application': cfg.get('Application', 'name', fallback=''), 'runtime': cfg.get('Application', 'runtime', fallback=''), 'instanceId': cfg.get('Instance', 'instance-id', fallback='')}
            except (OSError, ValueError, configparser.Error, UnicodeError, IndexError) as error:
                record['inspectionError'] = str(error)[:512]
            key = json.dumps(record, sort_keys=True)
            if key in diagnostic_seen:
                continue
            line = json.dumps({**timestamp(), **record}) + '\n'
            length = len(line.encode())
            if diagnostic_records >= 512 or diagnostic_bytes + length > 1048576:
                diagnostic_capped = True
                timeline('process-diagnostics-capped', records=diagnostic_records, bytes=diagnostic_bytes)
                return
            diagnostic_seen.add(key)
            with (output / 'process-diagnostics.jsonl').open('a') as stream:
                stream.write(line)
            diagnostic_records += 1
            diagnostic_bytes += length
        except (FileNotFoundError, ProcessLookupError):
            continue

def log_diagnostics():
    log = HOME / 'evidence/application.log'
    state_path = output / 'log-observation-state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {'offset': 0, 'capturedBytes': 0, 'assertionSeen': False}
    try:
        with log.open('rb') as stream:
            stream.seek(state['offset'])
            raw = stream.read(min(65536 - state['capturedBytes'], 8192))
        if not raw:
            return
        text = raw.decode(errors='replace')
        timeline('application-log-first-observed', phase=mode, offset=state['offset'], text=text)
        # Keep a short carry-over so a line split at the read cap is recognized.
        combined = state.get('tail', '') + text
        if not state['assertionSeen'] and 'event_origin_changed' in combined:
            timeline('assertion-first-observed', phase=mode, timingLimit='Sampling time only; emission can precede this observation')
            state['assertionSeen'] = True
        state.update(offset=state['offset'] + len(raw), capturedBytes=state['capturedBytes'] + len(raw), tail=combined[-256:])
        state_path.write_text(json.dumps(state))
        if state['capturedBytes'] >= 65536:
            timeline('application-log-diagnostics-capped', bytes=state['capturedBytes'])
    except FileNotFoundError:
        pass

FLATPAK_UNITS = ('flatpak-portal.service', 'flatpak-session-helper.service')
UNIT_FIELDS = ('Id', 'LoadState', 'ActiveState', 'SubState', 'Result', 'MainPID', 'ExecMainPID', 'ExecMainCode', 'ExecMainStatus', 'ExecMainStartTimestampMonotonic', 'ExecMainExitTimestampMonotonic', 'StateChangeTimestampMonotonic', 'BusName', 'FragmentPath')
JOURNAL_FIELDS = ('__REALTIME_TIMESTAMP', '__MONOTONIC_TIMESTAMP', '_UID', '_SYSTEMD_OWNER_UID', '_PID', '_COMM', '_SYSTEMD_USER_UNIT', 'USER_UNIT', 'PRIORITY', 'MESSAGE')
ACTIVATION_NAMES = r'(?<![A-Za-z0-9_.-])(?:org\.freedesktop\.portal\.Flatpak|org\.freedesktop\.Flatpak|flatpak-portal\.service|flatpak-session-helper\.service)(?![A-Za-z0-9_.-])'

def bounded_diagnostic_read(args, stdout_limit):
    # A new process group contains only this read-only diagnostic command.
    # Drain bounded pipes; never communicate() into an unbounded buffer.
    buffers = {'stdout': bytearray(), 'stderr': bytearray()}
    limits = {'stdout': stdout_limit, 'stderr': 2048}
    reason = ''
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    deadline = time.monotonic() + 2
    with selectors.DefaultSelector() as selector:
        selector.register(proc.stdout, selectors.EVENT_READ, 'stdout')
        selector.register(proc.stderr, selectors.EVENT_READ, 'stderr')
        try:
            while selector.get_map() and not reason:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    reason = 'TIMEOUT'
                    break
                for key, _ in selector.select(min(remaining, 0.1)):
                    name = key.data
                    room = limits[name] - len(buffers[name])
                    chunk = os.read(key.fd, min(4096, room + 1))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    buffers[name].extend(chunk[:room])
                    if len(chunk) > room:
                        reason = 'OUTPUT_LIMIT'
                        break
            if not reason:
                try:
                    proc.wait(timeout=max(0.001, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    reason = 'TIMEOUT'
        finally:
            if reason or proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.stdout.close()
            proc.stderr.close()
            proc.wait(timeout=0.5)
    return {'returncode': proc.returncode, 'limit': reason, **{key: bytes(value).decode(errors='replace') for key, value in buffers.items()}}

def save_optional(name, value):
    # Supplemental diagnostic failures cannot alter the required app gate.
    try:
        raw = json.dumps(value, ensure_ascii=True, indent=2).encode() + b'\n'
        if len(raw) > 131072:
            raw = b'{"status":"OUTPUT_LIMIT","limit":"Optional diagnostic serialization exceeded 128 KiB; records omitted"}\n'
        (output / name).write_bytes(raw)
    except OSError:
        pass

def service_snapshot(phase):
    result = {**timestamp(), 'phase': phase, 'claim': 'Read-only unit state; inactive does not prove activation failed'}
    try:
        query = bounded_diagnostic_read(['runuser', '-u', USER, '--', 'env', '-i', *user_env, 'systemctl', '--user', '--no-pager', 'show', *FLATPAK_UNITS, '--property=' + ','.join(UNIT_FIELDS)], 16384)
        records = []
        for block in query['stdout'].strip().split('\n\n')[:2]:
            values = dict(line.split('=', 1) for line in block.splitlines() if '=' in line)
            if values.get('Id') in FLATPAK_UNITS:
                records.append({key: value[:2048] for key, value in values.items() if key in UNIT_FIELDS})
        result.update(status='RECORDED' if query['returncode'] == 0 and not query['limit'] and {record['Id'] for record in records} == set(FLATPAK_UNITS) else 'INCOMPLETE', records=records, returncode=query['returncode'], limit=query['limit'], stderr=query['stderr'][:512])
    except Exception as error:
        result.update(status='UNAVAILABLE', reason=str(error)[:512])
    save_optional(f'flatpak-service-state-{phase}.json', result)

def journal_record_allowed(record, kind, fresh_uid, start_us, end_us):
    # Owner UID, when present, takes precedence: never accept another user's
    # cgroup merely because an emitter happens to run as the requested UID.
    owner = record.get('_SYSTEMD_OWNER_UID', record.get('_UID'))
    if str(owner) != str(fresh_uid):
        return False
    try:
        if not start_us <= int(record.get('__REALTIME_TIMESTAMP', '')) <= end_us:
            return False
    except (TypeError, ValueError):
        return False
    if kind == 'units':
        return record.get('_SYSTEMD_USER_UNIT') in FLATPAK_UNITS or record.get('USER_UNIT') in FLATPAK_UNITS
    if kind == 'dbus':
        return (record.get('_SYSTEMD_USER_UNIT') == 'dbus.service' or record.get('_COMM') == 'dbus-daemon') and isinstance(record.get('MESSAGE'), str) and re.search(ACTIVATION_NAMES, record['MESSAGE']) is not None
    return False

def service_journals(events):
    result = {'claim': 'Only exact fresh-UID Flatpak units and exact-name D-Bus activation messages; absence is not success', 'queries': {}}
    try:
        start = next(event['unixSeconds'] for event in events if event['event'] == 'session-launch-requested')
        end = next(event['unixSeconds'] for event in events if event['event'] == 'session-client-return')
        base = ['journalctl', '--boot', '--no-pager', '--quiet', f'--since=@{int(start)}', f'--until=@{int(end) + 1}', '--output=json', '--output-fields=' + ','.join(JOURNAL_FIELDS)]
        for kind, count, cap in (('units', 40, 65536), ('dbus', 20, 32768)):
            if kind == 'units':
                branches = [[f'{identity}={uid}', f'{field}={unit}'] for identity in ('_UID', '_SYSTEMD_OWNER_UID') for field in ('_SYSTEMD_USER_UNIT', 'USER_UNIT') for unit in FLATPAK_UNITS]
            else:
                branches = [[f'{identity}={uid}', match] for identity in ('_UID', '_SYSTEMD_OWNER_UID') for match in ('_SYSTEMD_USER_UNIT=dbus.service', '_COMM=dbus-daemon')]
            matches = []
            for branch in branches:
                if matches:
                    matches.append('+')
                matches.extend(branch)
            args = [*base, f'--lines={count}', *matches]
            if kind == 'dbus':
                args.extend(['--case-sensitive=yes', '--grep=' + ACTIVATION_NAMES])
            query = bounded_diagnostic_read(args, cap)
            records, malformed = [], 0
            for line in query['stdout'].splitlines()[:count]:
                try:
                    record = json.loads(line)
                    if isinstance(record, dict) and journal_record_allowed(record, kind, uid, int(start * 1000000), int(end * 1000000)):
                        records.append({key: value[:2048] for key, value in record.items() if key in JOURNAL_FIELDS and isinstance(value, str)})
                except ValueError:
                    malformed += 1
            result['queries'][kind] = {'status': 'RECORDED' if query['returncode'] == 0 and not query['limit'] and not malformed else 'INCOMPLETE', 'returncode': query['returncode'], 'limit': query['limit'], 'malformedLines': malformed, 'records': records, 'stderr': query['stderr'][:512], 'recordLimit': count}
    except Exception as error:
        result.update(status='UNAVAILABLE', reason=str(error)[:512])
    save_optional('flatpak-service-journal.json', result)

def final_diagnostics():
    # Existing metadata only. Never enable/change crash handling or read cores.
    log_diagnostics()
    service_snapshot('after-session')
    events = [json.loads(line) for line in (output / 'observation-timeline.jsonl').read_text().splitlines()]
    service_journals(events)
    start = next(event['unixSeconds'] for event in events if event['event'] == 'session-launch-requested')
    allowed = {'__REALTIME_TIMESTAMP', '__MONOTONIC_TIMESTAMP', 'COREDUMP_UID', 'COREDUMP_PID', 'COREDUMP_COMM', 'COREDUMP_EXE', 'COREDUMP_SIGNAL', 'COREDUMP_SIGNAL_NAME'}
    try:
        query = subprocess.run(['journalctl', '--boot', '--no-pager', '--quiet', '--lines=32', f'--since=@{int(start)}', f'--until=@{int(time.time()) + 1}', f'COREDUMP_UID={uid}', '--output=json', '--output-fields=' + ','.join(sorted(allowed))], capture_output=True, text=True, timeout=5)
        records = []
        for line in query.stdout.splitlines()[:32]:
            record = json.loads(line)
            if str(record.get('COREDUMP_UID', '')) == str(uid):
                records.append({key: str(value)[:2048] for key, value in record.items() if key in allowed})
        status = 'PRESENT' if query.returncode == 0 and records else 'UNAVAILABLE_OR_NO_MATCH'
        result = {'status': status, 'returncode': query.returncode, 'records': records, 'stderr': query.stderr[:512], 'limit': 'Existing journal metadata only; absence does not prove no crash occurred; fields and string lengths capped'}
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        result = {'status': 'UNAVAILABLE', 'reason': str(error)[:512]}
    (output / 'crash-journal-metadata.json').write_text(json.dumps(result, indent=2) + '\n')
    timeline('final-diagnostics-complete')

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
            found[int(path.name)] = {'pid': int(path.name), 'namespacePids': [int(v) for v in status.get('NSpid', '').split()], 'argv': argv, 'processType': process_type(argv), 'namespaces': ns, 'instanceId': cfg.get('Instance', 'instance-id', fallback=''), 'sandbox': cfg.get('Instance', 'sandbox', fallback='false'), 'application': APP}
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
        process_diagnostics()
        log_diagnostics()
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
        main = {pid: proc for pid, proc in procs.items() if proc['processType'] is None and proc['instanceId'] == instance_id}
        parent_namespaces = {p['namespaces']['pid'] for p in main.values()}
        renderers = []
        if parent_namespaces:
            for proc in procs.values():
                if proc['processType'] != 'renderer':
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
        time.sleep(0.25)
    raise RuntimeError('No sustained owned visible application window and renderer within 85 seconds')

if mode == 'final-diagnostics':
    final_diagnostics()
    sys.exit(0)

service_snapshot('before-observer')
timeline('observer-start', samplingLimit='Process diagnostics sampled between checks; transient processes may be missed')
try:
    result = observe()
except Exception as error:
    result = {'status': 'FAIL', 'reason': str(error), 'classification': 'UNRESOLVED_STARTUP_OR_FIXTURE_FAILURE', 'claim': 'Failure is not proof of application incompatibility; inspect text evidence.'}
(output / 'startup-result.json').write_text(json.dumps(result, indent=2) + '\n')
timeline('observer-result', status=result['status'], reason=result.get('reason', ''))
sys.exit(0 if result['status'] == 'PASS' else 1)
