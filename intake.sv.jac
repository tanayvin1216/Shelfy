"""Backshelf - the intake desk (spec section 6): `IntakeScan` and `ClearItem`.

Both walkers are the API. `jac start` turns them into `POST /walker/IntakeScan`
and `POST /walker/ClearItem`; there is no hand-written route anywhere.

The two spec flaws this module exists to fix:

  Flaw 1 (v1 discarded past-date food).  `shelf_life_verdict` carries the sec-4
  shelf-life table in its semstring, and `_discard_allowed` below is the
  defence-in-depth: even if the model returns `discard`, the WALKER refuses to
  honour it unless one of the four hard-discard conditions is physically true.
  A past date on its own can never produce a discard verdict on this code path.

  Flaw 2 (v1 flagged whole brands).  `_classify_recall` matches on brand AND
  product AND lot code, and returns the sec-4 confidence tier. A scanned lot
  that is demonstrably NOT in the recall's `code_info` is downgraded, not
  escalated - that is the entire point. Nothing is ever auto-discarded on a
  POSSIBLE or WEAK match.

`ClearItem`'s refusal gate lives in the walker (`can clear with Item entry`),
not in the UI, so it holds for the client, for curl, and for any future caller.
"""

import re;
import from datetime { date }

import from graph {
    Item, Shelf, Allergen, RecallFeed, RecallRecord,
    Stocks, Contains, FlaggedBy, Lists,
    ItemView,
    CONFIRMED, POSSIBLE, WEAK, SHELF_CANNED, SHELF_REVIEW,
    _get_shelf, _review_shelf, _get_allergen, _get_recall_feed, _now, _norm
}

import from llm {
    DateType, ShelfVerdict, LabelRead, ShelfLifeCall,
    extract_label, shelf_life_verdict,
    image_from_base64, image_from_source, _using_mock_llm
}

# Recall matching is deliberately NOT duplicated here. Intake and the
# retroactive sweep must agree to the letter about which recalls cover which
# jar: if the desk reads a jar CONFIRMED and the sweep reads the same jar WEAK,
# the sweep un-blocks it and silently stops naming the households that took it
# home. That happened - intake and the sweep each kept their own brand and
# product matchers and they drifted.
#
# So the whole grader lives in `sweep.sv.jac` and this file calls it. Intake
# adds only the volunteer-facing wording around the tier it is handed; it never
# decides the tier itself.
import from sweep {
    _classify, _product_matched, _evidence_id, _stamp, _lot_state
}

# ---------------------------------------------------------------------------
# Thresholds and vocabularies
# ---------------------------------------------------------------------------

"""Below this, the label read is a guess and the item goes to a human (sec 4:
"Low-confidence or unreadable extraction -> REVIEW, never a guess onto the shelf")."""
glob MIN_EXTRACTION_CONFIDENCE: float = 0.6;

"""Categories where a passed date genuinely does mean discard (sec 4)."""
glob DATE_CRITICAL_CATEGORIES: list[str] = ["baby_food_formula", "perishable"];

"""Pantries cannot accept these at all, dated or not."""
glob NEVER_ACCEPTED_CATEGORIES: list[str] = ["home_canned"];

