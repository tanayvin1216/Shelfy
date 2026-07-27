#!/usr/bin/env bash
#
# Backshelf - the full §12 demo, one command.
#
#   scripts/demo.sh --reset          # wipe the graph, start a server, replay everything
#   scripts/demo.sh                  # replay against whatever is already running
#   scripts/demo.sh --base https://backshelf.up.railway.app
#
# --reset is the stage setting. It deletes .jac/data/main.db*, restarts the
# server and rebuilds the graph from scratch, so every rehearsal shows the
# judge exactly what the real run will show. Without it the script is still
# safe to run repeatedly - SeedPantry and SeedDemo are idempotent - but each
# run leaves another scanned can behind and the shelf listing gets noisy.
#
# Every step below is one `POST /walker/<Name>`. There is no other API: the
# walkers ARE the endpoints, generated from the walker declarations.
#
# The easiest Gemini setup is the byLLM panel in the running app: paste a key
# and the next call uses it without a restart. `.env` remains available for a
# local machine you control. See README.md.
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
JAC="$REPO/.venv/bin/jac"

BASE="http://localhost:8390"
RESET=0
SERVE=0
LIVE_FEED=1

while [ $# -gt 0 ]; do
  case "$1" in
    --reset)  RESET=1; SERVE=1 ;;
    --serve)  SERVE=1 ;;
    --no-live) LIVE_FEED=0 ;;
    --base)   BASE="$2"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    http*)    BASE="$1" ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

