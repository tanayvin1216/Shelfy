"""Streaming under MockLLM, and `jac test` blocks against by-llm functions."""
import from byllm.lib { MockLLM }

enum Verdict { SAFE_TO_DISTRIBUTE, STAFF_REVIEW, DISCARD }

obj ShelfCall {
    has verdict: Verdict;
    has reason: str;
}
sem ShelfCall.verdict = "The disposition decision.";
sem ShelfCall.reason = "One sentence for a pantry volunteer.";

def rule(category: str, days_past_code: int) -> ShelfCall by llm(temperature=0.0);
sem rule = "Rule on this donated item using the pantry shelf-life table.";
sem rule.category = "Food category key.";
sem rule.days_past_code = "Days past the printed code.";

def volunteer_script(topic: str) -> str by llm(stream=True);
sem volunteer_script = "Write a short script a volunteer reads to a client.";
sem volunteer_script.topic = "What the script is about.";

glob llm = MockLLM(
    model_name="mockllm",
    config={
        "outputs": [
            ShelfCall(verdict=Verdict.DISCARD, reason="Past the hard limit."),
            "Hi! This item was checked today and is safe to take home.",
            ShelfCall(verdict=Verdict.SAFE_TO_DISTRIBUTE, reason="Well inside the window.")
        ]
    }
);

with entry {
    r = rule("canned_low_acid", 900);
    print("verdict:", r.verdict.name);

    print("stream:", end=" ");
    for chunk in volunteer_script("food safety") {
        print(chunk, end="|");
    }
    print("");
}

test "mock verdict is deterministic" {
    r = rule("dry_pasta_rice", 10);
    assert r.verdict == Verdict.SAFE_TO_DISTRIBUTE;
    assert "window" in r.reason;
}
