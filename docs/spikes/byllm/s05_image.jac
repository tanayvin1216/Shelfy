"""Image input: file path, bytes, and how it lands in the request payload."""
import from byllm.lib { Image, MockLLM }

obj LabelRead {
    has product_name: str;
    has date_type: str;
    has printed_date: str;
    has net_weight: str;
    has legible: bool;
}
sem LabelRead.product_name = "Product name exactly as printed.";
sem LabelRead.date_type = "'best_by' | 'sell_by' | 'use_by' | 'none'.";
sem LabelRead.printed_date = "The printed date verbatim, or '' if absent.";
sem LabelRead.net_weight = "Net weight verbatim, or ''.";
sem LabelRead.legible = "False if the photo is too blurry/cropped to trust.";

def read_label(photo: Image, hint: str) -> LabelRead by llm(temperature=0.0);
sem read_label = "Transcribe the food label in the photo into structured fields. Never guess a date that is not visible.";
sem read_label.photo = "A phone photo of the product label taken at the intake desk.";
sem read_label.hint = "Optional volunteer hint about what the item is.";

glob llm = MockLLM(
    model_name="mockllm",
    config={
        "verbose": True, "show_params": True,
        "outputs": [
            LabelRead(product_name="GREEN BEANS", date_type="best_by",
                      printed_date="03/2024", net_weight="14.5 OZ", legible=True)
        ]
    }
);

with entry {
    # 1. file path
    img = Image("label.png");
    print("mime:", img.mime_type);
    print("url prefix:", img.url[:40]);
    print("url len:", len(img.url));

    # 2. raw bytes
    with open("label.png", "rb") as f {
        raw = f.read();
    }
    img2 = Image(raw);
    print("bytes-ctor mime:", img2.mime_type, "len:", len(img2.url));

    # 3. remote URL passthrough
    img3 = Image("https://example.com/can.jpg");
    print("url passthrough:", img3.url, "mime:", img3.mime_type);

    # 4. actual by-llm call
    r = read_label(img, "canned vegetable");
    print("RESULT:", r.product_name, r.date_type, r.printed_date, r.net_weight, r.legible);
}
