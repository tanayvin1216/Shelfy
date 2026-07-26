"""Runnable proof for intake.sv.jac. `jac run tests/intake.jac`.

Every scenario pins the two byLLM answers through DemoLLM's `queue`, so the
graph behaviour under test is the WALKER's, not the model's.
"""

import base64;
import from datetime { date }

import from graph {
    SeedPantry, RecallRecord, RecallFeed, Item, Lists,
    CONFIRMED, POSSIBLE, WEAK, SHELF_CANNED, SHELF_REVIEW,
    _get_recall_feed, _find_recall_record, _get_shelf, _shelf_items
}
import from llm { llm, LabelRead, ShelfLifeCall, DateType, ShelfVerdict }
import from intake {
    IntakeScan, ClearItem, IntakeReport, ClearReport,
    _parse_code_date, _days_past_code, _lot_state, _tag_allergens,
    _discard_allowed, _packaging_compromised
}

glob mock: any = llm;

glob PNG: str = base64.b64encode(bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000a49444154789c6360000002000100ffff0300000600"
    "0557bfabd40000000049454e44ae426082"
)).decode();

obj DiscardCase {
    has category: str,
        days: int,
        note: str;
}

def bar(title: str) {
    print("\n" + "=" * 74);
    print(title);
    print("=" * 74);
}

def plant_recalls {
    feed = _get_recall_feed();
    wanted = [
        RecallRecord(
            recall_number="H-1125-2026",
            recalling_firm="Western Mixers Produce & Nuts",
            product_description="FIRST STREET Dark Chocolate Raisins 9oz",
            reason="Undeclared peanuts.",
            classification="Class I",
            code_info="Lot: 260562 BB: 022527",
            distribution_pattern="CA, NV, AZ",
            status="Ongoing",
            report_date="2026-07-15"
        ),
        RecallRecord(
            recall_number="H-1188-2026",
            recalling_firm="Western Mixers Produce & Nuts",
            product_description="FIRST STREET Yogurt Covered Pretzels 12oz",
            reason="Undeclared milk.",
            classification="Class II",
            code_info="Lot: 991244",
            distribution_pattern="CA",
            status="Ongoing",
            report_date="2026-07-18"
        )
    ];
    for rec in wanted {
        if _find_recall_record(rec.recall_number) is None {
            feed +>:Lists:+> rec;
        }
    }
    print("recall records on feed:",
          [r.recall_number for r in [feed ->:Lists:->]]);
}

def scan(label: LabelRead, call: ShelfLifeCall) -> IntakeReport {
    mock.queue = [label, call];
    w: any = root spawn IntakeScan(photo_base64=PNG, shelf_name=SHELF_CANNED);
    return w.reports[0] as IntakeReport;
}

def show(rep: IntakeReport) {
    print(f"  verdict          : {rep.verdict}");
    print(f"  blocked          : {rep.blocked}");
    print(f"  held on shelf    : {rep.holding_shelf}  (destination '{rep.destination_shelf}')");
    print(f"  days past code   : {rep.days_past_code}  (parsed: {rep.date_parsed})");
    print(f"  shelf-life window: {rep.shelf_life_window}");
    print(f"  allergen tags    : {[(t.name, t.evidence) for t in rep.allergen_tags]}");
    print(f"  records compared : {rep.recall_records_compared}");
    for m in rep.recall_matches {
        print(f"  match [{m.confidence}] {m.recall_number} -- {m.matched_fields}");
        print(f"        scanned lot '{m.scanned_lot}' vs recall codes '{m.recall_lot_codes}'");
    }
    print(f"  reason           : {rep.verdict_reason}");
    print("  trace:");
    for t in rep.trace {
        print(f"    [{t.source:<26}] {t.step}: {t.detail}");
    }
}

def try_clear(rep: IntakeReport) {
    c: any = root spawn ClearItem(item_id=rep.item.id, shelf_name=SHELF_CANNED);
    cr = c.reports[0] as ClearReport;
    print(f"  ClearItem -> cleared={cr.cleared} refused={cr.refused} shelf='{cr.shelf}'");
    print(f"  blocking recalls: {cr.blocking_recalls}");
    if cr.refusal_reason != "" {
        print(f"  {cr.refusal_reason}");
    }
}

