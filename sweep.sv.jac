"""Backshelf - RecallSweep (spec section 6).

The retroactive recall sweep. This is the part that does not exist anywhere
else: a recall announced on Tuesday is matched against the can that went out
the door on Saturday, and the sweep walks BACKWARD along the distribution
edges to name the households that took it home.

    RecallFeed ──(backward)──> Pantry ──> Shelf ──Stocks──> Item
                                  │                          │
                                  └──> Household             │
                                          └──Received──> Item
                                                          │
                                          (BACKWARD along Received)
                                                          ↓
                                                      Household

Every step is a `visit`. There is no join table, no query planner and no
`SELECT ... JOIN households ON ...` - the distribution history IS the graph,
so walking it backwards is one line: `visit [here <-:Received:<-]`.

Two guards this traversal needs, both worked out in
`docs/spikes/walkers/05_recall_sweep.jac` before this file existed:

  1. a `resolved` flag on the Root entry, because a backward sweep can arrive
     back at the node it started from and refire the base ability;
  2. a `seen` list of jids, because a household that received the same item
     twice - or an item sitting on a shelf AND in a household's history -
     would otherwise be counted twice.

Deliberately LLM-free. Spec section 4 says a recall verdict may reason only
over records actually retrieved from openFDA plus the scanned label, and must
cite the recall number. Every sentence this walker emits is either an openFDA
field verbatim or a template around one, so it structurally cannot invent a
recall. It also means the sweep runs at full speed with no API key.
"""

import hashlib;
import json;
import os;
import from urllib.request { urlopen }

import from graph {
    Item, Household, Pantry, Shelf, RecallFeed, RecallRecord,
    Stocks, Received, FlaggedBy, Lists,
    CONFIRMED, POSSIBLE, WEAK,
    _get_recall_feed, _now, _norm
}

# ---------------------------------------------------------------------------
# Source of truth: openFDA, with the venue-wifi fallback
# ---------------------------------------------------------------------------

"""Spec section 8 says status:"On-Going". The live API value is "Ongoing" -
"On-Going" returns zero records. Verified against the live endpoint."""
glob OPENFDA_STATUS: str = "Ongoing";

glob OPENFDA_URL: str =
    "https://api.fda.gov/food/enforcement.json"
    + "?search=status:%22Ongoing%22&limit=";

"""100 real ongoing recalls, pulled from the live endpoint and committed so the
demo does not depend on conference wifi."""
glob SNAPSHOT_PATH: str = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "data", "openfda-snapshot.json"
);

glob LIVE_TIMEOUT_S: float = 3.0;

# ---------------------------------------------------------------------------
# Report shapes - walkers report typed objs, never hand-built dicts
# ---------------------------------------------------------------------------

obj SweepHop {
    """One step of the traversal, kept so the demo can SHOW the walk rather
    than assert it happened. `direction` is the interesting column: the hops
    marked "backward" are the ones no pantry system has."""
    has depth: int,
        kind: str,
        direction: str,
        label: str,
        ref_id: str;
}

obj FlaggedItem {
    has item_id: str,
        brand: str,
        product: str,
        lot_code: str,
        shelf: str,
        on_shelf: bool,
        verdict: str,
        confidence: str,
        matched_fields: str,
        recall_number: str,
        classification: str,
        recall_reason: str,
        recall_code_info: str,
        action: str;
}

obj NotifyHousehold {
    """The call-down list a volunteer works from. Addressed by anonymous pickup
    code only - no name, no address, no phone.

    What this obj deliberately does NOT carry, and why (spec section 4,
    "Privacy" - the privacy design is a feature we demo, not an oversight):

      `notify_contact`  The household's self-supplied phone or email. It is the
        one field on `Household` that can identify a person, it is opt-in, and
        it was supplied for ONE purpose - so that the pantry can reach them
        about a recall. Publishing it in a walker report inverts that consent.
        A volunteer does not need the value to work the list either: they need
        to know whether the household can be phoned at all, which is what
        `contact_on_file` says. The value itself stays on the Household node,
        where whatever actually sends the notice can read it, and never crosses
        the wire.

      second-precision pickup times  `Received.timestamp` is stored to the
        second. A published list of {pickup code, item, 10:20:00} is a
        re-identification key: anyone who watched the line on that Saturday can
        tie a real face to an anonymous code and to what that person took home.
        Recall triage only ever needs "how long has this been in someone's
        cupboard", so `picked_up_at` is reported as the calendar DAY.

    Everything left is either anonymous by design (`pickup_code`, section 4) or
    is a fact about the recalled food rather than about a person.
    """
    has pickup_code: str,
        contact_on_file: bool,
        preferred_language: str,
        picked_up_at: str,
        item_id: str,
        brand: str,
        product: str,
        confidence: str,
        recall_number: str,
        classification: str,
        message: str;
}

