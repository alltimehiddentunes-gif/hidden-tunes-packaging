#!/usr/bin/env bash
set -euo pipefail
# This script is deliberately unusable on an owner's workstation/self-hosted runner.
[[ "${GITHUB_ACTIONS:-}" == true && "${HT_RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == Linux ]] || { echo 'Disposable GitHub-hosted Linux runner required'; exit 2; }
[[ "${GITHUB_REPOSITORY:-}" == alltimehiddentunes-gif/hidden-tunes-packaging && "$(uname -m)" == x86_64 ]] || exit 2
[[ "${GITHUB_WORKSPACE:-}" == /* && -d "$GITHUB_WORKSPACE/qualified-input/.git" ]] || exit 2
fixture="$GITHUB_WORKSPACE/qualified-input/snap"
qualified_commit=5ebd60d7871f7205ebcef902bbc1a820e8dca4bb
[[ "$(git -C "$fixture" rev-parse HEAD)" == "$qualified_commit" ]] || exit 2
[[ -z "$(git -C "$fixture" status --porcelain)" ]] || { echo 'Pinned packaging checkout is not clean'; exit 2; }
test_user=ht-snap-smoke
test_home=/home/ht-snap-smoke
if getent passwd "$test_user" >/dev/null || [[ -e "$test_home" || -e '/opt/Hidden Tunes Desktop' ]]; then echo 'Refusing pre-existing user/profile/native installation'; exit 2; fi
if snap list hiddentunes >/dev/null 2>&1; then echo 'Refusing pre-existing snap'; exit 2; fi
evidence="$GITHUB_WORKSPACE/snap-confinement-evidence"
[[ ! -e "$evidence" ]] || { echo 'Refusing pre-existing evidence directory'; exit 2; }
mkdir "$evidence"
exec > >(tee "$evidence/qualification.log") 2>&1
installed=no
user_created=no
runtime_created=no
systemd_session_attempted=no
firewall4=no
firewall6=no
test_uid=''
runtime_dir=''
stage=setup
smoke_status=FAIL
cleanup_status=NOT_RUN
cleanup() {
  local failed=0
  local mounts=''
  local uid_quiescent=yes
  if [[ "$user_created" == yes ]]; then
    # The UID was allocated only after refusing an existing account/home.
    if ! [[ "$(id -u "$test_user")" == "$test_uid" && "$test_uid" =~ ^[0-9]+$ && "$test_uid" -ge 1000 ]]; then return 1; fi
    if [[ "$systemd_session_attempted" == yes ]]; then
      # Stop the newly enabled manager before killing processes: otherwise it
      # could respawn user services after the offline firewall is removed.
      sudo loginctl disable-linger "$test_user" || { failed=1; uid_quiescent=no; }
      if sudo loginctl show-user "$test_uid" --property=UID --value >/dev/null 2>&1; then
        sudo timeout --signal=TERM --kill-after=5s 30s loginctl terminate-user "$test_uid" || { failed=1; uid_quiescent=no; }
      fi
      sudo timeout --signal=TERM --kill-after=5s 30s systemctl stop "user@$test_uid.service" "user-runtime-dir@$test_uid.service" || { failed=1; uid_quiescent=no; }
      for unit in "user@$test_uid.service" "user-runtime-dir@$test_uid.service"; do
        if [[ "$(systemctl show "$unit" --property=ActiveState --value)" != inactive ]]; then failed=1; uid_quiescent=no; fi
      done
      if [[ -e "/var/lib/systemd/linger/$test_user" || -L "/var/lib/systemd/linger/$test_user" ]]; then failed=1; uid_quiescent=no; fi
    fi
    sudo pkill -TERM -u "$test_uid" || [[ "$?" == 1 ]] || failed=1
    sleep 2
    if pgrep -u "$test_uid" >/dev/null; then sudo pkill -KILL -u "$test_uid" || failed=1; sleep 1; fi
    if pgrep -u "$test_uid" >/dev/null; then failed=1; uid_quiescent=no; fi
  fi
  if [[ "$uid_quiescent" == yes ]]; then
    if [[ "$firewall4" == yes ]]; then sudo iptables -D OUTPUT -m owner --uid-owner "$test_uid" -m comment --comment ht-snap-smoke -j REJECT || failed=1; fi
    if [[ "$firewall6" == yes ]]; then sudo ip6tables -D OUTPUT -m owner --uid-owner "$test_uid" -m comment --comment ht-snap-smoke -j REJECT || failed=1; fi
  else
    echo 'UID processes survived termination; retaining outbound firewall rules'
  fi
  if [[ "$installed" == yes ]]; then
    sudo snap remove --purge hiddentunes || failed=1
    if snap list hiddentunes >/dev/null 2>&1 || [[ -e /snap/hiddentunes/current ]]; then failed=1; fi
    if find /var/lib/snapd/desktop/applications -maxdepth 1 -name 'hiddentunes_*.desktop' -type f | grep -q .; then failed=1; fi
  fi
  if [[ "$runtime_created" == yes && "$uid_quiescent" == yes ]]; then
    if [[ -e "$runtime_dir" || -L "$runtime_dir" ]]; then
      if [[ "$runtime_dir" == "/run/user/$test_uid" && ! -L "$runtime_dir" && "$(readlink -f "$runtime_dir")" == "$runtime_dir" && "$(stat -c %u "$runtime_dir")" == "$test_uid" ]] && ! pgrep -u "$test_uid" >/dev/null; then
        # This directory did not exist before the test. Refuse any mount at or
        # below it; never traverse a remaining session mount or bind mount.
        if ! mounts="$(findmnt -rn --raw -o TARGET)"; then
          echo 'Unable to establish safe runtime mount state'; failed=1
        elif awk -v base="$runtime_dir" '$0 == base || index($0, base "/") == 1 { found=1 } END { exit !found }' <<< "$mounts"; then
          echo 'Refusing runtime cleanup with a remaining mount'; failed=1
        else
          sudo rm -rf --one-file-system -- "$runtime_dir" || failed=1
          [[ ! -e "$runtime_dir" ]] || failed=1
        fi
      else failed=1; fi
    fi
  fi
  if [[ "$user_created" == yes && "$uid_quiescent" == yes ]]; then
    if [[ "$(getent passwd "$test_user" | cut -d: -f6)" == "$test_home" && "$(readlink -f "$test_home")" == "$test_home" ]]; then
      sudo userdel --remove "$test_user" || failed=1
      if getent passwd "$test_user" >/dev/null || [[ -e "$test_home" ]]; then failed=1; fi
    else failed=1; fi
  fi
  [[ "$failed" == 0 ]]
}
finalize() {
  local rc=$?
  trap - EXIT
  set +e
  cleanup
  local cleanup_rc=$?
  if [[ "$cleanup_rc" == 0 ]]; then cleanup_status=PASS; else cleanup_status=FAIL; rc=1; fi
  if [[ "$smoke_status" != PASS ]]; then rc=1; fi
  HT_FINAL_RC="$rc" HT_FINAL_STAGE="$stage" HT_SMOKE_STATUS="$smoke_status" HT_CLEANUP_STATUS="$cleanup_status" python3 - <<'PY' > "$evidence/confinement-result.json"
import json, os
print(json.dumps({
    'status': 'PASS' if os.environ['HT_FINAL_RC'] == '0' else 'FAIL',
    'commit': os.environ['GITHUB_SHA'],
    'qualifiedRecipeCommit': '5ebd60d7871f7205ebcef902bbc1a820e8dca4bb',
    'stage': os.environ['HT_FINAL_STAGE'],
    'offlineVisibleWindowStartup': os.environ['HT_SMOKE_STATUS'],
    'cleanup': os.environ['HT_CLEANUP_STATUS'],
    'scope': 'Bounded offline X11 startup, visible-window ownership, Snap AppArmor/seccomp process evidence only',
    'applicationBytes': 'See installed-payload-parity.json; must PASS before any launch',
    'secureStore': 'NOT TESTED; password-manager-service remains disconnected',
    'electronInternalSandboxAudit': 'NOT CLAIMED; no sandbox-disabling flags permitted',
    'desktopFunctionalRequalification': 'NOT RUN',
    'storeAutoConnectApproval': 'NOT GRANTED; local browser-sandbox connection only',
    'publication': 'NOT PERFORMED',
    'failureInterpretation': 'A failed smoke alone does not prove application incompatibility; inspect stage and evidence for fixture or harness limitations.'
}, indent=2))
PY
  local result_rc=$?
  [[ "$result_rc" == 0 ]] || rc=1
  exit "$rc"
}
trap finalize EXIT

sudo apt-get update
sudo apt-get install -y squashfs-tools desktop-file-utils xvfb xauth openbox wmctrl x11-utils dbus-x11 dbus-user-session iptables
sudo snap install snapcraft --classic
snap version > "$evidence/snap-version.txt"
snapcraft --version > "$evidence/snapcraft-version.txt"
stage=recreate_fixture
cd "$fixture"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 -o original.deb 'https://downloads.hiddentunes.com/desktop/linux/1.0.1/Hidden-Tunes-Desktop-1.0.1-amd64.deb'
echo 'd858bff4cf38db047f2d1c5ae40600df53ec0870313e6d2715d5678449e5eb22  original.deb' | sha256sum --check --strict
[[ "$(stat -c %s original.deb)" == 146881864 ]]
dpkg-deb --extract original.deb original
sudo snapcraft pack --destructive-mode
artifact="$fixture/hiddentunes_1.0.1_amd64.snap"
[[ -f "$artifact" ]]
sha256sum "$artifact" > "$evidence/fixture-snap-sha256.txt"
unsquashfs -d unpacked "$artifact"
python3 scripts/verify-payload.py 'original/opt/Hidden Tunes Desktop' 'unpacked/opt/Hidden Tunes Desktop' > "$evidence/packaged-payload-parity.json"
cp unpacked/meta/snap.yaml "$evidence/snap.yaml"
grep -qx 'confinement: strict' "$evidence/snap.yaml"
installed=yes
sudo snap install --dangerous "$artifact"
[[ "$(snap list hiddentunes | awk 'NR==2 {print $2}')" == 1.0.1 ]]
python3 scripts/verify-payload.py 'original/opt/Hidden Tunes Desktop' '/snap/hiddentunes/current/opt/Hidden Tunes Desktop' > "$evidence/installed-payload-parity.json"
snap connections hiddentunes > "$evidence/connections-before.txt"
[[ "$(snap connections hiddentunes | awk '$2=="hiddentunes:password-manager-service" {print $3}')" == '-' ]]
# This local connection is an explicit test prerequisite, not Store approval.
sudo snap connect hiddentunes:browser-sandbox :browser-support
sudo snap disconnect hiddentunes:network
snap connections hiddentunes > "$evidence/connections-during.txt"
[[ "$(snap connections hiddentunes | awk '$2=="hiddentunes:browser-sandbox" {print $3}')" == ':browser-support' ]]
[[ "$(snap connections hiddentunes | awk '$2=="hiddentunes:network" {print $3}')" == '-' ]]
[[ "$(snap connections hiddentunes | awk '$2=="hiddentunes:password-manager-service" {print $3}')" == '-' ]]

stage=create_empty_session
sudo useradd --create-home --shell /bin/bash "$test_user"
user_created=yes
test_uid="$(id -u "$test_user")"
[[ "$test_uid" =~ ^[0-9]+$ && "$test_uid" -ge 1000 ]]
[[ "$(getent passwd "$test_user" | cut -d: -f6)" == "$test_home" && "$(readlink -f "$test_home")" == "$test_home" ]]
runtime_dir="/run/user/$test_uid"
[[ ! -e "$runtime_dir" && ! -L "$runtime_dir" ]]
[[ ! -e "/var/lib/systemd/linger/$test_user" && ! -L "/var/lib/systemd/linger/$test_user" ]]
if systemctl is-active --quiet "user@$test_uid.service"; then echo 'Refusing pre-existing user manager'; exit 2; fi
sudo install -d -m 0700 -o "$test_uid" -g "$(id -g "$test_user")" "$test_home/evidence"
# Defense in depth: no outbound IPv4/IPv6 for the unique test UID, even if
# another connected Snap interface permits sockets. X11/DBus use Unix sockets.
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$test_uid" -m comment --comment ht-snap-smoke -j REJECT
firewall4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$test_uid" -m comment --comment ht-snap-smoke -j REJECT
firewall6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$test_uid" -m comment --comment ht-snap-smoke -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$test_uid" -m comment --comment ht-snap-smoke -j REJECT
printf 'Temporary UID %s: outbound IPv4 and IPv6 REJECT; private Unix-socket X11/DBus; no credentials.\n' "$test_uid" > "$evidence/offline-isolation.txt"

stage=systemd_user_session
# The real user manager owns the session bus and can create Snap tracking
# scopes. A separate dbus-run-session bus cannot provide that systemd service.
runtime_created=yes
systemd_session_attempted=yes
sudo loginctl enable-linger "$test_user"
sudo timeout --signal=TERM --kill-after=5s 30s systemctl start "user@$test_uid.service"
systemctl is-active --quiet "user@$test_uid.service"
[[ -d "$runtime_dir" && ! -L "$runtime_dir" && "$(readlink -f "$runtime_dir")" == "$runtime_dir" && "$(stat -c %u "$runtime_dir")" == "$test_uid" ]]
systemctl show "user@$test_uid.service" --property=ActiveState --property=MainPID --property=ControlGroup > "$evidence/user-manager.txt"
loginctl show-user "$test_uid" --property=UID --property=Linger --property=RuntimePath >> "$evidence/user-manager.txt"
bus_ready=no
bus_deadline=$((SECONDS + 10))
while (( SECONDS < bus_deadline )); do
  if [[ -S "$runtime_dir/bus" && "$(stat -c %u "$runtime_dir/bus")" == "$test_uid" ]] &&
    sudo -u "$test_user" env -i HOME="$test_home" USER="$test_user" LOGNAME="$test_user" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" timeout --signal=TERM --kill-after=1s 1s systemctl --user show --property=Version > "$evidence/user-manager-bus.txt" 2>&1 &&
    grep -q '^Version=.' "$evidence/user-manager-bus.txt"; then
    bus_ready=yes
    break
  fi
  sleep 0.25
done
[[ "$bus_ready" == yes ]] || { echo 'Fixture failure: owned systemd user bus and manager were not ready within the bounded readiness window'; exit 1; }

cat > "$evidence/session.sh" <<'SESSION'
#!/usr/bin/env bash
set -euo pipefail
[[ "$(id -un)" == ht-snap-smoke && "$HOME" == /home/ht-snap-smoke && -n "${DISPLAY:-}" && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || exit 2
cd "$HOME/evidence"
[[ "$DBUS_SESSION_BUS_ADDRESS" == "unix:path=/run/user/$(id -u)/bus" ]]
cat "/proc/$$/cgroup" > session-cgroup.txt
grep -Fq "/user.slice/user-$(id -u).slice/user@$(id -u).service/" session-cgroup.txt || { echo 'Harness did not enter the dedicated systemd user cgroup'; exit 2; }
openbox --sm-disable > openbox.log 2>&1 &
wm_pid=$!
app_pid=''
stop_session() { [[ -z "$app_pid" ]] || kill -TERM "$app_pid" 2>/dev/null || true; kill -TERM "$wm_pid" 2>/dev/null || true; }
trap stop_session EXIT
for attempt in {1..30}; do if wmctrl -m > window-manager.txt 2>/dev/null; then break; fi; sleep 0.2; done
wmctrl -m > window-manager.txt
# No application flags or product environment overrides; Electron sandbox retained.
/snap/bin/hiddentunes > application.log 2>&1 &
app_pid=$!
python3 - <<'PY'
import json, os, pathlib, re, subprocess, time

root = pathlib.Path('/proc')
uid = os.getuid()
expected_exe = re.compile(r'^/snap/hiddentunes/[^/]+/opt/Hidden Tunes Desktop/hidden-tunes-desktop$')
forbidden = {'--no-sandbox', '--disable-setuid-sandbox', '--disable-seccomp-filter-sandbox', '--disable-gpu-sandbox', '--single-process'}
fatal = re.compile(r'No usable sandbox|SUID sandbox|FATAL:|Failed to move to new namespace|error while loading shared libraries|Missing X server|GPU process isn.t usable|The display compositor is frequently crashing', re.I)

def processes():
    found = {}
    for path in root.iterdir():
        if not path.name.isdigit():
            continue
        try:
            if path.stat().st_uid != uid:
                continue
            exe = os.readlink(path / 'exe')
            if not expected_exe.fullmatch(exe):
                continue
            argv = (path / 'cmdline').read_bytes().decode(errors='replace').rstrip('\0').split('\0')
            if any(arg.split('=', 1)[0] in forbidden for arg in argv):
                raise RuntimeError('Sandbox-disabling application flag observed')
            status = dict(line.split(':', 1) for line in (path / 'status').read_text().splitlines() if ':' in line)
            profile = (path / 'attr/current').read_text().strip()
            if profile != 'snap.hiddentunes.hiddentunes (enforce)' or status.get('Seccomp', '').strip() != '2':
                raise RuntimeError('Application process is not under required enforcing Snap profile/seccomp filter')
            found[int(path.name)] = {'pid': int(path.name), 'exe': exe, 'argv': argv, 'apparmor': profile, 'seccomp': status['Seccomp'].strip(), 'noNewPrivs': status.get('NoNewPrivs', '').strip()}
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError as error:
            pathlib.Path('startup-evidence.json').write_text(json.dumps({'status': 'FAIL', 'failureClassification': 'HARNESS_PERMISSION_LIMITATION', 'reason': str(error)}, indent=2))
            raise RuntimeError('Cannot inspect required process evidence; this is a harness limitation, not proven app incompatibility') from error
    return found

deadline = time.monotonic() + 65
first = None
observations = []
previous_signature = None
while time.monotonic() < deadline:
    log = pathlib.Path('application.log').read_text(errors='replace')
    if fatal.search(log):
        raise RuntimeError('Fatal startup/sandbox/loader diagnostic; inspect application.log')
    procs = processes()
    windows = subprocess.run(['wmctrl', '-lp'], capture_output=True, text=True, check=True).stdout
    visible = []
    for line in windows.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 4 or not parts[2].isdigit():
            continue
        pid = int(parts[2])
        if pid not in procs:
            continue
        info = subprocess.run(['xwininfo', '-id', parts[0]], capture_output=True, text=True)
        if info.returncode != 0 or 'Map State: IsViewable' not in info.stdout:
            continue
        props = subprocess.run(['xprop', '-id', parts[0], '_NET_WM_PID', 'WM_CLASS', '_NET_WM_NAME'], capture_output=True, text=True, check=True).stdout
        if not re.search(r'_NET_WM_PID\([^)]*\) = ' + str(pid) + r'\b', props):
            raise RuntimeError('Window PID ownership evidence missing')
        visible.append({'window': parts[0], 'pid': pid, 'title': parts[4] if len(parts) > 4 else '', 'properties': props})
    renderers = [p for p in procs.values() if '--type=renderer' in p['argv']]
    if visible and renderers:
        signature = (tuple(sorted((w['window'], w['pid']) for w in visible)), tuple(sorted(p['pid'] for p in renderers)))
        if first is None or signature != previous_signature:
            first = time.monotonic()
            observations = []
        previous_signature = signature
        observations.append({'seconds': round(time.monotonic() - first, 2), 'windows': visible, 'processes': list(procs.values())})
        if time.monotonic() - first >= 8:
            pathlib.Path('startup-evidence.json').write_text(json.dumps({'status': 'PASS', 'observationSeconds': round(time.monotonic() - first, 2), 'observations': observations, 'claim': 'Visible offline X11 window owned by the unchanged Snap executable; renderer present; observed app processes use enforcing Snap AppArmor and seccomp2. No functional, secure-store or complete Electron internal-sandbox claim.'}, indent=2))
            break
    else:
        first = None
        observations = []
        previous_signature = None
    time.sleep(2)
else:
    pathlib.Path('startup-evidence.json').write_text(json.dumps({'status': 'FAIL', 'failureClassification': 'STARTUP_NOT_ESTABLISHED', 'reason': 'No sustained visible application window with renderer and required process confinement within 65 seconds'}, indent=2))
    raise SystemExit(1)
PY
SESSION
chmod 0644 "$evidence/session.sh"
# The dedicated user cannot traverse the runner's private workspace. Place only
# this harness script in its new home; keep it root-owned and read-only.
sudo install -o root -g root -m 0444 "$evidence/session.sh" "$test_home/session.sh"
stage=offline_startup
set +e
(
  cd /
  # A user service is forked by the user manager directly into its hierarchy;
  # do not depend on moving a sudo child from the hosted-agent system cgroup.
  sudo -u "$test_user" env -i HOME="$test_home" USER="$test_user" LOGNAME="$test_user" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
    timeout --signal=TERM --kill-after=10s 125s systemd-run --user --wait --pipe --collect --property=Type=exec --property=RuntimeMaxSec=115s --unit=ht-snap-smoke \
    env -i HOME="$test_home" USER="$test_user" LOGNAME="$test_user" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
    timeout --signal=TERM --kill-after=10s 100s xvfb-run -a -s '-screen 0 1280x800x24 -nolisten tcp' bash "$test_home/session.sh"
)
session_rc=$?
set -e
# Copy only explicit text evidence before deleting the dedicated test account.
for name in application.log openbox.log window-manager.txt session-cgroup.txt startup-evidence.json; do
  if sudo test -f "$test_home/evidence/$name"; then sudo cat "$test_home/evidence/$name" > "$evidence/$name"; fi
done
[[ "$session_rc" == 0 ]] || { echo "Bounded session failed with exit $session_rc; timeout is not PASS"; exit 1; }
python3 - "$evidence/startup-evidence.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if data.get('status') != 'PASS' or data.get('observationSeconds', 0) < 8:
    raise SystemExit('Missing positive window/confinement evidence')
PY
smoke_status=PASS
stage=cleanup
# EXIT finalizer removes only the newly installed snap/account and exact UID rules.
