node Pantry { has name: str = "main"; }
node Item { has label: str = ""; has qty: int = 0; }
edge Holds { has added_at: str = ""; }

def:pub _pantry() -> Pantry {
    hits = [root.shared --> [?:Pantry]];
    if len(hits) > 0 { return hits[0]; }
    return (root.shared ++> Pantry(name="main"))[0];
}

walker:pub AddItem {
    has label: str;
    has qty: int = 1;
    has reports: list[dict] = [];
    can go with Root entry { visit [_pantry()]; }
    can at_p with Pantry entry {
        it = (here +>:Holds(added_at="2026-07-26"):+> Item(label=self.label, qty=self.qty))[0];
        report {"id": jid(it), "label": it.label};
        disengage;
    }
}

walker:pub ListItems {
    has reports: list[dict] = [];
    can go with Root entry {
        p = _pantry();
        report {"items": [{"id": jid(i), "label": i.label, "qty": i.qty}
                          for i in [p ->:Holds:-> [?:Item]]]};
    }
}

# AUTHENTICATED: plain `walker` == `walker:priv` -> 401 without a token
walker StaffAudit {
    has reports: list[dict] = [];
    can go with Root entry {
        report {"caller_root": jid(here), "shared_root": jid(root.shared)};
    }
}