"""Ingredient wording -> Allergen node name.

Deliberately over-inclusive. Over-tagging an allergen costs a client one item
on a filtered shelf; under-tagging costs a child an anaphylactic reaction. That
asymmetry runs the OPPOSITE way from recall matching, where over-flagging
destroys scarce food - which is why the two matchers are tuned differently.

The matched ingredient fragment is stored verbatim on the `Contains` edge as
`evidence`, so a volunteer can always see why a tag was applied.
"""
glob ALLERGEN_KEYWORDS: dict[str, list[str]] = {
    "milk": [
        "milk", "milks", "milkfat", "buttermilk", "cream", "creamer", "butter",
        "cheese", "whey", "casein", "caseinate", "lactose", "ghee", "yogurt",
        "yoghurt", "dairy", "custard"
    ],
    "eggs": [
        "egg", "eggs", "egg white", "egg whites", "egg yolk", "egg yolks",
        "albumin", "ovalbumin", "mayonnaise", "meringue"
    ],
    "fish": [
        "fish", "anchovy", "anchovies", "tuna", "salmon", "cod", "sardine",
        "sardines", "tilapia", "pollock", "worcestershire"
    ],
    "shellfish": [
        "shellfish", "shrimp", "prawn", "prawns", "crab", "lobster", "crawfish",
        "oyster", "oysters", "clam", "clams", "scallop", "scallops", "mussel",
        "mussels", "krill"
    ],
    "tree nuts": [
        "tree nut", "tree nuts", "almond", "almonds", "cashew", "cashews",
        "walnut", "walnuts", "pecan", "pecans", "pistachio", "pistachios",
        "hazelnut", "hazelnuts", "macadamia", "brazil nut", "brazil nuts",
        "praline", "marzipan"
    ],
    "peanuts": [
        "peanut", "peanuts", "peanut butter", "peanut oil", "peanut flour",
        "groundnut", "groundnuts", "arachis"
    ],
    "wheat": [
        "wheat", "wheat flour", "whole wheat", "enriched flour",
        "enriched wheat flour", "bleached flour", "graham flour", "semolina",
        "durum", "spelt", "farina", "gluten", "couscous", "bulgur", "seitan"
    ],
    "soybeans": [
        "soy", "soya", "soybean", "soybeans", "soy lecithin", "soybean oil",
        "soy protein", "soy sauce", "tofu", "edamame", "miso", "tempeh"
    ],
    "sesame": [
        "sesame", "sesame seed", "sesame seeds", "sesame oil", "tahini", "benne"
    ],
    "pork": [
        "pork", "bacon", "ham", "lard", "prosciutto", "pancetta", "chorizo"
    ],
    "beef": ["beef", "tallow", "oxtail", "suet"],
    "gelatin": ["gelatin", "gelatine"],
    "alcohol": [
        "alcohol", "wine", "beer", "rum", "brandy", "liqueur", "sherry",
        "vodka", "whiskey", "bourbon"
    ],
    "added sugar": [
        "sugar", "sugars", "cane sugar", "brown sugar", "cane juice",
        "corn syrup", "high fructose corn syrup", "dextrose", "sucrose",
        "fructose", "maltose", "molasses", "honey", "agave nectar",
        "invert sugar", "malt syrup", "rice syrup", "maple syrup", "glucose"
    ]
};

"""Compound ingredient names that contain an allergen keyword but are not that
allergen. Blanked out of the fragment before that one allergen is tested, so
'COCOA BUTTER' stops reading as dairy while 'PEANUT BUTTER' still reads as
peanuts (it is only removed for the milk test, not the peanut test)."""
glob FALSE_FRIENDS: dict[str, list[str]] = {
    "milk": [
        "cocoa butter", "shea butter", "peanut butter", "almond butter",
        "cashew butter", "sunflower butter", "apple butter", "coconut milk",
        "soy milk", "almond milk", "oat milk", "rice milk", "coconut cream",
        "cream of tartar"
    ],
    "beef": ["beef free"],
    "tree nuts": ["nutmeg", "coconut", "water chestnut"]
};

"""An ingredient fragment carrying one of these is a claim of ABSENCE, so it
must not produce a tag. Guards the diabetic filter against 'sugar free'."""
glob NEGATION_MARKERS: list[str] = [
    "sugar free", "sugar-free", "no added sugar", "unsweetened", "free of",
    "does not contain", "non-dairy", "nondairy", "dairy free", "dairy-free",
    "gluten free", "gluten-free"
];

"""Physical damage wording that genuinely does justify a discard (sec 4)."""
glob COMPROMISED_MARKERS: list[str] = [
    "bulg", "swell", "swollen", "rust", "punctur", "leak", "leaking",
    "broken seal", "seal broken", "seal is broken", "seal missing",
    "tampered", "compromised", "hissed", "sharp dent", "deep dent",
    "dent on the seam", "dent on seam", "dented seam", "seam dent",
    "seam is dented", "dent on the rim", "dent on rim", "rim dent"
];

"""Wording that CANCELS a damage word standing after it in the same clause.

A volunteer writes down what they CHECKED, not only what they found: "no dents,
no bulging, no rust; safety seal intact" describes a sound can. Reading it as a
damaged one bins edible food - Flaw 1 coming back through a different door - and
it also silently unlocks the `_discard_allowed` backstop. A negation reaches
only forward and only inside its own clause, so "no dents but the seam is
bulging" is still compromised.
"""
glob PACKAGING_NEGATIONS: list[str] = [
    " no ", " not ", " none", " never", " without ", " free of ", " free from ",
    " n/a", " nothing", " absent", " lacks ", " zero ", " does not ",
    " doesn't ", " didn't ", " isn't ", " is not ", " are not ", " aren't ",
    " negative for ", " clear of ", " nil"
];

"""Clause boundaries. A negation never reaches past one of these."""
glob CLAUSE_BREAKS: list[str] = [
    ";", ",", ".", "\n", "|", "/", " but ", " however ", " though ",
    " although ", " except ", " while ", " yet ", " and "
];

glob MONTH_NAMES: dict[str, int] = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
};

