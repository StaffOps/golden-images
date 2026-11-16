# shellcheck shell=bash
# static: no binaries at all — inspect the filesystem instead.
nonroot
files="$(cid=$(docker create "$IMG" /x); docker export "$cid" | tar -t; docker rm "$cid" >/dev/null)"
for f in etc/ssl/certs/ca-certificates.crt usr/share/zoneinfo/America/Sao_Paulo etc/passwd app/; do
  if grep -qx "$f" <<< "$files"; then printf '  \033[1;32mOK\033[0m   %-38s\n' "has /$f"; else printf '  \033[1;31mFAIL\033[0m %-38s\n' "has /$f"; FAILED=1; fi
done
if grep -qE '^(bin/sh|bin/busybox)$' <<< "$files"; then printf '  \033[1;31mFAIL\033[0m %-38s\n' "no shell"; FAILED=1; else printf '  \033[1;32mOK\033[0m   %-38s\n' "no shell"; fi