PORT="$(printf '%s' "$BASE" | sed -n 's#.*:\([0-9][0-9]*\)/*$#\1#p')"
[ -n "$PORT" ] || PORT=8390

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }
die()  { printf '\n\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# A 1x1 PNG. Under MockLLM the pixels do not matter; swap in a real photo with
#   BACKSHELF_PHOTO=$(base64 -i can.jpg | tr -d '\n') scripts/demo.sh
PHOTO="${BACKSHELF_PHOTO:-iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==}"

# ---------------------------------------------------------------------------
# Server lifecycle (only when we are pointed at a local port)
# ---------------------------------------------------------------------------

is_local() { case "$BASE" in http://localhost:*|http://127.0.0.1:*) return 0 ;; *) return 1 ;; esac; }

stop_server() {
  pkill -f "jac start main.jac --port $PORT" 2>/dev/null
  sleep 1
}

start_server() {
  bold "starting jac start main.jac --port $PORT"
  dim  "  (this is the whole backend: walkers become endpoints, no routes are written by hand)"
  : > /tmp/backshelf-server.log
  # Every fd is reopened, and `exec` replaces the subshell, so the server holds
  # no descriptor belonging to our caller. Without this, `demo.sh | tee` hangs
  # forever at the end: tee waits on a pipe the server is still holding open.
  ( cd "$REPO" && exec nohup "$JAC" start main.jac --port "$PORT" \
      < /dev/null >> /tmp/backshelf-server.log 2>&1 ) &
  disown 2>/dev/null || true
  local waited=0
  until grep -q "Server ready" /tmp/backshelf-server.log 2>/dev/null; do
    sleep 2; waited=$((waited + 2))
    [ "$waited" -gt 180 ] && { tail -30 /tmp/backshelf-server.log; die "server never became ready"; }
  done
  dim "  server ready after ${waited}s - log: /tmp/backshelf-server.log"
}

# Walker POSTs return {"error":"Unauthorized"} for ~30s after boot while walker
# registration finishes. That is not an auth bug; wait it out.
# The probe is SeedPantry because it is idempotent and needs no arguments. Its
# first successful response is kept: on a fresh graph that call is the one that
# actually builds the pantry, so step 1 replays it rather than re-POSTing and
# reporting a misleading "0 nodes created".
wait_registered() {
  printf '\033[2m  waiting for walker registration'
  local waited=0
  until curl -s -m 10 -X POST "$BASE/walker/SeedPantry" \
        -H 'Content-Type: application/json' -d '{}' 2>/dev/null \
        > /tmp/bs_first_seed.json && grep -q '"ok": true' /tmp/bs_first_seed.json; do
    printf '.'; sleep 3; waited=$((waited + 3))
    [ "$waited" -gt 180 ] && { printf '\033[0m\n'; die "walkers never registered at $BASE"; }
  done
  printf ' registered (%ss)\033[0m\n' "$waited"
}

if [ "$RESET" = 1 ]; then
  is_local || die "--reset only makes sense against a local server (BASE is $BASE)"
  bold "--reset / wiping the graph"
  stop_server
  rm -f "$REPO/.jac/data/main.db" "$REPO/.jac/data/main.db-shm" "$REPO/.jac/data/main.db-wal"
  dim "  removed .jac/data/main.db* - persistence in Jac is root-reachability, so that file IS the database"
fi

if [ "$SERVE" = 1 ]; then
  is_local || die "--serve only makes sense against a local server (BASE is $BASE)"
  [ "$RESET" = 1 ] || stop_server
  start_server
fi

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

# spawn <WalkerName> <json-body>  -> /tmp/bs_last.json, or die loudly
spawn() {
  local name="$1" body="$2"
  dim "\$ curl -s -X POST $BASE/walker/$name -d '$body'"
  curl -s -m 180 -X POST "$BASE/walker/$name" \
       -H 'Content-Type: application/json' \
       -d "$body" > /tmp/bs_last.json
  python3 - "$name" <<'PY' || exit 1
import json, sys
name = sys.argv[1]
try:
    d = json.load(open("/tmp/bs_last.json"))
except Exception:
    print("!! non-JSON response from %s (server not ready?):" % name)
    print(open("/tmp/bs_last.json").read()[:300]); sys.exit(1)
if not d.get("ok"):
    print("!! transport error on %s: %s" % (name, d.get("error"))); sys.exit(1)
# A walker that raises still returns ok:true with the traceback under data.error.
inner = (d.get("data") or {}).get("error")
if inner:
    print("!! %s raised inside the walker:\n%s" % (name, str(inner)[:900])); sys.exit(1)
if not (d.get("data") or {}).get("reports"):
    print("!! %s returned no reports" % name); sys.exit(1)
PY
}

# read the first report as `r` and run the given python body
show() { python3 -c "
import json
r = json.load(open('/tmp/bs_last.json'))['data']['reports'][0]
$1"; }

# ---------------------------------------------------------------------------
# 0 - the surface
# ---------------------------------------------------------------------------

if [ "$SERVE" = 1 ]; then wait_registered; fi

bold "0 / the API surface is the walkers, nothing hand-written"
curl -s -m 30 "$BASE/walkers" > /tmp/bs_walkers.json || die "cannot reach $BASE"
python3 -c "
import json,sys
try:
    d = json.load(open('/tmp/bs_walkers.json'))
except Exception:
    print('  cannot parse /walkers - is a server running at $BASE ?'); sys.exit(1)
print('  ' + ', '.join(d['data']['walkers']))
" || die "no server at $BASE - re-run with --serve (or --reset)"

rule
bold "1 / SeedPantry - the graph is the database, so seeding IS the schema"
if [ -s /tmp/bs_first_seed.json ]; then
  dim "\$ curl -s -X POST $BASE/walker/SeedPantry -d '{}'"
  cp /tmp/bs_first_seed.json /tmp/bs_last.json
  : > /tmp/bs_first_seed.json
else
  spawn SeedPantry '{}' || exit 1
fi
show '
print("  nodes created :", r["nodes_created"], "| already seeded:", r["already_seeded"])
print("  shelves       :", ", ".join(r["shelves"]))
print("  allergens     :", ", ".join(r["allergens"]))
'

bold "1b / SeedPantry AGAIN - idempotent, the counter is the proof"
spawn SeedPantry '{}' || exit 1
show '
print("  nodes created :", r["nodes_created"], "| already seeded:", r["already_seeded"])
'

rule
bold "2 / SeedDemo - Maria took a jar home on Saturday"
spawn SeedDemo '{}' || exit 1
show '
print("  nodes created :", r["created"], "| already seeded:", r["already_seeded"])
for h in r["handouts"]:
    print("  pickup %s <- %s  lot=%s  lang=%s" % (
        h["pickup_code"], h["product"], h["lot_code"] or "(unreadable)", h["preferred_language"]))
open("/tmp/bs_confirmed_id","w").write(r["confirmed_item_id"])
'
CONFIRMED_ID=$(cat /tmp/bs_confirmed_id)

rule
bold "3 / IntakeScan - byLLM reads the label, the walker walks the recall feed"
spawn IntakeScan "{\"photo_base64\":\"$PHOTO\",\"hint\":\"dented can from the back of the pallet\",\"shelf_name\":\"canned goods\"}" || exit 1
show '
print("  item          :", r["item"]["brand"], r["item"]["product"])
print("  verdict       :", r["verdict"], "| held on:", r["holding_shelf"], "-> destination", r["destination_shelf"])
print("  days past code:", r["days_past_code"], "| published window:", r["shelf_life_window"])
print("  reason        :", r["verdict_reason"])
print("  --- reasoning trace ---")
for t in r["trace"]:
    print("   [%-24s] %s" % (t["source"], t["detail"]))
open("/tmp/bs_scanned_id","w").write(r["item"]["id"])
open("/tmp/bs_llm_mode","w").write("mock" if r["using_mock_llm"] else "gemini")
if r["verdict"] != "review":
    print("  (note: expected verdict=review for a past-date shelf-stable can)")
'
SCANNED_ID=$(cat /tmp/bs_scanned_id)
echo
echo "  >> THE DATE-LABEL FIX: that can is past its best-by date and was NOT discarded."
echo "     Date labels are quality indicators, not safety dates. Backshelf routes it"
echo "     to REVIEW with the published shelf-life"
echo "     window and lets a human decide."

if [ "$(cat /tmp/bs_llm_mode)" = "mock" ]; then
  echo
  dim "  [LLM: MockLLM fallback - no Gemini key. Every code path runs, but the"
  dim "   label read is canned and does not depend on the photo. Paste a key into"
  dim "   the app's byLLM panel to make the next scan read a real label.]"
else
  dim "  [LLM: Gemini via byLLM - this is a real read of the photo you passed.]"
fi

rule
bold "4 / ClearItem on the clean scan - a human clears it onto the shelf"
spawn ClearItem "{\"item_id\":\"$SCANNED_ID\",\"shelf_name\":\"canned goods\"}" || exit 1
show '
print("  cleared:", r["cleared"], "| refused:", r["refused"], "| shelf:", r["shelf"])
'

rule
bold "5 / MatchNeeds - free-text constraints, filtered shelf, second language"
spawn MatchNeeds '{"pickup_code":"8830","constraints_text":"allergic to peanuts, vegetarian, diabetic","language":"Spanish"}' || exit 1
show '
print("  household found :", r["household_found"], "| language:", r["language"])
print("  avoids stored   :", r["avoids_stored"])
print("  avoids from text:", r["avoids_from_text"], "  <- byllm:resolve_constraints")
print("  union           :", r["avoiding"], "over", r["items_considered"], "items")
print("  framing         :", r["framing_note"])
print("  OFFERED (%d)" % len(r["offered"]))
for m in r["offered"]:
    print("    + %s %s" % (m["item"]["brand"], m["item"]["product"]))
    print("      %s" % m["explanation"][:200])
print("  WITHHELD (%d)" % len(r["withheld"]))
for w in r["withheld"]:
    print("    - %s %s  [%s] %s" % (w["brand"], w["product"], w["reason"], w["detail"]))
'
echo "  privacy check - a Household node holds no name, no address, no phone."
echo "    occurrences of \"notify_contact\" in the raw client response: $(grep -c notify_contact /tmp/bs_last.json)"

rule
bold "6 / RecallSweep - THE MONEY SHOT. Backwards, to the households."
spawn RecallSweep '{"live":false,"limit":100}' || exit 1
show '
print("  source :", r["source"], "|", r["source_note"])
print("  records:", r["records_seen"], "seen /", r["records_new"], "new /", r["records_updated"], "updated")
print("  items  :", r["items_scanned"], "scanned /", r["items_flagged"], "flagged")
print("  tiers  :", r["confirmed"], "confirmed /", r["possible"], "possible /", r["weak"], "weak")
print("  flags  :", r["flags_created"], "created /", r["flags_existing"], "already stood /", r["flags_held"], "held back")
print()
print("  === PULL FROM THE SHELF ===")
for x in r["pull_from_shelf"]:
    print("   [%s] %s %s  lot=%s" % (x["confidence"], x["brand"], x["product"], x["lot_code"] or "(unreadable)"))
    print("        %s (%s) - %s" % (x["recall_number"], x["classification"], x["recall_reason"]))
    print("        recall codes: %s" % x["recall_code_info"])
    print("        matched on  : %s" % x["matched_fields"])
    print("        action      : %s" % x["action"])
print()
print("  === INFORMATIONAL ONLY - brand matched, lot did not. Item stays available ===")
for x in r["informational"]:
    print("   [%s] %s %s  lot=%s" % (x["confidence"], x["brand"], x["product"], x["lot_code"] or "(unreadable)"))
    print("        %s" % x["action"])
print()
print("  === HOUSEHOLDS TO NOTIFY - reached by walking Received BACKWARDS ===")
if not r["notify_households"]:
    print("   (none - if this is empty on stage, re-run with --reset)")
for h in r["notify_households"]:
    print("   pickup code %s  [%s]  lang=%s  contact on file=%s  picked up %s" % (
        h["pickup_code"], h["confidence"], h["preferred_language"],
        h["contact_on_file"], h["picked_up_at"]))
    print("        %s" % h["message"])
print()
print("  === TRAVERSAL ===")
for t in r["trace"]:
    arrow = "<<<" if t["direction"] == "backward" else ">>>"
    print("   depth %d  %s %-8s %-11s %s" % (t["depth"], arrow, t["direction"], t["kind"], t["label"]))
'
echo
echo "  >> Those pickup codes are the point of the project. The backward hops in the"
echo "     traversal above are Item <-- Received -- Household. No existing pantry"
echo "     system can name them, because none of them keeps this graph."

if [ "$LIVE_FEED" = 1 ]; then
  rule
  bold "6b / RecallSweep against the LIVE openFDA feed (proves the network path)"
  dim "  the demo above uses data/openfda-snapshot.json because the live feed returns an"
  dim "  arbitrary page of ongoing recalls and does not reliably contain H-1125-2026."
  spawn RecallSweep '{"live":true,"limit":20}' || exit 1
  show '
print("  source :", r["source"], "|", r["source_note"])
print("  records:", r["records_seen"], "seen /", r["records_new"], "new")
'
fi

rule
bold "7 / ClearItem on the RECALLED item - the gate lives in the walker"
spawn ClearItem "{\"item_id\":\"$CONFIRMED_ID\",\"shelf_name\":\"canned goods\"}" || exit 1
show '
print("  cleared :", r["cleared"])
print("  refused :", r["refused"])
print("  blocking:", r["blocking_recalls"])
print("  reason  :", r["refusal_reason"])
'
echo "  There is no override parameter. The refusal is enforced in ClearItem itself,"
echo "  so it holds no matter what calls the endpoint - UI, curl, or another walker."

rule
bold "8 / MatchNeeds again - the same search, after the recall landed"
spawn MatchNeeds '{"pickup_code":"8830","constraints_text":"allergic to peanuts, vegetarian, diabetic","language":"Spanish"}' || exit 1
show '
print("  OFFERED (%d)" % len(r["offered"]))
for m in r["offered"]:
    print("    + %s %s" % (m["item"]["brand"], m["item"]["product"]))
print("  WITHHELD (%d)" % len(r["withheld"]))
for w in r["withheld"]:
    print("    - %s %s  [%s] %s" % (w["brand"], w["product"], w["reason"], w["detail"]))
'
echo "  Nothing about any label changed between step 5 and here. The graph changed."

rule
bold "Done. The client at $BASE/ drives these same six walkers."
if [ "$(cat /tmp/bs_llm_mode 2>/dev/null)" = "mock" ]; then
  echo "Ran on MockLLM. Paste a Gemini key into the app's byLLM panel for real extraction."
fi
