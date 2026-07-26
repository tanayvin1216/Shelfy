"""Runnable proof for client_search.sv.jac (`MatchNeeds`).

Seeds a four-item shelf built so that EVERY prune has to fire, then runs the
walker three ways: stored Avoids only, free text only, and a second language.

    jac run tests/match_needs.jac
"""

import from graph {
    SeedPantry, Item, RecallRecord, Household,
    Stocks, Contains, FlaggedBy, Avoids, Received, Lists,
    SHELF_CANNED, SHELF_REVIEW, CONFIRMED, POSSIBLE,
    _get_pantry, _get_shelf, _get_allergen, _get_recall_feed, _get_household,
    _find_recall_record, _shelf_items, _now
}
import from client_search { MatchNeeds, MatchReport }
import from llm { DemoLLM }
import llm as llm_mod;

"""The process-wide byLLM model, narrowed to the MockLLM subclass so its demo
hooks (`queue`, `config`) are visible. Real key present -> this harness is not
the thing you want to run."""
glob demo: DemoLLM = llm_mod.llm as DemoLLM;

def line(title: str) {
    print("\n" + "=" * 74);
    print(title);
    print("=" * 74);
}

def show(r: MatchReport) {
    print(f"pickup_code      : {r.pickup_code!r}  household_found={r.household_found}");
    print(f"language         : {r.language}");
    print(f"avoids (stored)  : {r.avoids_stored}");
    print(f"avoids (free txt): {r.avoids_from_text}");
    print(f"avoiding (union) : {r.avoiding}");
    print(f"shelves searched : {r.shelves_searched}");
    print(f"items considered : {r.items_considered}");
    print(f"OFFERED ({len(r.offered)}):");
    for m in r.offered {
        print(f"   + {m.item.brand} {m.item.product}  [{m.matched_shelf}]");
        print(f"     label lists: {[t.name for t in m.item.allergens]}");
        print(f"     note: {m.explanation}");
    }
    print(f"WITHHELD ({len(r.withheld)}):");
    for w in r.withheld {
        print(f"   - {w.brand} {w.product}");
        print(f"     reason={w.reason} :: {w.detail}");
    }
    print(f"framing_note     : {r.framing_note}");
}

def stock(shelf_name: str, brand: str, product: str, cat: str, ingr: str,
          tags: list[str], cleared: bool, verdict: str, reason: str) -> Item {
    it = (_get_shelf(shelf_name) +>:Stocks:+> Item(
        brand=brand, product=product, category=cat, ingredients_text=ingr,
        date_value="BEST BY 03/2024", date_type="best_by", lot_code="L-77",
        packaging_note="no visible damage", extraction_confidence=0.9,
        legibility_note="", verdict=verdict, verdict_reason=reason,
        cleared=cleared, scanned_at=_now()
    ))[0] as Item;
    for t in tags {
        it +>:Contains(evidence=f"'{t}' in the ingredient statement"):+> _get_allergen(t);
    }
    return it;
}

