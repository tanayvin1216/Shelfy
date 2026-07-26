#!/usr/bin/env bash
#
# Backshelf - replay the whole demo against a running server.
#
#   ./.venv/bin/jac start main.jac --port 8390 < /dev/null &   # wait for "Server ready"
#   scripts/demo.sh                                            # default http://localhost:8390
#   scripts/demo.sh https://backshelf.up.railway.app           # or a deployed URL
#
# Every step below is one `POST /walker/<Name>`. There is no other API: the
# walkers ARE the endpoints, generated from the walker declarations.
#
# Note on step 6: the live openFDA query returns an arbitrary 100 of several
# thousand ongoing recalls and does NOT reliably include H-1125-2026, the
# Class I peanut recall the demo is built on. The cached snapshot in
# data/openfda-snapshot.json does. `live=false` is therefore the stage setting;
# step 6b proves the live path works too.
#
set -uo pipefail

BASE="${1:-http://localhost:8390}"
JQ="python3 -c"

# A 1x1 PNG. Under MockLLM the pixels do not matter; swap in a real photo with
#   BACKSHELF_PHOTO=$(base64 -i can.jpg | tr -d '\n') scripts/demo.sh
PHOTO="${BACKSHELF_PHOTO:-iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==}"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

# spawn <WalkerName> <json-body>  -> writes the raw response to /tmp/bs_last.json
spawn() {
  local name="$1" body="$2"
  printf '\033[2m$ curl -s -X POST %s/walker/%s -d %s\033[0m\n' "$BASE" "$name" "'$body'"
  curl -s -X POST "$BASE/walker/$name" \
       -H 'Content-Type: application/json' \
       -d "$body" > /tmp/bs_last.json
  if ! python3 -c 'import json,sys; json.load(open("/tmp/bs_last.json"))' 2>/dev/null; then
    echo "!! non-JSON response (server not ready?):"; head -c 300 /tmp/bs_last.json; echo; exit 1
  fi
  if [ "$(python3 -c 'import json;print(json.load(open("/tmp/bs_last.json"))["ok"])')" != "True" ]; then
    echo "!! walker error:"; cat /tmp/bs_last.json; exit 1
  fi
}

show() { python3 -c "$1"; }

bold "0 / the API surface is the walkers, nothing hand-written"
curl -s "$BASE/walkers" > /tmp/bs_walkers.json
show '
import json
print("  " + ", ".join(json.load(open("/tmp/bs_walkers.json"))["data"]["walkers"]))
'

rule
bold "1 / SeedPantry - the graph is the database, so seeding IS the schema"
spawn SeedPantry '{}'
show '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  nodes created :", r["nodes_created"], "| already seeded:", r["already_seeded"])
print("  shelves       :", ", ".join(r["shelves"]))
print("  allergens     :", ", ".join(r["allergens"]))
'

bold "1b / SeedPantry AGAIN - idempotent, the counter is the proof"
spawn SeedPantry '{}'
show '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  nodes created :", r["nodes_created"], "| already seeded:", r["already_seeded"])
'

rule
bold "2 / SeedDemo - Maria took a jar home on Saturday"
spawn SeedDemo '{}'
python3 -c '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  nodes created :", r["created"], "| already seeded:", r["already_seeded"])
for h in r["handouts"]:
    print("  pickup %s <- %s  lot=%s  lang=%s" % (h["pickup_code"], h["product"], h["lot_code"] or "(unreadable)", h["preferred_language"]))
open("/tmp/bs_confirmed_id","w").write(r["confirmed_item_id"])
'
CONFIRMED_ID=$(cat /tmp/bs_confirmed_id)

rule
bold "3 / IntakeScan - byLLM reads the label, the walker walks the recall feed"
spawn IntakeScan "{\"photo_base64\":\"$PHOTO\",\"hint\":\"dented can from the back of the pallet\",\"shelf_name\":\"canned goods\"}"
python3 -c '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  item          :", r["item"]["brand"], r["item"]["product"])
print("  verdict       :", r["verdict"], "| held on:", r["holding_shelf"], "-> destination", r["destination_shelf"])
print("  days past code:", r["days_past_code"], "| published window:", r["shelf_life_window"])
print("  reason        :", r["verdict_reason"])
print("  --- reasoning trace ---")
for t in r["trace"]:
    print("   [%-24s] %s" % (t["source"], t["detail"]))
open("/tmp/bs_scanned_id","w").write(r["item"]["id"])
'
SCANNED_ID=$(cat /tmp/bs_scanned_id)
echo "  ^ past its best-by date and NOT discarded. v1 of this project threw this away."

rule
bold "4 / ClearItem on the clean scan - a human clears it onto the shelf"
spawn ClearItem "{\"item_id\":\"$SCANNED_ID\",\"shelf_name\":\"canned goods\"}"
show '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  cleared:", r["cleared"], "| refused:", r["refused"], "| shelf:", r["shelf"])
'