obj SweepReport {
    has source: str,
        source_note: str,
        feed_id: str,
        synced_at: str,
        records_seen: int,
        records_new: int,
        records_updated: int,
        items_scanned: int,
        items_flagged: int,
        flags_created: int,
        flags_existing: int,
        confirmed: int,
        possible: int,
        weak: int,
        pull_from_shelf: list[FlaggedItem],
        informational: list[FlaggedItem],
        notify_households: list[NotifyHousehold],
        trace: list[SweepHop],
        # Flags the sweep re-graded LOWER and then refused to write, because the
        # evidence behind the original grade had not changed. See `_may_rewrite`.
        flags_held: int = 0;
}

obj MatchCall {
    has matched: bool,
        confidence: str,
        matched_fields: str;
}

obj FetchResult {
    has source: str,
        note: str,
        rows: list[dict[str, any]];
}

# ---------------------------------------------------------------------------
# Loading recalls
# ---------------------------------------------------------------------------

"""Untyped-boundary helper: json rows arrive as `any`, so every field read is
narrowed here once instead of at forty call sites."""
def _s(row: dict[str, any], key: str) -> str {
    value = row.get(key, "");
    if isinstance(value, str) {
        return value;
    }
    return str(value);
}

def _rows_from(payload: any) -> list[dict[str, any]] {
    out: list[dict[str, any]] = [];
    if not isinstance(payload, dict) {
        return out;
    }
    rows = payload.get("results", []);
    if not isinstance(rows, list) {
        return out;
    }
    for row in rows {
        if isinstance(row, dict) {
            out.append(row);
        }
    }
    return out;
}

"""Live openFDA, hard-capped at `timeout_s` seconds. Any failure at all -
DNS, TLS, timeout, malformed body - returns empty so the caller falls back."""
def _fetch_live(limit: int, timeout_s: float) -> FetchResult {
    try {
        response = urlopen(OPENFDA_URL + str(limit), timeout=timeout_s);
        raw = response.read();
        response.close();
        rows = _rows_from(json.loads(raw as bytes));
        if len(rows) == 0 {
            return FetchResult(source="", note="openFDA returned no rows", rows=[]);
        }
        return FetchResult(
            source="openfda-live",
            note=f"live openFDA, {len(rows)} ongoing recalls",
            rows=rows
        );
    } except Exception as err {
        return FetchResult(
            source="",
            note=f"live openFDA unreachable ({str(err)[:80]})",
            rows=[]
        );
    }
}

def _read_snapshot(limit: int) -> FetchResult {
    try {
        with open(SNAPSHOT_PATH, "r") as handle {
            rows = _rows_from(json.loads(handle.read()));
        }
        return FetchResult(
            source="cached-snapshot",
            note=f"cached snapshot, {len(rows[:limit])} ongoing recalls",
            rows=rows[:limit]
        );
    } except Exception as err {
        return FetchResult(
            source="none",
            note=f"snapshot unreadable ({str(err)[:80]})",
            rows=[]
        );
    }
}

"""Live first, snapshot on any failure. A dead network must never block
intake or the sweep - spec section 8."""
def _load_recalls(live: bool, limit: int, timeout_s: float) -> FetchResult {
    if live {
        fetched = _fetch_live(limit, timeout_s);
        if len(fetched.rows) > 0 {
            return fetched;
        }
        fallback = _read_snapshot(limit);
        return FetchResult(
            source=fallback.source,
            note=f"{fetched.note}; fell back to {fallback.note}",
            rows=fallback.rows
        );
    }
    return _read_snapshot(limit);
}

def _is_active(row: dict[str, any]) -> bool {
    return _norm(_s(row, "status")) == _norm(OPENFDA_STATUS);
}

# ---------------------------------------------------------------------------
# Matching (spec section 4) - lot-aware, never brand-alone
# ---------------------------------------------------------------------------

