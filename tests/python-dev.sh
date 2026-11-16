# shellcheck shell=bash
check "python version"          --entrypoint python3 "$IMG" --version
check "pip version"             --entrypoint pip     "$IMG" --version
check "uv version"              --entrypoint uv      "$IMG" --version
check "venv + C extension build" --entrypoint bash   "$IMG" -c 'set -e; python3 -m venv /tmp/v && /tmp/v/bin/pip -q install --no-binary=:all: markupsafe && /tmp/v/bin/python -c "import markupsafe; print(\"markupsafe\", markupsafe.__version__)"'
check "uv sync style install"   --entrypoint bash    "$IMG" -c 'set -e; cd /tmp && uv venv -q && uv pip install -q fastapi uvicorn && .venv/bin/python -c "import fastapi; print(\"fastapi\", fastapi.__version__)"'
