"""Nested objs, list[obj], optional returns, and the typed-output retry loop."""
import from byllm.lib { MockLLM, MockRawResponse, OutputConversionError }

obj DateCode {
    has kind: str;
    has iso: str;
}
sem DateCode.kind = "'best_by' | 'sell_by' | 'use_by' | 'packed_on' | 'none'.";
sem DateCode.iso = "ISO-8601 date, or '' when no date is printed.";

obj Nutrient {
    has name: str;
    has grams: float;
}
sem Nutrient.name = "Nutrient name as printed, lowercase.";
sem Nutrient.grams = "Grams per serving.";

obj ParsedLabel {
    has product: str;
    has date: DateCode;
    has nutrients: list[Nutrient];
    has allergens: list[str];
}
sem ParsedLabel.product = "Product name as printed.";
sem ParsedLabel.date = "The printed date code, structured.";
sem ParsedLabel.nutrients = "Every nutrient line on the panel.";
sem ParsedLabel.allergens = "Allergens from the 'contains' statement, lowercase.";

def parse_label(ocr: str) -> ParsedLabel by llm(temperature=0.0);
sem parse_label = "Parse raw OCR text from a food label into structured fields.";
sem parse_label.ocr = "Raw OCR output, may contain noise and line breaks.";

obj LotHit {
    has found: bool;
    has lot_code: str;
}
sem LotHit.found = "True only if a lot code is actually printed in the OCR text.";
sem LotHit.lot_code = "The lot code, or '' when found is false.";

def find_lot(ocr: str) -> LotHit by llm();
sem find_lot = "Report the manufacturer lot code. Set found=false rather than guessing.";
sem find_lot.ocr = "Raw OCR output.";

def split_lines(ocr: str) -> list[str] by llm();
sem split_lines = "Split the OCR blob into one clean line per printed line.";
sem split_lines.ocr = "Raw OCR output.";

glob llm = MockLLM(
    model_name="mockllm",
    config={
        "verbose": True,
        "outputs": [
            # 1. nested obj + list[obj]
            ParsedLabel(
                product="GREEN BEANS",
                date=DateCode(kind="best_by", iso="2024-03-01"),
                nutrients=[Nutrient(name="protein", grams=2.0), Nutrient(name="fiber", grams=3.0)],
                allergens=[]
            ),
            # 2. "not found" via an obj flag (union returns are broken - see s07b)
            LotHit(found=False, lot_code=""),
            # 3. list[str]
            ["GREEN BEANS", "BEST BY 03/2024", "NET 14.5 OZ"],
            # 4. malformed JSON -> triggers a retry, then valid JSON
            MockRawResponse(content="{ not json at all"),
            MockRawResponse(
                content='{"product":"PENNE","date":{"kind":"best_by","iso":"2025-01-01"},"nutrients":[],"allergens":["wheat"]}'
            )
        ]
    }
);

with entry {
    p = parse_label("GREEN BEANS BEST BY 03/2024 NET 14.5 OZ");
    print("nested:", p.product, p.date.kind, p.date.iso, [(n.name, n.grams) for n in p.nutrients], p.allergens);

    lot = find_lot("no lot printed here");
    print("not-found flag:", lot.found, repr(lot.lot_code));

    print("list[str]:", split_lines("GREEN BEANS\nBEST BY 03/2024\nNET 14.5 OZ"));

    print("--- retry path ---");
    p2 = parse_label("PENNE BEST BY 01/2025 CONTAINS WHEAT");
    print("after retry:", p2.product, p2.date.iso, p2.allergens);
    print("dispatches seen:", len(llm.seen_prompts));
}
