#!/usr/bin/env bash
set -Eeuo pipefail

# This script must never administer an owner's actual Arch installation.
[[ ${GITHUB_ACTIONS:-} == true && -f /.dockerenv && $(id -u) == 0 ]]
[[ ${HT_RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ ${GITHUB_REPOSITORY:-} == alltimehiddentunes-gif/hidden-tunes-packaging ]]
source /etc/os-release
[[ $ID == arch ]]
cd "$(dirname "$0")"
mkdir -p evidence
exec > >(tee evidence/qualification.log) 2>&1
date -u '+%Y-%m-%dT%H:%M:%SZ' > evidence/started-at.txt
pacman -Syu --noconfirm --needed sudo namcap python pax-utils desktop-file-utils
pacman -Q > evidence/arch-package-versions.txt
useradd --create-home --user-group builder
printf 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/hiddentunes-ci-builder
chmod 0440 /etc/sudoers.d/hiddentunes-ci-builder
chown -R builder:builder "$PWD"
runuser -u builder -- makepkg --verifysource --noconfirm
python audit_deb.py Hidden-Tunes-Desktop-1.0.1-amd64.deb evidence/DEB-PAYLOAD-AUDIT.json > evidence/elf-audit-summary.json
runuser -u builder -- makepkg --printsrcinfo > evidence/SRCINFO.generated
runuser -u builder -- makepkg --syncdeps --noconfirm --cleanbuild --clean --log --nosign
mapfile -t packages < <(runuser -u builder -- makepkg --packagelist)
[[ ${#packages[@]} == 1 && -f ${packages[0]} ]]
sha256sum "${packages[0]}" > evidence/ARCH-PACKAGE-SHA256.txt
namcap PKGBUILD > evidence/namcap-PKGBUILD.txt 2>&1
namcap "${packages[0]}" > evidence/namcap-package.txt 2>&1
if pacman -Q hiddentunes >/dev/null 2>&1; then
  printf '%s\n' 'Refusing to disturb a pre-existing Hidden Tunes installation.' >&2
  exit 1
fi
cleanup() {
  if pacman -Q hiddentunes >/dev/null 2>&1; then
    pacman -Rns --noconfirm hiddentunes
  fi
}
trap cleanup EXIT
pacman -U --noconfirm "${packages[0]}"
pacman -Q hiddentunes | tee evidence/installed-version.txt
grep -qx 'hiddentunes 1.0.1-1' evidence/installed-version.txt
pacman -Qk hiddentunes | tee evidence/pacman-file-check.txt
pacman -Ql hiddentunes > evidence/installed-files.txt
desktop-file-validate /usr/share/applications/hidden-tunes-desktop.desktop
python verify_installed.py installed evidence/DEB-PAYLOAD-AUDIT.json evidence/installed-compatibility.json
pacman -Rns --noconfirm hiddentunes
! pacman -Q hiddentunes >/dev/null 2>&1
python verify_installed.py uninstalled evidence/DEB-PAYLOAD-AUDIT.json evidence/uninstall-compatibility.json
trap - EXIT
# Namcap can exit zero while reporting errors; preserve warnings and fail errors.
if grep -E '(^|[[:space:]])E:' evidence/namcap-PKGBUILD.txt evidence/namcap-package.txt; then
  printf '%s\n' 'Namcap errors remain; package is not qualified.' >&2
  exit 1
fi
printf '%s\n' 'PASS: source checksum, makepkg, generated SRCINFO, namcap error gate, ELF dependencies, byte identity, package install/version/file checks and uninstall.' > evidence/RESULT.txt
printf '%s\n' 'No application launch or functional playback/authentication testing was performed.' >> evidence/RESULT.txt
cat evidence/RESULT.txt
