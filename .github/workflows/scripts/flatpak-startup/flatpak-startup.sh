#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${HT_RUNNER_ENVIRONMENT:-} == github-hosted && ${RUNNER_OS:-} == Linux ]] || exit 2
[[ ${GITHUB_REPOSITORY:-} == alltimehiddentunes-gif/hidden-tunes-packaging && $(uname -m) == x86_64 && $(id -u) != 0 ]] || exit 2
[[ ${GITHUB_RUN_ID:-} =~ ^[0-9]+$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[0-9]+$ && ${GITHUB_WORKSPACE:-} == /* && ${RUNNER_TEMP:-} == /* ]] || exit 2
scripts=$(realpath "$(dirname "$0")")
[[ $scripts == "$GITHUB_WORKSPACE/.github/workflows/scripts/flatpak-startup" ]] || exit 2
candidate="$GITHUB_WORKSPACE/qualified-input/flathub"
qualified_commit=34cb5cbb5b49f44f4f140b2a3b81f90410797007
[[ $(git -C "$candidate" rev-parse HEAD) == "$qualified_commit" && -z $(git -C "$candidate" status --porcelain) ]] || exit 2
test_user=ht-flatpak-smoke
test_home=/home/ht-flatpak-smoke
app_id=com.hiddentunes.HiddenTunes
system_dir="/var/tmp/ht-flatpak-startup-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
build_work="$RUNNER_TEMP/ht-flatpak-startup-builder"
evidence="$GITHUB_WORKSPACE/flatpak-startup-evidence"
if getent passwd "$test_user" >/dev/null || [[ -e "$test_home" || -L "$test_home" || -e "$system_dir" || -L "$system_dir" || -e "$build_work" || -e "$evidence" ]]; then echo 'Refusing pre-existing disposable paths or user'; exit 2; fi
[[ ! -e /tmp/.X11-unix/X97 && ! -e /tmp/.X97-lock && ! -e '/opt/Hidden Tunes Desktop' ]] || exit 2
mkdir "$evidence" "$build_work"
exec > >(tee "$evidence/qualification.log") 2>&1
user_created=no; manager_attempted=no; system_created=no; installed=no
firewall4=no; firewall6=no; test_uid=''; runtime_dir=''; stage=setup; startup_status=NOT_RUN
system_fp() { sudo env FLATPAK_SYSTEM_DIR="$system_dir" flatpak "$@"; }
as_test() { sudo -u "$test_user" env -i HOME="$test_home" USER="$test_user" LOGNAME="$test_user" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" FLATPAK_SYSTEM_DIR="$system_dir" "$@"; }
no_mounts_under() {
  local listing
  listing=$(findmnt -rn --raw -o TARGET) || return 1
  ! awk -v base="$1" '$0 == base || index($0, base "/") == 1 { found=1 } END { exit !found }' <<< "$listing"
}
cleanup() {
  local failed=0 quiet=yes state probe
  local log="$evidence/cleanup-commands.log"
  if [[ $user_created == yes ]]; then
    [[ $(id -u "$test_user") == "$test_uid" && "$test_uid" =~ ^[0-9]+$ && "$test_uid" -ge 1000 ]] || return 1
    if [[ $manager_attempted == yes ]]; then
      sudo timeout 10s loginctl disable-linger "$test_user" >> "$log" 2>&1 || echo 'disable-linger nonzero; check final state' >> "$log"
      sudo timeout --kill-after=5s 30s loginctl terminate-user "$test_uid" >> "$log" 2>&1 || echo 'terminate-user nonzero; check final state' >> "$log"
      sudo timeout --kill-after=5s 30s systemctl stop "user@$test_uid.service" "user-runtime-dir@$test_uid.service" >> "$log" 2>&1 || echo 'stop nonzero; check final state' >> "$log"
    fi
    sudo pkill -TERM -u "$test_uid" >> "$log" 2>&1 || true
    sleep 2
    if pgrep -u "$test_uid" >/dev/null; then sudo pkill -KILL -u "$test_uid" >> "$log" 2>&1 || true; sleep 1; fi
    pgrep -u "$test_uid" > "$evidence/cleanup-remaining-pids.txt" 2>> "$log"; probe=$?
    printf 'UID=%s\nprocessProbeExit=%s\n' "$test_uid" "$probe" > "$evidence/cleanup-final-state.txt"
    [[ $probe == 1 ]] || { quiet=no; failed=1; }
    if [[ $manager_attempted == yes ]]; then
      for unit in "user@$test_uid.service" "user-runtime-dir@$test_uid.service"; do
        if state=$(systemctl show "$unit" --property=ActiveState --value 2>> "$log"); then
          printf '%s=%s\n' "$unit" "$state" >> "$evidence/cleanup-final-state.txt"
          [[ $state == inactive ]] || { quiet=no; failed=1; }
        else quiet=no; failed=1; fi
      done
      if sudo test ! -e "/var/lib/systemd/linger/$test_user" && sudo test ! -L "/var/lib/systemd/linger/$test_user"; then echo 'linger=absent' >> "$evidence/cleanup-final-state.txt"; else quiet=no; failed=1; fi
    fi
  fi
  if [[ $quiet == yes ]]; then
    if [[ $installed == yes ]]; then
      system_fp uninstall --system -y "$app_id" >> "$log" 2>&1 || failed=1
      if system_fp info --system "$app_id" >/dev/null 2>&1 || sudo test -e "$system_dir/exports/share/applications/$app_id.desktop"; then failed=1; fi
    fi
    if [[ $user_created == yes ]]; then
      if [[ -e "$runtime_dir" || -L "$runtime_dir" ]]; then
        if [[ "$runtime_dir" == "/run/user/$test_uid" && ! -L "$runtime_dir" && $(readlink -f "$runtime_dir") == "$runtime_dir" && $(stat -c %u "$runtime_dir") == "$test_uid" ]] && no_mounts_under "$runtime_dir"; then sudo rm -rf --one-file-system -- "$runtime_dir" || failed=1; else failed=1; fi
      fi
      if [[ $(getent passwd "$test_user" | cut -d: -f6) == "$test_home" && ! -L "$test_home" && $(readlink -f "$test_home") == "$test_home" ]] && no_mounts_under "$test_home"; then
        sudo userdel --remove "$test_user" >> "$log" 2>&1 || failed=1
        if getent passwd "$test_user" >/dev/null || [[ -e "$test_home" ]]; then failed=1; fi
      else failed=1; fi
    fi
    if [[ $system_created == yes ]]; then
      if [[ "$system_dir" == "/var/tmp/ht-flatpak-startup-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" && ! -L "$system_dir" && $(readlink -f "$system_dir") == "$system_dir" && $(stat -c %u "$system_dir") == 0 ]] && no_mounts_under "$system_dir"; then sudo rm -rf --one-file-system -- "$system_dir" || failed=1; else failed=1; fi
    fi
    [[ $firewall4 != yes ]] || sudo iptables -D OUTPUT -m owner --uid-owner "$test_uid" -m comment --comment ht-flatpak-smoke -j REJECT || failed=1
    [[ $firewall6 != yes ]] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$test_uid" -m comment --comment ht-flatpak-smoke -j REJECT || failed=1
  else
    echo 'UID final state unverified; keeping outbound firewall, account and installation intact'
  fi
  [[ $failed == 0 ]]
}
finalize() {
  local rc=$? cleanup_status=FAIL
  trap - EXIT
  set +e
  cleanup
  [[ $? != 0 ]] || cleanup_status=PASS
  [[ $cleanup_status == PASS && $startup_status == PASS ]] || rc=1
  python3 - "$evidence/result.json" "$rc" "$stage" "$startup_status" "$cleanup_status" <<'PY'
import json, os, sys
path, rc, stage, startup, cleanup = sys.argv[1:]
with open(path, 'w') as stream:
    json.dump({'status': 'PASS' if rc == '0' else 'FAIL', 'qualificationCommit': os.environ['GITHUB_SHA'], 'qualifiedRecipeCommit': '34cb5cbb5b49f44f4f140b2a3b81f90410797007', 'stage': stage, 'offlineVisibleStartup': startup, 'cleanup': cleanup, 'scope': 'Offline X11 startup and effective Flatpak identity/context only', 'functionalRequalification': 'NOT RUN', 'portalSecureStoreCallbacks': 'NOT TESTED', 'fullElectronZypakSandboxAudit': 'NOT CLAIMED', 'flathubSubmission': 'NOT PERFORMED; metadata/legal/human contribution gates unchanged'}, stream, indent=2)
PY
  [[ $? == 0 ]] || rc=1
  exit "$rc"
}
trap finalize EXIT

sudo apt-get update
sudo apt-get install -y flatpak binutils desktop-file-utils dbus-x11 dbus-user-session xvfb xauth openbox wmctrl x11-utils iptables
flatpak --version > "$evidence/flatpak-version.txt"
stage=recreate_qualified_fixture
# Builder tools have their own new per-user installation; the original app
# is only repackaged by the pinned recipe, never compiled or patched.
export XDG_DATA_HOME="$build_work/data" XDG_CONFIG_HOME="$build_work/config" XDG_CACHE_HOME="$build_work/cache"
export FLATPAK_USER_DIR="$XDG_DATA_HOME/flatpak"
mkdir "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
flatpak remote-add --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub org.flatpak.Builder org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08 org.electronjs.Electron2.BaseApp//25.08
flatpak list --user --columns=ref,origin,active > "$evidence/builder-runtime-refs.txt"
flatpak_binary=$(command -v flatpak)
dbus-run-session -- flatpak run --command=flatpak-builder --env=FLATPAK_BINARY="$flatpak_binary" --env=FLATPAK_USER_DIR="$FLATPAK_USER_DIR" --filesystem="$FLATPAK_USER_DIR" org.flatpak.Builder --user --disable-rofiles-fuse --repo="$build_work/repo" "$build_work/build" "$candidate/com.hiddentunes.HiddenTunes.yml"
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME FLATPAK_USER_DIR
# A new custom system installation is readable by the new UID; ordinary host
# installations/remotes/overrides remain untouched. Only this local repo is unsigned.
sudo install -d -o root -g root -m 0755 "$system_dir"
system_created=yes
system_fp remote-add --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
system_fp install --system -y flathub org.freedesktop.Platform//25.08
system_fp remote-add --system --no-gpg-verify ht-flatpak-startup "file://$build_work/repo"
installed=yes
system_fp install --system -y ht-flatpak-startup "$app_id"
system_fp info --system --show-metadata "$app_id" > "$evidence/installed-metadata.txt"
system_fp list --system --columns=ref,origin,active > "$evidence/installed-runtime-refs.txt"
location=$(system_fp info --system --show-location "$app_id")
[[ "$location" == "$system_dir/app/$app_id/"* ]]
python3 - "$candidate" "$location" "$evidence" <<'PY'
import configparser, hashlib, json, pathlib, sys
candidate, installed, evidence = map(pathlib.Path, sys.argv[1:])
record = json.loads((candidate / 'release-inspection.json').read_text())
app = installed / 'files/extra/hidden-tunes'
files = {p.relative_to(app).as_posix(): p for p in app.rglob('*') if p.is_file()}
if set(files) != set(record['payloadHashes']): raise RuntimeError('Original payload inventory differs')
for name, expected in record['payloadHashes'].items():
    if files[name].is_symlink() or hashlib.sha256(files[name].read_bytes()).hexdigest() != expected: raise RuntimeError('Original payload hash mismatch: ' + name)
cfg = configparser.ConfigParser(interpolation=None)
cfg.read(evidence / 'installed-metadata.txt')
expected = {'shared': 'ipc;network;', 'sockets': 'pulseaudio;x11;', 'devices': 'dri;'}
if dict(cfg['Context']) != expected: raise RuntimeError('Installed permissions differ from qualified evidence')
if cfg['Application']['name'] != 'com.hiddentunes.HiddenTunes' or cfg['Application']['command'] != 'hidden-tunes' or cfg['Application']['runtime'] != 'org.freedesktop.Platform/x86_64/25.08': raise RuntimeError('Installed identity/launcher/runtime mismatch')
if any(section.endswith('Bus Policy') for section in cfg.sections()): raise RuntimeError('Unexpected bus policy')
extra = cfg['Extra Data']
if extra.get('checksum') != 'd858bff4cf38db047f2d1c5ae40600df53ec0870313e6d2715d5678449e5eb22' or extra.get('size') != '146881864' or extra.get('uri') != 'https://downloads.hiddentunes.com/desktop/linux/1.0.1/Hidden-Tunes-Desktop-1.0.1-amd64.deb': raise RuntimeError('Official extra-data release metadata differs')
if (installed / 'files/bin/hidden-tunes').read_bytes() != (candidate / 'hidden-tunes').read_bytes(): raise RuntimeError('Qualified Zypak launcher changed')
(evidence / 'payload-parity.json').write_text(json.dumps({'status': 'PASS', 'originalFiles': len(files), 'version': record['packageMetadata']['version'], 'installedMetadata': 'PASS', 'launcher': 'UNCHANGED'}, indent=2))
PY

stage=create_offline_session
sudo useradd --create-home --shell /bin/bash "$test_user"
user_created=yes
test_uid=$(id -u "$test_user")
[[ "$test_uid" =~ ^[0-9]+$ && "$test_uid" -ge 1000 && $(readlink -f "$test_home") == "$test_home" ]]
runtime_dir="/run/user/$test_uid"
[[ ! -e "$runtime_dir" && ! -L "$runtime_dir" ]]
sudo test ! -e "/var/lib/systemd/linger/$test_user"
sudo test ! -L "/var/lib/systemd/linger/$test_user"
if systemctl is-active --quiet "user@$test_uid.service"; then exit 2; fi
sudo install -d -o "$test_uid" -g "$(id -g "$test_user")" -m 0700 "$test_home/evidence"
sudo install -o root -g root -m 0444 "$scripts/session.sh" "$test_home/session.sh"
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$test_uid" -m comment --comment ht-flatpak-smoke -j REJECT
firewall4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$test_uid" -m comment --comment ht-flatpak-smoke -j REJECT
firewall6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$test_uid" -m comment --comment ht-flatpak-smoke -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$test_uid" -m comment --comment ht-flatpak-smoke -j REJECT
manager_attempted=yes
sudo loginctl enable-linger "$test_user"
sudo timeout --kill-after=5s 30s systemctl start "user@$test_uid.service"
systemctl is-active --quiet "user@$test_uid.service"
[[ ! -L "$runtime_dir" && $(stat -c %u "$runtime_dir") == "$test_uid" ]]
bus_ready=no
deadline=$((SECONDS + 10))
while (( SECONDS < deadline )); do
  if sudo test -S "$runtime_dir/bus" && [[ $(sudo stat -c %u "$runtime_dir/bus") == "$test_uid" ]] && as_test timeout --kill-after=1s 1s systemctl --user show --property=Version > "$evidence/user-bus.txt" 2>&1 && grep -q '^Version=.' "$evidence/user-bus.txt"; then bus_ready=yes; break; fi
  sleep 0.25
done
[[ $bus_ready == yes ]] || { echo 'Fixture user manager readiness failed'; exit 1; }
# User-activated Flatpak helpers must resolve the same isolated installation.
# This affects only this new disposable manager, whose lifetime ends in cleanup.
as_test systemctl --user set-environment FLATPAK_SYSTEM_DIR="$system_dir"
systemctl show "user@$test_uid.service" --property=ActiveState --property=MainPID --property=ControlGroup > "$evidence/user-manager.txt"
stage=offline_startup
startup_status=RUNNING
stamp_observation() {
  sudo python3 - "$evidence/observation-timeline.jsonl" "$@" <<'PY'
import json, sys, time
path, event, *details = sys.argv[1:]
with open(path, 'a') as stream:
    stream.write(json.dumps({'unixSeconds': time.time(), 'monotonicSeconds': time.monotonic(), 'event': event, 'details': details}) + '\n')
PY
}
stamp_observation session-launch-requested
(
  cd /
  as_test timeout --signal=TERM --kill-after=10s 140s systemd-run --user --wait --pipe --collect --property=Type=exec --property=RuntimeMaxSec=125s --unit=ht-flatpak-smoke \
    env -i HOME="$test_home" USER="$test_user" LOGNAME="$test_user" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" FLATPAK_SYSTEM_DIR="$system_dir" DISPLAY=:97 XAUTHORITY="$test_home/.Xauthority" \
    timeout --signal=TERM --kill-after=10s 115s bash "$test_home/session.sh"
) > "$evidence/session.log" 2>&1 &
client_pid=$!
set +e
sudo env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin GITHUB_ACTIONS=true HT_RUNNER_ENVIRONMENT="$HT_RUNNER_ENVIRONMENT" GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
  timeout --kill-after=5s 100s python3 "$scripts/collect-startup.py" "$test_uid" "$location" "$evidence"
collector_rc=$?
stamp_observation collector-client-return "$collector_rc"
stamp_observation stop-marker-requested
sudo touch "$test_home/evidence/stop"
stop_rc=$?
stamp_observation stop-marker-write-return "$stop_rc"
wait "$client_pid"
session_rc=$?
stamp_observation session-client-return "$session_rc"
sudo env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin GITHUB_ACTIONS=true HT_RUNNER_ENVIRONMENT="$HT_RUNNER_ENVIRONMENT" GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
  timeout --kill-after=5s 10s python3 "$scripts/collect-startup.py" "$test_uid" "$location" "$evidence" final-diagnostics
diagnostics_rc=$?
stamp_observation optional-final-diagnostics-return "$diagnostics_rc"
set -e
for name in application.log xvfb.log openbox.log window-manager.txt session-cgroup.txt instance-id.txt; do
  if sudo test -f "$test_home/evidence/$name"; then sudo cat "$test_home/evidence/$name" > "$evidence/$name"; fi
done
[[ $collector_rc == 0 && $session_rc == 0 ]] || { echo "Collector=$collector_rc session=$session_rc; startup not established"; exit 1; }
startup_status=PASS
stage=cleanup
