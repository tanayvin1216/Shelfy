import from byllm.lib { Model }

glob llm = Model(model_name="claude-sonnet-4-6");
glob gem  = Model(model_name="gemini/gemini-2.0-flash");
glob olla = Model(model_name="ollama/llama3.2");

def a(x: str) -> str by llm();
def g(x: str) -> str by gem();
def o(x: str) -> str by olla();
sem a = "echo"; sem a.x = "in";
sem g = "echo"; sem g.x = "in";
sem o = "echo"; sem o.x = "in";

with entry {
    for (nm, f) in [("anthropic", a), ("gemini", g), ("ollama", o)] {
        try { print(nm, "->", f("hi")); }
        except Exception as e { print(nm, "ERR:", str(e)[:220]); }
    }
}
