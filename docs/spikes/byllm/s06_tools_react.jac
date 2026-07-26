"""Tool use / ReAct loop driven by MockToolCall - no API key."""
import from byllm.lib { MockLLM, MockToolCall }

glob RECALL_DB: dict[str, str] = {
    "0-51500-24128-4": "FDA Class I recall 2026-07-14: Listeria risk, all lots",
    "0-11110-00001-1": "no active recall"
};

def lookup_recall(upc: str) -> str {
    return RECALL_DB.get(upc, "no active recall");
}
sem lookup_recall = "Look up whether a UPC has an active FDA recall. Always call this before ruling on an item.";
sem lookup_recall.upc = "The 12-digit UPC printed on the package, hyphenated.";

def count_affected(lot_code: str) -> int {
    return len(lot_code) * 3;
}
sem count_affected = "Return how many pantry units carry the given lot code.";
sem count_affected.lot_code = "Manufacturer lot code, e.g. 'L2214B'.";

def recall_advice(upc: str, lot_code: str) -> str by llm(
    tools=[lookup_recall, count_affected],
    temperature=0.0,
    max_react_iterations=6
);
sem recall_advice = "Decide what the pantry should do about this item. Use the tools to check recall status and blast radius before answering.";
sem recall_advice.upc = "UPC of the item in hand.";
sem recall_advice.lot_code = "Lot code printed near the date.";

glob llm = MockLLM(
    model_name="mockllm",
    config={
        "verbose": True,
        "outputs": [
            MockToolCall(tool=lookup_recall, args={"upc": "0-51500-24128-4"}),
            MockToolCall(tool=count_affected, args={"lot_code": "L2214B"}),
            "PULL ALL 18 UNITS: UPC 0-51500-24128-4 is under FDA Class I recall for Listeria; quarantine and log."
        ]
    }
);

with entry {
    print("=== ReAct result ===");
    print(recall_advice("0-51500-24128-4", "L2214B"));
}
