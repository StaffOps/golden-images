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

log "testing $NAME ($IMG) suite=$SUITE"
marker
source "$ROOT/tests/$SUITE.sh"

[[ $FAILED -eq 0 ]] || die "$NAME: checks failed"
log "$NAME: all checks passed"
