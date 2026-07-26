"""No `glob llm` at all - the ambient `llm` builtin resolved from jac.toml / BYLLM_DEFAULT_MODEL."""
def label(text: str) -> str by llm();
sem label = "Give a one-word pantry category for this item.";
sem label.text = "Raw item description.";

with entry {
    print("ambient ->", label("canned green beans"));
}
