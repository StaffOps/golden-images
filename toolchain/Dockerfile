# Build toolchain: melange + apko pinned by version and checksum.
#
# Why a Dockerfile in a repo that avoids Dockerfiles: cgr.dev and ghcr.io/chainguard-dev
# no longer serve melange/apko images anonymously, and melange needs bubblewrap (Linux).
# This image gives the same toolchain on macOS (Docker Desktop) and on CI runners.
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

ARG TARGETARCH
ARG MELANGE_VERSION=0.65.0
ARG MELANGE_SHA256_amd64=82340e525934c634d2a15f8f5ae3ac6fe859b0a27e3841465b274cb5508af9d0
ARG MELANGE_SHA256_arm64=b85cda34f03b064cec7752e3cab91153e30ee823677f6d13ae71ad4ac3e44d1e
ARG APKO_VERSION=1.5.1
ARG APKO_SHA256_amd64=933452d304910d5a16f97d1f90eb86bcf757add91c3a8f9940dc52cc78ee51be
ARG APKO_SHA256_arm64=a5596a62c9096f384ab6e42dc3cbc142250a70d168b12bbffd8d8012ecededbc
# crane pushes the exact OCI layout that apko built and CI tested (no rebuild at publish).
ARG CRANE_VERSION=0.22.1
ARG CRANE_SHA256_amd64=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
ARG CRANE_SHA256_arm64=898c0cff975f898a33e8c4580bdafb0e7c02c7faa33374e946762f97c4ab7110

RUN apk add --no-cache bubblewrap ca-certificates-bundle curl tar

RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) m="$MELANGE_SHA256_amd64"; a="$APKO_SHA256_amd64"; c="$CRANE_SHA256_amd64"; carch=x86_64;; \
      arm64) m="$MELANGE_SHA256_arm64"; a="$APKO_SHA256_arm64"; c="$CRANE_SHA256_arm64"; carch=arm64;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1;; \
    esac; \
    cd /tmp; \
    curl -fsSLo melange.tgz "https://github.com/chainguard-dev/melange/releases/download/v${MELANGE_VERSION}/melange_${MELANGE_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLo apko.tgz "https://github.com/chainguard-dev/apko/releases/download/v${APKO_VERSION}/apko_${APKO_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLo crane.tgz "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_${carch}.tar.gz"; \
    echo "$m  melange.tgz" | sha256sum -c -; \
    echo "$a  apko.tgz" | sha256sum -c -; \
    echo "$c  crane.tgz" | sha256sum -c -; \
    tar -xzf melange.tgz --strip-components=1 -C /usr/local/bin "melange_${MELANGE_VERSION}_linux_${TARGETARCH}/melange"; \
    tar -xzf apko.tgz --strip-components=1 -C /usr/local/bin "apko_${APKO_VERSION}_linux_${TARGETARCH}/apko"; \
    tar -xzf crane.tgz -C /usr/local/bin crane; \
    rm -f melange.tgz apko.tgz crane.tgz; \
    melange version >/dev/null; apko version >/dev/null; crane version >/dev/null

WORKDIR /work
