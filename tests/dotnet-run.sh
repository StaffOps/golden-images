# shellcheck shell=bash
nonroot
check "dotnet --list-runtimes"  "$IMG" --list-runtimes
check "dotnet --info"           "$IMG" --info
