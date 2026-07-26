"""Typed-output failure handling: max_output_retries, OutputConversionError.raw_output."""
import from byllm.lib { MockLLM, MockRawResponse, MockError, OutputConversionError, ByLLMError, RateLimitError }

obj ShelfCall { has verdict: str; has reason: str; }
sem ShelfCall.verdict = "SAFE | REVIEW | DISCARD.";
sem ShelfCall.reason = "One sentence.";

def rule_noretry(cat: str) -> ShelfCall by llm(max_output_retries=0);
sem rule_noretry = "Rule on the item."; sem rule_noretry.cat = "Category.";

def rule_retry(cat: str) -> ShelfCall by llm(max_output_retries=2);
sem rule_retry = "Rule on the item."; sem rule_retry.cat = "Category.";

glob llm = MockLLM(model_name="mockllm", config={"outputs": [
    MockRawResponse(content="totally not json"),
    MockRawResponse(content="bad 1"),
    MockRawResponse(content="bad 2"),
    MockRawResponse(content='{"verdict":"DISCARD","reason":"third try worked"}'),
    MockError(error=RateLimitError("simulated 429"))
]});

def rule_err(cat: str) -> ShelfCall by llm();
sem rule_err = "Rule."; sem rule_err.cat = "Category.";

with entry {
    try { rule_noretry("canned"); }
    except OutputConversionError as e {
        print("no-retry raised:", type(e).__name__);
        print("raw_output:", repr(getattr(e, "raw_output", "")));
        print("is ByLLMError:", isinstance(e, ByLLMError));
    }
    print("dispatches after no-retry:", len(llm.seen_prompts));

    r = rule_retry("canned");
    print("recovered:", r.verdict, r.reason);
    print("dispatches total:", len(llm.seen_prompts));

    try { rule_err("canned"); }
    except Exception as e { print("dispatch error propagates:", type(e).__name__, e); }
}
