# AGENTS.md — golden-images

Operational guide for anyone (human or agent) changing this repo. The overview is in
[README.md](README.md), and the reason for the package design is in
[docs/adr/0001](docs/adr/0001-package-distribution.md). `CLAUDE.md` only points here.

## Layout

```
apks/                 melange specs (1 YAML = 1 APK): what Alpine v3.24 lacks (go-1.27) or ships late (.NET, from Microsoft)
images/<family>/      apko configs (1 YAML = 1 image): base, node, python, go, dotnet
catalog.json          source of truth: image name → config, repo, tags, test suite, packages (+ optional eol)
tests/<suite>.sh      smoke checks, sourced by scripts/test-image.sh (host-side docker run)
scripts/golden.sh     entrypoint: packages | build | full | image | test | list
scripts/build-packages.sh   melange, cache-aware, latest-only + prune + reindex
scripts/build-image.sh      apko build (+ docker load) or --publish
toolchain/Dockerfile  pinned melange + apko (+ bubblewrap) by version and sha256
dist/                 git-ignored: packages/ (the mounted APK cache), images/, sbom/
```

## Rules

- Builds run only through Docker (`scripts/golden.sh`). Do not install melange or apko on the host.
- Every image keeps `archs: [amd64, arm64]`.
- Pin everything: package versions plus a per-arch `expected-sha256`, the toolchain by
  sha256, Actions by commit SHA, Alpine by branch (`v3.24`).
- Never mix Alpine branches in one image. Node 22 uses v3.22 for the whole image because
  mixing branches breaks the musl/ICU/OpenSSL ABI.
- Runtime images: uid 65532, no shell, no package manager. `-dev` images: root, with a shell.
- Do not commit anything under `dist/`, and never commit `*.rsa` keys.

## Gotchas (verified while building)

- `cgr.dev/chainguard/{melange,apko}` and `ghcr.io/chainguard-dev/*` now **deny anonymous
  pulls**. That is why we build our own toolchain image from the GitHub release binaries.
- Locale: the images keep Alpine's default ICU data (English only). That is a deliberate
  choice to keep them small. If an app needs other locales (for example pt-BR formatting),
  add `icu-data-full` to its own image or to a new variant.
- Runtime images stay shell-free even though `nodejs`, `ca-certificates` and `icu-data-en`
  declare `depends: /bin/sh` (for install scripts that apko never runs). Without help, the
  resolver pulls `busybox-binsh` + `busybox` into node and dotnet runtimes. For every image
  with `run-as: "65532"`, the golden marker declares `provides: /bin/sh` on paper (no file),
  so no shell is installed. `noshell` in `test-image.sh` (all runtime suites) enforces it.
  Found and fixed on 2026-11-18: node 22/24/26 and dotnet aspnet/runtime 10 had shipped busybox.
- No image installs Alpine's `alpine-release`: the golden marker owns the OS identity instead
  (see below). Never ship an image with no `os-release`/`alpine-release` at all: Trivy still
  detects Alpine but emits **no purl** for any package, and Dependency-Track matches
  vulnerabilities by purl. Verified on 2026-11-18.
- Alpine Python is PEP 668 "externally managed". The `-dev` image sets
  `PIP_BREAK_SYSTEM_PACKAGES=1`, and the runtime image has no pip at all.
- `go` images set `GOTOOLCHAIN=local` so that a `go.mod` with a newer `toolchain` line fails
  loudly instead of silently downloading another toolchain.
- On macOS (zsh), do not rely on word-splitting of unquoted variables in ad-hoc shell. The
  scripts are bash.
- melange prints many `WARN ... (ppc64)` lines when packaging Go. They are harmless: they
  are Go sources for other architectures.
- `apko build` loads each arch as `<ref>-<arch>`. `build-image.sh` also adds the plain tag
  for the host arch.

## Golden marker package (do not remove)

`scripts/build-image.sh` generates and installs `staffops-golden-<name>` (version =
`GOLDEN_BUILD_VERSION`, or the current UTC timestamp) into every image, from `dist/meta`
signed with its own throwaway key. That is what links every derived image's SBOM to its
golden image. CI pins one version per job, so the image it tests and the one it
publishes carry the same marker.

The marker therefore does three jobs: traceability (`golden-image.json`), the OS identity
(below) and, on runtime images, the `/bin/sh` provider (see Gotchas).

### OS identity (also in the marker)

