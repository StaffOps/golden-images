# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

The repository itself is not versioned: there are no tags or GitHub Releases. Each image is
published to `ghcr.io/staffops/<image>` from `main`, with its own tags (see the README) and a
content fingerprint, and the weekly rebuild republishes only images whose content changed.
This file records changes to the images and the build.

## [Unreleased]

### Added

- Golden images built with melange and apko on Alpine v3.24, multi-arch (amd64 + arm64):
  `static`, `node` (22, 24, 26 and `-dev`), `python` (3.14 and `-dev`), `go` (1.26, 1.27),
  `dotnet-sdk`, `dotnet-aspnet` and `dotnet-runtime` (10). Signed with cosign keyless, with an SPDX
  SBOM attestation and a Trivy report.
- .NET 10 repackaged from Microsoft's official musl builds, with a `runtime.deps.json` so Trivy and
  Dependency-Track detect .NET runtime CVEs; Renovate updates for packages, toolchain and Actions.
- Per-image builds: `scripts/plan.sh` maps a diff to the affected images, and publishing is skipped
  when an image's content fingerprint is unchanged.
- StaffOps OS identity in a golden marker package (`staffops-golden-<name>`), keeping `ID=alpine`
  and the Alpine `VERSION_ID` so scanners still emit package purls.
- Backstage `catalog-info.yaml`, Argo Workflows selector, technology tags and TechDocs.

### Changed

- CI publishes the exact image it tested (OCI layout pushed with crane, no rebuild) and scans it on
  both architectures.
- `main` requires the `ci-ok` check before merge; host prerequisites are documented; ADR-0001
  (package distribution) is accepted.

### Fixed

- Runtime images are shell-free again: node 22/24/26 and dotnet aspnet/runtime 10 had shipped
  busybox through `/bin/sh` dependencies.
- The package cache is keyed on spec content; the .NET package epoch was bumped.
- QEMU is enabled in image jobs so the arm64 marker package builds.

[Unreleased]: https://github.com/StaffOps/golden-images/commits/main