glob DAYS_IN_MONTH: list[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

# ---------------------------------------------------------------------------
# Report shapes - walkers report these, never raw nodes or ad-hoc dicts
# ---------------------------------------------------------------------------

obj TraceStep {
    """One decision the walker made, with where the decision came from.

    `source` is either `byllm:<fn>` (a model call), `graph` (a traversal), or
    `rule sec 4` (a hard domain rule enforced in this file). The trace is what
    lets a judge - or a volunteer - see that the routing was not a black box.
    """
    has step: str,
        detail: str,
        source: str;
}

obj AllergenHit {
    has name: str,
        evidence: str;
}

obj RecallMatch {
    """The sec-4 confidence tier for one Item / RecallRecord pair."""
    has recall_number: str,
        confidence: str,
        matched_fields: str,
        note: str,
        scanned_lot: str,
        recall_lot_codes: str,
        classification: str,
        reason: str;
}

obj IntakeReport {
    has item: ItemView,
        verdict: str,
        verdict_reason: str,
        blocked: bool,
        destination_shelf: str,
        holding_shelf: str,
        days_past_code: int,
        date_parsed: bool,
        shelf_life_window: str,
        allergen_tags: list[AllergenHit],
        recall_matches: list[RecallMatch],
        recall_records_compared: int,
        trace: list[TraceStep],
        using_mock_llm: bool;
}

obj ClearReport {
    has item: ItemView | None,
        cleared: bool,
        refused: bool,
        refusal_reason: str,
        blocking_recalls: list[str],
        shelf: str;
}

# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

"""Split an ingredient statement into the phrases a label actually prints."""
def _fragments(text: str) -> list[str] {
    out: list[str] = [];
    for part in re.split(r"[,;.\n\r()\[\]]+", text) {
        cleaned = str(part).strip();
        if cleaned != "" {
            out.append(cleaned);
        }
    }
    return out;
}

# ---------------------------------------------------------------------------
# Date parsing - turns a printed code date into days past code
# ---------------------------------------------------------------------------

def _month_len(year: int, month: int) -> int {
    if month == 2 and ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) {
        return 29;
    }
    return DAYS_IN_MONTH[month - 1];
}

def _expand_year(raw: int) -> int {
    if raw >= 100 {
        return raw;
    }
    return 2000 + raw if raw < 70 else 1900 + raw;
}

"""Build a date, clamping the day into the month. Returns None on nonsense
so an unreadable date falls through to review instead of to a wrong verdict."""
def _mk_date(year: int, month: int, day: int) -> date | None {
    if month < 1 or month > 12 {
        return None;
    }
    if year < 1990 or year > 2100 {
        return None;
    }
    if day < 1 {
        return None;
    }
    clamped = day;
    limit = _month_len(year, month);
    if clamped > limit {
        clamped = limit;
    }
    return date(year, month, clamped);
}

"""Read the date a manufacturer actually ink-jets onto a package.

Handles ISO, `MON D YYYY`, `D MON YYYY`, `MON YYYY`, `M/D/YY`, `M/YYYY`,
`M/YY` and the bare 6-digit `MMDDYY` stamp (falling back to `YYMMDD` when
the first reading gives an impossible month). A month-only date resolves to
the LAST day of that month - the generous reading, which is the anti-waste
direction. Returns None when nothing parses; the caller then routes to
review rather than inventing a number.
"""
def _parse_code_date(date_value: str) -> date | None {
    raw = date_value.strip();
    if raw == "" {
        return None;
    }
    low = raw.lower();

    iso = re.search(r"(\d{4})-(\d{1,2})-(\d{1,2})", low);
    if iso {
        return _mk_date(int(iso.group(1)), int(iso.group(2)), int(iso.group(3)));
    }

    mdy_name = re.search(r"([a-z]{3})[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{2,4})", low);
    if mdy_name and mdy_name.group(1) in MONTH_NAMES {
        return _mk_date(
            _expand_year(int(mdy_name.group(3))),
            MONTH_NAMES[mdy_name.group(1)],
            int(mdy_name.group(2))
        );
    }

    dmy_name = re.search(r"(\d{1,2})\s*-?\s*([a-z]{3})[a-z]*\.?\s*-?\s*(\d{2,4})", low);
    if dmy_name and dmy_name.group(2) in MONTH_NAMES {
        return _mk_date(
            _expand_year(int(dmy_name.group(3))),
            MONTH_NAMES[dmy_name.group(2)],
            int(dmy_name.group(1))
        );
    }

    my_name = re.search(r"([a-z]{3})[a-z]*\.?\s+(\d{4})", low);
    if my_name and my_name.group(1) in MONTH_NAMES {
        month = MONTH_NAMES[my_name.group(1)];
        year = int(my_name.group(2));
        return _mk_date(year, month, _month_len(year, month));
    }

    mdy = re.search(r"(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})", low);
    if mdy {
        return _mk_date(
            _expand_year(int(mdy.group(3))), int(mdy.group(1)), int(mdy.group(2))
        );
    }

    my_full = re.search(r"(\d{1,2})[/\-.](\d{4})", low);
    if my_full {
        month = int(my_full.group(1));
        year = int(my_full.group(2));
        if month >= 1 and month <= 12 {
            return _mk_date(year, month, _month_len(year, month));
        }
    }

    my_short = re.search(r"(?<!\d)(\d{1,2})[/\-.](\d{2})(?!\d)", low);
    if my_short {
        month = int(my_short.group(1));
        year = _expand_year(int(my_short.group(2)));
        if month >= 1 and month <= 12 {
            return _mk_date(year, month, _month_len(year, month));
        }
    }

    stamp = re.search(r"(?<!\d)(\d{6})(?!\d)", low);
    if stamp {
        digits = stamp.group(1);
        as_mmddyy = _mk_date(
            _expand_year(int(digits[4:6])), int(digits[0:2]), int(digits[2:4])
        );
        if as_mmddyy is not None {
            return as_mmddyy;
        }
        return _mk_date(
            _expand_year(int(digits[0:2])), int(digits[2:4]), int(digits[4:6])
        );
    }

    return None;
}

