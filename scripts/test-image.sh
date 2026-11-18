#!/usr/bin/env bash
# Smoke-test an image. Runtime images have no shell, so every check is a `docker run`
# of the image's own binaries, driven from the host.
#
# Usage: scripts/test-image.sh <name> [image-ref]   (ref defaults to the locally loaded tag)
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

NAME="${1:-}"; [[ -n "$NAME" ]] || die "usage: $0 <name> [image-ref]"
SUITE="$(catalog_get "$NAME" test)" || die "image '$NAME' not in catalog.json"
IMG="${2:-$REGISTRY/$(catalog_get "$NAME" repo):$(jq -r --arg n "$NAME" '.images[] | select(.name == $n) | .tags[0]' "$CATALOG")}"

FAILED=0
check() { # description, then docker run args
  local d="$1"; shift
  local out
  if out="$(docker run --rm "$@" 2>&1)"; then
    printf '  \033[1;32mOK\033[0m   %-38s %s\n' "$d" "$(head -n1 <<< "$out")"
  else
    printf '  \033[1;31mFAIL\033[0m %-38s\n%s\n' "$d" "$out" | head -n 20
    FAILED=1
  fi
}
nonroot() { # image must not run as root
  local u
  u="$(docker image inspect -f '{{.Config.User}}' "$IMG")"
  if [[ "$u" == "65532" ]]; then printf '  \033[1;32mOK\033[0m   %-38s %s\n' "runs as nonroot" "$u"
  else printf '  \033[1;31mFAIL\033[0m %-38s user=%s\n' "runs as nonroot" "$u"; FAILED=1; fi
}

noshell() { # runtime images: no shell binary and no busybox, not even pulled in as a dependency
  local cid files db bad
  cid="$(docker create "$IMG" /x)"
  files="$(docker export "$cid" | tar -t)"
  db="$(docker cp "$cid:/usr/lib/apk/db/installed" - 2>/dev/null | tar -xO 2>/dev/null)" || db=""
  docker rm "$cid" >/dev/null
  bad="$(grep -xE 'bin/(sh|ash|bash|busybox)|usr/bin/(sh|bash)' <<< "$files"; grep -xE 'P:(busybox|busybox-binsh|bash)' <<< "$db")" || true
  if [[ -z "$bad" ]]; then printf '  \033[1;32mOK\033[0m   %-38s\n' "no shell"
  else printf '  \033[1;31mFAIL\033[0m %-38s %s\n' "no shell" "$(tr '\n' ' ' <<< "$bad")"; FAILED=1; fi
}

marker() { # every golden image must carry its marker (SBOM traceability)
  local cid j
  cid="$(docker create "$IMG" /x)"
  if j="$(docker cp "$cid:/etc/staffops/golden-image.json" - 2>/dev/null | tar -xO 2>/dev/null)" \
     && [[ "$(jq -r .name <<< "$j" 2>/dev/null)" == "$NAME" ]]; then
    printf '  \033[1;32mOK\033[0m   %-38s %s\n' "golden marker" "staffops-golden-$NAME $(jq -r .version <<< "$j")"
  else
    printf '  \033[1;31mFAIL\033[0m %-38s\n' "golden marker"; FAILED=1
  fi
  docker rm "$cid" >/dev/null
}

identity() { # StaffOps name, but ID/VERSION_ID still Alpine's so scanners keep matching CVEs
  local cid osr rel db ver
  cid="$(docker create "$IMG" /x)"
  osr="$(docker cp "$cid:/usr/lib/os-release" - 2>/dev/null | tar -xO 2>/dev/null)" || osr=""
  rel="$(docker cp "$cid:/etc/alpine-release" - 2>/dev/null | tar -xO 2>/dev/null)" || rel=""
  db="$(docker cp "$cid:/usr/lib/apk/db/installed" - 2>/dev/null | tar -xO 2>/dev/null)" || db=""
  docker rm "$cid" >/dev/null
  ver="$(sed -n 's/^VERSION_ID=//p' <<< "$osr")"
  if grep -qx 'NAME="StaffOps Golden Image"' <<< "$osr" && grep -qx 'ID=alpine' <<< "$osr" \
     && grep -qx "IMAGE_ID=$NAME" <<< "$osr" && [[ -n "$ver" && "$ver" == "$rel" ]] \
     && ! grep -qx 'P:alpine-release' <<< "$db"; then
    printf '  \033[1;32mOK\033[0m   %-38s %s\n' "os identity" "StaffOps / alpine $ver"
  else
    printf '  \033[1;31mFAIL\033[0m %-38s VERSION_ID=%s alpine-release=%s\n' "os identity" "$ver" "$rel"; FAILED=1
  fi
}

log "testing $NAME ($IMG) suite=$SUITE"
marker
identity
source "$ROOT/tests/$SUITE.sh"

[[ $FAILED -eq 0 ]] || die "$NAME: checks failed"
log "$NAME: all checks passed"
