"""How filter predicates bind names: node field vs local variable."""

node Pantry { has name: str; }
node Shelf  { has code: str; has cap: int = 10; }

def by_same_name(p: Pantry, code: str) -> list[Shelf] {
    return [p -->[?:Shelf, code == code]];
}

def by_diff_name(p: Pantry, wanted: str) -> list[Shelf] {
    return [p -->[?:Shelf, code == wanted]];
}

with entry:__main__ {
    p = Pantry(name="P");
    root ++> p;
    p ++> Shelf(code="A1", cap=5);
    p ++> Shelf(code="B2", cap=20);
    p ++> Shelf(code="C3", cap=99);

    print("same-name param 'code':", [s.code for s in by_same_name(p, "B2")]);
    print("diff-name param 'wanted':", [s.code for s in by_diff_name(p, "B2")]);

    local_code = "C3";
    print("local var in filter:", [s.code for s in [p -->[?:Shelf, code == local_code]]]);
    print("literal in filter:", [s.code for s in [p -->[?:Shelf, code == "A1"]]]);
    print("two predicates:", [s.code for s in [p -->[?:Shelf, cap > 5, cap < 50]]]);
    print("f-string built value:", [s.code for s in [p -->[?:Shelf, code == f"A{1}"]]]);
}
