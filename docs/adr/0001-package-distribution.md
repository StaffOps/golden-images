# ADR-0001: Custom packages live in this repo, served from a mounted cache directory

- Status: accepted (2026-11-18)
- Date: 2026-11-16
- Deciders: StaffOps platform

## Context

The golden images are built with apko from Alpine packages. A few things are not in the
Alpine stable branch we pin (v3.24), so we build them as APKs with melange. Today these are
`go-1.27` (only in Alpine edge) and the .NET 10 runtime, ASP.NET Core and SDK, repackaged from
Microsoft because Alpine stable skips and delays security releases (see AGENTS.md).

The reference design (BDC `custom-packages` and `custom-images`) uses two repos. Packages
are published to an external APK repository (an S3 bucket) with a long-lived signing key.
A cross-repo pipeline trigger rebuilds the images. It works, but it costs:

- a bucket, a domain and a long-lived melange key in a secret store;
- a hand-maintained package→image trigger map (`triggers.yml`), where a forgotten entry
  silently skips a rebuild;
- two pipelines to follow when debugging.

StaffOps is public, small, and has only two consumers of these packages: the images in this
repo. Nothing outside installs our APKs with `apk add`.

## Decision

1. **One repo.** Melange specs (`apks/`) and apko image configs (`images/`) live together.
   `catalog.json` declares which packages each image needs, which replaces the trigger map.
2. **No APK registry.** The package repository is a plain directory, `dist/packages/`.
   It is mounted into the build container, and apko reads it as `@local /work/dist/packages`.
3. **Latest version only.** `scripts/build-packages.sh` rebuilds a package only when its
   `name-version-r<epoch>.apk` is missing. After the build it deletes older versions and
   packages whose spec was removed, then re-indexes. Nothing keeps a history.
4. **Ephemeral signing key.** The melange key is generated inside the cache directory the
   first time and lives as long as the cache does. Packages never leave the build, so the
   key does not need to be stable or secret-managed. If the key is lost, every package is
   simply rebuilt.
5. **The CI cache is the same directory.** `actions/cache` restores `dist/packages` with a
   key derived from `apks/**` and the toolchain. A prefix `restore-keys` means a change
   to one spec rebuilds only that package.
6. **Images are what we publish.** Multi-arch images go to `ghcr.io/staffops`, with an
   SBOM per arch. They are signed keyless with cosign (GitHub OIDC), so no signing key
   exists anywhere.

## Options considered

| Option | Why not (now) |
|---|---|
| External APK repo (S3/R2 + domain, as in BDC) | Infra, a long-lived key and cross-repo triggers, for packages that nobody outside this repo consumes |
| Serve the APK repo from GitHub Pages / Releases | Still an external publish step plus key management. It is the easiest upgrade path if we ever need it (see below) |
| Commit `.apk` files to git | Binary blobs stay in git history forever, even after "latest only" pruning. The repo grows with each bump |
| Packages as OCI artifacts in GHCR | apko cannot consume them directly; it adds a pull/unpack step |

## Consequences

- Positive: zero infra for packages and no secrets. One pipeline, and the whole path can be
  reproduced locally with `scripts/golden.sh full <family>`.
- Positive: a cold cache costs about 2 minutes (fetch + repackage of 4 packages × 2 archs, dominated by the ~200 MB SDK);
  a warm cache costs under a second.
- Negative: our APKs cannot be installed with `apk add` outside the images. An app that
  needs one of them must `FROM` a golden image that includes it.
- Negative: a package that compiles from source (for example a future Python 3.15 build)
  would make cold-cache builds slow. The CI cache mitigates this, and it is the main
  trigger for reopening this decision.

## Reopen when

- Something outside this repo needs `apk add <our-package>`. In that case, publish
  `dist/packages` to GitHub Pages and move the key to a secret. That is a single workflow
  step, and the specs do not change.
- Cold-cache package builds go over ~15 minutes.
