#!/usr/bin/env bash
#
# Backshelf - real-photo extraction eval (spec §10).
#
#   scripts/eval.sh assets/labels                    # a directory of label photos
#   scripts/eval.sh assets/labels --base http://localhost:8390
#   scripts/eval.sh assets/labels --truth assets/labels/truth.csv
#
# Photograph 20-30 real food labels, drop them in a directory, run this. Each
# photo is POSTed to IntakeScan exactly as the phone client would send it, and
# the summary reports what the label read produced and how the §4 routing rules
# landed.
#
# WHAT THIS DOES AND DOES NOT MEASURE
#
# Without a Gemini key the app runs on the MockLLM fallback, which returns the
# same canned label regardless of the photo. In that mode this script refuses to
# print an accuracy number, because there is nothing real to be accurate about.
# It prints the routing distribution and says plainly that the reads are mock.
# With a key in .env it reports per-photo reads and, if you supply a truth file,
# per-field accuracy.
#
# TRUTH FILE (optional, for accuracy). CSV, one row per photo, header required:
#
#   filename,brand,product,date_value,date_type,lot_code
#   can01.jpg,DEL MONTE,Cut Green Beans 14.5 oz,BEST BY 03/2024,best_by,
#
# Blank cells mean "not printed on this package" and are scored as a correct
# read only when the model also returns blank. Matching is case-insensitive and
# ignores punctuation and extra whitespace, because a volunteer comparing two
# strings would too.
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BASE="http://localhost:8390"
DIR=""
TRUTH=""
SHELF="review queue"

while [ $# -gt 0 ]; do
  case "$1" in
    --base)  BASE="$2"; shift ;;
    --truth) TRUTH="$2"; shift ;;
    --shelf) SHELF="$2"; shift ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
    *)  DIR="$1" ;;
  esac
  shift
done

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ -n "$DIR" ]  || die "give me a directory of label photos. scripts/eval.sh <dir> (try --help)"
[ -d "$DIR" ]  || die "not a directory: $DIR"
[ -z "$TRUTH" ] || [ -f "$TRUTH" ] || die "truth file not found: $TRUTH"

# Collect photos. macOS bash 3.2 has no mapfile, so read a NUL-delimited list.
PHOTOS=()
while IFS= read -r -d '' f; do PHOTOS+=("$f"); done < <(
  find "$DIR" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.webp' \) \
    -print0 | sort -z
)
[ "${#PHOTOS[@]}" -gt 0 ] || die "no .jpg/.jpeg/.png/.heic/.webp files in $DIR"

curl -s -m 20 "$BASE/walkers" | grep -q IntakeScan \
  || die "no Backshelf server at $BASE - start one with: scripts/demo.sh --reset"

# The pantry must exist before anything can be scanned onto it.
curl -s -m 60 -X POST "$BASE/walker/SeedPantry" -H 'Content-Type: application/json' -d '{}' > /dev/null

bold "Backshelf extraction eval"
echo "  photos : ${#PHOTOS[@]} from $DIR"
echo "  server : $BASE"
echo "  truth  : ${TRUTH:-(none - reads will be listed, not scored)}"
echo

RESULTS=/tmp/bs_eval_results.jsonl
: > "$RESULTS"

i=0
for f in "${PHOTOS[@]}"; do
  i=$((i + 1))
  printf '  [%2d/%2d] %-40s ' "$i" "${#PHOTOS[@]}" "$(basename "$f")"

  if ! base64 -i "$f" > /tmp/bs_eval_b64 2>/dev/null; then
    base64 < "$f" > /tmp/bs_eval_b64 2>/dev/null || { echo "base64 failed"; continue; }
  fi
  tr -d '\n' < /tmp/bs_eval_b64 > /tmp/bs_eval_b64_flat

  python3 - "$f" "$SHELF" > /tmp/bs_eval_body.json <<'PY'
