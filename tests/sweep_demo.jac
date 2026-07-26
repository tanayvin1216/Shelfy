"""End-to-end proof for RecallSweep (§6) - the backward traversal.

    ./.venv/bin/jac run tests/sweep_demo.jac
    ./.venv/bin/jac test tests/sweep_demo.jac

Builds the Maria scenario against a REAL openFDA record (H-1125-2026, Class I,
undeclared peanuts, Western Mixers / FIRST STREET Dark Chocolate Raisins,
`Lot: 260562 BB: 022527`) and four items that exercise every §4 tier:

  A  lot 260562, on the shelf, HANDED OUT to pickup codes 4471 and 8830
     -> CONFIRMED. Pull it, and name both households.
  B  lot 991234, same brand and product, legible and NOT in the recall
     -> WEAK. Informational only. This is the fix to v1's Flaw 2: a brand
        match must not condemn every jar on the shelf.
  C  lot unreadable, handed out to 2210
     -> POSSIBLE. Review, surface the recall's codes, notify the household.
  D  a can of green beans
     -> no flag at all. Proves the sweep is not just flagging everything.

Idempotent: re-running creates nothing new, and the sweep's own
`flags_created` / `flags_existing` counters prove it does not stack edges.
"""

import from graph {
    Item, Household, Shelf,
    Received, Stocks,
    SeedPantry, SHELF_CANNED,
    CONFIRMED, POSSIBLE, WEAK,
    _get_household, _get_shelf, _now
}
import from sweep { RecallSweep, SweepReport, LIVE_TIMEOUT_S }

glob DEMO_BRAND: str = "FIRST STREET";
glob DEMO_PRODUCT: str = "Dark Chocolate Raisins 9 oz";

"""Get-or-create an Item on a shelf, keyed on brand+product+lot so the harness
can be run twice without forking the graph."""
def stock(shelf: Shelf, brand: str, product: str, lot: str, note: str) -> Item {
    for existing in [shelf ->:Stocks:->] {
        if existing.brand == brand and existing.product == product
           and existing.lot_code == lot {
            return existing;
        }
    }
    fresh = Item(
        brand=brand,
        product=product,
        category="snack_food",
        ingredients_text="dark chocolate, raisins",
        date_value="BB 022527",
        date_type="best_by",
        lot_code=lot,
        extraction_confidence=0.9,
        legibility_note=note,
        verdict="keep",
        verdict_reason="cleared at intake",
        cleared=True,
        scanned_at=_now()
    );
    shelf +>:Stocks:+> fresh;
    return fresh;
}

"""Hand an item to a household. Received points Household --> Item; the sweep
walks it in reverse."""
def hand_out(code: str, item: Item, language: str, contact: str, at: str) {
    household = _get_household(code);
    household.preferred_language = language;
    household.notify_contact = contact;
    for _existing in [edge household ->:Received:-> item] {
        return;
    }
    household +>:Received(pickup_code=code, timestamp=at):+> item;
}

def build_demo_graph {
    _ = root spawn SeedPantry();
    shelf = _get_shelf(SHELF_CANNED);

    confirmed_item = stock(shelf, DEMO_BRAND, DEMO_PRODUCT, "260562", "lot code sharp");
    hand_out("4471", confirmed_item, "en", "opted in: sms", "2026-07-18T10:20:00");
    hand_out("8830", confirmed_item, "es", "", "2026-07-18T11:05:00");

    _ = stock(shelf, DEMO_BRAND, DEMO_PRODUCT, "991234", "lot code sharp");

    possible_item = stock(shelf, DEMO_BRAND, DEMO_PRODUCT, "", "lot code smudged");
    hand_out("2210", possible_item, "en", "", "2026-07-19T09:40:00");

    _ = stock(shelf, "DEL MONTE", "Cut Green Beans 14.5 oz", "P8241", "clean");
}

def run_sweep(live: bool, timeout_s: float = LIVE_TIMEOUT_S) -> SweepReport {
    build_demo_graph();
    result = root spawn RecallSweep(live=live, limit=100, timeout_s=timeout_s);
    return result.reports[0];
}

with entry:__main__ {
    out = run_sweep(False);

    print("source      :", out.source, "|", out.source_note);
    print("records     :", out.records_seen, "seen /", out.records_new, "new /",
          out.records_updated, "updated");
    print("items       :", out.items_scanned, "scanned /", out.items_flagged, "flagged");
    print("flag edges  :", out.flags_created, "created /", out.flags_existing, "existing");
    print("tiers       :", out.confirmed, "confirmed /", out.possible, "possible /",
          out.weak, "weak");

    print("\n=== PULL FROM THE SHELF ===");
    for row in out.pull_from_shelf {
        print(f"  [{row.confidence}] {row.brand} {row.product}  lot={row.lot_code or '(unreadable)'}");
        print(f"      recall {row.recall_number} ({row.classification}) - {row.recall_reason}");
        print(f"      recall codes : {row.recall_code_info}");
        print(f"      matched on   : {row.matched_fields}");
        print(f"      shelf={row.shelf or '(not on a shelf)'}  verdict={row.verdict}");
        print(f"      action       : {row.action}");
    }

    print("\n=== INFORMATIONAL ONLY (v1 would have condemned these) ===");
    for row in out.informational {
        print(f"  [{row.confidence}] {row.brand} {row.product}  lot={row.lot_code}");
        print(f"      {row.matched_fields}");
        print(f"      verdict stays '{row.verdict}' - {row.action}");
    }

    print("\n=== HOUSEHOLDS TO NOTIFY (backward traversal) ===");
    for row in out.notify_households {
        print(f"  pickup code {row.pickup_code}  [{row.confidence}] "
              + f"lang={row.preferred_language} contact={row.notify_contact or '(none on file)'}");
        print(f"      took home {row.brand} {row.product} at {row.picked_up_at}");
        print(f"      {row.message}");
    }

    print("\n=== TRAVERSAL TRACE ===");
    for hop in out.trace {
        arrow = "<<<" if hop.direction == "backward" else ">>>";
        print(f"  depth {hop.depth} {arrow} {hop.direction:<8} {hop.kind:<11} {hop.label}");
    }

    print("\n--- re-running the sweep (idempotency) ---");
    again = run_sweep(False);
    print("records     :", again.records_seen, "seen /", again.records_new, "new /",
          again.records_updated, "updated");
    print("flag edges  :", again.flags_created, "created /", again.flags_existing, "existing");
    print("pickup codes:", [n.pickup_code for n in again.notify_households]);
}