"""Positive = the printed code date has passed. None = unparseable."""
def _days_past_code(date_value: str) -> int | None {
    parsed = _parse_code_date(date_value);
    if parsed is None {
        return None;
    }
    return (date.today() - parsed).days;
}

"""Item.date_type is a plain str on the graph; the LLM contract wants the enum."""
def _date_type_of(value: str) -> DateType {
    key = _norm(value);
    if key == "best_by" { return DateType.BEST_BY; }
    if key == "use_by" { return DateType.USE_BY; }
    if key == "sell_by" { return DateType.SELL_BY; }
    if key == "exp" { return DateType.EXP; }
    return DateType.UNKNOWN;
}

# ---------------------------------------------------------------------------
# Allergen tagging
# ---------------------------------------------------------------------------

def _fragment_negates(fragment: str) -> bool {
    low = fragment.lower();
    for marker in NEGATION_MARKERS {
        if marker in low {
            return True;
        }
    }
    return False;
}

"""Blank out the compound names that are false friends for THIS allergen only."""
def _mask_false_friends(fragment: str, allergen: str) -> str {
    masked: str = fragment.lower();
    for friend in FALSE_FRIENDS.get(allergen, []) {
        masked = masked.replace(friend, " ");
    }
    return masked;
}

def _fragment_lists(fragment: str, keywords: list[str]) -> bool {
    low = fragment.lower();
    for kw in keywords {
        if re.search(r"(?<![a-z])" + re.escape(kw) + r"(?![a-z])", low) {
            return True;
        }
    }
    return False;
}

"""Every allergen / dietary tag this LABEL LISTS, with the words that justify it.

Never phrased as "contains" anywhere it reaches a person - an ingredient
statement is evidence about a label, not proof about a food.
"""
def _tag_allergens(ingredients_text: str) -> list[AllergenHit] {
    hits: list[AllergenHit] = [];
    if ingredients_text.strip() == "" {
        return hits;
    }
    frags = _fragments(ingredients_text);
    for name in ALLERGEN_KEYWORDS.keys() {
        evidence: list[str] = [];
        for frag in frags {
            if _fragment_negates(frag) {
                continue;
            }
            if _fragment_lists(_mask_false_friends(frag, name), ALLERGEN_KEYWORDS[name])
               and frag not in evidence {
                evidence.append(frag);
            }
        }
        if len(evidence) > 0 {
            hits.append(AllergenHit(name=name, evidence="; ".join(evidence)[:180]));
        }
    }
    return hits;
}

# ---------------------------------------------------------------------------
# Recall matching - the fix to Flaw 2
# ---------------------------------------------------------------------------

