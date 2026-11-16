#!/usr/bin/env bash
# Shared helpers. Source from the other scripts; do not execute directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="dist/packages"          # mounted APK cache: latest version of each package only
CATALOG="$ROOT/catalog.json"
REGISTRY="${REGISTRY:-$(jq -r .registry "$CATALOG")}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Host arch in apk naming (x86_64 / aarch64) and OCI naming (amd64 / arm64).
host_apk_arch() { case "$(uname -m)" in x86_64|amd64) echo x86_64;; arm64|aarch64) echo aarch64;; *) die "unsupported host arch";; esac; }
oci_arch()      { case "$1" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) die "unknown arch $1";; esac; }
apk_arch()      { case "$1" in x86_64|amd64) echo x86_64;; aarch64|arm64) echo aarch64;; *) die "unknown arch $1";; esac; }

# Toolchain image, tagged by the hash of its Dockerfile so a version bump rebuilds it.
toolchain_image() {
  local h
  h="$( (sha256sum 2>/dev/null || shasum -a 256) < "$ROOT/toolchain/Dockerfile" | cut -c1-12)"
  echo "golden-images-toolchain:$h"
}

ensure_toolchain() {
  TOOLCHAIN_IMAGE="$(toolchain_image)"
  if ! docker image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1; then
    log "building toolchain image $TOOLCHAIN_IMAGE"
    docker build -q -t "$TOOLCHAIN_IMAGE" "$ROOT/toolchain" >/dev/null
  fi
}

# Run melange/apko inside the toolchain container with the repo mounted at /work.
# --privileged is required by melange's bubblewrap runner.
tc() {
  ensure_toolchain
  local extra=()
  if [[ -n "${DOCKER_CONFIG_MOUNT:-}" ]]; then
    extra+=(-v "$DOCKER_CONFIG_MOUNT:/root/.docker:ro")
  fi
  # Extra docker args, e.g. TC_DOCKER_ARGS="--network container:registry" to publish
  # to a throwaway local registry (see README "Test the publish path locally").
  if [[ -n "${TC_DOCKER_ARGS:-}" ]]; then
    read -r -a more <<< "$TC_DOCKER_ARGS"; extra+=("${more[@]}")
  fi
  docker run --rm --privileged "${extra[@]}" -v "$ROOT:/work" -w /work "$TOOLCHAIN_IMAGE" "$@"
}

# Ephemeral signing key for local packages (dist/packages). Image markers use their own key.
# Packages never leave the build, so the key only needs to be consistent within the cache.
ensure_signing_key() {
  if [[ ! -f "$ROOT/$PKG_DIR/melange.rsa" ]]; then
    log "generating melange signing key in $PKG_DIR"
    mkdir -p "$ROOT/$PKG_DIR"
    rm -rf "$ROOT/$PKG_DIR"/*/   # anything signed by an older key is useless now
    tc melange keygen "$PKG_DIR/melange.rsa" >/dev/null
  fi
}

catalog_get() { # name field
  jq -er --arg n "$1" --arg f "$2" '.images[] | select(.name == $n) | .[$f] // empty' "$CATALOG"
}
