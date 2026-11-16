#!/usr/bin/env bash
# Print the primary image ref (registry/repo:first-tag) of a catalog entry.
source "$(dirname "$0")/lib.sh"
n="${1:?usage: ref.sh <name>}"
echo "$REGISTRY/$(catalog_get "$n" repo):$(jq -r --arg n "$n" '.images[] | select(.name == $n) | .tags[0]' "$CATALOG")"