"""Units, legal suffixes and packaging words carry no identifying signal, so
they are stripped before two product descriptions are compared. Without this,
'9 oz' alone would tie a can of beans to a bag of raisins."""
glob NOISE_WORDS: list[str] = [
    "oz", "lb", "lbs", "ounce", "ounces", "pound", "pounds", "gram", "grams",
    "count", "ct", "pack", "packs", "case", "cases", "box", "boxes", "bag",
    "bags", "can", "cans", "jar", "jars", "bottle", "bottles", "net", "wt",
    "size", "inc", "llc", "ltd", "co", "corp", "company", "brand", "the",
    "and", "with", "for", "all", "new", "fl"
];

"""Words that appear around a lot code rather than being one.

This vocabulary and the functions below are the single lot-code matcher for the
whole product: `intake.sv.jac` imports from here rather than keeping its own
copy, because an item that reads CONFIRMED at the intake desk and WEAK during
the sweep - or the reverse - is a silent safety bug."""
glob LOT_LABEL_WORDS: list[str] = [
    "lot", "lots", "batch", "batches", "code", "codes", "number", "numbers",
    "no", "bb", "best", "by", "before", "use", "used", "using", "exp",
    "expires", "expiration", "expiry", "date", "dates", "mfg", "manufacture",
    "manufactured", "sell", "sold", "est", "ubd", "item",
    "if", "and", "the", "of", "all",
    # "Lot Code(s):" tokenises to LOT / CODE / S, and that stray S would
    # otherwise glue itself to the front of the code that follows it.
    "s",
    # The product-identifier labels below are also run boundaries.
    "upc", "upcs", "gtin", "gtins", "ean", "sku", "skus", "barcode",
    "barcodes", "plu", "bar"
];

"""Labels whose digits identify a PRODUCT LINE, not a batch.

A UPC is printed on every unit a firm has ever made, so a UPC is the exact
opposite of a lot code: matching on one condemns the entire product line.
openFDA `code_info` mixes the two
freely - H-1146-2026 reads `UPC: 041262288874 ... Lot Codes (expiration date):
AUG0326, AUG1026, AUG1726` - so a volunteer who transcribes the barcode into
the lot field would otherwise read CONFIRMED against every bag Wise ever
packed.

Digits following one of these labels are therefore dropped, not collected. The
suppression ends at the next label word or the next break character, so the
`AUG0326` list later in that same field is still read normally."""
glob PRODUCT_ID_LABEL_WORDS: list[str] = [
    "upc", "upcs", "gtin", "gtins", "ean", "sku", "skus", "barcode",
    "barcodes", "plu", "bar"
];

"""A comma, a semicolon or a line break genuinely ends one lot code and starts
the next. Every OTHER separator - space, dash, slash, dot, colon - is cosmetic
printing, and treating it as a boundary is what made `AUG 03 26` read as a
different batch from `AUG0326`."""
glob LOT_BREAK_CHARS: str = ",;\n\r";

def _alnum_words(text: str) -> list[str] {
    out: list[str] = [];
    current = "";
    for character in text.lower() {
        if character.isalnum() {
            current += character;
        } else {
            if current {
                out.append(current);
            }
            current = "";
        }
    }
    if current {
        out.append(current);
    }
    return out;
}

def _signal_words(text: str) -> list[str] {
    out: list[str] = [];
    for word in _alnum_words(text) {
        if len(word) >= 3 and word not in NOISE_WORDS and word not in out {
            out.append(word);
        }
    }
    return out;
}

"""Does this look like a printed lot code rather than a stray word or a year?

A code always carries a digit. Beyond that the bar is deliberately different
for the two shapes: a mixed letter/digit string is distinctive at 4 characters
(`L4409`, `AUG0326`), while a bare number needs 5 before it stops colliding
with the years and quantities that share the same field ('2027', '9 oz')."""
def _is_code_like(token: str) -> bool {
    has_digit = False;
    has_letter = False;
    for character in token {
        if character.isdigit() {
            has_digit = True;
        } elif character.isalpha() {
            has_letter = True;
        }
    }
    if not has_digit {
        return False;
    }
    if has_letter {
        return len(token) >= 4;
    }
    return len(token) >= 5;
}

