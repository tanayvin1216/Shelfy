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
    """Addressed by anonymous pickup code only - no name, no address, no phone.
    `notify_contact` is whatever the household opted in with, or empty."""
    has pickup_code: str,
        notify_contact: str,
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
        trace: list[SweepHop];
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

"""Words that appear around a lot code rather than being one."""
glob CODE_NOISE: list[str] = [
    "lot", "lots", "code", "codes", "number", "numbers", "best", "bb", "by",
    "use", "exp", "expiration", "date", "dates", "mfg", "manufacture",
    "manufactured", "upc", "sell", "all", "and", "the", "of", "before", "sku"
];

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

def _code_words(text: str) -> list[str] {
    out: list[str] = [];
    for word in _alnum_words(text) {
        if len(word) >= 3 and word not in CODE_NOISE and word not in out {
            out.append(word);
        }
    }
    return out;
}

def _shared(left: list[str], right: list[str]) -> list[str] {
    return [word for word in left if word in right];
}

"""A recall names the firm that recalled it, which is often NOT the brand on
the package - Western Mixers recalls a jar labelled FIRST STREET. So the
brand is checked against the firm AND the product description."""
def _brand_hit(brand: str, firm: str, description: str) -> bool {
    wanted = _signal_words(brand);
    if len(wanted) == 0 {
        return False;
    }
    haystack = _signal_words(firm) + _signal_words(description);
    return len(_shared(wanted, haystack)) == len(wanted);
}

def _product_hit(product: str, description: str) -> list[str] {
    return _shared(_signal_words(product), _signal_words(description));
}

"""Three-valued on purpose. 'differs' is not 'no information' - a legible lot
code that is absent from the recall's code list is positive evidence that
THIS jar is not the recalled jar, and that is the whole fix to v1's flaw 2."""
def _lot_state(item_lot: str, code_info: str) -> str {
    mine = _code_words(item_lot);
    theirs = _code_words(code_info);
    if len(mine) == 0 or len(theirs) == 0 {
        return "unknown";
    }
    if len(_shared(mine, theirs)) > 0 {
        return "match";
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

    overlap = _product_hit(item.product, record.product_description);
    if len(overlap) < 2 {
        return MatchCall(
            matched=True,
            confidence=WEAK,
            matched_fields="brand only; product description does not match"
        );
    }

    shared_words = ", ".join(overlap);
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

def _action_for(confidence: str) -> str {
    if confidence == CONFIRMED {
        return "Pull from the shelf now. Do not distribute.";
    }
    if confidence == POSSIBLE {
        return "Move to the review queue and compare the printed code against the recall code list.";
    }
    return "No action. Same brand, different product or different lot - the item stays available.";
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

            fresh = True;
            for link in [edge here ->:FlaggedBy:-> record] {
                fresh = False;
                link.confidence = call.confidence;
                link.matched_fields = call.matched_fields;
            }
            if fresh {
                here +>:FlaggedBy(
                    confidence=call.confidence, matched_fields=call.matched_fields
                ):+> record;
                self.flags_created += 1;
            } else {
                self.flags_existing += 1;
            }

            # Never discard on a recall match. CONFIRMED and POSSIBLE pull the
            # item back for a human; WEAK leaves it exactly where it was.
            if call.confidence == CONFIRMED or call.confidence == POSSIBLE {
                here.cleared = False;
                here.verdict = "review";
                here.verdict_reason = (
                    f"Recall {record.recall_number}: {record.reason} "
                    + f"[{call.confidence}: {call.matched_fields}]"
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
                confidence=call.confidence,
                matched_fields=call.matched_fields,
                recall_number=record.recall_number,
                classification=record.classification,
                recall_reason=record.reason,
                recall_code_info=record.code_info,
                action=_action_for(call.confidence)
            );
            if call.confidence == WEAK {
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
                    self.notify_households.append(NotifyHousehold(
                        pickup_code=here.pickup_code,
                        notify_contact=here.notify_contact,
                        preferred_language=here.preferred_language,
                        picked_up_at=picked_up,
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
            trace=self.trace
        );
    }
}
