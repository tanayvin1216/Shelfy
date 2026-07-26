import from byllm.lib { MockLLM }

glob llm = MockLLM(model_name="mockllm", config={"outputs": ["Bonjour", "Salut"]});

def translate(text: str) -> str by llm();
sem translate = "Translate the given English text into French.";
sem translate.text = "English source text.";

with entry {
    print(translate("Hello"));
    print(translate("Hi"));
}
