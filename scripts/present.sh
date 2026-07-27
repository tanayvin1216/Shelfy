#!/usr/bin/env bash
# One-command stage setup. Preflight first; the destructive clean reset is last.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

DEPLOYED_URL="https://backshelf-production.up.railway.app"
OPEN_TABS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --open) OPEN_TABS=1 ;;
    --base) DEPLOYED_URL="${2%/}"; shift ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

./scripts/preflight.sh --base "$DEPLOYED_URL"

if [ "$OPEN_TABS" = 1 ]; then
  open "$DEPLOYED_URL"
  open "https://github.com/tanayvin1216/Shelfy/blob/main/sweep.sv.jac#L960"
fi

# Keep this last. It wipes .jac/data/main.db*, restarts the local server, and
# leaves exactly the seeded presentation graph behind.
./scripts/demo.sh --reset

printf '\nREADY TO PRESENT\n'
printf '  app:  %s\n' "$DEPLOYED_URL"
printf '  code: https://github.com/tanayvin1216/Shelfy/blob/main/sweep.sv.jac#L960\n'
