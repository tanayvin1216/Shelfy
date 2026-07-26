"""obj vs node, node inheritance + polymorphic [?:Base] filters, edge subtype endpoints."""

obj IntakeLine {
    has sku: str;
    has qty: int = 1;
}

node Perishable {
    has name: str = "?";
    has days_left: int = 7;
}

node Dairy(Perishable) {
    has fat_pct: float = 3.5;
}

node Produce(Perishable) {
    has organic: bool = False;
}

node Pantry { has name: str = "P"; }

edge Holds: Pantry --> Perishable { has bin: str = "b0"; }
edge ColdHolds(Holds) { has temp_c: float = 4.0; }

def summarize(lines: list[IntakeLine]) -> int {
    total = 0;
    for l in lines { total += l.qty; }
    return total;
}

with entry:__main__ {
    print("=== obj is plain in-memory data ===");
    lines = [IntakeLine(sku="PB-100", qty=2), IntakeLine(sku="OM-200", qty=5)];
    print("total qty:", summarize(lines));

    p = Pantry(name="Eastside");
    root ++> p;

    milk = Dairy(name="Milk", days_left=5, fat_pct=2.0);
    kale = Produce(name="Kale", days_left=3, organic=True);
    bread = Perishable(name="Bread", days_left=2);

    p +>:ColdHolds(bin="C1", temp_c=3.0):+> milk;
    p +>:Holds(bin="A2"):+> kale;
    p +>:Holds(bin="A3"):+> bread;

    print("=== polymorphic node filter [?:Perishable] matches subclasses ===");
    print([n.name for n in [p -->[?:Perishable]]]);
    print("only Dairy :", [n.name for n in [p -->[?:Dairy]]]);
    print("only Produce:", [n.name for n in [p -->[?:Produce]]]);

    print("=== edge subtype: [->:Holds:->] matches ColdHolds too ===");
    print("Holds     :", [n.name for n in [p ->:Holds:->]]);
    print("ColdHolds :", [n.name for n in [p ->:ColdHolds:->]]);

    print("=== inherited field predicate ===");
    print("expiring<=3:", [n.name for n in [p -->[?:Perishable, days_left <= 3]]]);

    print("=== edge attrs across subtype ===");
    for e in [edge p ->:Holds:->] { print(" ", type(e).__name__, e.bin); }

    print("=== BACKWARD from a subclass node to its Pantry ===");
    print([x.name for x in [milk <-:Holds:<-]]);
    print([x.name for x in [milk <-:ColdHolds:<-]]);
}
