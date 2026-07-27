"""Runnable MockLLM harness for the four §7 byLLM functions.

    ./.venv/bin/jac run tests/llm_mock.jac        # execute + dump prompts
    ./.venv/bin/jac test tests/llm_mock.jac       # assertions (llm_mock.test.jac)

Runs with no API key. Its job is to prove two things that `jac check` cannot:

  1. all four functions execute and hand back correctly typed values, so the
     walkers can rely on them today;
  2. the §4 domain rules actually reach the model. Every `sem` annotation is
     assembled into the request, and this file prints the assembled prompt for
     `shelf_life_verdict` verbatim - if the shelf-life table is not in that
     dump, the fix to Flaw 1 is not real.
"""

import from llm {
    DEFAULT_MODEL_NAME,
    DateType,
    ItemForClient,
    LabelRead,
    ShelfLifeCall,
    ShelfVerdict,
    extract_label,
    image_from_base64,
    image_from_source,
    explain_for_client,
    llm,
    resolve_constraints,
    shelf_life_verdict,
    _normalize_model_name
}

"""The prompt text byLLM assembled for the most recent dispatch.

MockLLM records each dispatch as the Python *repr* of the message list, so
newlines and quotes arrive backslash-escaped. Undo that so what is printed and
asserted on is the text the model actually receives.
"""
def last_prompt -> str {
    raw: any = getattr(llm, "seen_prompts", []);
    seen: list = list(raw);
    if len(seen) == 0 {
        return "";
    }
    return (
        str(seen[-1])
        .replace("\\n", "\n")
        .replace("\\'", "'")
        .replace('\\"', '"')
    );
}

def dispatch_count -> int {
    raw: any = getattr(llm, "seen_prompts", []);
    seen: list = list(raw);
    return len(seen);
}

def rule(title: str) {
    print("\n" + "=" * 78);
    print(title);
    print("=" * 78);
}

with entry {
    print("model in use:", type(llm).__name__, "/", llm.model_name);

    # -- 1. extract_label ---------------------------------------------------
    rule("1. extract_label(photo, hint) -> LabelRead");
    read = extract_label(
        image_from_source("docs/spikes/byllm/label.png"),
        "dented can off the back of the pallet"
    );
    print("brand ............", read.brand);
    print("product ..........", read.product);
    print("category .........", read.category);
    print("ingredients ......", read.ingredients_text);
    print("date_value .......", read.date_value);
    print("date_type ........", read.date_type, "-> stores as", str(read.date_type));
    print("lot_code .........", repr(read.lot_code));
    print("packaging_note ...", read.packaging_note);
    print("confidence .......", read.extraction_confidence);
    print("legibility_note ..", read.legibility_note);

    # -- 2. shelf_life_verdict ----------------------------------------------
    rule("2. shelf_life_verdict(category, date_type, days_past_code, packaging_note)");
    call = shelf_life_verdict(
        "canned_low_acid", DateType.BEST_BY, 847, "shallow dent on the flat side, seams intact"
    );
    print("verdict ..........", call.verdict, "-> stores as", str(call.verdict));
    print("reason ...........", call.reason);
    print("window ...........", call.typical_window_past_code);

    rule("2b. ASSEMBLED PROMPT for shelf_life_verdict (proof the §4 table lands)");
    print(last_prompt());

    # -- 3. explain_for_client ----------------------------------------------
    rule("3. explain_for_client(item, constraints, language) -> str");
    card = ItemForClient(
        brand=read.brand,
        product=read.product,
        category=read.category,
        date_value=read.date_value,
        date_type=read.date_type,
        allergens_listed=[],
        ingredients_text=read.ingredients_text,
        shelf_life_note=call.typical_window_past_code
    );
    note = explain_for_client(card, ["peanuts", "added sugar"], "Spanish");
    print(note);

    rule("3b. ASSEMBLED PROMPT for explain_for_client (framing rules)");
    print(last_prompt());

    # -- 4. resolve_constraints ---------------------------------------------
    rule("4. resolve_constraints(free_text) -> list[str]");
    tags = resolve_constraints("allergic to peanuts, vegetarian, diabetic");
    print("tags .............", tags);

    rule("4b. ASSEMBLED PROMPT for resolve_constraints (closed vocabulary)");
    print(last_prompt());

    rule("summary");
    print("dispatches:", dispatch_count());
    print("ShelfVerdict.REVIEW is the past-date route:", str(ShelfVerdict.REVIEW));
}