The marker writes `/usr/lib/os-release` (with `/etc/os-release` linked to it) and
`/etc/alpine-release`, replacing Alpine's `alpine-release` package and its ~60 `alpine-keys`
files. The branding is ours; the two scanner fields stay Alpine's:

| Field | Value | Why |
|---|---|---|
| `NAME`, `PRETTY_NAME`, `HOME_URL` | StaffOps Golden Image ... | branding |
| `IMAGE_ID`, `IMAGE_VERSION`, `BUILD_ID` | image name, build version, commit | standard os-release fields for image builds |
| `ID` | `alpine` | **do not change** |
| `VERSION_ID` + `/etc/alpine-release` | Alpine point release (`3.24.4`), read from the branch APKINDEX at build time | **do not change** |

Trivy and Grype build the purl (`pkg:apk/alpine/<pkg>@<ver>?distro=<VERSION_ID>`) from `ID` and
`VERSION_ID`, then look CVEs up in Alpine's secdb for that release. Measured on 2026-11-18:
`VERSION_ID=20261118...` makes both scanners report "alpine 20261118..." (no data, so zero
CVEs in silence); `ID=staffops` (even with `ID_LIKE=alpine`) drops every purl. With the layout
above, `python-3.14-dev` gave the same package purls and the same 33 Grype findings as with
`alpine-release`. `tests` checks the identity on every image (`identity` in `test-image.sh`).
The Alpine point release is part of the content fingerprint, since the marker is excluded.

## Why .NET comes from Microsoft, not Alpine

Measured on 2026-11-16 for .NET 10: Alpine 3.24-stable usually packages a runtime patch
within 2 days of Microsoft (max 7). However, it **skipped** security releases 10.0.5 and
10.0.11, leaving 30 days on a runtime with known CVEs. Its SDK is also stuck on an older
feature band (10.0.3xx while Microsoft is on 10.0.4xx). `apks/msft-*` repackage
Microsoft's official linux-musl tarballs (sha512 from `releases.json`) into
`/usr/share/dotnet`. The three packages are self-contained and mutually exclusive: each
image installs exactly one of them.

### .NET CVE detection (do not remove)

Our apk names (`msft-*`) are unknown to vulnerability databases, and Alpine's secdb is
sparse for .NET anyway. Each `msft-*` package writes `/usr/share/dotnet/staffops-runtime.deps.json`,
which declares the bundled shared frameworks as the official NuGet runtime packs
(`Microsoft.NETCore.App.Runtime.linux-musl-<arch>@<ver>`), with versions read from the tarball.
Trivy skips files owned by OS packages, so each dotnet image re-exposes the file via an
apko `hardlink` at `/usr/share/dotnet-sbom/runtime.deps.json`. Result: `trivy image` (and
Dependency-Track) match .NET runtime CVEs from GitHub advisories, on the golden image and on
every image built FROM it. Verified: declaring 10.0.1 gives 35 CVEs, 10.0.15 gives 0.

## Per-image builds and publish skip

- `scripts/plan.sh <base> [head]` maps changed files to images (see README). It replaces
  the reference repo's hand-maintained `triggers.yml`, using `catalog.json` `packages`/`test`.
  When adding a file type that influences an image, teach `plan.sh` about it.
- `build-image.sh --publish` compares the content fingerprint with the annotation on the
  published image and exits with `published=false` when they are equal. Sign/attest steps
  run only when `published == 'true'`. The fingerprint excludes the marker (its version is
  the build time) and depends on the arch set (`dist/images/<name>.<archs>.fingerprint`).

## Bumping versions

- Alpine package (Node, Python, Go 1.26, .NET): the weekly CI rebuild picks up patch
  releases automatically. To change a minor, edit the `pkg=~X` constraint in the image YAML.
- melange package: bump `package.version`, reset `epoch: 0`, and run
  `scripts/update-checksums.sh apks/<pkg>.yaml` (Renovate does both). To do it by hand, update both
  `expected-sha256`/`expected-sha512` values (for GitHub releases, `gh release view <tag> -R <repo> --json assets`
  shows the digests; for Go, use `https://go.dev/dl/?mode=json`). Then run
  `scripts/golden.sh full <image>`.
- When Alpine stable ships Go 1.27, delete `apks/go-1.27.yaml`, switch the image to
  `go=~1.27`, and remove `packages` from its catalog entry.
- Toolchain: update the version and sha256 args in `toolchain/Dockerfile`. The image tag is
  derived from the file hash, so it rebuilds by itself.
