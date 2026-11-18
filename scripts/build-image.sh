#!/usr/bin/env bash
# Build (and optionally publish) one image from catalog.json with apko.
#
# Usage:
#   scripts/build-image.sh <name> [--arch amd64,arm64]            # build + docker load (host arch default)
#   scripts/build-image.sh <name> --publish [--suffix 20261116]   # push multi-arch to $REGISTRY, print digest
#
# --publish pushes the image already built for the same --arch set (dist/images/<name>.<archs>.oci),
# byte for byte, with crane; it builds first only if that image is missing. It never rebuilds.
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
#
# The marker also owns the OS identity (replaces Alpine's alpine-release package):
#   /usr/lib/os-release (+ /etc/os-release link): NAME/PRETTY_NAME are ours, IMAGE_ID /
#     IMAGE_VERSION / BUILD_ID carry image, build and commit. ID=alpine and VERSION_ID=<Alpine
#     point release> must stay: scanners build the purl (pkg:apk/alpine/...?distro=X) from
#     them and look CVEs up in Alpine's secdb per release. A made-up VERSION_ID = zero CVEs.
#   /etc/alpine-release: Trivy reads it to identify Alpine when os-release is not decisive.
MARKER="staffops-golden-$NAME"
BUILD_VERSION="${GOLDEN_BUILD_VERSION:-$(date -u +%Y%m%d.%H%M%S)}"   # CI pins one per run
COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo dev)"
META_DIR="dist/meta"

