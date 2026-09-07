#!/usr/bin/env bash
set -euo pipefail
[[ "$(id -un)" == ht-flatpak-smoke && "$HOME" == /home/ht-flatpak-smoke ]] || exit 2
[[ "$DBUS_SESSION_BUS_ADDRESS" == "unix:path=/run/user/$(id -u)/bus" ]] || exit 2
[[ "$DISPLAY" == :97 && "$XAUTHORITY" == "$HOME/.Xauthority" ]] || exit 2
cd "$HOME/evidence"
cat "/proc/$$/cgroup" > session-cgroup.txt
grep -Fq "/user.slice/user-$(id -u).slice/user@$(id -u).service/" session-cgroup.txt || exit 2
[[ ! -e "$HOME/.var/app/com.hiddentunes.HiddenTunes" ]] || { echo 'Profile is not empty'; exit 2; }
[[ ! -e /tmp/.X11-unix/X97 && ! -e /tmp/.X97-lock ]] || exit 2
umask 077
touch "$XAUTHORITY"
xauth -f "$XAUTHORITY" add "$DISPLAY" . "$(mcookie)"
Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp -auth "$XAUTHORITY" > xvfb.log 2>&1 &
x_pid=$!
wm_pid=''
app_pid=''
stop_session() {
  flatpak kill com.hiddentunes.HiddenTunes >/dev/null 2>&1 || true
  [[ -z "$app_pid" ]] || kill -TERM "$app_pid" 2>/dev/null || true
  [[ -z "$wm_pid" ]] || kill -TERM "$wm_pid" 2>/dev/null || true
  kill -TERM "$x_pid" 2>/dev/null || true
  wait || true
}
trap stop_session EXIT
for attempt in {1..30}; do if xdpyinfo >/dev/null 2>&1; then break; fi; sleep 0.2; done
xdpyinfo >/dev/null
openbox --sm-disable > openbox.log 2>&1 &
wm_pid=$!
for attempt in {1..30}; do if wmctrl -m > window-manager.txt 2>/dev/null; then break; fi; sleep 0.2; done
wmctrl -m > window-manager.txt
# Original manifest command and zypak launcher; only network access is subtracted.
flatpak run --system --unshare=network --instance-id-fd=3 com.hiddentunes.HiddenTunes 3> instance-id.txt > application.log 2>&1 &
app_pid=$!
for attempt in {1..100}; do
  [[ ! -e stop ]] || exit 0
  kill -0 "$app_pid" 2>/dev/null || { wait "$app_pid"; exit 1; }
  sleep 1
done
echo 'Collector did not finish within the bounded session'
exit 1
