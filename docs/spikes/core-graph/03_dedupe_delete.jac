"""Dedupe-on-rescan, edge existence, deletion, root reachability."""

node Pantry {
    has name: str;
}

node Item {
    has sku: str;
    has name: str;
    has lot: str = "";
    has slug: str by postinit;

    def postinit {
        self.slug = f"{self.sku}-{self.lot}";
    }
}

node Shelf {
    has code: str;
}

edge Stocks: Shelf --> Item {
    has placed_on: str = "2026-01-01";
}

def get_or_create_shelf(p: Pantry, code: str) -> Shelf {
    existing = [p -->[?:Shelf, code == code]];
    if len(existing) > 0 {
        return existing[0];
    }
    fresh = Shelf(code=code);
    p ++> fresh;
    return fresh;
}

def find_shelf(p: Pantry, code: str) -> Shelf | None {
    for s in [p -->[?:Shelf]] {
        if s.code == code { return s; }
    }
    return None;
}

def upsert_shelf(p: Pantry, code: str) -> Shelf {
    hit = find_shelf(p, code);
    if hit is not None { return hit; }
    fresh = Shelf(code=code);
    p ++> fresh;
    return fresh;
}

def stocks_edge_exists(s: Shelf, i: Item) -> bool {
    return len([edge s ->:Stocks:-> i]) > 0;
}

with entry:__main__ {
    p = Pantry(name="Eastside");
    root ++> p;

    print("=== postinit derived field ===");
    it = Item(sku="PB-100", name="Peanut Butter", lot="L77");
    print(it.slug);

    print("=== BUG DEMO: shadowed param in filter predicate ===");
    a1 = get_or_create_shelf(p, "A1");
    b2 = get_or_create_shelf(p, "B2");
    print("shelves after get_or_create A1,B2:", [s.code for s in [p -->[?:Shelf]]]);
    print("a1 is b2?", a1 is b2);

    print("=== CORRECT upsert (explicit loop) ===");
    p2 = Pantry(name="Westside");
    root ++> p2;
    x1 = upsert_shelf(p2, "A1");
    x2 = upsert_shelf(p2, "B2");
    x3 = upsert_shelf(p2, "A1");
    print("shelves:", [s.code for s in [p2 -->[?:Shelf]]]);
    print("x1 is x3 (deduped)?", x1 is x3, "| x1 is x2?", x1 is x2);

    print("=== edge existence check ===");
    root ++> it;
    print("before connect:", stocks_edge_exists(x1, it));
    x1 +>:Stocks(placed_on="2026-07-01"):+> it;
    print("after connect:", stocks_edge_exists(x1, it));
    if not stocks_edge_exists(x1, it) {
        x1 +>:Stocks:+> it;
    }
    print("edge count after guarded re-connect:", len([edge x1 ->:Stocks:-> it]));

    print("=== delete a TYPED edge (iterate + del) ===");
    for e in [edge x1 ->:Stocks:-> it] { del e; }
    print("after typed edge delete:", stocks_edge_exists(x1, it));

    print("=== delete an UNTYPED edge with del --> ===");
    print("before:", [s.code for s in [p2 -->[?:Shelf]]]);
    p2 del --> x2;
    print("after :", [s.code for s in [p2 -->[?:Shelf]]]);

    print("=== delete a NODE (cascades all edges) ===");
    gone_id = jid(x1);
    del x1;
    print("removed jid:", gone_id[:8], "... shelves left:", [s.code for s in [p2 -->[?:Shelf]]]);

    print("=== root reachability ===");
    orphan = Item(sku="OR-999", name="Orphan", lot="Z");
    print("orphan built but not attached; root children count:", len([root -->]));
    print("root types:", [type(n).__name__ for n in [root -->]]);
    print("orphan reachable from root?", orphan in [root --> -->] or orphan in [root -->]);
    print("root jid:", jid(root)[:12]);
}
