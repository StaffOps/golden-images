# shellcheck shell=bash
check "go version"              --entrypoint go "$IMG" version
check "GOTOOLCHAIN=local"       --entrypoint go "$IMG" env GOTOOLCHAIN
check "static build (CGO=0)"    --entrypoint bash "$IMG" -c 'set -e; mkdir -p /tmp/h && cd /tmp/h && go mod init h >/dev/null 2>&1 && printf "package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"hello static\")}\n" > m.go && CGO_ENABLED=0 go build -o h . && ./h'
check "cgo build (musl)"        --entrypoint bash "$IMG" -c 'set -e; mkdir -p /tmp/c && cd /tmp/c && go mod init c >/dev/null 2>&1 && printf "package main\n// #include <stdio.h>\nimport \"C\"\nimport \"fmt\"\nfunc main(){fmt.Println(\"hello cgo\")}\n" > m.go && CGO_ENABLED=1 go build -o c . && ./c'
