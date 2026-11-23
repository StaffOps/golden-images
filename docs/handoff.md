# Handoff

Last updated: 2026-11-23 · Backstage docs-standard rollout · branch `main`

## State

golden-images builds minimal, multi-arch, signed base images with melange and apko and publishes
them to `ghcr.io/staffops/<image>`: `static`, `node`, `python`, `go`, `dotnet-sdk`, `dotnet-aspnet`
and `dotnet-runtime` (see the [README](https://github.com/StaffOps/golden-images/blob/main/README.md)
and [AGENTS.md](https://github.com/StaffOps/golden-images/blob/main/AGENTS.md)). The repository has no
tags or releases; each image is versioned by its own tags and content fingerprint. `main` is
protected and requires the `ci-ok` check. The latest `build` runs succeed, including the weekly
scheduled rebuild on 2026-11-23. The last code change landed on 2026-11-18 (publish the tested image,
shell-free runtimes); later commits only touch the Backstage catalog. No work is in progress.

## Done

- Backstage catalog, Argo Workflows selector, tags and TechDocs (#6-#9, [`a2301a8`](https://github.com/StaffOps/golden-images/commit/a2301a8))
- `ci-ok` required before merge, host prerequisites documented, ADR-0001 accepted (#5, [`572e995`](https://github.com/StaffOps/golden-images/commit/572e995))
- CI publishes the exact tested image and scans both archs (#4, [`878ffa3`](https://github.com/StaffOps/golden-images/commit/878ffa3))
- StaffOps OS identity and shell-free runtime images (#3, [`afb1be7`](https://github.com/StaffOps/golden-images/commit/afb1be7))
- Each image built and published individually (#2, [`3c07b83`](https://github.com/StaffOps/golden-images/commit/3c07b83))
- .NET 10 from Microsoft's musl builds, with CVE detection, and Renovate (#1, [`b0f87e1`](https://github.com/StaffOps/golden-images/commit/b0f87e1), [`dc1a606`](https://github.com/StaffOps/golden-images/commit/dc1a606))

## In progress

- Nothing. No open pull requests or issues. Renovate opens PRs for packages, toolchain, the Alpine
  branch and Actions (none open today). Check with `gh pr list -R StaffOps/golden-images`.

## Next steps

1. Migrate consumers listed in [Inventory](inventory.md) to the golden images; .NET 8 users move to 10
   (from the inventory's "Golden replacement" column).
2. When Alpine stable ships Go 1.27, drop `apks/go-1.27.yaml` and switch the image to `go=~1.27`
   (AGENTS.md, "Bumping versions").
3. Delete the merged branches `chore/branch-protection-docs`, `feat/publish-tested-image` and
   `feat/staffops-identity-distroless` (suggested, inferred).

## Decisions

- [ADR-0001](adr/0001-package-distribution.md): custom packages live in this repo, served from a
  mounted cache directory (accepted 2026-11-18).
- Rationale for .NET from Microsoft instead of Alpine, and for the OS identity fields, is in AGENTS.md.

## Risks and open questions

- Images ship Alpine's English-only ICU data; an app that needs other locales adds `icu-data-full`
  itself (AGENTS.md).
- Verifying signatures needs cosign v3+; cosign v2 reports "no signatures found" (README).
- Changing `ID` or `VERSION_ID` in the OS identity silently zeroes CVE findings (AGENTS.md, measured
  2026-11-18).
- Renovate updates require the Renovate GitHub App on the repo; whether it is installed is not
  visible from the repo (open question).

## How to verify

```bash
gh run list -R StaffOps/golden-images -L 5
scripts/golden.sh list
scripts/golden.sh full node            # packages + images + smoke tests, host arch
cosign verify ghcr.io/staffops/node:24 \
  --certificate-identity-regexp '^https://github.com/StaffOps/golden-images/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
