"""Spike 2: root.shared as the one true shared graph, for anon AND logged-in."""

node Pantry {
    has name: str = "main";
}

node Item {
    has label: str = "",
        qty: int = 0;
}

edge Holds {
    has added_at: str = "";
}

def:pub _shared_pantry() -> Pantry {
    hits = [root.shared --> [?:Pantry]];
    if len(hits) > 0 {
        return hits[0];
    }
    return (root.shared ++> Pantry(name="main"))[0];
}

walker:pub SharedAdd {
    has label: str;
    has qty: int = 1;
    has reports: list[dict] = [];

    can go with Root entry {
        visit [_shared_pantry()];
    }

    can at_pantry with Pantry entry {
        it = (here +>:Holds(added_at="2026-07-26"):+> Item(label=self.label, qty=self.qty))[0];
        report {"item_id": jid(it), "pantry_jid": jid(here), "my_root": jid(root)};
        disengage;
    }
}

walker:pub SharedList {
    has found: list[dict] = [];
    has reports: list[dict] = [];

    can go with Root entry {
        p = _shared_pantry();
        for it in [p ->:Holds:-> [?:Item]] {
            self.found.append({"label": it.label, "qty": it.qty});
        }
        report {"pantry_jid": jid(p), "my_root": jid(root),
                "shared_root": jid(root.shared), "items": self.found};
    }
}