rule
bold "5 / MatchNeeds - free-text constraints, filtered shelf, second language"
spawn MatchNeeds '{"pickup_code":"8830","constraints_text":"allergic to peanuts, diabetic","language":"Spanish"}'
show '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  household found :", r["household_found"], "| language:", r["language"])
print("  avoids stored   :", r["avoids_stored"])
print("  avoids from text:", r["avoids_from_text"])
print("  union           :", r["avoiding"], "over", r["items_considered"], "items")
print("  OFFERED (%d)" % len(r["offered"]))
for m in r["offered"]:
    print("    + %s %s" % (m["item"]["brand"], m["item"]["product"]))
    print("      %s" % m["explanation"][:160])
print("  WITHHELD (%d)" % len(r["withheld"]))
for w in r["withheld"]:
    print("    - %s %s  [%s] %s" % (w["brand"], w["product"], w["reason"], w["detail"]))
'
echo "  privacy check - notify_contact never crosses the wire:"
echo "    occurrences of \"notify_contact\" in the raw response: $(grep -c notify_contact /tmp/bs_last.json)"

rule
bold "6 / RecallSweep - THE MONEY SHOT. Backwards, to the households."
spawn RecallSweep '{"live":false,"limit":100}'
show '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  source :", r["source"], "|", r["source_note"])
print("  records:", r["records_seen"], "seen /", r["records_new"], "new /", r["records_updated"], "updated")
print("  items  :", r["items_scanned"], "scanned /", r["items_flagged"], "flagged")
print("  tiers  :", r["confirmed"], "confirmed /", r["possible"], "possible /", r["weak"], "weak")
print()
print("  === PULL FROM THE SHELF ===")
for x in r["pull_from_shelf"]:
    print("   [%s] %s %s  lot=%s" % (x["confidence"], x["brand"], x["product"], x["lot_code"] or "(unreadable)"))
    print("        %s (%s) - %s" % (x["recall_number"], x["classification"], x["recall_reason"]))
    print("        recall codes: %s   matched on: %s" % (x["recall_code_info"], x["matched_fields"]))
print()
print("  === INFORMATIONAL ONLY - v1 would have condemned these ===")
for x in r["informational"]:
    print("   [%s] %s %s  lot=%s  -> %s" % (x["confidence"], x["brand"], x["product"], x["lot_code"], x["action"]))
print()
print("  === HOUSEHOLDS TO NOTIFY - reached by walking Received BACKWARDS ===")
for h in r["notify_households"]:
    print("   pickup code %s  [%s]  lang=%s  contact=%s" % (h["pickup_code"], h["confidence"], h["preferred_language"], h["notify_contact"] or "(none on file)"))
    print("        %s" % h["message"])
print()
print("  === TRAVERSAL ===")
for t in r["trace"]:
    arrow = "<<<" if t["direction"] == "backward" else ">>>"
    print("   depth %d  %s %-8s %-10s %s" % (t["depth"], arrow, t["direction"], t["kind"], t["label"]))
'
echo "  No existing pantry system can name those pickup codes."

rule
bold "6b / RecallSweep against the LIVE openFDA feed (network path)"
spawn RecallSweep '{"live":true,"limit":20}'
show '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  source :", r["source"], "|", r["source_note"])
print("  records:", r["records_seen"], "seen /", r["records_new"], "new")
'

rule
bold "7 / ClearItem on the RECALLED item - the gate is in the walker"
spawn ClearItem "{\"item_id\":\"$CONFIRMED_ID\",\"shelf_name\":\"canned goods\"}"
show '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  cleared :", r["cleared"])
print("  refused :", r["refused"])
print("  blocking:", r["blocking_recalls"])
print("  reason  :", r["refusal_reason"])
'
echo "  There is no override parameter for a CONFIRMED recall. Not in the UI - in the walker."

rule
bold "8 / MatchNeeds again - the same search, after the recall landed"
spawn MatchNeeds '{"pickup_code":"8830","constraints_text":"allergic to peanuts, diabetic","language":"Spanish"}'
show '
import json
r=json.load(open("/tmp/bs_last.json"))["data"]["reports"][0]
print("  OFFERED (%d)" % len(r["offered"]))
for m in r["offered"]:
    print("    + %s %s" % (m["item"]["brand"], m["item"]["product"]))
print("  WITHHELD (%d)" % len(r["withheld"]))
for w in r["withheld"]:
    print("    - %s %s  [%s] %s" % (w["brand"], w["product"], w["reason"], w["detail"]))
'
echo "  Step 5 offered those jars. Nothing about the label changed - the graph did."

rule
bold "Done. The client at $BASE/ drives the same six walkers."
