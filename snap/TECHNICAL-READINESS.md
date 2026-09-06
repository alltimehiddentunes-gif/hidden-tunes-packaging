# Snap candidate — qualification in progress

This isolated project wraps the existing official DEB. It does not compile or modify application code. The original download and every original application file are compared by SHA-256 after packaging and installation. Build and registration checks run only on a disposable GitHub-hosted Ubuntu 24.04 runner; no owner machine installation or application launch is performed.

The candidate uses supported core24 with Canonical's GNOME extension, strict confinement and a plain launcher that retains Electron's internal sandbox. It is marked `grade: devel`. The expanded project and snap interface connections are retained as evidence, including any permissions introduced by the GNOME extension. No stable Store publication or complete runtime qualification is claimed.

The preliminary runtime library list follows the existing DEB's requirements plus NSS/NSPR and audio dependencies; Snapcraft's library lint and actual confinement checks must establish sufficiency. The package does not execute Debian post-install or removal scripts.

First CI run 34064701802 packed successfully and reported only lint warnings. Its parity check stopped because Snapcraft normalized the non-executable `resources/brand/icon.png` mode from 0664 to 0644. The verifier now explicitly records and permits only this observed removal of group-write permission; exact file inventory, all 75 file hashes and every other mode (especially sandbox 0755) remain required. No installer, executable or application data bytes were changed. GPU/vendor-library and unused-library lint warnings remain visible in the retained evidence.

Remaining publication gates:

Run 34065228906 installed version 1.0.1 and successfully removed it during cleanup, but failed the single-desktop-entry gate. Official Snapcraft `DesktopFile.write` renames the supplied entry to the app name without removing a differently named original. The integration part now uses `hiddentunes.desktop` before that processing, matching the app name and avoiding duplicate menu entries. The original released application is untouched. Source: https://github.com/canonical/snapcraft/blob/main/snapcraft/parts/desktop_file.py

The second run 34064967660 passed all 75 original file hashes and the explicit mode checks. Generic desktop validation rejected the unexpanded `${SNAP}` icon placeholder, which Canonical documents for Snap desktop entries. CI therefore validates snapd's actual installed desktop entry and checks its removal, rather than passing an unexpanded template to a generic validator. Reference: https://documentation.ubuntu.com/snapcraft/en/latest/how-to/crafting/configure-package-information/

- `browser-support` with `allow-sandbox: true` requires trusted-publisher review and does not auto-connect. No `--no-sandbox` or classic-confinement fallback is introduced.
- The password-manager-service interface is declared for the existing libsecret integration; connection and secure-store behavior under confinement remain unqualified.
- Assess GNOME extension permissions, launch under confinement and necessary integration changes. Existing Desktop acceptance is preserved; repeated playback/auth/navigation qualification is not part of this package check.
- Owner publisher login, name registration and acceptance of any new Snap Store declarations are pending. No credentials or agreement acceptance are automated here.
- Store artwork/listing and final `grade: stable` require readiness review; the existing upstream desktop icon is copied unchanged only for local menu integration.

Official references checked 7 September 2026:

- https://ubuntu.com/docs/snapcraft/9/how-to/integrations/craft-an-electron-app/
- https://ubuntu.com/docs/snapcraft/9/reference/snapcraft-yaml/
- https://ubuntu.com/docs/snapcraft/9/reference/extensions/gnome-extension/
- https://snapcraft.io/docs/reference/interfaces/browser-support-interface/

Repository qualification material may be AI-assisted. Application binaries and licensing remain unchanged.
