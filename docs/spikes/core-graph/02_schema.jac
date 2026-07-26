"""Backshelf real-schema spike: nodes, typed edges with attrs, forward + BACKWARD traversal."""

node Pantry {
    has name: str;
    has city: str = "unknown";
}

node Shelf {
    has code: str;
    has temp_c: float = 20.0;
}

node Item {
    has sku: str;
    has name: str;
    has lot: str = "";
    has qty: int = 1;
    has slug: str by postinit;

    def postinit {
        self.slug = f"{self.sku}-{self.lot}";
    }
}

node Allergen {
    has label: str;
}

node Household {
    has family: str;
    has size: int = 1;
}

node RecallRecord {
    has recall_id: str;
    has reason: str = "";
    has severity: int = 1;
}

edge Stocks: Shelf --> Item {
    has placed_on: str = "2026-01-01";
}

edge Contains: Item --> Allergen {
    has evidence: str = "label";
    has confidence: float = 1.0;
}

edge Received: Household --> Item {
    has pickup_code: str;
    has qty: int = 1;
}

edge FlaggedBy: Item --> RecallRecord {
    has confidence: float = 0.5;
    has method: str = "lot-match";
}

with entry:__main__ {
    pantry = Pantry(name="Eastside Pantry", city="Ann Arbor");
    root ++> pantry;

    shelf_a = Shelf(code="A1", temp_c=4.0);
    shelf_b = Shelf(code="B2");
    pantry ++> shelf_a;
    pantry ++> shelf_b;

    peanut_butter = Item(sku="PB-100", name="Peanut Butter", lot="L77", qty=12);
    oat_milk      = Item(sku="OM-200", name="Oat Milk", lot="L88", qty=6);
    rice          = Item(sku="RC-300", name="Rice", lot="L99", qty=30);

    shelf_a +>:Stocks(placed_on="2026-07-01"):+> peanut_butter;
    shelf_a +>:Stocks(placed_on="2026-07-02"):+> oat_milk;
    shelf_b +>:Stocks:+> rice;

    peanuts = Allergen(label="peanuts");
    gluten  = Allergen(label="gluten");
    root ++> peanuts;
    root ++> gluten;

    peanut_butter +>:Contains(evidence="ingredient-list", confidence=0.99):+> peanuts;
    oat_milk      +>:Contains(evidence="may-contain", confidence=0.30):+> gluten;

    hh_lopez = Household(family="Lopez", size=4);
    hh_chen  = Household(family="Chen", size=2);
    hh_okoro = Household(family="Okoro", size=3);
    pantry ++> hh_lopez;
    pantry ++> hh_chen;
    pantry ++> hh_okoro;

    hh_lopez +>:Received(pickup_code="PU-001", qty=2):+> peanut_butter;
    hh_chen  +>:Received(pickup_code="PU-002", qty=1):+> peanut_butter;
    hh_chen  +>:Received(pickup_code="PU-003", qty=1):+> rice;
    hh_okoro +>:Received(pickup_code="PU-004", qty=3):+> oat_milk;

    recall = RecallRecord(recall_id="FDA-2026-441", reason="Salmonella", severity=3);
    root ++> recall;
    peanut_butter +>:FlaggedBy(confidence=0.95, method="lot-match"):+> recall;

    print("=== 1. all outgoing from pantry (untyped) ===");
    print([n for n in [pantry -->]]);

    print("=== 2. by node type ===");
    print([s.code for s in [pantry -->[?:Shelf]]]);
    print([h.family for h in [pantry -->[?:Household]]]);

    print("=== 3. by edge type ===");
    print([i.name for i in [shelf_a ->:Stocks:->]]);

    print("=== 4. by EDGE ATTRIBUTE value ===");
    print([i.name for i in [shelf_a ->:Stocks:placed_on == "2026-07-01":->]]);
    print([i.name for i in [hh_chen ->:Received:qty > 0:->]]);
    print([a.label for a in [peanut_butter ->:Contains:confidence > 0.5:->]]);

    print("=== 5. by NODE FIELD value ===");
    print([h.family for h in [pantry -->[?:Household, size > 2]]]);
    print([i.name for i in [shelf_a ->:Stocks:->[?qty > 10]]]);

    print("=== 6. reading edge OBJECTS (edge has-fields) ===");
    for e in [edge hh_chen ->:Received:->] {
        print(e.pickup_code, e.qty);
    }

    print("=== 7. multi-hop FORWARD ===");
    print([i.name for i in [pantry --> ->:Stocks:->]]);
    print([a.label for a in [pantry --> ->:Stocks:-> ->:Contains:->]]);

    print("=== 8. BACKWARD traversal (the money query) ===");
    flagged = [recall <-:FlaggedBy:<-];
    print("items flagged by recall:", [i.name for i in flagged]);

    print("--- one-liner: RecallRecord -> Households that received a flagged item ---");
    affected = [recall <-:FlaggedBy:<- <-:Received:<-];
    print("affected households:", [h.family for h in affected]);

    print("--- with edge-attribute detail (pickup codes) ---");
    for itm in [recall <-:FlaggedBy:<-] {
        for e in [edge itm <-:Received:<-] {
            print(itm.name, "->", e.pickup_code, "qty", e.qty);
        }
    }

    print("--- backward with node filter (size >= 3) ---");
    print([h.family for h in [recall <-:FlaggedBy:<- <-:Received:<-[?:Household, size >= 3]]]);

    print("--- backward untyped (<--): who points at shelf_a ---");
    print([p for p in [shelf_a <--]]);

    print("=== 9. bidirectional <--> ===");
    print(len([peanut_butter <-->]));
}
