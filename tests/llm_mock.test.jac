"""Assertions for the four §7 byLLM functions, run under MockLLM.

    ./.venv/bin/jac test tests/llm_mock.jac

Annex of `llm_mock.jac` - it sees that module's imports without re-importing.

Most of these tests assert on the ASSEMBLED PROMPT rather than on the returned
value, because under MockLLM the returned value is canned and proves nothing.
What is worth guarding is that the §4 domain rules are still reaching the
model: if someone trims `sem shelf_life_verdict`, the shelf-life table stops
arriving and Flaw 1 comes back silently. These tests fail loudly instead.
"""

import from byllm.lib { MockLLM }

test "no GEMINI_API_KEY means the app still runs on MockLLM" {
    assert isinstance(llm, MockLLM), f"expected a MockLLM fallback, got {type(llm).__name__}";
}

test "retired Gemini 2.0 model names migrate to the stable default" {
    assert DEFAULT_MODEL_NAME == "gemini/gemini-2.5-flash";
    assert _normalize_model_name("") == DEFAULT_MODEL_NAME;
    assert _normalize_model_name("gemini/gemini-2.0-flash") == DEFAULT_MODEL_NAME;
    assert _normalize_model_name("gemini-2.0-flash") == DEFAULT_MODEL_NAME;
    assert _normalize_model_name("gemini/gemini-3.6-flash") == "gemini/gemini-3.6-flash";
}

test "extract_label returns a fully populated LabelRead" {
    read = extract_label(image_from_source("docs/spikes/byllm/label.png"), "canned vegetable");
    assert isinstance(read, LabelRead);
    assert isinstance(read.date_type, DateType);
    assert isinstance(read.extraction_confidence, float);
    assert read.category == "canned_low_acid";
}

test "extract_label prompt tells the model not to invent a lot code" {
    p = last_prompt();
    assert "lot code" in p;
    assert "worse than no value at all" in p;
    assert "never fill a field from general knowledge of the product" in p;
    assert "leave it empty and say so in legibility_note" in p;
}

test "date_type is a closed vocabulary, not free text" {
    # The whole shelf-life fix branches on this field, so it must be a real
    # constraint the model cannot step outside of, not a str the model fills in.
    # byLLM renders these members into the response_format json_schema as
    # `'enum': ['best_by', 'use_by', 'sell_by', 'exp', 'unknown']` - visible in
    # the show_params dump from `jac run tests/llm_mock.jac`.
    vals = [str(d) for d in DateType];
    assert vals == ["best_by", "use_by", "sell_by", "exp", "unknown"], f"got {vals}";
    assert [str(v) for v in ShelfVerdict] == ["keep", "review", "discard"];
}

test "shelf_life_verdict routes a past-date canned good to review, not discard" {
    call = shelf_life_verdict(
        "canned_low_acid", DateType.BEST_BY, 847, "shallow dent on the flat side, seams intact"
    );
    assert isinstance(call, ShelfLifeCall);
    assert call.verdict == ShelfVerdict.REVIEW;
    assert call.verdict != ShelfVerdict.DISCARD;
    assert str(call.verdict) == "review";
}

test "the §4 shelf-life table reaches the model" {
    p = last_prompt();
    for row in [
        "canned_low_acid (vegetables, meat, soup, beans) ... 2-5 years past code",
        "canned_high_acid (tomatoes, citrus, fruit, pickles) ... 12-18 months past code",
        "dry_pasta_rice (dry pasta, white rice) ... 2+ years past code",
        "boxed_mix (cake, brownie, pancake) ... 12 months past code",
        "cereal ... 6-12 months past code",
        "peanut_butter ... 6-12 months past code",
        "shelf_stable_juice (juice, juice boxes) ... 6-12 months past code",
        "condiment_sauce (unopened condiments and sauces) ... 12-18 months past code",
        "snack_food (snacks, crackers, chips) ... 3-6 months past code, quality only",
        "nutrition_drink (Ensure, Boost) ... use by the date, do not extend",
        "baby_food_formula (baby food, infant formula) ... NEVER past the date",
        "perishable (dairy, eggs, fresh meat, produce) ... do not extend past the date"
    ] {
        assert row in p, f"shelf-life table row missing from the prompt: {row}";
    }
}

