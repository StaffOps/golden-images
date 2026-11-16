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
- Every image installs `alpine-release` (`/etc/os-release`). Without it, Trivy still detects
  Alpine but emits **no purl** for any package, and Dependency-Track matches vulnerabilities by purl.
  Do not remove it.
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

## Why .NET comes from Microsoft, not Alpine

Measured on 2026-11-16 for .NET 10: Alpine 3.24-stable usually packages a runtime patch
within 2 days of Microsoft (max 7). However, it **skipped** security releases 10.0.5 and
10.0.11, leaving 30 days on a runtime with known CVEs. Its SDK is also stuck on an older
feature band (10.0.3xx while Microsoft is on 10.0.4xx). `apks/msft-*` repackage
Microsoft's official linux-musl tarballs (sha512 from `releases.json`) into
`/usr/share/dotnet`. The three packages are self-contained and mutually exclusive: each
image installs exactly one of them.

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
