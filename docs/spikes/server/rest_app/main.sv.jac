"""Spike 3: @restspec custom routes, uploads, typed responses."""

import from http { HTTPMethod }

glob storage: any = store();

node Item {
    has label: str = "",
        qty: int = 0;
}

obj ItemView {
    has id: str;
    has label: str;
    has qty: int;
}

# --- custom GET route with path + query params ---
@restspec(method=HTTPMethod.GET, path="/pantry/{pantry_id}/items")
walker:pub GetPantryItems {
    has pantry_id: str;
    has q: str = "";
    has reports: list[dict] = [];

    can go with Root entry {
        report {"pantry": self.pantry_id, "q": self.q};
    }
}

# --- typed response from a pub function ---
def:pub add_item(label: str, qty: int = 1) -> ItemView {
    it = (root.shared ++> Item(label=label, qty=qty))[0];
    return ItemView(id=jid(it), label=it.label, qty=it.qty);
}

def:pub all_items() -> list[ItemView] {
    return [ItemView(id=jid(i), label=i.label, qty=i.qty)
            for i in [root.shared --> [?:Item]]];
}

# --- deliberate error, to see the error envelope ---
walker:pub Boom {
    has reports: list[dict] = [];

    can go with Root entry {
        raise ValueError("kaboom");
    }
}