test "the fix to Flaw 1 reaches the model as an explicit rule" {
    p = last_prompt();
    assert "a past date, on its own, NEVER produces discard" in p;
    assert "NOT federally regulated and are NOT safety dates" in p;
    assert "Past-date shelf-stable goods go to review with a shelf-life note" in p;
    assert "Never state that a food is safe" in p;
}

test "the four hard-discard conditions reach the model" {
    p = last_prompt();
    assert "baby_food_formula and the date has passed" in p;
    assert "bulging or swelling" in p;
    assert "perishable (dairy, eggs, fresh meat, produce) and the date has passed" in p;
    assert "home_canned, or the item is unlabeled or homemade" in p;
}

test "explain_for_client returns plain text in the requested language" {
    card = ItemForClient(
        brand="DEL MONTE",
        product="Cut Green Beans 14.5 oz",
        category="canned_low_acid",
        date_value="BEST BY 03/2024",
        date_type=DateType.BEST_BY,
        allergens_listed=[],
        ingredients_text="GREEN BEANS, WATER, SALT.",
        shelf_life_note="2-5 years past code"
    );
    note = explain_for_client(card, ["peanuts", "added sugar"], "Spanish");
    assert isinstance(note, str);
    assert len(note) > 0;
}

test "the §4 framing rules reach explain_for_client" {
    p = last_prompt();
    assert "Never say a food is safe" in p;
    assert "Say 'the label lists' and 'the label does not list'" in p;
    assert "Never say 'contains'" in p;
    assert "'free from'" in p;
    assert "check the label on the package themselves" in p;
}

test "resolve_constraints returns tag names from the seeded vocabulary" {
    tags = resolve_constraints("allergic to peanuts, vegetarian, diabetic");
    assert isinstance(tags, list);
    for t in tags {
        assert isinstance(t, str);
    }
}

test "the closed Allergen vocabulary reaches resolve_constraints" {
    p = last_prompt();
    assert "milk, eggs, fish, shellfish, tree nuts, peanuts, wheat, soybeans, sesame" in p;
    assert "pork, beef, gelatin, alcohol" in p;
    assert "added sugar" in p;
    assert "vegetarian -> fish, shellfish, pork, beef, gelatin" in p;
    assert "peanuts are legumes" in p;
}

test "DemoLLM routes on return type, so call ORDER does not matter" {
    # Deliberately the reverse of the order above. Stock MockLLM pops a fixed
    # list and would hand a str back to a LabelRead call here.
    tags = resolve_constraints("no nuts");
    assert isinstance(tags, list);
    read = extract_label(image_from_source("docs/spikes/byllm/label.png"), "");
    assert isinstance(read, LabelRead);
    call = shelf_life_verdict("cereal", DateType.SELL_BY, 40, "no visible damage");
    assert isinstance(call, ShelfLifeCall);
}

test "DemoLLM never runs dry" {
    for _ in range(12) {
        assert isinstance(
            shelf_life_verdict("snack_food", DateType.BEST_BY, 10, "no visible damage"),
            ShelfLifeCall
        );
    }
}

test "queue lets a demo script pin an exact answer" {
    pinned = ShelfLifeCall(
        verdict=ShelfVerdict.DISCARD,
        reason="Infant formula past its date is the one unconditional discard.",
        typical_window_past_code="do not extend past the printed date"
    );
    q: any = getattr(llm, "queue", []);
    q.append(pinned);
    got = shelf_life_verdict("baby_food_formula", DateType.USE_BY, 12, "sealed, undamaged");
    assert got.verdict == ShelfVerdict.DISCARD;
    assert len(q) == 0, "queue should have been consumed";
}

test "image_from_base64 accepts a raw payload and a data URL" {
    import base64;
    with open("docs/spikes/byllm/label.png", "rb") as f {
        raw = f.read();
    }
    b64 = base64.b64encode(raw).decode();
    a = image_from_base64(b64);
    b = image_from_base64("data:image/png;base64," + b64);
    assert a.mime_type == b.mime_type;
    assert len(a.url) == len(b.url);
    assert len(a.url) > 0;
}
