# shellcheck shell=bash
nonroot
noshell
check "dotnet --list-runtimes"  "$IMG" --list-runtimes
check "dotnet --info"           "$IMG" --info

# A real app, the way consumers use these images: compile in the SDK image, run here.
# DOTNET_SDK_IMAGE overrides the SDK used (default: the local or published dotnet-sdk:10).
dotnet_app() {
  local sdk="${DOTNET_SDK_IMAGE:-$REGISTRY/dotnet-sdk:10}" out="$ROOT/dist/test/$NAME" tpl cid port body
  if ! docker image inspect "$sdk" >/dev/null 2>&1 && ! docker pull -q "$sdk" >/dev/null 2>&1; then
    printf '  \033[1;33mSKIP\033[0m %-38s %s\n' "real app" "no SDK image $sdk"; return
  fi
  tpl=console; [[ "$NAME" == dotnet-aspnet-* ]] && tpl=web
  rm -rf "$out"; mkdir -p "$out"
  if ! docker run --rm -v "$out:/out" --entrypoint bash "$sdk" -c \
       "set -e; cd /tmp && dotnet new $tpl -o app >/dev/null && cd app && dotnet publish -c Release -o /out/bin >/dev/null" >"$out.log" 2>&1; then
    printf '  \033[1;31mFAIL\033[0m %-38s\n' "real app (build in SDK)"; tail -n 15 "$out.log"; FAILED=1; return
  fi
  if [[ "$tpl" == console ]]; then
    check "real app (console)" -v "$out/bin:/app:ro" "$IMG" /app/app.dll
    return
  fi
  # ASP.NET: start the server, then call it from the host.
  cid="$(docker run -d -p 127.0.0.1::8080 -v "$out/bin:/app:ro" "$IMG" /app/app.dll)"
  port="$(docker port "$cid" 8080/tcp | head -n1 | cut -d: -f2)"
  for _ in $(seq 1 30); do body="$(curl -fsS "http://127.0.0.1:$port/" 2>/dev/null)" && break; sleep 1; done
  if [[ "$body" == "Hello World!" ]]; then printf '  \033[1;32mOK\033[0m   %-38s %s\n' "real app (HTTP on 8080)" "$body"
  else printf '  \033[1;31mFAIL\033[0m %-38s\n' "real app (HTTP on 8080)"; docker logs "$cid" 2>&1 | tail -n 15; FAILED=1; fi
  docker rm -f "$cid" >/dev/null
}
dotnet_app
