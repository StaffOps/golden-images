#!/usr/bin/env bash
# Recompute pinned checksums after a version bump (Renovate only changes the version).
#
#   scripts/update-checksums.sh apks/<pkg>.yaml ...   # every `uses: fetch` step: download, hash, write back
#   scripts/update-checksums.sh toolchain/Dockerfile  # melange/apko sha256 from the release checksums.txt
#   scripts/update-checksums.sh                       # all of the above
#
# The hash algorithm is whatever the spec already uses (expected-sha256 or expected-sha512).
# `${{package.version}}` in the URI is replaced by package.version. Needs: bash, curl, yq (mikefarah), sha*sum/shasum.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
hash_of() { # algo(256|512) file
  if command -v "sha$1sum" >/dev/null; then "sha$1sum" "$2" | cut -d' ' -f1
  else shasum -a "$1" "$2" | cut -d' ' -f1; fi
}

update_spec() {
  local spec="$1" version n i uri key algo tmp sum
  version="$(yq -r '.package.version' "$spec")"
  n="$(yq '[.. | select(tag == "!!map" and .uses == "fetch")] | length' "$spec")"
  for ((i = 0; i < n; i++)); do
    uri="$(yq -r "[.. | select(tag == \"!!map\" and .uses == \"fetch\")][$i].with.uri" "$spec")"
    if [[ "$(yq "[.. | select(tag == \"!!map\" and .uses == \"fetch\")][$i].with | has(\"expected-sha512\")" "$spec")" == true ]]; then
      key=expected-sha512; algo=512
    else
      key=expected-sha256; algo=256
    fi
    local url="${uri//\$\{\{package.version\}\}/$version}"
    tmp="$(mktemp)"
    log "$spec: $url"
    curl -fsSL --retry 3 -o "$tmp" "$url"
    sum="$(hash_of "$algo" "$tmp")"
    rm -f "$tmp"
    URI="$uri" SUM="$sum" yq -i "(.. | select(tag == \"!!map\" and .uses == \"fetch\" and .with.uri == strenv(URI))).with.\"$key\" = strenv(SUM)" "$spec"
  done
}

update_toolchain() {
  local f=toolchain/Dockerfile tool ver sums arch sum
  for tool in melange apko; do
    ver="$(sed -nE "s/^ARG ${tool^^}_VERSION=(.+)$/\1/p" "$f")"
    sums="$(curl -fsSL --retry 3 "https://github.com/chainguard-dev/$tool/releases/download/v$ver/checksums.txt")"
    for arch in amd64 arm64; do
      sum="$(awk -v n="${tool}_${ver}_linux_${arch}.tar.gz" '$2 == n {print $1}' <<< "$sums")"
      [[ -n "$sum" ]] || { echo "no checksum for $tool $ver $arch" >&2; exit 1; }
      log "$f: $tool $ver $arch"
      sed -i.bak -E "s/^(ARG ${tool^^}_SHA256_${arch}=).*/\1$sum/" "$f" && rm -f "$f.bak"
    done
  done
  # crane: go-containerregistry release, assets named go-containerregistry_Linux_<x86_64|arm64>.
  ver="$(sed -nE 's/^ARG CRANE_VERSION=(.+)$/\1/p' "$f")"
  sums="$(curl -fsSL --retry 3 "https://github.com/google/go-containerregistry/releases/download/v$ver/checksums.txt")"
  for arch in amd64 arm64; do
    local carch=x86_64; [[ "$arch" == arm64 ]] && carch=arm64
    sum="$(awk -v n="go-containerregistry_Linux_${carch}.tar.gz" '$2 == n {print $1}' <<< "$sums")"
    [[ -n "$sum" ]] || { echo "no checksum for crane $ver $arch" >&2; exit 1; }
    log "$f: crane $ver $arch"
    sed -i.bak -E "s/^(ARG CRANE_SHA256_${arch}=).*/\1$sum/" "$f" && rm -f "$f.bak"
  done
}

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(apks/*.yaml toolchain/Dockerfile)
for t in "${targets[@]}"; do
  case "$t" in
    toolchain/Dockerfile) update_toolchain;;
    apks/*.yaml) update_spec "$t";;
    *) echo "skip $t" >&2;;
  esac
done
