"""Backshelf - the four byLLM reasoning functions (spec §7).

Everything the model is told lives in `sem` annotations and type signatures.
There is not one prompt string in this file, and there must never be one: the
§4 domain rules ARE the semstrings, so the rules travel with the type system
instead of with a hand-rolled f-string somewhere in a walker.

The §4 shelf-life table is carried by `sem shelf_life_verdict` below. That
annotation is the fix to Flaw 1 (v1 discarded past-date shelf-stable food).

Model selection is explicit and env-driven - see `_select_model`:
    GEMINI_API_KEY set   -> real Gemini through byLLM
    GEMINI_API_KEY unset -> DemoLLM (a MockLLM) so the whole app still runs
"""

import base64;
import os;
import from byllm.lib { Image, MockLLM, Model, MTRuntime }
import from byllm.llm { BaseLLM }
import from byllm.types { CompletionResult }

# byllm 0.6.19 mis-annotates `Image.url` as a string literal instead of a union,
# so a direct `Image(...)` can never pass `jac check`. Construct through here.
glob _ImageCls: any = Image;

# ---------------------------------------------------------------------------
# Constrained vocabularies
# ---------------------------------------------------------------------------

enum DateType: str {
    BEST_BY = "best_by",
    USE_BY = "use_by",
    SELL_BY = "sell_by",
    EXP = "exp",
    UNKNOWN = "unknown"
}
sem DateType =
    "Which KIND of date is printed on the package. Getting this right is the "
    "single most important field on the label: 'best by' and 'sell by' are "
    "quality indicators set by the manufacturer, while 'use by' on infant "
    "formula or baby food is the one federally meaningful safety date. The "
    "entire routing decision downstream branches on this value, so choose "
    "UNKNOWN rather than guessing when the wording is not actually printed.";
sem DateType.BEST_BY =
    "The package says 'Best By', 'Best Before', 'Best if Used By', or 'BB'. Quality only.";
sem DateType.USE_BY =
    "The package says 'Use By'. Quality for most foods; a real safety date only on "
    "infant formula and baby food.";
sem DateType.SELL_BY =
    "The package says 'Sell By' or 'Pull By'. A stock-rotation instruction aimed at the "
    "retailer, not at the person eating the food.";
sem DateType.EXP =
    "The package says 'EXP', 'Expires', or 'Expiration'. Common on nutrition drinks and "
    "infant formula.";
sem DateType.UNKNOWN =
    "No date wording is printed, or the wording is smudged, cropped, or too blurry to "
    "read with confidence. Choose this instead of guessing - an unknown date type routes "
    "the item to human review, which is the correct and safe outcome.";

enum ShelfVerdict: str {
    KEEP = "keep",
    REVIEW = "review",
    DISCARD = "discard"
}
sem ShelfVerdict = "Where this donated item goes next.";
sem ShelfVerdict.KEEP =
    "Within its printed date and undamaged. Route to the normal shelf (a human still "
    "clears it before it goes out).";
sem ShelfVerdict.REVIEW =
    "A volunteer must look at it. This is the correct answer for essentially every "
    "past-date shelf-stable item, and for anything unreadable or ambiguous.";
sem ShelfVerdict.DISCARD =
    "Bin it. Reserved for the short, explicit hard-discard list - never assigned on the "
    "basis of a past date alone.";

# ---------------------------------------------------------------------------
# 1. extract_label
# ---------------------------------------------------------------------------

obj LabelRead {
    has brand: str;
    has product: str;
    has category: str;
    has ingredients_text: str;
    has date_value: str;
    has date_type: DateType;
    has lot_code: str;
    has packaging_note: str;
    has extraction_confidence: float;
    has legibility_note: str;
}
sem LabelRead = "Everything legible on one donated food package, transcribed - not interpreted.";
sem LabelRead.brand =
    "Brand or manufacturer name exactly as printed, e.g. 'FIRST STREET'. Empty string if "
    "no brand is visible.";
