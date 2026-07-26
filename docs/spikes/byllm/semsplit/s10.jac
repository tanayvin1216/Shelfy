import from byllm.lib { MockLLM }

obj ShelfCall {
    has verdict: str;
    has reason: str;
}

def rule(category: str, days_past_code: int) -> ShelfCall by llm();

glob llm = MockLLM(
    model_name="mockllm",
    config={"verbose": True, "show_params": True,
            "outputs": [ShelfCall(verdict="DISCARD", reason="x")]}
);

with entry {
    print(rule("canned_low_acid", 900).verdict);
}
