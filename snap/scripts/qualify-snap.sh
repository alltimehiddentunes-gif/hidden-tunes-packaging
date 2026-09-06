#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${HT_RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == Linux ]] || { echo 'Disposable GitHub-hosted Linux runner required'; exit 2; }
[[ "${GITHUB_REPOSITORY:-}" == alltimehiddentunes-gif/hidden-tunes-packaging ]] || exit 2
[[ "$(uname -m)" == x86_64 ]] || exit 2
cd "$GITHUB_WORKSPACE/snap"
mkdir -p evidence
exec > >(tee -a evidence/qualification.log) 2>&1
if snap list hiddentunes >/dev/null 2>&1; then echo 'Refusing pre-existing installation'; exit 2; fi
if [[ -e '/opt/Hidden Tunes Desktop' ]]; then echo 'Refusing existing native installation'; exit 2; fi
snap version
snapcraft --version
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 -o original.deb 'https://downloads.hiddentunes.com/desktop/linux/1.0.1/Hidden-Tunes-Desktop-1.0.1-amd64.deb'
echo 'd858bff4cf38db047f2d1c5ae40600df53ec0870313e6d2715d5678449e5eb22  original.deb' | sha256sum -c -
[[ "$(stat -c %s original.deb)" == 146881864 ]]
dpkg-deb --extract original.deb original
snapcraft expand-extensions > evidence/expanded-snapcraft.yaml
sudo snapcraft pack --destructive-mode
mapfile -t packages < <(find . -maxdepth 1 -name 'hiddentunes_1.0.1_amd64.snap' -type f)
[[ "${#packages[@]}" == 1 ]]
artifact="${packages[0]}"
sha256sum "$artifact" > evidence/snap-sha256.txt
unsquashfs -d unpacked "$artifact"
python3 scripts/verify-payload.py 'original/opt/Hidden Tunes Desktop' 'unpacked/opt/Hidden Tunes Desktop' > evidence/payload-parity.json
cp unpacked/meta/snap.yaml evidence/snap.yaml
# The source desktop file deliberately uses Canonical's ${SNAP} placeholder.
# Validate the actual desktop entry after snapd expands it during installation.
installed=no
cleanup() { if [[ "$installed" == yes ]]; then sudo snap remove --purge hiddentunes; fi; }
trap cleanup EXIT
sudo snap install --dangerous "$artifact"
installed=yes
snap list hiddentunes | tee evidence/installed.txt
[[ "$(snap list hiddentunes | awk 'NR==2 {print $2}')" == 1.0.1 ]]
snap connections hiddentunes > evidence/connections.txt
mapfile -t desktop_entries < <(find /var/lib/snapd/desktop/applications -maxdepth 1 -name 'hiddentunes_*.desktop' -type f)
[[ "${#desktop_entries[@]}" == 1 ]]
desktop_entry="${desktop_entries[0]}"
desktop-file-validate "$desktop_entry"
cp "$desktop_entry" evidence/installed.desktop
python3 scripts/verify-payload.py 'original/opt/Hidden Tunes Desktop' '/snap/hiddentunes/current/opt/Hidden Tunes Desktop' > evidence/installed-payload-parity.json
sudo snap remove --purge hiddentunes
installed=no
if snap list hiddentunes >/dev/null 2>&1; then exit 1; fi
[[ ! -e /snap/hiddentunes/current ]]
[[ ! -e "$desktop_entry" ]]
python3 - <<'PY' > evidence/package-result.json
import json, os
print(json.dumps({'status':'PASS','commit':os.environ['GITHUB_SHA'],'pack':'PASS','applicationBytes':'UNCHANGED','install':'PASS','version':'1.0.1','uninstall':'PASS','applicationLaunch':'NOT RUN BY DESIGN','functionalTesting':'NOT RUN BY DESIGN','confinementRuntime':'PENDING','storeSubmission':'BLOCKED: publisher authentication, terms, sandbox review and remaining qualification'},indent=2))
PY