sem LabelRead.product =
    "Product description as printed, including size or net weight when shown, e.g. "
    "'Dark Chocolate Raisins 9oz'. Empty string if unreadable.";
sem LabelRead.category =
    "Exactly one key from this closed list, chosen from what the food actually is: "
    "canned_low_acid (canned vegetables, meat, soup, beans), "
    "canned_high_acid (canned tomatoes, citrus, fruit, pickles), "
    "dry_pasta_rice, boxed_mix (cake, brownie, pancake), cereal, peanut_butter, "
    "shelf_stable_juice, condiment_sauce, snack_food (crackers, chips, cookies, dried "
    "fruit), nutrition_drink (Ensure, Boost, meal-replacement shakes), "
    "baby_food_formula (infant formula, jarred or pouched baby food), "
    "perishable (dairy, eggs, fresh meat, produce), "
    "home_canned (a mason jar, a handwritten label, or any homemade item), "
    "other. Use 'other' rather than forcing a poor fit.";
sem LabelRead.ingredients_text =
    "The ingredient statement transcribed verbatim, including any 'Contains:' and "
    "'May contain:' lines, because those lines are what allergen tagging is built on. "
    "Empty string if no ingredient panel is visible in the photo.";
sem LabelRead.date_value =
    "The printed date exactly as it appears, e.g. '022527', 'BB 02/25/27', "
    "'JAN 23 2027'. Do not normalise it and do not invent one - empty string if no date "
    "is legible.";
sem LabelRead.date_type =
    "Which kind of date date_value is. Read the wording printed next to the date; do not "
    "infer it from the food type.";
sem LabelRead.lot_code =
    "The manufacturer lot / batch code verbatim, e.g. 'Lot 260562'. This is the field "
    "that lets a recall be matched to THIS package rather than to a whole brand, so "
    "transcribe every character including letters and spaces. Empty string if no lot "
    "code is legible - an empty lot code is far better than a guessed one.";
sem LabelRead.packaging_note =
    "What the container physically looks like: dents and whether they are on a seam, "
    "bulging or swelling, rust, punctures, leaks, and whether the safety seal or "
    "shrink band is intact. Write 'no visible damage' when it looks sound. Report only "
    "what is visible in the photo.";
sem LabelRead.extraction_confidence =
    "0.0 to 1.0, how much of this reading you would stand behind. Below 0.6 means you "
    "are guessing, and the item will be sent to a human instead of to the shelf. Score "
    "honestly - a low score here is a feature, not a failure.";
sem LabelRead.legibility_note =
    "One short sentence naming what could NOT be read and why, e.g. 'lot code cropped "
    "out of frame' or 'date smudged'. Empty string when the whole label read cleanly.";

def extract_label(photo: Image, hint: str) -> LabelRead by llm(temperature=0.0);
sem extract_label =
    "Transcribe one donated food package from a photo taken at a food pantry intake "
    "desk. You are a transcriber, not an appraiser: report what is printed and what is "
    "visible, and never fill a field from general knowledge of the product. If "
    "something is not in the photo, leave it empty and say so in legibility_note. A "
    "guessed date or a guessed lot code is worse than no value at all, because a wrong "
    "lot code can either hide a real recall or destroy food that was never recalled.";
sem extract_label.photo =
    "A phone photo of the package, taken by a volunteer at the intake desk - often "
    "handheld, off-angle, and lit by fluorescent overheads. The date and lot code are "
    "usually ink-jetted on the lid, the can rim, or a crimped end rather than on the "
    "main label.";
sem extract_label.hint =
    "An optional free-text note from the volunteer about what the item is, e.g. "
    "'dented can from the back of the pallet'. May be empty. Treat it as a hint only - "
    "the photo overrides it wherever they disagree.";

