"""Backshelf server spike: pub vs auth walkers, spawn-on-node, envelope."""

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

# ---------- PUBLIC (anonymous OK) ----------

walker:pub EnsurePantry {
    has name: str = "main";
    has reports: list[dict] = [];

    can go with Root entry {
        hits = [here --> [?:Pantry, name == self.name]];
        if len(hits) > 0 {
            report {"pantry_id": jid(hits[0]), "created": False};
        } else {
            p = (here ++> Pantry(name=self.name))[0];
            report {"pantry_id": jid(p), "created": True};
        }
    }
}

walker:pub AddItem {
    has label: str;
    has qty: int = 1;
    has reports: list[dict] = [];

    # fires when the caller spawns on root (default)
    can from_root with Root entry {
        visit [here --> [?:Pantry]];
    }

    # fires when the caller spawns directly on a Pantry via _jac_spawn_node
    can at_pantry with Pantry entry {
        it = (here +>:Holds(added_at="2026-07-26"):+> Item(label=self.label, qty=self.qty))[0];
        report {"item_id": jid(it), "label": it.label, "qty": it.qty, "pantry": here.name};
        disengage;
    }
}

walker:pub ListItems {
    has found: list[dict] = [];
    has reports: list[list[dict]] = [];

    can from_root with Root entry {
        visit [here --> [?:Pantry]];
    }

    can at_pantry with Pantry entry {
        for it in [here ->:Holds:-> [?:Item]] {
            self.found.append({"id": jid(it), "label": it.label, "qty": it.qty});
        }
    }

    can done with exit {
        report self.found;
    }
}

# ---------- AUTHENTICATED (plain walker == walker:priv) ----------

walker AuditLog {
    has reports: list[dict] = [];

    can go with Root entry {
        report {"secret": "staff-only", "root_id": jid(here)};
    }
}

# ---------- FUNCTIONS ----------

def:pub ping() -> dict {
    return {"pong": True, "root": jid(root)};
}

def:priv whoami() -> str {
    return jid(root);
}