import json, sys
body = {
    "photo_base64": open("/tmp/bs_eval_b64_flat").read(),
    "hint": "",
    "shelf_name": sys.argv[2],
}
json.dump(body, open("/tmp/bs_eval_body.json", "w"))
PY

  curl -s -m 180 -X POST "$BASE/walker/IntakeScan" \
       -H 'Content-Type: application/json' \
       --data-binary @/tmp/bs_eval_body.json > /tmp/bs_eval_resp.json

  python3 - "$f" "$RESULTS" <<'PY'
import json, os, sys
path, results = sys.argv[1], sys.argv[2]
row = {"filename": os.path.basename(path)}
try:
    d = json.load(open("/tmp/bs_eval_resp.json"))
except Exception:
    row["error"] = "non-JSON response"
    print("NON-JSON RESPONSE")
    open(results, "a").write(json.dumps(row) + "\n"); sys.exit(0)
inner = (d.get("data") or {}).get("error")
if not d.get("ok") or inner or not (d.get("data") or {}).get("reports"):
    row["error"] = str(d.get("error") or inner or "no reports")[:200]
    print("ERROR: " + row["error"][:60])
    open(results, "a").write(json.dumps(row) + "\n"); sys.exit(0)
r = d["data"]["reports"][0]
it = r["item"]
row.update({
    "brand": it["brand"], "product": it["product"], "category": it["category"],
    "date_value": it["date_value"], "date_type": it["date_type"],
    "lot_code": it["lot_code"], "confidence": it["extraction_confidence"],
    "legibility_note": it["legibility_note"], "packaging_note": it["packaging_note"],
    "verdict": r["verdict"], "days_past_code": r["days_past_code"],
    "recall_matches": len(r["recall_matches"]),
    "using_mock_llm": r["using_mock_llm"],
})
print("%-9s conf=%.2f  %s %s" % (row["verdict"], row["confidence"],
                                 row["brand"][:18], row["product"][:26]))
open(results, "a").write(json.dumps(row) + "\n")
PY
done

python3 - "$RESULTS" "${TRUTH:-}" <<'PY'
import json, re, sys, csv, os

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
truth_path = sys.argv[2] if len(sys.argv) > 2 else ""

ok = [r for r in rows if "error" not in r]
bad = [r for r in rows if "error" in r]
mock = any(r.get("using_mock_llm") for r in ok)

W = 70
print()
print("=" * W)
print("EXTRACTION EVAL - %d photos" % len(rows))
print("=" * W)

if bad:
    print("\n  %d photo(s) failed to scan:" % len(bad))
    for r in bad:
        print("    %-30s %s" % (r["filename"], r["error"][:60]))

if not ok:
    print("\n  Nothing scanned successfully. No summary to report.")
    sys.exit(1)

print("\nROUTING (§4 verdicts)")
print("-" * W)
verdicts = {}
for r in ok:
    verdicts[r["verdict"]] = verdicts.get(r["verdict"], 0) + 1
for v in ("keep", "review", "discard"):
    n = verdicts.get(v, 0)
    print("  %-9s %3d  %5.1f%%  %s" % (v, n, 100.0 * n / len(ok), "#" * int(30.0 * n / len(ok))))
for v, n in sorted(verdicts.items()):
    if v not in ("keep", "review", "discard"):
        print("  %-9s %3d  %5.1f%%" % (v, n, 100.0 * n / len(ok)))

past = [r for r in ok if (r.get("days_past_code") or 0) > 0]
disc = [r for r in past if r["verdict"] == "discard"]
print("\n  past their printed date : %d" % len(past))
print("  of those, discarded     : %d   <- v1 would have discarded all %d" % (len(disc), len(past)))

flagged = [r for r in ok if r.get("recall_matches", 0) > 0]
print("  carrying a recall flag  : %d" % len(flagged))

conf = [r["confidence"] for r in ok]
lowc = [r for r in ok if r["confidence"] < 0.7]
print("\nSELF-REPORTED EXTRACTION CONFIDENCE")
print("-" * W)
print("  mean %.2f   min %.2f   max %.2f   below 0.70: %d" %
      (sum(conf) / len(conf), min(conf), max(conf), len(lowc)))

