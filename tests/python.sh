# shellcheck shell=bash
nonroot
check "python version"          "$IMG" --version
check "stdlib: ssl/sqlite/zoneinfo" "$IMG" -c 'import ssl, sqlite3, zoneinfo, json; print(ssl.OPENSSL_VERSION, zoneinfo.ZoneInfo("America/Sao_Paulo"))'
check "no pip in runtime"       "$IMG" -c 'import importlib.util,sys; sys.exit(importlib.util.find_spec("pip") is not None)'
