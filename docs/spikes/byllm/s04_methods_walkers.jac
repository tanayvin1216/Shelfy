"""by llm on obj methods, node methods, and inside walker abilities."""
import from byllm.lib { MockLLM }

obj Donation {
    has label_text: str;
    has category: str;

    def guess_allergens -> list[str] by llm();
}
sem Donation.guess_allergens =
    "List allergens implied by this donation's label text and category.";

node Item {
    has name: str;
    has note: str = "";

    def blurb -> str by llm();
}
sem Item.blurb = "Write a one-line shelf tag for this item.";

walker Triage {
    has summary: str = "";

    def classify(raw: str) -> str by llm();

    can go with Root entry {
        visit [-->];
    }

    can look with Item entry {
        self.summary = self.classify(here.name + " / " + here.note);
        print("walker-ability by-llm ->", self.summary);
        print("node-method by-llm  ->", here.blurb());
    }
}
sem Triage.classify = "Classify a raw intake string into a pantry category.";
sem Triage.classify.raw = "Raw scanned text from the intake desk.";

glob llm = MockLLM(
    model_name="mockllm",
    config={"outputs": ["milk, soy", "canned_low_acid", "Green beans - use by Mar", "dry_pasta_rice", "Penne - pantry staple"]}
);

with entry {
    d = Donation(label_text="contains milk and soy lecithin", category="snack_bar");
    print("obj-method by-llm   ->", d.guess_allergens());

    root ++> Item(name="Green beans", note="dent-free");
    root ++> Item(name="Penne", note="box crushed");
    root spawn Triage();
}