"""The codes one uninterrupted run of words spells: the run glued back together,
plus each word that is code-like on its own.

Both are needed. `JUL 07 2027` is one code printed with spaces, so the glue is
what matches it; `- 408125075E14F2 - 708125076E14F2 -` is a dash-separated LIST,
so the individual words are what match it."""
def _lot_forms(run: list[str]) -> list[str] {
    forms: list[str] = [];
    if len(run) == 0 {
        return forms;
    }
    glued = "".join(run);
    if _is_code_like(glued) {
        forms.append(glued);
    }
    for token in run {
        if _is_code_like(token) and token not in forms {
            forms.append(token);
        }
    }
    return forms;
}

"""Read a free-text code field as the set of lot codes it actually names.

openFDA `code_info` is typed by a person at the recalling firm, so the same
code shows up as `AUG0326`, `AUG 03 26`, `Lot Code(s): 26J000059877-01` or
`Best If Used By: JUL 07 2027`. Spacing, dashes, slashes and case carry no
meaning and must not demote a real match to WEAK - a WEAK match leaves the jar
on the shelf and never names the household that took one home.

What DOES end a code: a break character, or a label word. Everything between
two of those is one code. Nothing here loosens the match itself: comparison is
still equality between whole codes, so a genuinely different batch still
differs and the item stays available (spec section 4, flaw 2).

What is DELIBERATELY NOT collected: a digit run introduced by a product-line
label (see PRODUCT_ID_LABEL_WORDS). `suppressed` carries that state across the
run that follows the label and is cleared by the next label word or break."""
def _lot_candidates(text: str) -> list[str] {
    out: list[str] = [];
    run: list[str] = [];
    token = "";
    suppressed = False;
    for character in text.upper() + "\n" {
        if character.isalnum() {
            token += character;
            continue;
        }
        ends_run = character in LOT_BREAK_CHARS;
        next_suppressed = suppressed;
        if token != "" {
            low = token.lower();
            if low in LOT_LABEL_WORDS {
                ends_run = True;
                # A product-line label opens a suppressed region; any other
                # label word closes one ("UPC: 123 Lot: 456" keeps 456).
                next_suppressed = low in PRODUCT_ID_LABEL_WORDS;
            } else {
                run.append(token);
            }
            token = "";
        }
        if character in LOT_BREAK_CHARS {
            next_suppressed = False;
        }
        if ends_run {
            # The run just closed belongs to the state it was collected under.
            if not suppressed {
                for form in _lot_forms(run) {
                    if form not in out {
                        out.append(form);
                    }
                }
            }
            run = [];
            suppressed = next_suppressed;
        }
    }
    return out;
}

def _shared(left: list[str], right: list[str]) -> list[str] {
    return [word for word in left if word in right];
}

def _compact(text: str) -> str {
    return "".join(_alnum_words(text));
}

"""A recall names the firm that recalled it, which is often NOT the brand on
the package - Western Mixers recalls a jar labelled FIRST STREET. So the
brand is checked against the firm AND the product description.

THE definition. `intake.sv.jac` has none of its own: for a while it kept a
parallel copy, the two drifted, and an item the desk graded CONFIRMED came back
from the sweep as WEAK - which un-blocked it and dropped the household that had
already taken one home. Brand alone never blocks anything (it caps out at WEAK),
so this is deliberately the union of every shape either copy accepted rather
than the intersection."""
def _brand_hit(brand: str, firm: str, description: str) -> bool {
    tight = _compact(brand);
    if len(tight) < 3 {
        return False;
    }
    # 1. The brand string appears whole inside the firm or the description
    #    ("WISE" inside "Wise Foods Inc"; "FIRST STREET" inside the description).
    firm_tight = _compact(firm);
    if len(firm_tight) >= 3 and (tight in firm_tight or firm_tight in tight) {
        return True;
    }
    description_tight = _compact(description);
    if len(description_tight) >= 3 and tight in description_tight {
        return True;
    }
    wanted = _signal_words(brand);
    if len(wanted) == 0 {
        return False;
    }
    # 2. Every distinctive word of the brand is somewhere in the recall.
    if len(_shared(wanted, _signal_words(firm) + _signal_words(description))) == len(wanted) {
        return True;
    }
    # 3. Two distinctive words shared with the firm name.
    return len(_shared(wanted, _signal_words(firm))) >= 2;
}

def _product_hit(product: str, description: str) -> list[str] {
    return _shared(_signal_words(product), _signal_words(description));
}