"""Build the `photo` argument for `extract_label` from a base64 payload.

IntakeScan receives the phone photo as base64 (spec §6). byllm 0.6.19 annotates
`Image.url` with a string LITERAL of its own union type rather than the union
itself, so NO argument can satisfy `jac check` at a direct `Image(...)` call.
Calling through the `any`-typed `_ImageCls` glob and casting back is the
workaround proven in docs/spikes/byllm/s05c_image_factory.jac.
Accepts a bare base64 string or a `data:image/...;base64,` data URL.
"""
def image_from_base64(payload: str) -> Image {
    body = payload.split(",")[-1] if payload.startswith("data:") else payload;
    return _ImageCls(base64.b64decode(body)) as Image;
}

"""Build the `photo` argument for `extract_label` from a file path or URL."""
def image_from_source(src: str) -> Image {
    return _ImageCls(src) as Image;
}

# ---------------------------------------------------------------------------
# 2. shelf_life_verdict  -- this is where the fix to Flaw 1 lives
# ---------------------------------------------------------------------------

obj ShelfLifeCall {
    has verdict: ShelfVerdict;
    has reason: str;
    has typical_window_past_code: str;
}
sem ShelfLifeCall = "A routing decision for one donated item, with the rule that produced it.";
sem ShelfLifeCall.verdict = "Where the item goes: keep, review, or discard.";
sem ShelfLifeCall.reason =
    "Two sentences at most, plain English, addressed to a volunteer holding the item. "
    "Name the rule you applied. When the verdict is review because the item is past its "
    "code, say plainly that the date is a quality date rather than a safety date and "
    "that the item is not being thrown away.";
sem ShelfLifeCall.typical_window_past_code =
    "The published pantry shelf-life window for this category, quoted from the table, "
    "e.g. '2-5 years past code' or '12-18 months past code'. For categories that must "
    "not be extended, write 'do not extend past the printed date'. Empty string when "
    "the item is not past its code.";

def shelf_life_verdict(
    category: str,
    date_type: DateType,
    days_past_code: int,
    packaging_note: str
) -> ShelfLifeCall by llm(temperature=0.0);

sem shelf_life_verdict =
    "Decide where one donated item goes at a food pantry intake desk.\n"
    "\n"
    "START FROM THIS FACT, IT IS THE WHOLE POINT OF THIS FUNCTION: except for infant "
    "formula and baby food, food date labels in the United States are NOT federally "
    "regulated and are NOT safety dates. 'Best by' and 'sell by' indicate peak quality. "
    "Food banks routinely and deliberately distribute past-code shelf-stable food, and "
    "publish shelf-life guides precisely because they do. Date-label confusion drives "
    "an estimated 20% of household food waste. Pantries are chronically supply "
    "constrained, so throwing out edible food is itself a harm, not a safe default.\n"
    "\n"
    "THE HARD RULE: a past date, on its own, NEVER produces discard. Past-date "
    "shelf-stable goods go to review with a shelf-life note. There is no exception to "
    "this other than the explicit discard list below.\n"
    "\n"
    "DISCARD ONLY IF ONE OF THESE IS TRUE, and nothing else ever produces discard:\n"
    "  1. category is baby_food_formula and the date has passed (days_past_code > 0). "
    "This is the one federally regulated category and it discards unconditionally.\n"
    "  2. packaging_note describes a compromised container: a dent on the seam or rim, "
    "bulging or swelling, rust through the metal, a puncture, a leak, or a broken "
    "safety seal or shrink band. A shallow dent on the flat body of a can with the "
    "seams intact is NOT compromised.\n"
    "  3. category is perishable (dairy, eggs, fresh meat, produce) and the date has "
    "passed.\n"
    "  4. category is home_canned, or the item is unlabeled or homemade. Pantries "
    "cannot accept these at all.\n"
    "\n"
    "REFERENCE SHELF-LIFE WINDOWS PAST THE CODE DATE, from published food bank guides:\n"
    "  canned_low_acid (vegetables, meat, soup, beans) ... 2-5 years past code\n"
    "  canned_high_acid (tomatoes, citrus, fruit, pickles) ... 12-18 months past code\n"
    "  dry_pasta_rice (dry pasta, white rice) ... 2+ years past code\n"
    "  boxed_mix (cake, brownie, pancake) ... 12 months past code\n"
    "  cereal ... 6-12 months past code\n"
    "  peanut_butter ... 6-12 months past code\n"
    "  shelf_stable_juice (juice, juice boxes) ... 6-12 months past code\n"
    "  condiment_sauce (unopened condiments and sauces) ... 12-18 months past code\n"
    "  snack_food (snacks, crackers, chips) ... 3-6 months past code, quality only\n"
    "  nutrition_drink (Ensure, Boost) ... use by the date, do not extend\n"
    "  baby_food_formula (baby food, infant formula) ... NEVER past the date\n"
    "  perishable (dairy, eggs, fresh meat, produce) ... do not extend past the date\n"
    "\n"
    "DECIDE IN THIS ORDER:\n"
    "  a. Any discard condition above is true -> discard, and say which one.\n"
    "  b. date_type is UNKNOWN, or days_past_code cannot be trusted, or the category is "
    "'other' -> review. Never discard for ambiguity.\n"
    "  c. days_past_code <= 0, container sound -> keep.\n"
    "  d. days_past_code > 0 on any shelf-stable category -> review. Quote that "
    "category's window in typical_window_past_code and say in the reason whether the "
    "item is inside or beyond that window. Beyond the window is still review, not "
    "discard: the window describes quality, and a human makes the final call.\n"
    "  e. nutrition_drink past its date -> review, with a note that this category is "
    "not extended past the printed date.\n"
    "\n"
    "Never state that a food is safe. You are routing an item to a person, not "
    "certifying it.";

