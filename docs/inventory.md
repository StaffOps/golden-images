# Image inventory: what StaffOps and PersonalAIgent build on today

Survey of every Dockerfile in the `StaffOps` and `PersonalAIgent` GitHub orgs (2026-11-16).
Private repositories are described generically.
It records the base images in use, what each Dockerfile installs on top, and the golden
image that replaces it.

## Base images in use

| Base image (as written) | Uses | Where | Golden replacement |
|---|---:|---|---|
| `python:3.11-slim` | 14 | private agent platform (API + CLI runners), anomaly-detection/ml, otel-libs python examples, a private agent service | `python:3.14-dev` (build) → `python:3.14` (run) |
| `python:3.11-alpine` | 2 | aigent-squad | same |
| `python:3.12-slim` / `-alpine` | 3 | maturity-score-card, aigent-squad/mcp-server, a private sandbox | same |
| `golang:1.22` / `1.25-alpine` / `1.26.10-alpine` | 8 | otel-libs go examples, anomaly-detection controller, a private Go service | `go:1.27` or `go:1.26` (build) → `static` (run) |
| `alpine:3.20` | 8 | Go runtime stage (otel-libs, anomaly-detection) | `static` |
| `gcr.io/distroless/static-debian12:nonroot` | 1 | a private Go service (runtime) | `static` |
| `mcr.microsoft.com/dotnet/sdk:8.0` / `:10.0` | 6 | otel-libs dotnet examples | `dotnet-sdk:10` (8 is EOL: migrate) |
| `mcr.microsoft.com/dotnet/aspnet:8.0` / `:10.0` | 6 | otel-libs dotnet examples | `dotnet-aspnet:10` (8 is EOL: migrate) |
| `caddy:2.11.7-alpine` | 1 | a private static docs site | out of scope (third-party app image) |
| `debian` (digest) | 1 | a private sshd sandbox | out of scope for now (needs sshd; candidate `base/sshd`) |
| `ghcr.io/openclaw/openclaw` | 1 | a private agent service | out of scope (upstream app image) |
| `grafana/grafana` | 2 | grafana-plugins dev containers | out of scope |

Node.js is not used as a base anywhere. A private agent runner installs **Node 22**
from NodeSource on top of `python:3.11-slim` so that it can run `npm i -g @anthropic-ai/claude-code`.

## What the Dockerfiles install on top (candidates for packages)

| Installed by hand | Where | Status |
|---|---|---|
| `opencode` via `curl https://opencode.ai/install \| bash` | private agent runner | not packaged: out of scope (decided 2026-11-16) |
| Go 1.27 toolchain | (new; Alpine stable only has 1.26) | **packaged**: `apks/go-1.27.yaml` |
| Node 22 via NodeSource + `@anthropic-ai/claude-code` | private agent runner | next: `apks/claude-code.yaml` → `agent-claude` image |
| `kiro-cli` zip from AWS | private agent runner | next: verify that a musl build exists first (the zip used today is glibc) |
| `gcc g++` + prophet/scikit-learn wheels | anomaly-detection/ml | use `python:3.14-dev`; check prophet musllinux wheels on 3.14 |
| `git`, `openssh-client`, `curl`, `jq` | many | already in every `-dev` image |

## Version policy applied

| Language | Asked for | Built | Why |
|---|---|---|---|
| Node.js | 22, 24, 26 | 22, 24, 26 | 22 comes from the Alpine v3.22 branch: no newer branch ships it, and mixing branches breaks ABI. 24 = `nodejs`, 26 = `nodejs-current` from v3.24. 26 has been Active LTS since Oct 2026 (`lts`/`latest` tags) |
| Go | latest + LTS if one exists | 1.27 + 1.26 | Go has no LTS; upstream supports the last two minors. 1.26 is in use by a private Go service and comes from Alpine; 1.27 is a melange package from go.dev |
| Python | LTS + latest, or latest only | 3.14 | Python has no LTS. 3.14 is the newest in Alpine. 3.15 (Oct 2026) is not packaged by Alpine yet |
| .NET | 8 and 10 | 10 (sdk, aspnet, runtime) | Repackaged from Microsoft's official musl tarballs (like BDC): Alpine stable skipped 2 security releases and lags on the SDK band. 8 was dropped: end of support on 2026-11-10, so the otel-libs `:8.0` examples should move to 10 |

## Migration notes

- **Python 3.11/3.12 → 3.14** is the largest change: it affects 19 Dockerfiles.
  Pure-Python deps (fastapi, uvicorn, grpc) are fine. Native wheels must have musllinux
  builds for cp314, or they compile in `-dev`. Check `prophet`, `numpy==1.26.4`
  (it has no cp314 wheels, so bump it) and `pandas==2.2.1`.
- `python:3.14-dev` sets `PIP_BREAK_SYSTEM_PACKAGES=1`, so the existing
  `pip install -r requirements.txt` lines keep working. The recommended pattern is a venv
  in `-dev` copied into the runtime image.
- Runtime images run as uid **65532** and have **no shell**. `HEALTHCHECK CMD curl ...`
  will not work: use the language runtime (`python -c ...`) or a Kubernetes probe instead.
- ASP.NET images listen on **8080** (`ASPNETCORE_HTTP_PORTS`), not 80.