"""Does the item's product name describe the recalled product?

Two distinctive words in common, or - when the item's name only HAS one
distinctive word ('Raisins') - that one word. The single-word case is why this
is one function and not two: the sweep used to require two words flat, so a
one-word product that intake graded CONFIRMED was re-graded WEAK on the next
sweep. This is still nowhere near brand-only matching: CONFIRMED additionally
requires the lot code to match."""
def _product_matched(product: str, description: str) -> bool {
    words = _signal_words(product);
    if len(words) == 0 {
        return False;
    }
    overlap = _product_hit(product, description);
    if len(overlap) >= 2 {
        return True;
    }
    return len(words) == 1 and len(overlap) == 1;
}

"""Three-valued on purpose, and shared with the intake desk.

`match`    a code the item carries is one of the codes the recall names.
`differs`  both sides are legible and no code is common - positive evidence
           that THIS jar is not the recalled jar. This survives formatting:
           normalising away spaces
           and dashes never turns a different batch into a match.
`unknown`  one side names no code at all. Absence of evidence, so POSSIBLE -
           a human compares the printed code by hand."""
def _lot_state(item_lot: str, code_info: str) -> str {
    mine = _lot_candidates(item_lot);
    theirs = _lot_candidates(code_info);
    if len(mine) == 0 or len(theirs) == 0 {
        return "unknown";
    }
    for code in mine {
        if code in theirs {
            return "match";
        }
    }
    return "differs";
}

"""Spec section 4 confidence tiers, in one place.

  CONFIRMED  brand + product + lot code all match      -> block from the shelf
  POSSIBLE   brand + product, lot not compared         -> review, show the codes
  WEAK       brand only, or a lot code that differs    -> informational only

Nothing here ever returns discard. A recall match pulls an item for a human;
it does not throw food away on its own.
"""
def _classify(item: Item, record: RecallRecord) -> MatchCall {
    if not _brand_hit(item.brand, record.recalling_firm, record.product_description) {
        return MatchCall(matched=False, confidence="", matched_fields="");
    }

    if not _product_matched(item.product, record.product_description) {
        return MatchCall(
            matched=True,
            confidence=WEAK,
            matched_fields="brand only; product description does not match"
        );
    }

    shared_words = ", ".join(_product_hit(item.product, record.product_description));
    state = _lot_state(item.lot_code, record.code_info);

    if state == "match" {
        return MatchCall(
            matched=True,
            confidence=CONFIRMED,
            matched_fields=f"brand, product ({shared_words}), lot code {item.lot_code}"
        );
    }
    if state == "differs" {
        return MatchCall(
            matched=True,
            confidence=WEAK,
            matched_fields=(
                f"brand, product ({shared_words}); lot code {item.lot_code} is not in "
                + "the recalled code list, so this unit is most likely not covered"
            )
        );
    }
    return MatchCall(
        matched=True,
        confidence=POSSIBLE,
        matched_fields=(
            f"brand, product ({shared_words}); lot code not compared - "
            + ("none was legible on this item" if not item.lot_code
               else "the recall lists no code information")
        )
    );
}

# ---------------------------------------------------------------------------
# Flag durability - a grade a human was told to act on is not silently undone
# ---------------------------------------------------------------------------

"""Severity order. Anything unrecognised ranks 0 so it can only ever be
raised, never used to lower a real grade."""
glob TIER_ORDER: list[str] = [WEAK, POSSIBLE, CONFIRMED];

def _tier_rank(confidence: str) -> int {
    if confidence in TIER_ORDER {
        return TIER_ORDER.index(confidence) + 1;
    }
    return 0;
}

"""A fingerprint of the two facts a tier is derived from: the codes the item
carries and the codes the recall names. If it is unchanged, a re-run that
produces a different tier is a code disagreement, not new information."""
def _evidence_id(item_lot: str, code_info: str) -> str {
    basis = ",".join(_lot_candidates(item_lot)) + "#" + ",".join(_lot_candidates(code_info));
    return hashlib.sha1(basis.encode("utf-8")).hexdigest()[:10];
}

glob EVIDENCE_OPEN: str = " [ev:";

def _stamp(matched_fields: str, evidence: str) -> str {
    return matched_fields + EVIDENCE_OPEN + evidence + "]";
}

def _evidence_of(matched_fields: str) -> str {
    if EVIDENCE_OPEN not in matched_fields {
        return "";
    }
    return matched_fields.split(EVIDENCE_OPEN)[-1].split("]")[0];
}