sem shelf_life_verdict.category =
    "One key from the closed category list: canned_low_acid, canned_high_acid, "
    "dry_pasta_rice, boxed_mix, cereal, peanut_butter, shelf_stable_juice, "
    "condiment_sauce, snack_food, nutrition_drink, baby_food_formula, perishable, "
    "home_canned, other. If it is 'other', route to review rather than picking a "
    "neighbouring row of the table.";
sem shelf_life_verdict.date_type =
    "The kind of date printed on the package. best_by and sell_by are quality dates. "
    "use_by and exp are also quality dates on everything except infant formula and baby "
    "food. unknown means the wording could not be read, which forces review.";
sem shelf_life_verdict.days_past_code =
    "Whole days between the printed code date and today. Positive means the code date "
    "has passed; negative means the code date is still in the future; 0 is today.";
sem shelf_life_verdict.packaging_note =
    "The volunteer's description of the physical container, e.g. 'small dent on the flat "
    "side, seams intact' or 'lid is bulging'. 'no visible damage' means the container is "
    "sound. Judge only what this note actually describes - absence of a note is not "
    "evidence of damage.";

# ---------------------------------------------------------------------------
# 3. explain_for_client
# ---------------------------------------------------------------------------

obj ItemForClient {
    has brand: str;
    has product: str;
    has category: str;
    has date_value: str;
    has date_type: DateType;
    has allergens_listed: list[str];
    has ingredients_text: str;
    has shelf_life_note: str;
}
sem ItemForClient = "One item currently on the pantry shelf, as shown to the person choosing it.";
sem ItemForClient.brand = "Brand as printed on the package.";
sem ItemForClient.product = "Product description as printed.";
sem ItemForClient.category = "The pantry category key for this item.";
sem ItemForClient.date_value = "The date printed on the package, verbatim.";
sem ItemForClient.date_type = "Which kind of date date_value is.";
sem ItemForClient.allergens_listed =
    "The allergens and dietary tags that THIS PACKAGE'S LABEL LISTS, tagged at intake "
    "from the ingredient statement. An item missing from this list means the label did "
    "not list it - it does NOT mean the food is free of it.";
sem ItemForClient.ingredients_text = "The ingredient statement as printed, or empty if none was legible.";
sem ItemForClient.shelf_life_note =
    "The pantry's shelf-life note for this item, if it is past its printed code. Empty "
    "otherwise.";

def explain_for_client(
    item: ItemForClient,
    constraints: list[str],
    language: str
) -> str by llm(temperature=0.2);

