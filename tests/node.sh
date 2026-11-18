# shellcheck shell=bash
nonroot
noshell
check "node version"            "$IMG" -p 'process.version'
check "TLS + Intl"              "$IMG" -e 'require("tls"); console.log(new Intl.NumberFormat().format(1234.5))'
check "timezone data"           -e TZ=America/Sao_Paulo "$IMG" -e 'console.log(new Date().toString())'
