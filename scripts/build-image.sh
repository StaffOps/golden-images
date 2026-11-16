#!/usr/bin/env bash
# Build (and optionally publish) one image from catalog.json with apko.
#
# Usage:
#   scripts/build-image.sh <name> [--arch amd64,arm64]            # build + docker load (host arch default)
#   scripts/build-image.sh <name> --publish [--suffix 20261116]   # push multi-arch to $REGISTRY, print digest
#
# Images that consume local packages need scripts/build-packages.sh first (same archs).
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

NAME="${1:-}"; [[ -n "$NAME" ]] || die "usage: $0 <name> [--arch ...] [--publish] [--suffix S]"; shift
ARCHS="$(oci_arch "$(host_apk_arch)")"
PUBLISH=0
SUFFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCHS="$2"; shift 2;;
    --publish) PUBLISH=1; shift;;
    --suffix) SUFFIX="$2"; shift 2;;
    *) die "unknown arg $1";;
  esac
done

CONFIG="$(catalog_get "$NAME" config)" || die "image '$NAME' not in catalog.json"
REPO="$REGISTRY/$(catalog_get "$NAME" repo)"
mapfile -t TAGS < <(jq -r --arg n "$NAME" '.images[] | select(.name == $n) | .tags[]' "$CATALOG")
EOL="$(catalog_get "$NAME" eol || true)"
[[ -z "$EOL" ]] || warn "$NAME is past end of support ($EOL) — kept for migration only"

# Every local package the image needs must exist in the cache for every arch.
while read -r pkg; do
  [[ -n "$pkg" ]] || continue
  IFS=',' read -r -a al <<< "$ARCHS"
  for a in "${al[@]}"; do
    compgen -G "$PKG_DIR/$(apk_arch "$a")/$pkg-*.apk" >/dev/null \
      || die "package $pkg missing for $a — run: scripts/build-packages.sh --arch $(apk_arch "$a")"
  done
done < <(jq -r --arg n "$NAME" '.images[] | select(.name == $n) | (.packages // [])[]' "$CATALOG")

# --- Golden image marker -------------------------------------------------------------
# Every image gets an APK named staffops-golden-<name>, generated here, that installs
# /etc/staffops/golden-image.json. Because it lives in the apk database, any SBOM of an
# image built FROM this one (Trivy, Syft, ...) lists it as a component. That is how
# consumers stay linked to the exact golden image + build they depend on (Dependency-Track).
MARKER="staffops-golden-$NAME"
BUILD_VERSION="${GOLDEN_BUILD_VERSION:-$(date -u +%Y%m%d.%H%M%S)}"   # CI pins one per run
COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo dev)"
META_DIR="dist/meta"

