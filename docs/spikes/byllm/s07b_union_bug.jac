"""Union / Optional return types on `by llm` - BROKEN in byllm 0.6.19."""
import from byllm.lib { MockLLM }

def find_lot(ocr: str) -> str | None by llm();
sem find_lot = "Return the lot code, or null if absent.";
sem find_lot.ocr = "Raw OCR output.";

def pick(ocr: str) -> int | str by llm();
sem pick = "Return an int or a str.";
sem pick.ocr = "Raw OCR output.";

glob llm = MockLLM(model_name="mockllm", config={"outputs": [None, 7]});

with entry {
    try {
        print("optional:", find_lot("no lot printed"));
    } except Exception as e {
        print("OPTIONAL FAILED:", type(e).__name__, e);
    }
    try {
        print("union:", pick("x"));
    } except Exception as e {
        print("UNION FAILED:", type(e).__name__, e);
    }
}