sem explain_for_client =
    "Write a short note to a person picking up food at a pantry, telling them what this "
    "package's label shows in relation to what they told us to watch out for.\n"
    "\n"
    "FRAMING RULES, ABSOLUTE:\n"
    "  - Never say a food is safe, unsafe, safe for them, or fine to eat. You are "
    "reporting a label, not certifying a food.\n"
    "  - Say 'the label lists' and 'the label does not list'. Never say 'contains', "
    "'free from', 'free of', 'does not contain', or 'allergen-free'. An ingredient "
    "statement is evidence about a label, not proof about a food: manufacturers "
    "reformulate, and shared equipment is not always declared.\n"
    "  - Never promise the item is suitable for a medical or religious restriction. "
    "Report what the label lists and let the person decide.\n"
    "  - Always end by telling them to check the label on the package themselves.\n"
    "\n"
    "STYLE: two to four short sentences, plain everyday words, the reading level of a "
    "community newsletter. No jargon, no bullet points, no markdown, no emoji. Warm and "
    "matter-of-fact - this person is standing in a line with their kids. Do not "
    "apologise and do not lecture.\n"
    "\n"
    "CONTENT: name the item, then say for each of their stated constraints whether the "
    "label lists the relevant ingredient or does not list it. `allergens_listed` holds "
    "only what THIS package's label actually declares, so a constraint missing from "
    "that list means the label did not list it and NOT that the food is free of it - "
    "say it that way round. If the item is past its "
    "printed date, say so plainly and pass on the shelf-life note, making clear that "
    "the date is about quality rather than a safety cutoff. If the ingredient statement "
    "was not legible, say that instead of implying anything about what is in the food.";

sem explain_for_client.item =
    "The item on the shelf, including the allergens its label lists and the ingredient "
    "statement transcribed at intake.";
sem explain_for_client.constraints =
    "What this household told us to watch for, as resolved tag names, e.g. "
    "['peanuts', 'added sugar']. May be empty, in which case just describe the item and "
    "what its label lists.";
sem explain_for_client.language =
    "The language to write the ENTIRE note in, given as a name or BCP-47 code, e.g. "
    "'Spanish', 'es', 'Vietnamese', 'zh-Hant'. Write every word in that language "
    "including any label wording you paraphrase, and use the register an ordinary "
    "speaker would use rather than a formal or literary one. Default to English if it "
    "is empty.";

# ---------------------------------------------------------------------------
# 4. resolve_constraints
# ---------------------------------------------------------------------------

def resolve_constraints(free_text: str) -> list[str] by llm(temperature=0.0);

sem resolve_constraints =
    "Turn what a person said about their dietary needs into tag names that exist in the "
    "pantry's graph.\n"
    "\n"
    "Return ONLY names drawn from this closed vocabulary, lowercase, exactly as spelled "
    "here:\n"
    "  FDA major allergens: milk, eggs, fish, shellfish, tree nuts, peanuts, wheat, "
    "soybeans, sesame\n"
    "  Dietary and religious tags: pork, beef, gelatin, alcohol\n"
    "  Health tags: added sugar\n"
    "\n"
    "Expand a stated need into every tag it implies, because the person will not name "
    "them all:\n"
    "  vegetarian -> fish, shellfish, pork, beef, gelatin\n"
    "  vegan -> milk, eggs, fish, shellfish, pork, beef, gelatin\n"
    "  diabetic or 'watching my sugar' -> added sugar\n"
    "  halal or kosher -> pork, alcohol, gelatin\n"
    "  'no nuts' -> peanuts, tree nuts (peanuts are legumes, so name both explicitly)\n"
    "  lactose intolerant or dairy-free -> milk\n"
    "  celiac or gluten-free -> wheat\n"
    "\n"
    "Return an empty list rather than inventing a tag for something the vocabulary does "
    "not cover - an unmatched tag would silently filter nothing. Do not return "
    "duplicates. Do not return a tag for a preference that is about taste rather than "
    "avoidance.";