print("\nPER-PHOTO READS")
print("-" * W)
print("  %-22s %-16s %-24s %-8s %s" % ("file", "brand", "product", "date", "lot"))
for r in ok:
    print("  %-22s %-16s %-24s %-8s %s" % (
        r["filename"][:22], (r["brand"] or "-")[:16], (r["product"] or "-")[:24],
        (r["date_value"] or "-")[:8], (r["lot_code"] or "-")[:12]))

# ---- accuracy, only when it means something -------------------------------

def norm(s):
    # Drop case and every non-alphanumeric, so "Kellogg's" == "Kelloggs" and
    # "BEST BY 03/2024" == "best by 032024". A volunteer holding the can would
    # call those the same read; only the characters carry information.
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())

print()
print("=" * W)
if mock:
    print("ACCURACY: NOT MEASURED")
    print("=" * W)
    print("""
  This run used the MockLLM fallback (no GEMINI_API_KEY), which returns the
  same canned label for every photo. The reads above are not reads of these
  photographs and an accuracy number computed from them would be fiction, so
  none is printed.

  What this run DID prove: %d photos went end to end through IntakeScan, the
  §4 routing rules fired, and %d recall comparison(s) ran against the graph.

  To measure extraction for real: paste a Gemini key into the running app's
  byLLM panel, then run this script again. No restart is needed.""" % (len(ok), sum(r.get("recall_matches", 0) for r in ok)))
elif not truth_path:
    print("ACCURACY: NOT MEASURED (no truth file)")
    print("=" * W)
    print("""
  These are real Gemini reads of real photographs. To score them, write down
  what is actually printed on each package and pass it with --truth:

      filename,brand,product,date_value,date_type,lot_code

  Reporting accuracy without a ground truth would be guessing.""")
else:
    truth = {}
    with open(truth_path, newline="") as fh:
        for t in csv.DictReader(fh):
            truth[t["filename"].strip()] = t
    fields = ["brand", "product", "date_value", "date_type", "lot_code"]
    scored = [r for r in ok if r["filename"] in truth]
    missing = [r["filename"] for r in ok if r["filename"] not in truth]
    print("ACCURACY - %d of %d photos have ground truth" % (len(scored), len(ok)))
    print("=" * W)
    if missing:
        print("  not in truth file: " + ", ".join(missing[:8]))
    if not scored:
        print("  nothing to score.")
    else:
        print("\n  %-12s %8s %8s" % ("field", "correct", "rate"))
        totals = {}
        for f in fields:
            hits = sum(1 for r in scored if norm(r.get(f)) == norm(truth[r["filename"]].get(f)))
            totals[f] = hits
            print("  %-12s %5d/%-3d %7.1f%%" % (f, hits, len(scored), 100.0 * hits / len(scored)))
        allf = sum(totals.values())
        print("  %-12s %5d/%-3d %7.1f%%" % ("OVERALL", allf, len(scored) * len(fields),
                                            100.0 * allf / (len(scored) * len(fields))))
        perfect = sum(1 for r in scored
                      if all(norm(r.get(f)) == norm(truth[r["filename"]].get(f)) for f in fields))
        print("\n  every field correct on %d/%d photos (%.1f%%)" %
              (perfect, len(scored), 100.0 * perfect / len(scored)))
        print("\n  MISSES")
        for r in scored:
            wrong = [f for f in fields if norm(r.get(f)) != norm(truth[r["filename"]].get(f))]
            if wrong:
                print("    %-22s %s" % (r["filename"][:22], ", ".join(wrong)))
                for f in wrong:
                    print("        %-11s read %-28r truth %r" %
                          (f, (r.get(f) or "")[:28], (truth[r["filename"]].get(f) or "")[:28]))

print("\n  raw per-photo JSON: %s" % sys.argv[1])
PY
