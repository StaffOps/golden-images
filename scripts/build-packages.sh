#!/usr/bin/env bash
# Build melange packages into the mounted cache dir (dist/packages), keeping ONLY the
# latest version of each package. A package is rebuilt only when its
# name-version-r<epoch>.apk is missing from the cache, so a warm cache makes this a no-op.
#
# Usage: scripts/build-packages.sh [--arch x86_64,aarch64] [--force] [apks/<pkg>.yaml ...]
#   default arch: host arch. --force rebuilds even when cached.
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

ARCHS="$(host_apk_arch)"
FORCE=0
SPECS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCHS="$2"; shift 2;;
    --force) FORCE=1; shift;;
    -h|--help) sed -n '2,9p' "$0"; exit 0;;
    *) SPECS+=("$1"); shift;;
  esac
done
[[ ${#SPECS[@]} -gt 0 ]] || SPECS=(apks/*.yaml)
IFS=',' read -r -a ARCH_LIST <<< "$ARCHS"

mkdir -p "$PKG_DIR"

ensure_signing_key

spec_field() { yq -r ".package.$2" "$1"; }

declare -A WANTED=()   # apk filename per package name, used for pruning
for spec in apks/*.yaml; do
  n="$(spec_field "$spec" name)"; v="$(spec_field "$spec" version)"; e="$(spec_field "$spec" epoch)"
  WANTED["$n"]="$n-$v-r${e:-0}.apk"
done

for arch in "${ARCH_LIST[@]}"; do
  arch="$(apk_arch "$arch")"
  mkdir -p "$PKG_DIR/$arch"
  for spec in "${SPECS[@]}"; do
    n="$(spec_field "$spec" name)"
    target="$PKG_DIR/$arch/${WANTED[$n]}"
    if [[ $FORCE -eq 0 && -f "$target" ]]; then
      log "cached  $arch ${WANTED[$n]}"
      continue
    fi
    log "build   $arch ${WANTED[$n]}"
    tc melange build "$spec" \
      --arch "$arch" \
      --signing-key "$PKG_DIR/melange.rsa" \
      --out-dir "$PKG_DIR" \
      --source-dir "./apks"
  done

  # Prune: drop older versions and packages whose spec was deleted.
  shopt -s nullglob
  for apk in "$PKG_DIR/$arch"/*.apk; do
    f="$(basename "$apk")"
    n="$(sed -E 's/-[^-]+-r[0-9]+\.apk$//' <<< "$f")"
    if [[ "${WANTED[$n]:-}" != "$f" ]]; then
      log "prune   $arch $f"
      rm -f "$apk"
    fi
  done
  apks=("$PKG_DIR/$arch"/*.apk)
  shopt -u nullglob
  if [[ ${#apks[@]} -gt 0 ]]; then
    tc melange index --signing-key "$PKG_DIR/melange.rsa" \
      -o "$PKG_DIR/$arch/APKINDEX.tar.gz" "${apks[@]}" >/dev/null
  fi
done
log "packages ready in $PKG_DIR"
ls -1 "$PKG_DIR"/*/*.apk 2>/dev/null | sed "s#^#    #" >&2 || true
