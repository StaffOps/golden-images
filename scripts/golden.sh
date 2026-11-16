#!/usr/bin/env bash
# Single entrypoint to reproduce the whole path locally (same scripts CI runs).
#
#   1) packages only
#        scripts/golden.sh packages [pkg ...]                 # all packages if none given
#   2) chosen packages + image(s)
#        scripts/golden.sh build <target> --packages go-1.27[,other]
#   3) full flow: every package the target needs (cache-aware) + image(s) + tests
#        scripts/golden.sh full <target>
#   4) image only, from what is already in the package cache (dist/packages)
#        scripts/golden.sh image <target>
#
#   <target> = a language/family (node, python, go, dotnet, base) — every image in
#              images/<family>/ — or an exact image name from catalog.json (e.g. node-24-dev),
#              or "all".
#
# Options (any command):
#   --arch x86_64,aarch64   archs to build (default: host). Accepts amd64/arm64 too.
#   --force                 rebuild packages even if cached
#   --test / --no-test      run smoke tests after image build (default: on for full, off otherwise)
#
# Other:
#   scripts/golden.sh list            # images, families, and the packages each one needs
#   scripts/golden.sh test <target>   # smoke tests only, on already-loaded images
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

usage() { sed -n '2,27p' "$0"; exit "${1:-0}"; }

CMD="${1:-}"; [[ -n "$CMD" ]] || usage 1; shift
ARCHS="$(host_apk_arch)"
FORCE=()
TEST=""
CHOSEN_PKGS=""
POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCHS="$2"; shift 2;;
    --force) FORCE=(--force); shift;;
    --test) TEST=1; shift;;
    --no-test) TEST=0; shift;;
    --packages) CHOSEN_PKGS="$2"; shift 2;;
    -h|--help) usage;;
    *) POS+=("$1"); shift;;
  esac
done

# apk archs (x86_64,aarch64) for melange, OCI archs (amd64,arm64) for apko.
APK_ARCHS="$(IFS=,; for a in $ARCHS; do apk_arch "$a"; done | paste -sd, -)"
OCI_ARCHS="$(IFS=,; for a in $ARCHS; do oci_arch "$a"; done | paste -sd, -)"

# Resolve a target to image names.
resolve_images() {
  local t="$1"
  if [[ "$t" == all ]]; then jq -r '.images[].name' "$CATALOG"; return; fi
  if jq -e --arg n "$t" '.images[] | select(.name == $n)' "$CATALOG" >/dev/null; then echo "$t"; return; fi
  local out
  out="$(jq -r --arg f "images/$t/" '.images[] | select(.config | startswith($f)) | .name' "$CATALOG")"
  [[ -n "$out" ]] || die "unknown target '$t' (try: scripts/golden.sh list)"
  echo "$out"
}

# Packages (melange specs) the given images need, deduplicated.
needed_packages() {
  local names; names="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  jq -r --argjson ns "$names" '[.images[] | select(.name as $n | $ns | index($n)) | (.packages // [])[]] | unique[]' "$CATALOG"
}

pkg_spec() { [[ -f "apks/$1.yaml" ]] || die "no package spec apks/$1.yaml"; echo "apks/$1.yaml"; }

build_packages() { # pkg names...
  [[ $# -gt 0 ]] || { log "no packages needed"; return 0; }
  local specs=()
  for p in "$@"; do specs+=("$(pkg_spec "$p")"); done
  "$ROOT/scripts/build-packages.sh" --arch "$APK_ARCHS" "${FORCE[@]}" "${specs[@]}"
}

build_images() { # image names...
  local n ok=() bad=()
  for n in "$@"; do
    if "$ROOT/scripts/build-image.sh" "$n" --arch "$OCI_ARCHS"; then
      ok+=("$n")
      if [[ "$TEST" == 1 ]]; then
        if [[ ",$OCI_ARCHS," == *",$(oci_arch "$(host_apk_arch)"),"* ]]; then
          "$ROOT/scripts/test-image.sh" "$n" || bad+=("$n (test)")
        else
          warn "skipping tests for $n: host arch not among built archs"
        fi
      fi
    else
      bad+=("$n (build)")
    fi
  done
  log "done: ${#ok[@]} built${bad:+, failed: ${bad[*]}}"
  [[ ${#bad[@]} -eq 0 ]]
}

case "$CMD" in
  list)
    jq -r '.images[] | [.name, (.config | split("/")[1]), (.repo + ":" + (.tags | join(","))), ((.packages // []) | join(",") | if . == "" then "-" else . end), (.eol // "-")] | @tsv' "$CATALOG" \
      | (printf 'IMAGE\tFAMILY\tTAGS\tPACKAGES\tEOL\n'; cat) | column -t -s $'\t'
    ;;
  packages)                                     # flow 1
    if [[ ${#POS[@]} -eq 0 ]]; then
      "$ROOT/scripts/build-packages.sh" --arch "$APK_ARCHS" "${FORCE[@]}"
    else
      build_packages "${POS[@]}"
    fi
    ;;
  build)                                        # flow 2
    [[ ${#POS[@]} -eq 1 ]] || die "usage: golden.sh build <target> --packages a,b"
    [[ -n "$CHOSEN_PKGS" ]] || die "build needs --packages (use 'full' to pick them automatically, 'image' for none)"
    IFS=',' read -r -a P <<< "$CHOSEN_PKGS"
    build_packages "${P[@]}"
    IMGS_RAW="$(resolve_images "${POS[0]}")" || exit 1; mapfile -t IMGS <<< "$IMGS_RAW"
    build_images "${IMGS[@]}"
    ;;
  full)                                         # flow 3
    [[ ${#POS[@]} -eq 1 ]] || die "usage: golden.sh full <target>"
    TEST="${TEST:-1}"
    IMGS_RAW="$(resolve_images "${POS[0]}")" || exit 1; mapfile -t IMGS <<< "$IMGS_RAW"
    P_RAW="$(needed_packages "${IMGS[@]}")"; P=(); [[ -z "$P_RAW" ]] || mapfile -t P <<< "$P_RAW"
    log "target ${POS[0]}: images=[${IMGS[*]}] packages=[${P[*]:-}]"
    build_packages "${P[@]}"
    build_images "${IMGS[@]}"
    ;;
  image)                                        # flow 4
    [[ ${#POS[@]} -eq 1 ]] || die "usage: golden.sh image <target>"
    IMGS_RAW="$(resolve_images "${POS[0]}")" || exit 1; mapfile -t IMGS <<< "$IMGS_RAW"
    build_images "${IMGS[@]}"
    ;;
  test)
    [[ ${#POS[@]} -eq 1 ]] || die "usage: golden.sh test <target>"
    IMGS_RAW="$(resolve_images "${POS[0]}")" || exit 1; mapfile -t IMGS <<< "$IMGS_RAW"
    rc=0; for n in "${IMGS[@]}"; do "$ROOT/scripts/test-image.sh" "$n" || rc=1; done; exit $rc
    ;;
  *) usage 1;;
esac
