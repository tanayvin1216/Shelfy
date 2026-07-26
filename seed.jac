"""Runnable harness for graph.sv.jac.

`jac run seed.jac` persists into ./.jac, so running it a second time exercises
the real re-seed path: same process spawns SeedPantry twice, and the second
process run re-enters a graph that already exists.
"""

import from graph {
    SeedPantry, Pantry, Shelf, Allergen, Household, RecallFeed, RecallRecord, Item,
    Stocks, Contains, FlaggedBy, Avoids, Received, Lists,
    SHELF_CANNED, SHELF_REVIEW, CONFIRMED,
    _get_pantry, _get_shelf, _get_allergen, _get_recall_feed, _get_household,
    _find_recall_record, _shelf_items, _now
}

def census(label: str) {
    p = _get_pantry();
    print(
        f"{label:<22} pantries={len([root --> [?:Pantry]])}"
        f" shelves={len([p --> [?:Shelf]])}"
        f" allergens={len([p --> [?:Allergen]])}"
        f" feeds={len([p --> [?:RecallFeed]])}"
        f" households={len([p --> [?:Household]])}"
    );
}

with entry:__main__ {
    print("=== SeedPantry run #1 ===");
    r1 = root spawn SeedPantry();
    s1 = r1.reports[0];
    print("nodes_created:", s1.nodes_created, "| already_seeded:", s1.already_seeded);
    print("shelves :", s1.shelves);
    print("allergens:", s1.allergens);
    census("after run #1");

    print("=== SeedPantry run #2 (same process) ===");
    r2 = root spawn SeedPantry();
    s2 = r2.reports[0];
    print("nodes_created:", s2.nodes_created, "| already_seeded:", s2.already_seeded);
    print("same pantry node?", s1.pantry_id == s2.pantry_id);
    print("same recall feed?", s1.recall_feed_id == s2.recall_feed_id);
    census("after run #2");

    print("=== helper upserts are also idempotent ===");
    a = _get_allergen("Tree Nuts ");
    b = _get_allergen("tree nuts");
    print("'Tree Nuts ' and 'tree nuts' resolve to one node?", jid(a) == jid(b));
    print("allergen total still:", len([_get_pantry() --> [?:Allergen]]));

    print("=== demo item + to_view projection ===");
    canned = _get_shelf(SHELF_CANNED);
    if len(_shelf_items(SHELF_CANNED)) == 0 {
        jar = (canned +>:Stocks:+> Item(
            brand="First Street",
            product="Dark Chocolate Raisins 9oz",
            category="snack foods",
            ingredients_text="raisins, chocolate, sugar, soy lecithin",
            date_value="2027-02-25",
            date_type="best_by",
            lot_code="260562",
            packaging_note="intact",
            extraction_confidence=0.91,
            legibility_note="clear",
            verdict="review",
            verdict_reason="lot code matches an active recall, needs a human",
            scanned_at=_now()
        ))[0] as Item;

        jar +>:Contains(evidence="soy lecithin"):+> _get_allergen("soybeans");
        jar +>:Contains(evidence="undeclared peanut, per recall"):+> _get_allergen("peanuts");

        feed = _get_recall_feed();
        rec = _find_recall_record("H-1125-2026");
        if rec is None {
            rec = (feed +>:Lists:+> RecallRecord(
                recall_number="H-1125-2026",
                recalling_firm="Western Mixers Produce & Nuts",
                product_description="FIRST STREET Dark Chocolate Raisins 9oz",
                reason="Undeclared peanuts.",
                classification="Class I",
                code_info="Lot: 260562 BB: 022527",
                distribution_pattern="CA, NV, AZ",
                status="Ongoing",
                report_date="2026-07-15"
            ))[0] as RecallRecord;
        }
        jar +>:FlaggedBy(confidence=CONFIRMED, matched_fields="brand+product+lot"):+> rec;

        hh = _get_household("4471");
        hh +>:Received(pickup_code="4471", timestamp=_now()):+> jar;
        hh +>:Avoids:+> _get_allergen("peanuts");
    }

    for it in _shelf_items(SHELF_CANNED) {
        v = it.to_view();
        print("view.id            :", v.id[:12], "...");
        print("view.product       :", v.brand, "-", v.product);
        print("view.shelf         :", v.shelf);
        print("view.date          :", v.date_type, v.date_value, "lot", v.lot_code);
        print("view.verdict       :", v.verdict, "| cleared:", v.cleared);
        print("view.allergens     :", [(t.name, t.evidence) for t in v.allergens]);
        print("view.recall_flags  :", [(f.recall_number, f.confidence, f.code_info) for f in v.recall_flags]);
        print("view.blocked       :", v.has_confirmed_recall);
    }

    print("=== backward reach (proves the Received edge is wired) ===");
    for it in _shelf_items(SHELF_CANNED) {
        print("households that took", it.product, ":",
              [e.pickup_code for e in [edge it <-:Received:<-]]);
    }

    census("final");
}
