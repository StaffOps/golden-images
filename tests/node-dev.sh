# shellcheck shell=bash
check "node version"            --entrypoint node "$IMG" -p 'process.version'
check "npm version"             --entrypoint npm  "$IMG" -v
check "pnpm version"            --entrypoint pnpm "$IMG" -v
check "yarn version"            --entrypoint yarn "$IMG" -v
check "native addon (node-gyp)" --entrypoint bash "$IMG" -c 'set -e; cd /tmp && npm init -y >/dev/null && npm install --no-audit --no-fund bufferutil@4 --build-from-source >/dev/null 2>&1 && node -e "require(\"bufferutil\"); console.log(\"bufferutil built\")"'
