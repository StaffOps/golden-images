#!/usr/bin/env bash
# Decide which images a change affects. This is the data-driven equivalent of the reference
# repo's per-image `rules: changes:` plus the package→image trigger map (triggers.yml),
# derived from catalog.json instead of being maintained by hand.
#
#   scripts/plan.sh <base-ref> [<head-ref>]   # JSON array of image names affected by base..head
#   scripts/plan.sh --all                     # every image
#
# Rules (per changed file):
#   images/<f>/<x>.yaml          → the image whose config is that file
#   apks/<pkg>.yaml              → every image listing <pkg> in catalog "packages"
#   tests/<suite>.sh             → every image using that test suite
#   catalog.json                 → images whose catalog entry changed
#   scripts/{lib,golden,build-image,build-packages,test-image}.sh, toolchain/, build workflow → all
#   (the build process itself changed). Helper scripts (plan, ref, update-checksums) → nothing.
#   anything else (docs, renovate.json, other workflows) → nothing
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

if [[ "${1:-}" == "--all" ]]; then jq -c '[.images[].name]' "$CATALOG"; exit 0; fi
BASE="${1:?usage: plan.sh <base-ref> [<head-ref>] | --all}"; HEAD="${2:-HEAD}"

# No usable base (first push, force-push, shallow history): be safe, build everything.
if ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  warn "base $BASE not available, planning all images"
  jq -c '[.images[].name]' "$CATALOG"; exit 0
fi

mapfile -t CHANGED < <(git diff --name-only "$BASE" "$HEAD")
declare -A PICK=()
add_all() { while read -r n; do PICK["$n"]=1; done < <(jq -r '.images[].name' "$CATALOG"); }

for f in "${CHANGED[@]}"; do
  case "$f" in
    scripts/lib.sh|scripts/golden.sh|scripts/build-image.sh|scripts/build-packages.sh|scripts/test-image.sh|toolchain/*|.github/workflows/build.yml)
      log "plan: $f → all"; add_all;;
    images/*.yaml)
      while read -r n; do log "plan: $f → $n"; PICK["$n"]=1; done \
        < <(jq -r --arg f "$f" '.images[] | select(.config == $f) | .name' "$CATALOG");;
    apks/*.yaml)
      p="$(basename "$f" .yaml)"
      while read -r n; do log "plan: $f → $n"; PICK["$n"]=1; done \
        < <(jq -r --arg p "$p" '.images[] | select((.packages // []) | index($p)) | .name' "$CATALOG");;
    tests/*.sh)
      s="$(basename "$f" .sh)"
      while read -r n; do log "plan: $f → $n"; PICK["$n"]=1; done \
        < <(jq -r --arg s "$s" '.images[] | select(.test == $s) | .name' "$CATALOG");;
    catalog.json)
      # Compare entries one by one between base and head.
      old="$(git show "$BASE:catalog.json" 2>/dev/null || echo '{"images":[]}')"
      while read -r n; do log "plan: catalog entry $n changed"; PICK["$n"]=1; done < <(
        jq -r --argjson old "$old" '
          ($old.images | map({(.name): .}) | add // {}) as $o
          | .images[] | select($o[.name] != .) | .name' "$CATALOG");;
  esac
done

# Keep catalog order; drop names that no longer exist.
jq -c --argjson pick "$(printf '%s\n' "${!PICK[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
  '[.images[].name | select(. as $n | $pick | index($n))]' "$CATALOG"