sem resolve_constraints.free_text =
    "What the person typed or said, in any language and in their own words, e.g. "
    "'allergic to peanuts, vegetarian, diabetic' or 'soy alergica a los mariscos'. May "
    "be messy, abbreviated, or empty.";

# ---------------------------------------------------------------------------
# Model selection: real Gemini when the key is present, MockLLM when it is not
# ---------------------------------------------------------------------------

obj DemoLLM(MockLLM) {
    """MockLLM that never runs dry and never depends on call ORDER.

    Stock MockLLM pops one entry off a fixed `outputs` list per call, so the
    app crashes on the first call past the end of the list and mis-serves any
    call made out of the scripted order. Backshelf's walkers call these four
    functions in whatever order the graph dictates, all day, so instead we
    route on the RETURN TYPE the call site asked for (`mt_run.resp_type`):
    a `LabelRead` call always gets a LabelRead back.

    `queue` is an escape hatch for tests and demo seeding: anything pushed
    there is consumed first, in order, before the type-routed defaults.
    """
    has queue: list[object] = [],
        canned: dict[str, object] = {};

    override def dispatch_no_streaming(mt_run: MTRuntime) -> CompletionResult;
}

impl DemoLLM.dispatch_no_streaming(mt_run: MTRuntime) -> CompletionResult {
    if len(self.queue) > 0 {
        nxt = self.queue.pop(0);
    } else {
        key = str(getattr(mt_run.resp_type, "__name__", "str"));
        nxt = self.canned.get(key, "");
    }
    self.config["outputs"] = [nxt];
    return super.dispatch_no_streaming(mt_run);
}

"""A DemoLLM stocked with one plausible answer per return type.

The default LabelRead is the §11 demo item: a can of green beans well past a
'best by' date, which v1 would have thrown away and v2 routes to review.
"""
def _demo_llm -> DemoLLM {
    return DemoLLM(
        model_name="mockllm",
        config={"outputs": [], "verbose": True, "show_params": True},
        canned={
            "LabelRead": LabelRead(
                brand="DEL MONTE",
                product="Cut Green Beans 14.5 oz",
                category="canned_low_acid",
                ingredients_text="GREEN BEANS, WATER, SALT.",
                date_value="BEST BY 03/2024",
                date_type=DateType.BEST_BY,
                lot_code="",
                packaging_note="shallow dent on the flat side, seams intact",
                extraction_confidence=0.88,
                legibility_note="lot code not visible in this photo"
            ),
            "ShelfLifeCall": ShelfLifeCall(
                verdict=ShelfVerdict.REVIEW,
                reason=(
                    "This can is past its best-by date, which is a quality date set by "
                    "the manufacturer and not a safety cutoff, so it is not being "
                    "thrown away. Put it in the review queue for a volunteer to look "
                    "over the seams and the dent."
                ),
                typical_window_past_code="2-5 years past code"
            ),
            "str": (
                "This is a can of Del Monte cut green beans. The label lists green "
                "beans, water and salt, and it does not list peanuts or added sugar. "
                "The best-by date on the can has passed, which is about quality rather "
                "than a safety cutoff - canned vegetables are usually good for two to "
                "five years past that date. Please check the label on the package "
                "yourself before you use it."
            ),
            "list": ["peanuts", "added sugar"]
        }
    );
}

"""THE SWITCH. Gemini when GEMINI_API_KEY is set, MockLLM when it is not.

No key on the machine means the whole product still runs end to end today,
which is the point - intake, verdicts, client explanations and the recall sweep
all work against DemoLLM. Set GEMINI_API_KEY and nothing else in the codebase
changes.
"""
def _select_model -> BaseLLM {
    api_key = os.getenv("GEMINI_API_KEY", "");
    if api_key {
        return Model(
            model_name=os.getenv("BACKSHELF_MODEL", "gemini/gemini-2.0-flash"),
            api_key=api_key
        );
    }
    return _demo_llm();
}

glob llm: BaseLLM = _select_model();

"""True when this process is running on the MockLLM fallback."""
def _using_mock_llm -> bool {
    return isinstance(llm, MockLLM);
}
