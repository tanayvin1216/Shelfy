"""Clean-checking Image factory: hold the class in an `any` glob and call through it."""
import from byllm.lib { Image, MockLLM }

glob _ImageCls: any = Image;

def to_image(src: str) -> Image {
    return _ImageCls(src) as Image;
}

obj LabelRead {
    has product_name: str;
    has printed_date: str;
}
sem LabelRead.product_name = "Product name exactly as printed.";
sem LabelRead.printed_date = "Printed date verbatim, or '' if absent.";

def read_label(photo: Image) -> LabelRead by llm(temperature=0.0);
sem read_label = "Transcribe the food label in the photo. Never invent a date.";
sem read_label.photo = "Phone photo of the product label.";

glob llm = MockLLM(
    model_name="mockllm",
    config={"outputs": [LabelRead(product_name="GREEN BEANS", printed_date="03/2024")]}
);

with entry {
    img = to_image("label.png");
    print("mime:", img.mime_type, "urllen:", len(img.url));
    r = read_label(img);
    print("RESULT:", r.product_name, r.printed_date);
}