"""Volunteer-facing wording for a tier the shared grader already decided.

The sec-4 tiers themselves are `_classify` in `sweep.sv.jac` - brand alone is
never enough to block anything, and a `differs` lot is DOWNGRADED to WEAK
rather than escalated, because a Jif recall must not flag every jar of Jif in
the building. This function chooses no tier; it only explains one. That is the
whole reason it stopped having its own matchers."""
def _note_for(
    confidence: str, lot: str, product_hit: bool,
    record: RecallRecord, scanned: str, codes: str
) -> str {
    if confidence == CONFIRMED {
        return (
            f"Recall {record.recall_number} matches this package on brand, product "
            f"and lot code. Scanned lot {scanned}; recall codes {codes}. "
            "Blocked from the shelf - ClearItem will refuse it."
        );
    }
    if confidence == POSSIBLE {
        return (
            f"Recall {record.recall_number} matches this package on brand and "
            f"product, but the lot codes were not compared. Scanned lot {scanned}; "
            f"recall codes {codes}. Compare them by hand before this goes out."
        );
    }
    if product_hit and lot == "differs" {
        return (
            f"Recall {record.recall_number} covers this brand and product, but the scanned lot "
            f"{scanned} is not among the recalled codes {codes}, so this package "
            "looks like a different batch. Informational only."
        );
    }
    return (
        f"Recall {record.recall_number} is against this brand but a different "
        f"product ({record.product_description}). Informational only - the item "
        "proceeds normally."
    );
}

def _classify_recall(item: Item, record: RecallRecord) -> RecallMatch | None {
    call = _classify(item, record);
    if not call.matched {
        return None;
    }
    lot = _lot_state(item.lot_code, record.code_info);
    scanned = item.lot_code if item.lot_code.strip() != "" else "(no lot code read)";
    codes = record.code_info if record.code_info.strip() != "" else "(recall lists no lot codes)";
    return RecallMatch(
        recall_number=record.recall_number,
        confidence=call.confidence,
        matched_fields=call.matched_fields,
        note=_note_for(
            call.confidence, lot,
            _product_matched(item.product, record.product_description),
            record, scanned, codes
        ),
        scanned_lot=scanned,
        recall_lot_codes=codes,
        classification=record.classification,
        reason=record.reason
    );
}

# ---------------------------------------------------------------------------
# Verdict guards - the fix to Flaw 1, enforced in code and not only in a prompt
# ---------------------------------------------------------------------------

"""Cut a packaging note into clauses so a negation cannot leak across one."""
def _split_clauses(text: str) -> list[str] {
    parts = [text];
    for brk in CLAUSE_BREAKS {
        nxt: list[str] = [];
        for p in parts {
            for piece in p.split(brk) {
                nxt.append(piece);
            }
        }
        parts = nxt;
    }
    return [p.strip() for p in parts if p.strip() != ""];
}

"""Where `marker` starts a word in `clause`, else -1.

Plain substring matching finds "rust" inside "crust" and bins a good box.
"""
def _marker_index(clause: str, marker: str) -> int {
    width = len(marker);
    i = 0;
    while i <= len(clause) - width {
        if clause[i:i + width] == marker and (
            i == 0 or not clause[i - 1].isalpha()
        ) {
            return i;
        }
        i += 1;
    }
    return -1;
}

"""True when a negation cue stands before position `idx` in this clause."""
def _negated_before(clause: str, idx: int) -> bool {
    head = " " + clause[:idx] + " ";
    for cue in PACKAGING_NEGATIONS {
        if cue in head {
            return True;
        }
    }
    return False;
}

"""True only for damage the note actually REPORTS.

A damage word counts when it starts a word in a clause and no negation stands
before it in that same clause. So "no bulging" and "no rust" read as a sound
package, "the seam is bulging" reads as a compromised one, and an empty or
clean note ("none", "no visible damage", "undamaged") reads as sound rather
than as damage.
"""
def _packaging_compromised(packaging_note: str) -> bool {
    for clause in _split_clauses(packaging_note.lower()) {
        for marker in COMPROMISED_MARKERS {
            idx = _marker_index(clause, marker);
            if idx >= 0 and not _negated_before(clause, idx) {
                return True;
            }
        }
    }
    return False;
}

"""The complete sec-4 discard list. Nothing outside it may ever be binned.

This is the hard backstop on Flaw 1: `shelf_life_verdict` is told the rule in
its semstring, but a model is not a guarantee. If the model returns `discard`
and none of these four conditions holds, the walker overrides it to `review`.
"""
def _discard_allowed(category: str, days_past_code: int, packaging_note: str) -> bool {
    cat = _norm(category);
    if cat in NEVER_ACCEPTED_CATEGORIES {
        return True;
    }
    if cat in DATE_CRITICAL_CATEGORIES and days_past_code > 0 {
        return True;
    }
    return _packaging_compromised(packaging_note);
}

# ---------------------------------------------------------------------------
# IntakeScan
# ---------------------------------------------------------------------------

