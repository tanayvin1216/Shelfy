"""Persistence-by-reachability across `jac run` invocations."""

node Pantry { has name: str; has region: str = "midwest"; }
node Ghost  { has tag: str; }

with entry:__main__ {
    print("--- run start ---");
    print("root children BEFORE:", [type(n).__name__ for n in [root -->]]);
    print("pantries reachable:", [p.name for p in [root -->[?:Pantry]]]);

    existing = [root -->[?:Pantry]];
    if len(existing) == 0 {
        root ++> Pantry(name="Eastside");
        print("created Eastside");
    } else {
        print("Eastside already exists -> skipped create");
    }

    _unreached = Ghost(tag="never-attached");
    print("root children AFTER:", [type(n).__name__ for n in [root -->]]);
    print("--- run end ---");
}