with entry:__main__ {
    # quiet the MockLLM's prompt dump for the first runs; re-enabled below where
    # the assembled prompt is the actual evidence.
    demo.config["verbose"] = False;
    demo.config["show_params"] = False;

    root spawn SeedPantry();

    if len(_shelf_items(SHELF_CANNED)) == 0 {
        # 1. clean, cleared, no avoided tag  -> OFFERED
        stock(SHELF_CANNED, "DEL MONTE", "Cut Green Beans 14.5oz", "canned_low_acid",
              "GREEN BEANS, WATER, SALT.", [], True, "review",
              "Past its best-by date, which is a quality date and not a safety cutoff. "
              "Canned vegetables keep 2-5 years past code.");

        # 2. cleared but the label lists peanuts -> PRUNED label_lists_avoided
        stock(SHELF_CANNED, "JIF", "Creamy Peanut Butter 16oz", "peanut_butter",
              "ROASTED PEANUTS, SUGAR, PALM OIL. CONTAINS: PEANUTS.",
              ["peanuts", "added sugar"], True, "keep", "Within date, container sound.");

        # 3. never cleared by a human -> PRUNED not_cleared
        stock(SHELF_CANNED, "STORE BRAND", "Chicken Noodle Soup 10.5oz",
              "canned_low_acid", "CHICKEN BROTH, ENRICHED PASTA, CHICKEN.",
              ["wheat"], False, "review", "Awaiting volunteer clearance.");

        # 4. cleared, then a recall landed on it -> PRUNED active_recall
        raisins = stock(SHELF_CANNED, "FIRST STREET", "Dark Chocolate Raisins 9oz",
              "snack_food", "RAISINS, CHOCOLATE, SUGAR, SOY LECITHIN.",
              ["soybeans"], True, "keep", "Within date.");
        rec = _find_recall_record("H-1125-2026");
        if rec is None {
            rec = (_get_recall_feed() +>:Lists:+> RecallRecord(
                recall_number="H-1125-2026",
                recalling_firm="Western Mixers Produce & Nuts",
                product_description="FIRST STREET Dark Chocolate Raisins 9oz",
                reason="Undeclared peanuts.", classification="Class I",
                code_info="Lot: L-77 BB: 022527", distribution_pattern="CA, NV, AZ",
                status="Ongoing", report_date="2026-07-15"
            ))[0] as RecallRecord;
        }
        raisins +>:FlaggedBy(confidence=CONFIRMED,
                             matched_fields="brand+product+lot"):+> rec;

        # the household: peanut allergy stored as a durable Avoids edge, no PII
        hh = _get_household("8830");
        hh.preferred_language = "en";
        hh +>:Avoids:+> _get_allergen("peanuts");
        hh +>:Received(pickup_code="8830", timestamp=_now()):+> raisins;
    }

    line("A. spawn on root with a pickup code - stored Avoids only");
    a = (root spawn MatchNeeds(pickup_code="8830")).reports[0];
    show(a);

    line("B. spawn on the Household node itself (the _jac_spawn_node path)");
    hh = _get_household("8830");
    b = (hh spawn MatchNeeds()).reports[0];
    print(f"same shape from the node spawn? offered={len(b.offered)} "
          f"withheld={len(b.withheld)} avoiding={b.avoiding}");

    line("C. walk-up client, no pickup code, free text only");
    c = (root spawn MatchNeeds(constraints_text="allergic to peanuts, diabetic")).reports[0];
    show(c);

    line("D. unknown pickup code falls back to anonymous browse (not an error)");
    d = (root spawn MatchNeeds(pickup_code="0000")).reports[0];
    print(f"pickup_code echoed={d.pickup_code!r} household_found={d.household_found} "
          f"avoiding={d.avoiding} offered={len(d.offered)} withheld={len(d.withheld)}");

    line("E. second language - the demo beat (spec section 12, 1:30-2:10)");
    demo.queue.append(
        "Esto es una lata de ejotes cortados Del Monte. La etiqueta indica ejotes, "
        "agua y sal, y no indica cacahuates. La fecha 'best by' de la lata ya paso, "
        "lo cual se refiere a la calidad y no a un limite de seguridad. Por favor "
        "revise la etiqueta del paquete antes de usarlo."
    );
    e = (root spawn MatchNeeds(pickup_code="8830", language="Spanish")).reports[0];
    print(f"language routed to byLLM: {e.language}");
    for m in e.offered {
        print(f"   + {m.item.brand} {m.item.product}");
        print(f"     {m.explanation}");
    }

    line("F. proof the language actually reaches the model, not just the report");
    demo.config["show_params"] = True;
    demo.config["verbose"] = True;
    f = (root spawn MatchNeeds(pickup_code="8830", language="Vietnamese")).reports[0];
    print(f"offered={len(f.offered)}");
}