walker:pub IntakeScan {
    """Scan one donated package at the intake desk. Spawns on a `Shelf`.

    Sequence (spec sec 6): read the label with byLLM -> create the `Item` ->
    link `Contains` edges to `Allergen` nodes carrying the justifying ingredient
    words -> ask byLLM for the shelf-life call -> VISIT the `RecallFeed` and
    walk its `RecallRecord` nodes, writing `FlaggedBy` edges at the sec-4
    confidence tier -> settle the verdict -> report the item and the trace.

    The recall step is a real traversal, not a helper call: the walker moves
    Shelf -> RecallFeed -> RecallRecord and does its comparison on arrival at
    each record, so the reasoning happens where the data lives.

    Nothing this walker creates is cleared. `cleared` stays False and the item
    is stocked on the review queue until a human runs `ClearItem`.
    """

    has photo_base64: str = "";
    has photo_source: str = "";
    has hint: str = "";
    has shelf_name: str = SHELF_CANNED;

    has item: Item | None = None;
    has destination_shelf: str = "";
    has label: LabelRead | None = None;
    has shelf_call: ShelfLifeCall | None = None;
    has days_past: int = 0;
    has date_parsed: bool = False;
    has allergen_tags: list[AllergenHit] = [];
    has matches: list[RecallMatch] = [];
    has records_compared: int = 0;
    has trace: list[TraceStep] = [];
    has resolved: bool = False;
    has reports: list[IntakeReport] = [];

    def note(step: str, detail: str, source: str) {
        self.trace.append(TraceStep(step=step, detail=detail, source=source));
    }

    can locate with Root entry {
        # Spawned on root instead of on a Shelf: resolve the shelf by name and
        # walk into it, so `POST /walker/IntakeScan` works with or without
        # `_jac_spawn_node`.
        if self.resolved {
            skip;
        }
        self.resolved = True;
        visit [_get_shelf(self.shelf_name)];
    }

    can scan with Shelf entry {
        self.destination_shelf = here.name;

        # --- 1. read the label (byLLM; sem annotations are the prompt) -------
        photo = image_from_base64(self.photo_base64)
            if self.photo_base64.strip() != ""
            else image_from_source(self.photo_source);
        read = extract_label(photo, self.hint);
        self.label = read;
        self.note(
            "extract_label",
            f"{read.brand} / {read.product} [{read.category}] "
            f"date={read.date_value} ({str(read.date_type)}) lot={read.lot_code} "
            f"confidence={read.extraction_confidence}",
            "byllm:extract_label"
        );
        if read.legibility_note.strip() != "" {
            self.note("legibility", read.legibility_note, "byllm:extract_label");
        }

        # --- 2. create the Item, held on the review queue --------------------
        holding = _review_shelf();
        item = (holding +>:Stocks:+> Item(
            brand=read.brand,
            product=read.product,
            category=_norm(read.category),
            ingredients_text=read.ingredients_text,
            date_value=read.date_value,
            date_type=str(read.date_type),
            lot_code=read.lot_code,
            packaging_note=read.packaging_note,
            extraction_confidence=read.extraction_confidence,
            legibility_note=read.legibility_note,
            verdict="review",
            verdict_reason="scan in progress",
            cleared=False,
            scanned_at=_now()
        ))[0] as Item;
        self.item = item;
        self.note(
            "create_item",
            f"Item {jid(item)[:12]}... stocked on '{holding.name}' pending human "
            f"clearance; destination shelf is '{here.name}'.",
            "graph"
        );

        # --- 3. Contains edges, carrying the ingredient words as evidence ----
        self.allergen_tags = _tag_allergens(read.ingredients_text);
        for hit in self.allergen_tags {
            item +>:Contains(evidence=hit.evidence):+> _get_allergen(hit.name);
        }
        if len(self.allergen_tags) > 0 {
            self.note(
                "allergen_tags",
                "; ".join([f"{h.name} <- '{h.evidence}'" for h in self.allergen_tags]),
                "graph"
            );
        } else {
            self.note(
                "allergen_tags",
                "The ingredient statement lists none of the tracked allergens."
                if read.ingredients_text.strip() != ""
                else "No ingredient statement was legible, so nothing could be tagged.",
                "graph"
            );
        }

        # --- 4. shelf-life call (byLLM) --------------------------------------
        parsed = _days_past_code(read.date_value);
        self.date_parsed = parsed is not None;
        self.days_past = parsed if parsed is not None else 0;
        routing_type = _date_type_of(str(read.date_type))
            if self.date_parsed
            else DateType.UNKNOWN;
        if not self.date_parsed {
            self.note(
                "date_parse",
                f"Could not read a code date out of '{read.date_value}', so the date "
                "type is treated as unknown and the item routes to review. Unreadable "
                "is never a reason to discard.",
                "rule sec 4"
            );
        } else {
            self.note(
                "date_parse",
                f"Code date parsed from '{read.date_value}': {self.days_past} days past "
                "code." if self.days_past > 0 else
                f"Code date parsed from '{read.date_value}': {-self.days_past} days "
                "still to run.",
                "graph"
            );
        }
        call = shelf_life_verdict(
            _norm(read.category), routing_type, self.days_past, read.packaging_note
        );
        self.shelf_call = call;
        self.note(
            "shelf_life_verdict",
            f"{str(call.verdict)} - {call.reason}",
            "byllm:shelf_life_verdict"
        );

        # --- 5. walk to the recall feed --------------------------------------
        visit [_get_recall_feed()];
    }

    can open_feed with RecallFeed entry {
        # Fan out over every recall record the feed lists.
        records = [here ->:Lists:->];
        self.note(
            "recall_scan",
            f"Comparing against {len(records)} recall record(s) on the feed "
            f"(last synced: {here.last_synced if here.last_synced != '' else 'never'}).",
            "graph"
        );
        visit records;
    }

    can compare with RecallRecord entry {
        # Arrive at one recall record and grade it against the scanned item.
        self.records_compared += 1;
        item = self.item;
        if item is None {
            skip;
        }
        hit = _classify_recall(item, here);
        if hit is None {
            skip;
        }
        # The evidence stamp is what lets a later RecallSweep tell "the lot code
        # was corrected" apart from "the two graders disagree" (see
        # `_may_rewrite`). Without it a re-grade can never lower this edge.
        item +>:FlaggedBy(
            confidence=hit.confidence,
            matched_fields=_stamp(
                hit.matched_fields, _evidence_id(item.lot_code, here.code_info)
            )
        ):+> here;
        self.matches.append(hit);
        self.note(
            "recall_match",
            f"[{hit.confidence}] {hit.note}",
            "rule sec 4"
        );
    }

    can settle with RecallFeed exit {
        # Runs after every record has been compared. Settles the verdict.
        item = self.item;
        call = self.shelf_call;
        if item is None or call is None {
            disengage;
        }

        confirmed = [m for m in self.matches if m.confidence == CONFIRMED];
        possible = [m for m in self.matches if m.confidence == POSSIBLE];
        weak = [m for m in self.matches if m.confidence == WEAK];

        verdict = str(call.verdict);
        reasons: list[str] = [];

        # sec 4 backstop: a past date alone can NEVER produce a discard.
        if verdict == "discard" and not _discard_allowed(
            item.category, self.days_past, item.packaging_note
        ) {
            self.note(
                "verdict_override",
                "The model returned discard, but none of the four hard-discard "
                "conditions is true for this package - date labels are quality dates, "
                "not safety dates, so the walker overrode discard to review. v1 would "
                "have thrown this out.",
                "rule sec 4"
            );
            verdict = "review";
            reasons.append(
                "Past its printed date but shelf stable and undamaged, so it is going "
                "to review rather than the bin."
            );
        }

        reasons.append(call.reason);

        if len(confirmed) > 0 {
            if verdict != "discard" {
                verdict = "review";
            }
            reasons.insert(0, "BLOCKED: " + " ".join([m.note for m in confirmed]));
        } elif len(possible) > 0 {
            if verdict == "keep" {
                verdict = "review";
            }
            for m in possible {
                reasons.append(m.note);
            }
        }

        if item.extraction_confidence < MIN_EXTRACTION_CONFIDENCE {
            # sec 4 cuts both ways: a read this weak may not put a guess on the
            # shelf, and it may not put one in the bin either. The category and
            # the date are both products of THIS read, so a discard resting on
            # them is worth no more than the read is. Physical damage is an
            # observation of the package rather than of the label, so a genuinely
            # compromised container still discards at any confidence.
            damaged = _packaging_compromised(item.packaging_note);
            if verdict == "keep" or (verdict == "discard" and not damaged) {
                was = verdict;
                verdict = "review";
                reasons.append(
                    f"The label read scored {item.extraction_confidence}, below the "
                    f"{MIN_EXTRACTION_CONFIDENCE} bar, so a person checks this one "
                    "rather than a guess deciding it."
                );
                self.note(
                    "low_confidence",
                    f"extraction_confidence {item.extraction_confidence} < "
                    f"{MIN_EXTRACTION_CONFIDENCE} -> review (was {was}). An unreadable "
                    "label is never a reason to discard.",
                    "rule sec 4"
                );
            }
        }

        for m in weak {
            reasons.append(m.note);
        }

        item.verdict = verdict;
        item.verdict_reason = " ".join(reasons);
        self.note("verdict", f"{verdict} - {item.verdict_reason}", "rule sec 4");

        view = item.to_view();
        report IntakeReport(
            item=view,
            verdict=verdict,
            verdict_reason=item.verdict_reason,
            blocked=view.has_confirmed_recall,
            destination_shelf=self.destination_shelf,
            holding_shelf=view.shelf,
            days_past_code=self.days_past,
            date_parsed=self.date_parsed,
            shelf_life_window=call.typical_window_past_code,
            allergen_tags=self.allergen_tags,
            recall_matches=self.matches,
            recall_records_compared=self.records_compared,
            trace=self.trace,
            using_mock_llm=_using_mock_llm()
        );
        disengage;
    }
}