"""May a re-evaluation overwrite an existing FlaggedBy edge?

Upgrades always. Downgrades ONLY when the evidence fingerprint on the edge
differs from the one just computed - that is a volunteer correcting a smudged
lot code, or openFDA republishing `code_info`, and it must still be able to
release an item that genuinely is not covered.

A downgrade with the SAME fingerprint means two code paths disagreed. Spec
section 4 gives a human control of the shelf: once someone has been told to
hold a jar, a background re-run must not quietly hand it back, un-clear the
CONFIRMED gate in `ClearItem`, and drop the household that already took one
home from `notify_households`. So that write is refused and counted."""
def _may_rewrite(
    old_confidence: str, old_fields: str, new_confidence: str, new_evidence: str
) -> bool {
    if _tier_rank(new_confidence) >= _tier_rank(old_confidence) {
        return True;
    }
    old_evidence = _evidence_of(old_fields);
    return old_evidence != "" and old_evidence != new_evidence;
}

def _action_for(confidence: str) -> str {
    if confidence == CONFIRMED {
        return "Pull from the shelf now. Do not distribute.";
    }
    if confidence == POSSIBLE {
        return "Move to the review queue and compare the printed code against the recall code list.";
    }
    return "No action. Same brand, different product or different lot - the item stays available.";
}

"""Drop the clock off an ISO pickup timestamp. Second-precision pickup times
in an anonymous report are a re-identification key (see NotifyHousehold); the
day is all recall triage needs."""
def _pickup_day(timestamp: str) -> str {
    return timestamp.split("T")[0];
}

"""The household-facing sentence. Every fact in it comes from the openFDA
record; the recall number is always cited so it can be looked up."""
def _notice(record: RecallRecord, item: Item, confidence: str) -> str {
    what = (item.brand + " " + item.product).strip();
    opening = (
        f"An item you picked up, {what}, is covered by FDA recall "
        + f"{record.recall_number}"
    );
    if record.classification {
        opening += f" ({record.classification})";
    }
    if confidence == POSSIBLE {
        opening = (
            f"An item you picked up, {what}, may be covered by FDA recall "
            + f"{record.recall_number}"
            + (f" ({record.classification})" if record.classification else "")
        );
    }
    reason = record.reason if record.reason else "no reason was published";
    tail = f". The recall reason given by the FDA is: {reason}";
    if record.code_info {
        tail += f" The recalled codes are: {record.code_info}.";
    }
    if confidence == POSSIBLE {
        tail += (
            " We could not read the code on the package we gave you, so please compare "
            + "the code printed on yours against that list."
        );
    }
    return opening + tail + " Please do not eat it, and bring it back to the pantry.";
}

# ---------------------------------------------------------------------------
# RecallSweep
# ---------------------------------------------------------------------------