build_marker() {
  # Markers use their own throwaway key, so image jobs never need the package private key.
  if [[ ! -f "$META_DIR/meta.rsa" ]]; then
    mkdir -p "$META_DIR"; rm -rf "$META_DIR"/*/
    tc melange keygen "$META_DIR/meta.rsa" >/dev/null 2>&1
  fi
  local arch a spec="dist/meta-spec/$MARKER.yaml" json
  mkdir -p dist/meta-spec "$META_DIR"
  json="$(jq -nc --arg name "$NAME" --arg repo "$REPO" --arg ver "$BUILD_VERSION" --arg commit "$COMMIT" \
            --argjson tags "$(printf '%s\n' "${TAGS[@]}" | jq -R . | jq -sc .)" \
            '{name:$name, image:$repo, tags:$tags, version:$ver, commit:$commit,
              source:"https://github.com/StaffOps/golden-images", config:"'"$CONFIG"'"}')"
  cat > "$spec" <<EOF
package:
  name: $MARKER
  version: "$BUILD_VERSION"
  epoch: 0
  description: "StaffOps golden image $REPO:${TAGS[0]} (commit $COMMIT)"
  url: https://github.com/StaffOps/golden-images
  copyright:
    - license: Apache-2.0
  options:
    no-depends: true
    no-provides: true
environment:
  contents:
    repositories:
      - https://dl-cdn.alpinelinux.org/alpine/v3.24/main
    packages:
      - busybox
pipeline:
  - runs: |
      mkdir -p "\${{targets.destdir}}/etc/staffops"
      cat > "\${{targets.destdir}}/etc/staffops/golden-image.json" <<'JSON'
      $json
      JSON
EOF
  IFS=',' read -r -a al <<< "$ARCHS"
  for a in "${al[@]}"; do
    arch="$(apk_arch "$a")"
    if [[ -f "$META_DIR/$arch/$MARKER-$BUILD_VERSION-r0.apk" ]]; then continue; fi
    rm -f "$META_DIR/$arch/$MARKER"-[0-9]*.apk
    log "marker  $arch $MARKER-$BUILD_VERSION"
    tc melange build "$spec" --arch "$arch" --signing-key "$META_DIR/meta.rsa" \
      --out-dir "$META_DIR" >/dev/null 2>"dist/meta-spec/$MARKER-$arch.log" \
      || { cat "dist/meta-spec/$MARKER-$arch.log" >&2; die "marker build failed"; }
    shopt -s nullglob; local apks=("$META_DIR/$arch"/*.apk); shopt -u nullglob
    tc melange index --signing-key "$META_DIR/meta.rsa" -o "$META_DIR/$arch/APKINDEX.tar.gz" "${apks[@]}" >/dev/null 2>&1
  done
}
build_marker

MARKER_ARGS=(
  --repository-append "/work/$META_DIR"
  --keyring-append "$META_DIR/meta.rsa.pub"
  --package-append "$MARKER"
  --annotations "org.opencontainers.image.version:$BUILD_VERSION"
  --annotations "org.opencontainers.image.revision:$COMMIT"
  --annotations "dev.staffops.golden-image:$NAME"
)

mkdir -p dist/images "dist/sbom/$NAME"
FP_FILE="dist/images/$NAME.${ARCHS//,/-}.fingerprint"   # per arch set: amd64-only and multi-arch builds differ
FP_KEY="dev.staffops.golden-image.fingerprint"

# Content fingerprint: config + catalog entry + exact resolved apk set per arch (from the SBOMs),
# excluding the marker (its version is the build time). Equal fingerprint = same image content.
fingerprint() {
  local sboms=("dist/sbom/$NAME"/sbom-*.spdx.json) f
  {
    cat "$CONFIG"
    jq -c --arg n "$NAME" '.images[] | select(.name == $n)' "$CATALOG"
    for f in "${sboms[@]}"; do
      [[ "$f" == *sbom-index.spdx.json ]] && continue
      jq -r '.packages[] | select(([.externalRefs[]?.referenceLocator][0] // "") | startswith("pkg:apk/"))
             | select(.name | startswith("staffops-golden-") | not)
             | ([.externalRefs[]?.referenceLocator][0])' "$f"
    done | sort
  } | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1
}

build_local() {
  log "build $NAME ($ARCHS)"
  rm -f "dist/sbom/$NAME"/sbom-*.spdx.json
  tc apko build "$CONFIG" "$REPO:${TAGS[0]}" "dist/images/$NAME.tar" --arch "$ARCHS" "${MARKER_ARGS[@]}" --sbom-path "dist/sbom/$NAME" >/dev/null
  fingerprint > "$FP_FILE"
  log "fingerprint $NAME $(cut -c1-16 "$FP_FILE")"
}

published_fingerprint() {
  docker buildx imagetools inspect --raw "$REPO:${TAGS[0]}" 2>/dev/null \
    | jq -r --arg k "$FP_KEY" '.annotations[$k] // empty' 2>/dev/null || true
}

set_output() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1" >> "$GITHUB_OUTPUT"; }

if [[ $PUBLISH -eq 1 ]]; then
  [[ -f "$FP_FILE" ]] || build_local
  FP="$(cat "$FP_FILE")"
  OLD="$(published_fingerprint)"
  if [[ "$FP" == "$OLD" && "${FORCE_PUBLISH:-0}" != 1 ]]; then
    log "unchanged $NAME (fingerprint ${FP:0:16} already published): skipping publish/sign"
    rm -f "dist/images/$NAME.digest"
    set_output "published=false"
    exit 0
  fi
  log "changed $NAME: published=${OLD:0:16}${OLD:+ }new=${FP:0:16}"
  refs=()
  for t in "${TAGS[@]}"; do
    refs+=("$REPO:$t")
    [[ -z "$SUFFIX" ]] || refs+=("$REPO:$t-$SUFFIX")
  done
  log "publish $NAME -> ${refs[*]} ($ARCHS)"
  # apko prints the multi-arch index digest ref on stdout.
  tc apko publish "$CONFIG" "${refs[@]}" --arch "$ARCHS" "${MARKER_ARGS[@]}" \
    --annotations "$FP_KEY:$FP" --sbom-path "dist/sbom/$NAME" \
    | tail -n1 | tee "dist/images/$NAME.digest"
  set_output "published=true"
else
  build_local
  docker load -q < "dist/images/$NAME.tar" >&2
  # apko tags loaded images as <ref>-<arch>; give the host arch the plain tag too.
  host="$(oci_arch "$(host_apk_arch)")"
  if docker image inspect "$REPO:${TAGS[0]}-$host" >/dev/null 2>&1; then
    docker tag "$REPO:${TAGS[0]}-$host" "$REPO:${TAGS[0]}"
  fi
  OLD="$(published_fingerprint)"
  if [[ -n "$OLD" && "$OLD" == "$(cat "$FP_FILE")" ]]; then log "$NAME: same content as published $REPO:${TAGS[0]}"
  else log "$NAME: content differs from published $REPO:${TAGS[0]}${OLD:+ }${OLD:-(no fingerprint published yet)}"; fi
  echo "$REPO:${TAGS[0]}"
fi