# ---------------------------------------------------------------------------
# ClearItem
# ---------------------------------------------------------------------------

walker:pub ClearItem {
    """A human clears one scanned item onto a shelf. Spawns on an `Item`.

    THE GATE (spec sec 4, "Human control"): this walker REFUSES to clear an item
    that carries a CONFIRMED `FlaggedBy` edge. The check is `can clear with Item
    entry` below - it is in the walker, so it holds for the Jac client, for a
    raw `POST /walker/ClearItem`, and for anything written later. No UI state
    and no request field can get past it; there is no override parameter for it.

    A `discard` verdict is also refused, but that one IS overridable
    (`override_discard`) because a volunteer holding the can is a better judge
    of a dent than a photo was. A confirmed recall is not a judgement call.
    """

    has item_id: str = "";
    has shelf_name: str = SHELF_CANNED;
    has override_discard: bool = False;
    has resolved: bool = False;
    has reports: list[ClearReport] = [];

    can locate with Root entry {
        # Resolve `item_id` when the caller spawned on root instead of passing
        # `_jac_spawn_node`.
        if self.resolved {
            skip;
        }
        self.resolved = True;
        if self.item_id.strip() == "" {
            # Spawned straight onto the Item with `_jac_spawn_node`: the runtime
            # still runs this Root ability, and there is nothing to resolve.
            skip;
        }
        target = jobj(self.item_id);
        if isinstance(target, Item) {
            visit [target];
        } else {
            report ClearReport(
                item=None,
                cleared=False,
                refused=True,
                refusal_reason=(
                    f"No Item resolves from item_id '{self.item_id}'. Spawn this walker "
                    "on an Item with _jac_spawn_node, or pass a valid item_id."
                ),
                blocking_recalls=[],
                shelf=""
            );
            disengage;
        }
    }

    can clear with Item entry {
        # --- THE REFUSAL GATE, enforced in the walker ------------------------
        blocking: list[str] = [];
        for record in [here ->:FlaggedBy:->] {
            for link in [edge here ->:FlaggedBy:-> record] {
                if link.confidence == CONFIRMED and record.recall_number not in blocking {
                    blocking.append(record.recall_number);
                }
            }
        }
        if len(blocking) > 0 {
            details: list[str] = [];
            for record in [here ->:FlaggedBy:->] {
                if record.recall_number in blocking {
                    details.append(
                        f"{record.recall_number} ({record.classification}): "
                        f"{record.reason} Recall lot codes: {record.code_info}. "
                        f"Scanned lot: {here.lot_code if here.lot_code != '' else '(none read)'}."
                    );
                }
            }
            report ClearReport(
                item=here.to_view(),
                cleared=False,
                refused=True,
                refusal_reason=(
                    "REFUSED. This item carries a CONFIRMED recall match and cannot be "
                    "cleared onto a shelf. " + " ".join(details)
                ),
                blocking_recalls=blocking,
                shelf=here.to_view().shelf
            );
            disengage;
        }

        # --- discard verdicts need an explicit human override ----------------
        if here.verdict == "discard" and not self.override_discard {
            report ClearReport(
                item=here.to_view(),
                cleared=False,
                refused=True,
                refusal_reason=(
                    "REFUSED. This item is routed to discard: " + here.verdict_reason
                    + " Re-send with override_discard=true only after inspecting the "
                    + "package yourself."
                ),
                blocking_recalls=[],
                shelf=here.to_view().shelf
            );
            disengage;
        }

        # --- cleared: move it off the review queue onto its shelf ------------
        destination = _get_shelf(self.shelf_name);
        for link in [edge here <-:Stocks:<-] {
            del link;
        }
        destination +>:Stocks:+> here;
        here.cleared = True;
        report ClearReport(
            item=here.to_view(),
            cleared=True,
            refused=False,
            refusal_reason="",
            blocking_recalls=[],
            shelf=destination.name
        );
        disengage;
    }
}
