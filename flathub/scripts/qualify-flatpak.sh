#!/bin/bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true && ${HT_RUNNER_ENVIRONMENT:-} == github-hosted && ${RUNNER_OS:-} == Linux ]] || { echo 'Refusing non-hosted execution' >&2; exit 1; }
[[ ${GITHUB_REPOSITORY:-} == alltimehiddentunes-gif/hidden-tunes-packaging ]] || { echo 'Unexpected qualification repository' >&2; exit 1; }
[[ $(uname -m) == x86_64 && $(id -u) != 0 && ${USER:-} != Wills ]] || { echo 'Unexpected runner account or architecture' >&2; exit 1; }
[[ -n ${RUNNER_TEMP:-} && -n ${GITHUB_WORKSPACE:-} ]] || exit 1
candidate=$(realpath "$(dirname "$0")/..")
[[ $candidate == "$(realpath "$GITHUB_WORKSPACE")/flathub" ]] || { echo 'Candidate is not in this job checkout' >&2; exit 1; }
runner_temp=$(realpath "$RUNNER_TEMP")
work="$runner_temp/hiddentunes-flatpak-verification"
[[ $(dirname "$work") == "$runner_temp" && ! -e $work ]] || { echo 'Temporary workspace is not a new direct runner child' >&2; exit 1; }
mkdir "$work"
export XDG_DATA_HOME="$work/data" XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache"
export FLATPAK_USER_DIR="$XDG_DATA_HOME/flatpak"
mkdir "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
evidence="$GITHUB_WORKSPACE/ci-results/flathub"
mkdir -p "$evidence"
export HT_FLATPAK_EVIDENCE="$evidence"
export HT_FLATPAK_BUILD='NOT RUN' HT_FLATPAK_INSTALL='NOT RUN' HT_FLATPAK_IDENTITY='NOT RUN' HT_FLATPAK_LINKER='NOT RUN' HT_FLATPAK_UNINSTALL='NOT RUN'
export HT_FLATPAK_METADATA_LINT='NOT RUN' HT_FLATPAK_MANIFEST_LINT='NOT RUN'
app_id=com.hiddentunes.HiddenTunes
installed=false
finish() {
  exit_code=$?
  trap - EXIT
  if [[ $installed == true ]]; then
    flatpak uninstall --user -y "$app_id" >>"$evidence/cleanup.log" 2>&1 || true
  fi
  export HT_FLATPAK_EXIT_CODE="$exit_code"
  python3 - <<'PY'
import datetime, json, os
from pathlib import Path
keys = ['BUILD','INSTALL','IDENTITY','LINKER','UNINSTALL','METADATA_LINT','MANIFEST_LINT']
result = {k.lower(): os.environ['HT_FLATPAK_' + k] for k in keys}
for key in result:
    if result[key] == 'RUNNING':
        result[key] = 'FAIL'
result.update(repositoryCommit=os.environ['GITHUB_SHA'], completedUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(), exitCode=int(os.environ['HT_FLATPAK_EXIT_CODE']), applicationLaunch='NOT RUN BY DESIGN', functionalRequalification='NOT RUN BY DESIGN', flathubSubmission='BLOCKED: owner metadata and independent human submission gates remain')
result['technicalPackageChecks'] = 'PASS' if all(result[k] == 'PASS' for k in ('build','install','identity','linker','uninstall')) and result['exitCode'] == 0 else 'FAIL'
(Path(os.environ['HT_FLATPAK_EVIDENCE']) / 'package-result.json').write_text(json.dumps(result, indent=2) + '\n')
PY
  exit "$exit_code"
}
trap finish EXIT

flatpak --version | tee "$evidence/flatpak-version.log"
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub org.flatpak.Builder org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08 org.electronjs.Electron2.BaseApp//25.08
flatpak list --user --columns=ref,origin,active | tee "$evidence/tool-runtime-refs.log"
flatpak remote-ls --user flathub --columns=ref | grep -E 'org.freedesktop.(Platform|Sdk)/x86_64/|org.electronjs.Electron2.BaseApp/x86_64/' | tee "$evidence/available-runtime-refs.log"