with entry:__main__ {
    mock.config["verbose"] = False;
    mock.config["show_params"] = False;

    bar("0. seed + plant active recalls");
    s: any = root spawn SeedPantry();
    print("seed nodes_created:", s.reports[0].nodes_created);
    plant_recalls();
    print("today is", date.today().isoformat());

    bar("1. date parser on real label formats");
    for raw in [
        "2027-02-25", "BEST BY 03/2024", "BB 02/25/27", "JAN 23 2027",
        "23 JAN 2027", "MAR 2024", "022527", "EXP 12/26", "smudged"
    ] {
        print(f"  {raw:<18} -> {_parse_code_date(raw)}   days past: {_days_past_code(raw)}");
    }

    bar("2. lot-code tri-state (the fix to Flaw 2)");
    for pair in [
        ("260562", "Lot: 260562 BB: 022527"),
        ("Lot 260562", "Lot: 260562 BB: 022527"),
        ("770001", "Lot: 260562 BB: 022527"),
        ("", "Lot: 260562 BB: 022527"),
        ("260562", "")
    ] {
        print(f"  scanned '{pair[0]:<12}' vs code_info '{pair[1]:<24}' -> {_lot_state(pair[0], pair[1])}");
    }

    bar("3. allergen tagging carries the justifying words");
    for text in [
        "RAISINS, CHOCOLATE (SUGAR, COCOA BUTTER, SOY LECITHIN), MILK. CONTAINS: MILK, SOY.",
        "WATER, CHICKPEAS, TAHINI, SALT.",
        "CARBONATED WATER, NATURAL FLAVOR. SUGAR FREE."
    ] {
        print(f"  '{text[:52]}...'");
        for h in _tag_allergens(text) {
            print(f"      {h.name:<12} <- {h.evidence}");
        }
    }

    bar("4. sec-4 discard guard");
    for case in [
        DiscardCase(category="canned_low_acid", days=900, note="no visible damage"),
        DiscardCase(category="canned_low_acid", days=900, note="small dent on the flat side, seams intact"),
        DiscardCase(category="canned_low_acid", days=0, note="lid is bulging"),
        DiscardCase(category="canned_low_acid", days=0, note="dent on the seam"),
        DiscardCase(category="baby_food_formula", days=5, note="no visible damage"),
        DiscardCase(category="baby_food_formula", days=-30, note="no visible damage"),
        DiscardCase(category="home_canned", days=-400, note="mason jar, handwritten label")
    ] {
        print(f"  {case.category:<18} days={case.days:<5} '{case.note}'"
              f" -> discard allowed: {_discard_allowed(case.category, case.days, case.note)}");
    }

    # ------------------------------------------------------------------
    bar("5. CONFIRMED recall  (brand + product + lot all match)");
    w1 = scan(
        LabelRead(
            brand="FIRST STREET",
            product="Dark Chocolate Raisins 9oz",
            category="snack_food",
            ingredients_text="RAISINS, CHOCOLATE (SUGAR, COCOA BUTTER, SOY LECITHIN, MILK).",
            date_value="022527",
            date_type=DateType.BEST_BY,
            lot_code="Lot 260562",
            packaging_note="no visible damage",
            extraction_confidence=0.93,
            legibility_note=""
        ),
        ShelfLifeCall(
            verdict=ShelfVerdict.KEEP,
            reason="Within its printed best-by date and the bag is sound.",
            typical_window_past_code=""
        )
    );
    show(w1);
    print("  --- ClearItem on a CONFIRMED flag ---");
    try_clear(w1);

    # ------------------------------------------------------------------
    bar("6. WEAK recall  (brand matches, different product) + past-date can");
    w2 = scan(
        LabelRead(
            brand="FIRST STREET",
            product="Cut Green Beans 14.5 oz",
            category="canned_low_acid",
            ingredients_text="GREEN BEANS, WATER, SALT.",
            date_value="BEST BY 03/2024",
            date_type=DateType.BEST_BY,
            lot_code="",
            packaging_note="small dent on the flat side, seams intact",
            extraction_confidence=0.88,
            legibility_note="lot code not visible in this photo"
        ),
        ShelfLifeCall(
            verdict=ShelfVerdict.REVIEW,
            reason=(
                "This can is past its best-by date, which is a quality date rather "
                "than a safety cutoff, so it is not being thrown away."
            ),
            typical_window_past_code="2-5 years past code"
        )
    );
    show(w2);
    print("  --- ClearItem on a WEAK flag ---");
    try_clear(w2);
    print("  shelf after clearing:",
          [(i.brand, i.product, i.cleared) for i in _shelf_items(SHELF_CANNED)]);

    # ------------------------------------------------------------------
    bar("7. POSSIBLE recall  (brand + product match, lot unreadable)");
    w3 = scan(
        LabelRead(
            brand="FIRST STREET",
            product="Dark Chocolate Raisins 9oz",
            category="snack_food",
            ingredients_text="RAISINS, CHOCOLATE, SUGAR.",
            date_value="BB 02/25/27",
            date_type=DateType.BEST_BY,
            lot_code="",
            packaging_note="no visible damage",
            extraction_confidence=0.81,
            legibility_note="lot code cropped out of frame"
        ),
        ShelfLifeCall(
            verdict=ShelfVerdict.KEEP,
            reason="Still inside its printed date and the bag is sound.",
            typical_window_past_code=""
        )
    );
    show(w3);
    print("  --- ClearItem on a POSSIBLE flag (must NOT be blocked) ---");
    try_clear(w3);

    # ------------------------------------------------------------------
    bar("8. lot DIFFERS  (v1 would have flagged the whole brand)");
    w4 = scan(
        LabelRead(
            brand="FIRST STREET",
            product="Dark Chocolate Raisins 9oz",
            category="snack_food",
            ingredients_text="RAISINS, CHOCOLATE, SUGAR.",
            date_value="BB 08/30/27",
            date_type=DateType.BEST_BY,
            lot_code="Lot 770914",
            packaging_note="no visible damage",
            extraction_confidence=0.95,
            legibility_note=""
        ),
        ShelfLifeCall(
            verdict=ShelfVerdict.KEEP,
            reason="Still inside its printed date.",
            typical_window_past_code=""
        )
    );
    show(w4);

    # ------------------------------------------------------------------
    bar("9. the Flaw 1 backstop: walker overrides a bad `discard`");
    w5 = scan(
        LabelRead(
            brand="Barilla",
            product="Penne Rigate 16oz",
            category="dry_pasta_rice",
            ingredients_text="SEMOLINA (WHEAT).",
            date_value="BEST BY 01/2023",
            date_type=DateType.BEST_BY,
            lot_code="L-4409",
            packaging_note="box is a bit crushed, inner bag sealed",
            extraction_confidence=0.9,
            legibility_note=""
        ),
        ShelfLifeCall(
            verdict=ShelfVerdict.DISCARD,
            reason="It is past its date.",
            typical_window_past_code="2+ years past code"
        )
    );
    show(w5);

    # ------------------------------------------------------------------
    bar("10. infant formula past date DOES discard, and ClearItem refuses it");
    w6 = scan(
        LabelRead(
            brand="NARA ORGANICS",
            product="Infant Formula Stage 1 800g",
            category="baby_food_formula",
            ingredients_text="NONFAT MILK, LACTOSE, WHEY PROTEIN.",
            date_value="USE BY 02/2026",
            date_type=DateType.USE_BY,
            lot_code="F-2201",
            packaging_note="no visible damage",
            extraction_confidence=0.94,
            legibility_note=""
        ),
        ShelfLifeCall(
            verdict=ShelfVerdict.DISCARD,
            reason=(
                "Infant formula is the one federally regulated date category and it "
                "is past its use-by date, so it cannot go out."
            ),
            typical_window_past_code="do not extend past the printed date"
        )
    );
    show(w6);
    try_clear(w6);

    bar("11. final shelf state");
    print("  canned goods:", [(i.product, i.verdict, i.cleared) for i in _shelf_items(SHELF_CANNED)]);
    print("  review queue:", [(i.product, i.verdict, i.cleared) for i in _shelf_items(SHELF_REVIEW)]);
}