# Alpine point release (e.g. 3.24.4) of the branch this image uses, from the official
# APKINDEX: the version of the alpine-release package, minus the -rN suffix.
alpine_version() {
  local branch idx
  branch="$(grep -oE 'alpinelinux\.org/alpine/v[0-9]+\.[0-9]+/main' "$CONFIG" | head -n1 | grep -oE 'v[0-9]+\.[0-9]+')" \
    || die "$CONFIG: no Alpine vX.Y/main repository"
  idx="https://dl-cdn.alpinelinux.org/alpine/$branch/main/x86_64/APKINDEX.tar.gz"
  # No early `exit` in awk: closing the pipe would SIGPIPE tar and, with pipefail, kill the script.
  curl -fsSL --retry 3 "$idx" | tar -xzO APKINDEX \
    | awk '/^P:/{p=substr($0,3)} /^V:/{if (p=="alpine-release" && !v) {v=substr($0,3); sub(/-r[0-9]+$/,"",v)}} END{print v}'
}
ALPINE_VERSION="$(alpine_version)"
[[ "$ALPINE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not resolve the Alpine release for $CONFIG (got '$ALPINE_VERSION')"

# Runtime images (run-as 65532) must not ship a shell. Some Alpine packages (nodejs,
# ca-certificates, icu-data-en) declare a dependency on /bin/sh only for their install
# scripts, which apko never runs; the resolver would then pull busybox-binsh + busybox.
# The marker provides /bin/sh on paper (no file), so nothing installs a shell.
PROVIDES=""
if [[ "$(yq -r '.accounts."run-as" // ""' "$CONFIG")" == "65532" ]]; then
  PROVIDES=$'  dependencies:\n    provides:\n      - /bin/sh'
fi

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
$PROVIDES
environment:
  contents:
    repositories:
      - https://dl-cdn.alpinelinux.org/alpine/v3.24/main
    packages:
      - busybox
pipeline:
  - runs: |
      d="\${{targets.destdir}}"
      mkdir -p "\$d/etc/staffops" "\$d/usr/lib"
      cat > "\$d/etc/staffops/golden-image.json" <<'JSON'
      $json
      JSON
      cat > "\$d/usr/lib/os-release" <<'OSREL'
      NAME="StaffOps Golden Image"
      ID=alpine
      VERSION_ID=$ALPINE_VERSION
      IMAGE_ID=$NAME
      IMAGE_VERSION=$BUILD_VERSION
      BUILD_ID=$COMMIT
      PRETTY_NAME="StaffOps Golden Image $NAME ($BUILD_VERSION)"
      HOME_URL="https://github.com/StaffOps/golden-images"
      BUG_REPORT_URL="https://github.com/StaffOps/golden-images/issues"
      OSREL
      ln -s ../usr/lib/os-release "\$d/etc/os-release"
      echo "$ALPINE_VERSION" > "\$d/etc/alpine-release"
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
# Everything is per arch set: an amd64-only build and a multi-arch build are different images.
ASET="${ARCHS//,/-}"
TAR="dist/images/$NAME.$ASET.tar"          # apko output, docker-loadable
LAYOUT="dist/images/$NAME.$ASET.oci"       # the same blobs as an OCI layout: what gets pushed
FP_FILE="dist/images/$NAME.$ASET.fingerprint"
FP_KEY="dev.staffops.golden-image.fingerprint"

# --- Build once, publish those exact bytes ----------------------------------------------
# The image that is tested and scanned is the image that is published: --publish never
# rebuilds, it pushes $LAYOUT with crane, so the index digest, the per-arch manifests and the
# SBOM (which names the index digest) all stay identical. The content fingerprint is
# therefore an input of the build (an index annotation), computed from the package set apko
# resolves before building and checked against the SBOMs after.

# "arch name version" of every package apko resolves for the config, marker excluded from the
# list. The marker must take part in the resolution (it provides /bin/sh on runtime images), and
# show-packages has no --package-append, so resolve a copy of the config with the marker added.
resolved_packages() {
  local a al cfg="dist/meta-spec/$NAME.apko.yaml"
  yq ".contents.repositories += [\"/work/$META_DIR\"] | .contents.keyring += [\"$META_DIR/meta.rsa.pub\"]
      | .contents.packages += [\"$MARKER\"]" "$CONFIG" > "$cfg"
  IFS=',' read -r -a al <<< "$ARCHS"
  for a in "${al[@]}"; do
    tc apko show-packages "$cfg" --arch "$a" --format '{{ .Name }} {{ .Version }}' 2>/dev/null \
      | grep -v "^$MARKER " | sed "s/^/$(apk_arch "$a") /"
  done | sort
}

# The same list, read from the SBOMs of the image that was actually built.
sbom_packages() {
  local f arch
  for f in "dist/sbom/$NAME"/sbom-*.spdx.json; do
    [[ "$f" == *sbom-index.spdx.json ]] && continue
    arch="$(basename "$f" .spdx.json)"; arch="${arch#sbom-}"
    jq -r --arg a "$arch" '.packages[]
      | select(([.externalRefs[]?.referenceLocator][0] // "") | startswith("pkg:apk/"))
      | select(.name | startswith("staffops-golden-") | not)
      | "\($a) \(.name) \(.versionInfo)"' "$f"
  done | sort
}

# Content fingerprint: config + catalog entry + Alpine release (it is in the marker's
# os-release, and the marker is excluded) + the exact package set per arch.
fingerprint() { # resolved packages
  {
    cat "$CONFIG"
    jq -c --arg n "$NAME" '.images[] | select(.name == $n)' "$CATALOG"
    echo "alpine-version $ALPINE_VERSION"
    echo "$1"
  } | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1
}

sha256_of() { (sha256sum 2>/dev/null || shasum -a 256) < "$1" | cut -d' ' -f1; }

# apko's tar holds the OCI index (index.json), manifests/configs as "sha256:<hex>" and layers
# as "<hex>.tar.gz". Rearrange them as an OCI image layout without touching a single byte.
make_layout() {
  local tmp f hex
  tmp="$(mktemp -d)"
  tar -xf "$TAR" -C "$tmp"
  rm -rf "$LAYOUT"; mkdir -p "$LAYOUT/blobs/sha256"
  for f in "$tmp"/*; do
    case "$(basename "$f")" in
      index.json)     mv "$f" "$LAYOUT/index.json";;
      manifest.json)  ;;                                  # docker-load metadata, not OCI
      sha256:*)       hex="$(basename "$f")"; mv "$f" "$LAYOUT/blobs/sha256/${hex#sha256:}";;
      *.tar.gz)       hex="$(basename "$f" .tar.gz)"; mv "$f" "$LAYOUT/blobs/sha256/$hex";;
      *)              rm -rf "$tmp"; die "unexpected entry in apko tar: $(basename "$f")";;
    esac
  done
  rm -rf "$tmp"
  printf '{"imageLayoutVersion":"1.0.0"}' > "$LAYOUT/oci-layout"
  # Every blob must be content-addressed correctly, or the push would not be the tested image.
  for f in "$LAYOUT"/blobs/sha256/*; do
    [[ "$(sha256_of "$f")" == "$(basename "$f")" ]] || die "blob $(basename "$f") does not match its digest"
  done
  # One single-arch layout per arch for scanners: `trivy --input` ignores --platform on a
  # multi-arch layout and always scans the first manifest. Same blobs, hardlinked.
  local a al
  IFS=',' read -r -a al <<< "$ARCHS"
  for a in "${al[@]}"; do
    a="$(oci_arch "$a")"
    rm -rf "$LAYOUT-$a"; mkdir -p "$LAYOUT-$a/blobs/sha256"
    for f in "$LAYOUT"/blobs/sha256/*; do ln "$f" "$LAYOUT-$a/blobs/sha256/"; done
    cp "$LAYOUT/oci-layout" "$LAYOUT-$a/"
    jq -c --arg a "$a" '.manifests |= map(select(.platform.architecture == $a))' "$LAYOUT/index.json" > "$LAYOUT-$a/index.json"
    [[ "$(jq '.manifests | length' "$LAYOUT-$a/index.json")" == 1 ]] || die "no single $a manifest in the index"
  done
}

local_digest() { echo "sha256:$(sha256_of "$LAYOUT/index.json")"; }

build_local() {
  local pkgs fp
  log "build $NAME ($ARCHS)"
  pkgs="$(resolved_packages)"; [[ -n "$pkgs" ]] || die "apko resolved no packages for $CONFIG"
  fp="$(fingerprint "$pkgs")"
  rm -f "dist/sbom/$NAME"/sbom-*.spdx.json "$TAR" "$FP_FILE"
  tc apko build "$CONFIG" "$REPO:${TAGS[0]}" "$TAR" --arch "$ARCHS" "${MARKER_ARGS[@]}" \
    --annotations "$FP_KEY:$fp" --sbom-path "dist/sbom/$NAME" >/dev/null
  if [[ "$(sbom_packages)" != "$pkgs" ]]; then
    diff <(echo "$pkgs") <(sbom_packages) >&2 || true
    die "$NAME: package set changed between resolve and build (Alpine updated mid-build?); run again"
  fi
  make_layout
  echo "$fp" > "$FP_FILE"
  log "fingerprint $NAME ${fp:0:16}, index $(local_digest | cut -c1-19)"
}

published_fingerprint() {
  docker buildx imagetools inspect --raw "$REPO:${TAGS[0]}" 2>/dev/null \
    | jq -r --arg k "$FP_KEY" '.annotations[$k] // empty' 2>/dev/null || true
}

set_output() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1" >> "$GITHUB_OUTPUT"; }

if [[ $PUBLISH -eq 1 ]]; then
  [[ -f "$FP_FILE" && -f "$LAYOUT/index.json" ]] || build_local
  FP="$(cat "$FP_FILE")"
  OLD="$(published_fingerprint)"
  if [[ "$FP" == "$OLD" && "${FORCE_PUBLISH:-0}" != 1 ]]; then
    log "unchanged $NAME (fingerprint ${FP:0:16} already published): skipping publish/sign"
    rm -f "dist/images/$NAME.digest"
    set_output "published=false"
    exit 0
  fi
  log "changed $NAME: published=${OLD:0:16}${OLD:+ }new=${FP:0:16}"
  DIGEST="$(local_digest)"
  log "publish $NAME $DIGEST -> $REPO:${TAGS[0]} ($ARCHS)"
  pushed="$(tc crane push --index "$LAYOUT" "$REPO:${TAGS[0]}" | tail -n1)"
  [[ "$pushed" == "$REPO@$DIGEST" ]] || die "pushed $pushed, expected $REPO@$DIGEST: registry did not store the built index"
  for t in "${TAGS[@]}"; do
    refs=("$t"); [[ -z "$SUFFIX" ]] || refs+=("$t-$SUFFIX")
    for r in "${refs[@]}"; do
      [[ "$r" == "${TAGS[0]}" ]] && continue
      tc crane tag "$REPO@$DIGEST" "$r" >/dev/null
      log "tag     $REPO:$r"
    done
  done
  echo "$REPO@$DIGEST" | tee "dist/images/$NAME.digest"
  set_output "published=true"
else
  build_local
  docker load -q < "$TAR" >&2
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