# Validation really runs. Its result stays separate from package compatibility;
# missing owner-approved metadata must never be reported as a Flathub PASS.
set +e
flatpak run --command=flatpak-builder-lint org.flatpak.Builder appstream "$candidate/com.hiddentunes.HiddenTunes.metainfo.xml" 2>&1 | tee "$evidence/metainfo-lint.log"
metadata_exit=${PIPESTATUS[0]}
flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest "$candidate/com.hiddentunes.HiddenTunes.yml" 2>&1 | tee "$evidence/manifest-lint.log"
manifest_exit=${PIPESTATUS[0]}
set -e
if [[ $metadata_exit == 0 ]]; then export HT_FLATPAK_METADATA_LINT=PASS; else export HT_FLATPAK_METADATA_LINT="FAIL ($metadata_exit)"; fi
if [[ $manifest_exit == 0 ]]; then export HT_FLATPAK_MANIFEST_LINT=PASS; else export HT_FLATPAK_MANIFEST_LINT="FAIL ($manifest_exit)"; fi

desktop-file-validate "$candidate/com.hiddentunes.HiddenTunes.desktop"
# The official default wrapper hardcodes HOME/.local/share/flatpak. Invoke its
# same builder directly, preserving the host Flatpak binding and this job's
# isolated installation rather than letting that wrapper replace the directory.
flatpak_binary=$(command -v flatpak)
export HT_FLATPAK_BUILD=RUNNING
flatpak run --command=flatpak-builder --env=FLATPAK_BINARY="$flatpak_binary" --env=FLATPAK_USER_DIR="$FLATPAK_USER_DIR" --filesystem="$FLATPAK_USER_DIR" org.flatpak.Builder --user --disable-rofiles-fuse --repo="$work/repo" "$work/build" "$candidate/com.hiddentunes.HiddenTunes.yml" 2>&1 | tee "$evidence/build.log"
export HT_FLATPAK_BUILD=PASS
# Only this newly created local CI repository is unsigned; the upstream Flathub
# remote above retains its standard signature verification.
flatpak remote-add --user --no-gpg-verify hiddentunes-ci "file://$work/repo"
export HT_FLATPAK_INSTALL=RUNNING
flatpak install --user -y hiddentunes-ci "$app_id" 2>&1 | tee "$evidence/install.log"
installed=true
export HT_FLATPAK_INSTALL=PASS
flatpak info --user --show-metadata "$app_id" | tee "$evidence/installed-metadata.log"
location=$(flatpak info --user --show-location "$app_id")
export HT_FLATPAK_IDENTITY=RUNNING
python3 "$candidate/scripts/verify_installed.py" "$location" | tee "$evidence/installed-identity.log"
export HT_FLATPAK_IDENTITY=PASS

# Ask only the runtime's ELF loader to resolve the original executable's
# dependencies. The application entry point, Electron, and renderer never run.
interpreter=$(readelf -l "$location/files/extra/hidden-tunes/hidden-tunes-desktop" | sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p')
[[ $interpreter == /lib64/ld-linux-x86-64.so.2 ]]
export HT_FLATPAK_LINKER=RUNNING
flatpak run --user --unshare=network --nosocket=x11 --nosocket=pulseaudio --command="$interpreter" "$app_id" --list /app/extra/hidden-tunes/hidden-tunes-desktop 2>&1 | tee "$evidence/runtime-linker.log"
if grep -q 'not found' "$evidence/runtime-linker.log"; then echo 'Runtime dependency missing' >&2; exit 1; fi
export HT_FLATPAK_LINKER=PASS
export HT_FLATPAK_UNINSTALL=RUNNING
flatpak uninstall --user -y "$app_id" 2>&1 | tee "$evidence/uninstall.log"
installed=false
if flatpak info --user "$app_id" >/dev/null 2>&1; then echo 'Application ref remains after uninstall' >&2; exit 1; fi
if [[ -e "$XDG_DATA_HOME/flatpak/exports/share/applications/$app_id.desktop" ]]; then echo 'Exported launcher remains after uninstall' >&2; exit 1; fi
export HT_FLATPAK_UNINSTALL=PASS