walker:pub RecallSweep {
    """Sync active recalls, flag matching items, then walk backward along the
    distribution edges to the households that already took them home.

    Spawn it on the RecallFeed (`_jac_spawn_node`) or on root - the Root entry
    resolves the feed either way.

    Idempotent: re-running updates the RecallRecord nodes in place, updates
    existing FlaggedBy edges instead of stacking duplicates, and reports the
    same two lists. `flags_created` vs `flags_existing` is the proof.

    Why this is `:pub` even though it is a staff operation. Spec section 1
    reserves `:pub` for client-facing search, and a sweep is volunteer work -
    but `:priv` in jaclang 0.16.7 gives each caller an ISOLATED root, which
    would hand the sweep an empty pantry and break it outright rather than
    protect it. There is no per-request auth tier to hide behind, so the
    protection is placed where it actually holds: nothing this walker reports
    identifies a person. Pickup codes are anonymous by design (section 4) and
    naming them is the point of the sweep; the two fields that were NOT
    anonymous - the opt-in contact method and the second-precision pickup time
    - are redacted in `NotifyHousehold`, which documents each one. Read that
    obj before adding a field here: the report shape is the access control.
    """

    has live: bool = True;
    has limit: int = 100;
    has timeout_s: float = LIVE_TIMEOUT_S;

    # --- guards ported from docs/spikes/walkers/05_recall_sweep.jac ---
    has resolved: bool = False;
    has synced: bool = False;
    has seen_items: list[str] = [];
    has expanded_households: list[str] = [];
    has notified_keys: list[str] = [];

    # --- accumulators ---
    has records: list[RecallRecord] = [];
    has source: str = "";
    has source_note: str = "";
    has records_seen: int = 0;
    has records_new: int = 0;
    has records_updated: int = 0;
    has items_scanned: int = 0;
    has flags_created: int = 0;
    has flags_existing: int = 0;
    has flags_held: int = 0;
    has flagged_item_ids: list[str] = [];
    has pull_from_shelf: list[FlaggedItem] = [];
    has informational: list[FlaggedItem] = [];
    has notify_households: list[NotifyHousehold] = [];
    has trace: list[SweepHop] = [];
    has synced_at: str = "";
    has feed_id: str = "";

    has reports: list[SweepReport] = [];

    def hop(depth: int, kind: str, direction: str, label: str, ref: str) {
        self.trace.append(
            SweepHop(depth=depth, kind=kind, direction=direction, label=label, ref_id=ref)
        );
    }

    # -- Root: resolve the feed. `resolved` stops a re-entry from refiring it.
    can enter_root with Root entry {
        if self.resolved {
            skip;
        }
        self.resolved = True;
        visit [_get_recall_feed()];
    }

    # -- Step 1: pull active recalls, upsert RecallRecord nodes.
    can sync with RecallFeed entry {
        if self.synced {
            skip;
        }
        self.synced = True;
        self.feed_id = jid(here);
        self.hop(0, "RecallFeed", "spawn", "openFDA feed", jid(here));

        fetched = _load_recalls(self.live, self.limit, self.timeout_s);
        self.source = fetched.source;
        self.source_note = fetched.note;

        existing: dict[str, RecallRecord] = {};
        for known in [here ->:Lists:->] {
            existing[known.recall_number] = known;
        }

        for row in fetched.rows {
            if not _is_active(row) {
                continue;
            }
            number = _s(row, "recall_number");
            if not number {
                continue;
            }
            self.records_seen += 1;

            record = existing.get(number, None);
            if record is None {
                record = RecallRecord(recall_number=number);
                here +>:Lists:+> record;
                existing[number] = record;
                self.records_new += 1;
            } else {
                self.records_updated += 1;
            }

            record.recalling_firm = _s(row, "recalling_firm");
            record.product_description = _s(row, "product_description");
            record.reason = _s(row, "reason_for_recall");
            record.classification = _s(row, "classification");
            record.code_info = _s(row, "code_info");
            record.distribution_pattern = _s(row, "distribution_pattern");
            record.status = _s(row, "status");
            record.report_date = _s(row, "report_date");
            self.records.append(record);
        }

        self.synced_at = _now();
        here.last_synced = self.synced_at;

        # BACKWARD: the feed hangs off the Pantry, so the only way out is up.
        visit [here <--];
    }

    can span_pantry with Pantry entry {
        self.hop(1, "Pantry", "backward", here.name, jid(here));
        visit [here --> [?:Shelf]];
        visit [here --> [?:Household]];
    }

    can scan_shelf with Shelf entry {
        self.hop(2, "Shelf", "forward", here.name, jid(here));
        visit [here ->:Stocks:->];
    }

    # -- Step 2 + 3: match, flag, then walk backward to the households.
    can check_item with Item entry {
        if jid(here) in self.seen_items {
            skip;
        }
        self.seen_items.append(jid(here));
        self.items_scanned += 1;

        hit_any = False;
        for record in self.records {
            call = _classify(here, record);
            if not call.matched {
                continue;
            }
            hit_any = True;

            evidence = _evidence_id(here.lot_code, record.code_info);
            # What the EDGE ends up saying, which is not always what this run
            # computed - a refused downgrade leaves the older, higher grade
            # standing and everything below reports that instead.
            standing = call.confidence;
            standing_fields = call.matched_fields;

            fresh = True;
            for link in [edge here ->:FlaggedBy:-> record] {
                fresh = False;
                if _may_rewrite(
                    link.confidence, link.matched_fields, call.confidence, evidence
                ) {
                    link.confidence = call.confidence;
                    link.matched_fields = _stamp(call.matched_fields, evidence);
                } else {
                    standing = link.confidence;
                    standing_fields = (
                        link.matched_fields.split(EVIDENCE_OPEN)[0]
                        + f" (held: a re-check graded this {call.confidence} on "
                        + "unchanged evidence, so the earlier grade stands)"
                    );
                    self.flags_held += 1;
                }
            }
            if fresh {
                here +>:FlaggedBy(
                    confidence=call.confidence,
                    matched_fields=_stamp(call.matched_fields, evidence)
                ):+> record;
                self.flags_created += 1;
            } else {
                self.flags_existing += 1;
            }

            # Never discard on a recall match. CONFIRMED and POSSIBLE pull the
            # item back for a human; WEAK leaves it exactly where it was.
            if standing == CONFIRMED or standing == POSSIBLE {
                here.cleared = False;
                here.verdict = "review";
                here.verdict_reason = (
                    f"Recall {record.recall_number}: {record.reason} "
                    + f"[{standing}: {standing_fields}]"
                );
            }

            shelves = [here <-:Stocks:<-];
            entry = FlaggedItem(
                item_id=jid(here),
                brand=here.brand,
                product=here.product,
                lot_code=here.lot_code,
                shelf=(shelves[0].name if len(shelves) > 0 else ""),
                on_shelf=(len(shelves) > 0),
                verdict=here.verdict,
                confidence=standing,
                matched_fields=standing_fields,
                recall_number=record.recall_number,
                classification=record.classification,
                recall_reason=record.reason,
                recall_code_info=record.code_info,
                action=_action_for(standing)
            );
            if standing == WEAK {
                self.informational.append(entry);
            } else {
                self.pull_from_shelf.append(entry);
            }
        }

        if hit_any {
            self.flagged_item_ids.append(jid(here));
            self.hop(
                3, "Item", "forward",
                (here.brand + " " + here.product).strip(), jid(here)
            );
            # ------------------------------------------------------------
            # THE BACKWARD TRAVERSAL. Received points Household --> Item, so
            # walking it in reverse from a recalled can lands on exactly the
            # households that carried it home. One line, no join table.
            # ------------------------------------------------------------
            visit [here <-:Received:<-];
        }
    }

    can notify with Household entry {
        for item in [here ->:Received:->] {
            if jid(item) not in self.flagged_item_ids {
                continue;
            }
            for record in [item ->:FlaggedBy:->] {
                for link in [edge item ->:FlaggedBy:-> record] {
                    if link.confidence == WEAK {
                        continue;
                    }
                    key = here.pickup_code + "|" + jid(item) + "|" + record.recall_number;
                    if key in self.notified_keys {
                        continue;
                    }
                    self.notified_keys.append(key);

                    picked_up = "";
                    for handoff in [edge here ->:Received:-> item] {
                        picked_up = handoff.timestamp;
                    }

                    self.hop(
                        4, "Household", "backward",
                        f"pickup code {here.pickup_code}", jid(here)
                    );
                    # Redacted on the way out, not at the UI: this walker is
                    # :pub, so this obj IS the anonymous response.
                    self.notify_households.append(NotifyHousehold(
                        pickup_code=here.pickup_code,
                        contact_on_file=(here.notify_contact != ""),
                        preferred_language=here.preferred_language,
                        picked_up_at=_pickup_day(picked_up),
                        item_id=jid(item),
                        brand=item.brand,
                        product=item.product,
                        confidence=link.confidence,
                        recall_number=record.recall_number,
                        classification=record.classification,
                        message=_notice(record, item, link.confidence)
                    ));
                }
            }
        }

        # Items already handed out may no longer sit on any shelf, so the
        # household's own history is a second way in. Guarded: expand once.
        if jid(here) not in self.expanded_households {
            self.expanded_households.append(jid(here));
            visit [here ->:Received:->];
        }
    }

    # RecallFeed is entered first, so its exit runs last - after the whole
    # traversal, backward hops included.
    can finish with RecallFeed exit {
        confirmed = len([f for f in self.pull_from_shelf if f.confidence == CONFIRMED]);
        possible = len([f for f in self.pull_from_shelf if f.confidence == POSSIBLE]);
        report SweepReport(
            source=self.source,
            source_note=self.source_note,
            feed_id=self.feed_id,
            synced_at=self.synced_at,
            records_seen=self.records_seen,
            records_new=self.records_new,
            records_updated=self.records_updated,
            items_scanned=self.items_scanned,
            items_flagged=len(self.flagged_item_ids),
            flags_created=self.flags_created,
            flags_existing=self.flags_existing,
            confirmed=confirmed,
            possible=possible,
            weak=len(self.informational),
            pull_from_shelf=self.pull_from_shelf,
            informational=self.informational,
            notify_households=self.notify_households,
            trace=self.trace,
            flags_held=self.flags_held
        );
    }
}
