"""What a node/obj method sends as context, and `incl_info` extra context."""
import from byllm.lib { MockLLM }

node PantryItem {
    has name: str;
    has category: str;
    has days_past_code: int;
    has packaging_note: str;

    def verdict_text -> str by llm(temperature=0.0);
}
sem PantryItem = "A single donated food item sitting at the intake desk.";
sem PantryItem.verdict_text = "Rule on THIS item using its own fields. One sentence.";
sem PantryItem.name = "Product name as printed on the label.";
sem PantryItem.category = "Pantry shelf-life category key.";
sem PantryItem.days_past_code = "Days elapsed past the printed date code.";
sem PantryItem.packaging_note = "Volunteer's observation about the container.";

def with_extra(q: str) -> str by llm(
    incl_info={"pantry_name": "Eastside Food Bank", "today": "2026-07-26"}
);
sem with_extra = "Answer using the pantry context supplied.";
sem with_extra.q = "The question.";

glob llm = MockLLM(
    model_name="mockllm",
    config={"verbose": True, "show_params": True, "outputs": ["A", "B"]}
);

with entry {
    it = PantryItem(name="Green beans", category="canned_low_acid",
                    days_past_code=900, packaging_note="seam dent");
    print("R1:", it.verdict_text());
    print("R2:", with_extra("Is today past the code?"));
}
