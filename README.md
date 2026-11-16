# golden-images

Minimal, multi-arch (amd64 + arm64) and signed base images for the StaffOps and
PersonalAIgent projects. Images are built declaratively with [apko](https://github.com/chainguard-dev/apko)
on top of Alpine; the few things Alpine does not ship are packaged with
[melange](https://github.com/chainguard-dev/melange) in this same repo.

```
apks/*.yaml ──melange──▶ dist/packages/   (mounted cache, latest version only)
                               │
images/**/*.yaml ──apko──◀─────┘  + Alpine v3.24 ──▶ ghcr.io/staffops/<image>  (SBOM + cosign keyless)
```

## Images

| Image | Tags | Notes |
|---|---|---|
| `ghcr.io/staffops/static` | `latest` | ca-certs + tzdata, no shell, uid 65532. For Go (`CGO_ENABLED=0`) binaries |
| `ghcr.io/staffops/node` | `22` `24` `26` `lts` `latest` + `-dev` variants | runtime: `node` only, no npm. `-dev`: npm, pnpm, yarn, node-gyp toolchain |
| `ghcr.io/staffops/python` | `3.14` `latest` + `-dev` variants | runtime: no pip. `-dev`: pip, uv, C toolchain |
| `ghcr.io/staffops/go` | `1.27` `latest`, `1.26` | build images; ship binaries on `static` |
| `ghcr.io/staffops/dotnet-sdk` | `10` `latest` | .NET SDK (official Microsoft musl build) |
| `ghcr.io/staffops/dotnet-aspnet` | `10` `latest` | ASP.NET Core runtime, port 8080 (official Microsoft musl build) |
| `ghcr.io/staffops/dotnet-runtime` | `10` `latest` | .NET runtime (official Microsoft musl build) |

Every published tag also gets a dated immutable twin (`24-20261116`). In production, pin by
digest. Conventions:

- **Runtime images** run as `nonroot` (uid/gid 65532), have **no shell** and no package
  manager, and use `/app` as the working directory.
- **`-dev` / SDK / Go images** run as root and include bash, git, curl and a C toolchain.
  They are meant for build stages and CI jobs.

### Typical multi-stage use

```dockerfile
FROM ghcr.io/staffops/go:1.27 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/app ./cmd/app

FROM ghcr.io/staffops/static
COPY --from=build /out/app /app/app
ENTRYPOINT ["/app/app"]
```

```dockerfile
FROM ghcr.io/staffops/python:3.14-dev AS build
WORKDIR /app
COPY requirements.txt .
RUN python3 -m venv /venv && /venv/bin/pip install -r requirements.txt

FROM ghcr.io/staffops/python:3.14
COPY --from=build /venv /venv
COPY app/ /app/app/
ENV PATH=/venv/bin:$PATH
ENTRYPOINT ["/venv/bin/python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0"]
```

### Traceability: every derived image depends on its golden image

Each image installs a small generated APK, `staffops-golden-<name>` (for example
`staffops-golden-node-24`), whose version is the build timestamp (`20261116.181500`). The
package writes `/etc/staffops/golden-image.json` (image, tags, version, commit).

Because it is a real entry in the apk database, any SBOM generated for an image built
`FROM` a golden image (Trivy, Syft, Docker Scout...) lists it as a component, without
the app team doing anything. In Dependency-Track this answers:

- *which projects run on `node-24`?* Search for the component `staffops-golden-node-24`.
- *who is still on an old build?* Filter that component by version.

The same build is also stamped on the image itself as the OCI annotations
`org.opencontainers.image.version`, `org.opencontainers.image.revision` and
`dev.staffops.golden-image`. Its SPDX SBOM is attached as a signed cosign attestation:

```bash
cosign verify-attestation --type spdxjson ghcr.io/staffops/node:24 \
  --certificate-identity-regexp '^https://github.com/StaffOps/golden-images/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

### Verify a signature

Signatures and SBOM attestations use the Sigstore bundle format (OCI referrers), so
verification needs **cosign v3+**: cosign v2 reports "no signatures found". The same applies to admission
policies (for example Kyverno `verifyImages`), which must support the bundle format.

```bash
cosign verify ghcr.io/staffops/node:24 \
  --certificate-identity-regexp '^https://github.com/StaffOps/golden-images/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Build locally

You only need Docker. melange and apko run inside a pinned toolchain container
(`toolchain/Dockerfile`), which is built automatically on first use.

`scripts/golden.sh` covers the four flows. `<target>` is a family (`node`, `python`, `go`,
`dotnet`, `base`), an image name from `catalog.json`, or `all`.

| # | Flow | Command |
|---|---|---|
| 1 | Packages only | `scripts/golden.sh packages [go-1.27]` |
| 2 | Chosen packages + image(s) | `scripts/golden.sh build go-1.27 --packages go-1.27` |
| 3 | Full: every package the target needs + images + tests | `scripts/golden.sh full go` |
| 4 | Image(s) only, from the existing package cache | `scripts/golden.sh image node` |

```bash
scripts/golden.sh list                         # images, families, packages each one needs
scripts/golden.sh full dotnet                  # whole .NET family, host arch, with tests
scripts/golden.sh full all --arch x86_64,aarch64 --no-test
scripts/golden.sh packages --force go-1.27     # rebuild a package even if cached
scripts/golden.sh test node-24                 # tests only, on already-loaded images
```

Images are loaded into Docker as `ghcr.io/staffops/<repo>:<tag>`. Non-host archs use the
`-<arch>` suffix and run under QEMU emulation.

### The package cache

`dist/packages/` is the APK repository. It is just a directory, mounted into the build
container and read by apko as `@local`. It is git-ignored, and it holds:

- the latest build of each package for each arch (`x86_64/`, `aarch64/`) plus a signed `APKINDEX`;
- the melange signing key, which is generated on first use. Packages never leave the build.

A package is rebuilt only when its `name-version-r<epoch>.apk` is missing. Older versions
and packages whose spec was removed are pruned automatically. Delete the directory to start
from scratch. See [ADR-0001](docs/adr/0001-package-distribution.md) for why there is no APK
registry.

### Test the publish path locally

```bash
docker run -d --name registry -p 5000:5000 registry:2
REGISTRY=localhost:5000 TC_DOCKER_ARGS="--network container:registry" \
  scripts/build-image.sh static --arch amd64,arm64 --publish
docker rm -f registry
```

## CI (`.github/workflows/build.yml`)

1. **packages**: restores `dist/packages` from the Actions cache, builds what is missing
   for both archs (arm64 via QEMU), and hands the directory to the image jobs as an artifact.
2. **image** (one job per image): apko build → smoke tests on amd64 → on `main` only,
   publish the multi-arch index with SBOMs → cosign keyless sign by digest → Trivy report.

It runs on PRs (build + test, no publish), on push to `main`, weekly on Monday (to pick up
Alpine security fixes) and manually with a `target`.

## Automatic updates

| What | How it updates |
|---|---|
| Alpine packages (Node, Python, Go 1.26, libs) | weekly rebuild picks up patch releases, no PR |
| .NET 10 runtime/ASP.NET/SDK, Go 1.27 (our melange packages) | Renovate PR → `checksums` workflow recomputes hashes on the branch → CI builds + tests |
| melange / apko toolchain | Renovate PR (+ checksums from the signed release `checksums.txt`) |
| Alpine stable branch (`v3.24` → next) | one grouped Renovate PR touching every image (node-22 excluded) |
| GitHub Actions | weekly grouped Renovate PR, pinned by SHA |

Every PR body says why (release notes, security context). Nothing is automerged.
Requires the Renovate GitHub App on the repo. `scripts/update-checksums.sh` does the
checksum step locally too.

## Add something

- **A package**: add `apks/<name>.yaml` (pin the version and the `expected-sha256` for each
  arch), list it under `packages` of the images that use it in `catalog.json`, then run
  `scripts/golden.sh full <image>`.
- **An image**: add `images/<family>/<name>.yaml` (keep `archs: [amd64, arm64]`), add an
  entry to `catalog.json` and, if needed, a `tests/<suite>.sh`. The CI matrix picks it up
  automatically.

See [AGENTS.md](AGENTS.md) for conventions and gotchas, and [docs/inventory.md](docs/inventory.md)
for which project uses what.

## License

The build definitions in this repo (configs, specs, scripts, workflows) are licensed under
[Apache-2.0](LICENSE). The published images contain third-party software (Alpine, Node.js,
Python, Go, .NET, ...) under their own licenses. Each image ships an SPDX SBOM that
lists every package with its license; see [NOTICE](NOTICE).

StaffOps is not affiliated with or endorsed by the upstream projects. Names such as .NET,
Node.js, Python and Go are used only to describe the software that the images contain.
