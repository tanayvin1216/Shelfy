"""Backshelf flagship spike: structured verdict from a sem-encoded rules table."""
import from byllm.lib { MockLLM }

enum Verdict {
    SAFE_TO_DISTRIBUTE,
    STAFF_REVIEW,
    DISCARD
}
sem Verdict = "Disposition decision for a single donated food item.";
sem Verdict.SAFE_TO_DISTRIBUTE = "Item is within its usable window; put it on the shelf.";
sem Verdict.STAFF_REVIEW = "Ambiguous: a human must open/inspect before it goes out.";
sem Verdict.DISCARD = "Unsafe or past the hard limit; bin it, do not distribute.";

obj ShelfCall {
    has verdict: Verdict;
    has reason: str;
    has confidence: float;
    has days_of_shelf_life_left: int;
    has flags: list[str];
}
sem ShelfCall = "A shelf-life ruling for one donated item.";
sem ShelfCall.verdict = "The disposition decision.";
sem ShelfCall.reason =
    "One sentence, plain English, addressed to a pantry volunteer. Cite the rule you applied.";
sem ShelfCall.confidence = "0.0-1.0. Below 0.6 means you are guessing.";
sem ShelfCall.days_of_shelf_life_left =
    "Estimated days remaining past today before the item must be pulled. Negative if already past.";
sem ShelfCall.flags =
    "Short machine-readable tags, e.g. 'dented_can', 'temp_abuse', 'infant_formula'.";

def rule_shelf_life(
    category: str,
    date_type: str,
    days_past_code: int,
    packaging_note: str
) -> ShelfCall by llm(temperature=0.0);

sem rule_shelf_life =
    """Decide whether a donated food item may be distributed, using the USDA-style
pantry rules below. Apply the FIRST rule that matches.

HARD DISCARD (always, regardless of dates):
  - Any 'use by' date on infant formula or baby food that has passed -> DISCARD.
  - Swollen, leaking, rusted-through, or deeply dented-on-the-seam cans -> DISCARD.
  - Home-canned or unlabeled items -> DISCARD.

SHELF-LIFE TABLE (days past the printed code that remain acceptable):
  | category        | best_by | sell_by | use_by |
  | canned_low_acid |   730   |   365   |    0   |
  | canned_high_acid|   365   |   180   |    0   |
  | dry_pasta_rice  |   365   |   180   |    0   |
  | boxed_cereal    |   180   |    90   |    0   |
  | shelf_milk_uht  |    90   |    45   |    0   |
  | snack_bar       |    90   |    60   |    0   |
  | baby_formula    |     0   |     0   |    0   |
  | refrigerated    |     3   |     3   |    0   |

DECISION:
  - days_past_code <= (table value * 0.5)  -> SAFE_TO_DISTRIBUTE
  - between 50% and 100% of the table value -> STAFF_REVIEW
  - over 100% of the table value            -> DISCARD
  - Any packaging_note describing damage escalates one level toward DISCARD.""";

sem rule_shelf_life.category =
    "One of the category keys in the shelf-life table. If it does not match, choose the closest and lower confidence.";
sem rule_shelf_life.date_type =
    "The kind of printed date: 'best_by', 'sell_by', or 'use_by'.";
sem rule_shelf_life.days_past_code =
    "Whole days between the printed code date and today. Negative means the code is still in the future.";
sem rule_shelf_life.packaging_note =
    "Free-text volunteer observation about the container, e.g. 'small side dent, seam intact'.";

glob llm = MockLLM(
    model_name="mockllm",
    config={
        "outputs": [
            ShelfCall(
                verdict=Verdict.STAFF_REVIEW,
                reason="Canned low-acid at 400 days past best-by is between 50% and 100% of the 730-day allowance, and the dent needs a look.",
                confidence=0.72,
                days_of_shelf_life_left=330,
                flags=["dented_can"]
            ),
            ShelfCall(
                verdict=Verdict.DISCARD,
                reason="Infant formula past its use-by date is an unconditional discard.",
                confidence=0.99,
                days_of_shelf_life_left=-12,
                flags=["infant_formula", "past_use_by"]
            )
        ]
    }
);

with entry {
    a = rule_shelf_life("canned_low_acid", "best_by", 400, "small side dent, seam intact");
    print(a.verdict, a.verdict.name, type(a).__name__);
    print(a.reason);
    print(a.confidence, a.days_of_shelf_life_left, a.flags);

    b = rule_shelf_life("baby_formula", "use_by", 12, "sealed, undamaged");
    print(b.verdict.name, b.flags);
    print("is DISCARD:", b.verdict == Verdict.DISCARD);
}
