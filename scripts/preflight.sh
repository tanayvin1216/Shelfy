#!/usr/bin/env bash
# Verify the presentation surface without changing the pantry graph.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

BASE="https://backshelf-production.up.railway.app"
ALLOW_MOCK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2%/}"; shift ;;
    --allow-mock) ALLOW_MOCK=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    http*) BASE="${1%/}" ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing: $1" >&2
    exit 1
  }
}

need curl
need python3

WALKERS_FILE="$(mktemp -t backshelf-walkers.XXXXXX)"
STATUS_FILE="$(mktemp -t backshelf-llm-status.XXXXXX)"
trap 'rm -f "$WALKERS_FILE" "$STATUS_FILE"' EXIT

printf 'Backshelf preflight: %s\n' "$BASE"
curl -fsS -m 30 "$BASE/walkers" > "$WALKERS_FILE"
curl -fsS -m 30 -X POST "$BASE/walker/LlmStatus" \
  -H 'Content-Type: application/json' -d '{}' > "$STATUS_FILE"

python3 - "$WALKERS_FILE" "$STATUS_FILE" "$ALLOW_MOCK" <<'PY'
import json
import sys

walkers_path, status_path, allow_mock_raw = sys.argv[1:]
allow_mock = allow_mock_raw == "1"
required = {
    "ClearItem", "IntakeScan", "LlmStatus", "MatchNeeds",
    "RecallSweep", "SeedDemo", "SeedPantry", "SetLlmKey",
}

with open(walkers_path, encoding="utf-8") as handle:
    walkers_envelope = json.load(handle)
with open(status_path, encoding="utf-8") as handle:
    status_envelope = json.load(handle)

if not walkers_envelope.get("ok"):
    raise SystemExit("FAIL: /walkers did not return ok:true")
walkers = set(walkers_envelope.get("data", {}).get("walkers", []))
missing = sorted(required - walkers)
if missing:
    raise SystemExit("FAIL: missing walkers: " + ", ".join(missing))
print(f"  OK  API surface: {len(walkers)} walkers registered")

if not status_envelope.get("ok"):
    raise SystemExit("FAIL: LlmStatus did not return ok:true")
reports = status_envelope.get("data", {}).get("reports", [])
if not reports:
    raise SystemExit("FAIL: LlmStatus returned no report")
status = reports[0]
model = status.get("model", "")
source = status.get("source", "")
using_mock = bool(status.get("using_mock_llm"))
last_error = status.get("last_error", "").strip()

print(f"  INFO LLM source: {source}; model: {model}")
if "gemini-2.0-flash" in model:
    raise SystemExit("FAIL: retired Gemini 2.0 Flash is still configured")
if last_error:
    raise SystemExit("FAIL: last model call fell back to MockLLM:\n" + last_error)
if using_mock and not allow_mock:
    raise SystemExit(
        "FAIL: deployed app is on MockLLM. Paste the key in the byLLM panel, "
        "make one IntakeScan, then rerun preflight."
    )
if using_mock:
    print("  WARN MockLLM allowed for this local check")
else:
    print("  OK  Gemini is configured and the last model call has no error")

print("  READY presentation surface passed")
PY
