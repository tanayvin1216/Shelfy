"""Dump the ACTUAL prompt/params byLLM sends, with no API key."""
import from byllm.lib { MockLLM }

enum Verdict { SAFE_TO_DISTRIBUTE, STAFF_REVIEW, DISCARD }
sem Verdict.DISCARD = "Unsafe or past the hard limit; bin it.";

obj ShelfCall {
    has verdict: Verdict;
    has reason: str;
    has confidence: float;
}
sem ShelfCall.verdict = "The disposition decision.";
sem ShelfCall.reason = "One sentence for a pantry volunteer.";
sem ShelfCall.confidence = "0.0-1.0.";

def rule_shelf_life(category: str, date_type: str, days_past_code: int) -> ShelfCall by llm();
sem rule_shelf_life = "Apply the pantry shelf-life table and rule on this item.";
sem rule_shelf_life.category = "Food category key.";
sem rule_shelf_life.date_type = "'best_by' | 'sell_by' | 'use_by'.";
sem rule_shelf_life.days_past_code = "Days elapsed past the printed code.";

glob llm = MockLLM(
    model_name="mockllm",
    config={
        "verbose": True,
        "show_params": True,
        "outputs": [ShelfCall(verdict=Verdict.DISCARD, reason="x", confidence=0.1)]
    }
);

with entry {
    r = rule_shelf_life("canned_low_acid", "best_by", 900);
    print("RESULT:", r.verdict.name);
    print("=== SEEN PROMPTS ===");
    for p in llm.seen_prompts {
        print(p);
    }
}
