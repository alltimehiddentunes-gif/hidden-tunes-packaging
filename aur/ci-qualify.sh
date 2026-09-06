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
# The official container omits usr/share/doc/* at installation. Preserve its
# config and override only this package's documentation in a test-only copy.
cp /etc/pacman.conf evidence/pacman-original.conf
cp /etc/pacman.conf evidence/pacman-test.conf
printf '\n[options]\nNoExtract = !usr/share/doc/hidden-tunes-desktop/*\n' >> evidence/pacman-test.conf
pacman-conf --config "$PWD/evidence/pacman-original.conf" NoExtract > evidence/noextract-original.txt
pacman-conf --config "$PWD/evidence/pacman-test.conf" NoExtract > evidence/noextract-test.txt
if pacman -Q hiddentunes >/dev/null 2>&1; then
  printf '%s\n' 'Refusing to disturb a pre-existing Hidden Tunes installation.' >&2
  exit 1
fi
cleanup() {
  if pacman -Q hiddentunes >/dev/null 2>&1; then
    pacman --config "$PWD/evidence/pacman-test.conf" -Rns --noconfirm hiddentunes
  fi
}
trap cleanup EXIT
pacman --config "$PWD/evidence/pacman-test.conf" -U --noconfirm "${packages[0]}"
pacman -Q hiddentunes | tee evidence/installed-version.txt
grep -qx 'hiddentunes 1.0.1-1' evidence/installed-version.txt
pacman --config "$PWD/evidence/pacman-test.conf" -Qk hiddentunes | tee evidence/pacman-file-check.txt
pacman -Ql hiddentunes > evidence/installed-files.txt
desktop-file-validate /usr/share/applications/hidden-tunes-desktop.desktop
python verify_installed.py installed evidence/DEB-PAYLOAD-AUDIT.json evidence/installed-compatibility.json
pacman --config "$PWD/evidence/pacman-test.conf" -Rns --noconfirm hiddentunes
! pacman -Q hiddentunes >/dev/null 2>&1
python verify_installed.py uninstalled evidence/DEB-PAYLOAD-AUDIT.json evidence/uninstall-compatibility.json
trap - EXIT
# Retain every raw diagnostic. Only the documented original Electron /opt
# placement diagnostic is reviewed; any other namcap error fails qualification.
python check_namcap.py evidence
printf '%s\n' 'PASS with documented opt/ placement exception: source checksum, makepkg, generated SRCINFO, reviewed namcap diagnostics, ELF dependencies, byte identity, package install/version/file checks and uninstall.' > evidence/RESULT.txt
printf '%s\n' 'No application launch or functional playback/authentication testing was performed.' >> evidence/RESULT.txt
cat evidence/RESULT.txt
