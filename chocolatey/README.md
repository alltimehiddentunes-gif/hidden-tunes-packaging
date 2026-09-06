# Hidden Tunes Chocolatey qualification

This directory contains the proposed `hidden-tunes` Chocolatey package for Desktop 1.0.1 and its isolated packaging check. It is not a Chocolatey Community Repository publication.

The package downloads the existing official Windows x64 installer and enforces SHA-256 `3b8f17048e441ee9cfd9e59b2cab529a3372d3bee61d888796b1ba67be6df40b`. Application binaries are not stored in this repository or in the generated package. Hidden Tunes remains governed by its [Desktop EULA](https://hiddentunes.com/legal/desktop-eula).

The workflow uses Chocolatey already provided by the official GitHub-hosted Windows 2025 image. It packs the local definition, installs only that local package with the existing `/S /currentuser` installer arguments, checks the installed version and application hash, and uninstalls through Chocolatey. It does not launch Hidden Tunes or perform playback, account, navigation, or other functional testing. It refuses local computers, self-hosted runners, the owner's Windows account, SYSTEM, and pre-existing Hidden Tunes installations. Only narrow JSON evidence and command logs are uploaded.

`--yes` authorizes the already reviewed local package scripts in the disposable CI account. This workflow does not install third-party dependency packages, configure Community Repository authentication, accept contribution terms, or submit a package.

Public submission remains gated on private publishing authentication, review and authorization of applicable Chocolatey contribution terms, and the repository's own validation/moderation. A passing qualification workflow does not mean Chocolatey has accepted or published the package.

For the next Desktop release, update the package version, immutable installer URL and SHA-256, the registration-version check, and `scripts/release-lock.json` with independently verified application identity and script hashes. Do not overwrite the 1.0.1 download URL. Run qualification for the revised package before submission.
