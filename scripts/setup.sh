#!/usr/bin/env bash
# One-command bootstrap for a fresh clone.
#   ./scripts/setup.sh
# Then:
#   ./.venv/bin/jac start main.jac     # http://localhost:8000
#   ./scripts/demo.sh                  # seed demo state (the graph starts empty)
set -euo pipefail

cd "$(dirname "$0")/.."

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 — $2" >&2; exit 1; }
}

need python3 "install Python 3.12 or newer"
need node "install node 20 or newer — the .cl.jac client is bundled by vite"

py_ok=$(python3 -c 'import sys; print(1 if sys.version_info >= (3,12) else 0)')
if [ "$py_ok" != "1" ]; then
  echo "Python 3.12+ required, found $(python3 --version)" >&2
  exit 1
fi

echo "==> creating .venv"
python3 -m venv .venv

# Pins are load-bearing. Installing jac-cloud drags jaclang back to 0.9.0, which
# cannot import byllm's plugin.jac and leaves you with a jac binary that will not
# start. requirements.txt is the whole story — do not add jac-cloud.
echo "==> installing python deps"
./.venv/bin/pip install --quiet --upgrade pip
./.venv/bin/pip install --quiet -r requirements.txt

echo "==> installing npm deps for the client bundle"
./.venv/bin/jac install

if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> wrote .env — add your GEMINI_API_KEY for real label extraction"
  echo "    (without it the app runs on MockLLM and returns canned extractions)"
fi

echo
echo "==> verifying the toolchain"
# Capture rather than pipe — jac's banner blows up with BrokenPipeError against `head`.
jac_version="$(./.venv/bin/jac --version 2>/dev/null)"
printf '%s\n' "$jac_version" | grep -iE "version|jaclang|byllm|plugin" || printf '%s\n' "$jac_version"

echo
echo "ready."
echo "  ./.venv/bin/jac start main.jac    # then open http://localhost:8000"
echo "  ./scripts/demo.sh                 # seed demo state in another terminal"
