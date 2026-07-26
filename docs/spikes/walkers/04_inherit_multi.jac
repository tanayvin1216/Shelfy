node Pantry { has name: str; }
node Lot     { has code: str; has recalled: bool = False; }
node Household { has name: str; }

edge Holds: Pantry --> Lot {}
edge GaveTo: Lot --> Household { has qty: int = 1; }

# --- get-or-create via visit ... else ---
walker EnsurePantry {
    has name: str;
    has created: bool = False;
    has reports: list[str] = [];
    can run with Root entry {
        visit [here --> [?:Pantry, name == self.name]] else {
            fresh = here ++> Pantry(name=self.name);
            self.created = True;
            visit fresh;
        }
    }
    can seen with Pantry entry {
        report f"pantry={here.name} created={self.created}";
    }
}

# --- lookup base walker: resolves a jid once, subclasses add one ability ---
walker FindLot {
    has lot_id: str = "";
    can locate with Root entry {
        target = jobj(self.lot_id);
        if isinstance(target, Lot) {
            visit [target];
        }
    }
}

walker MarkRecalled(FindLot) {
    has reports: list[dict] = [];
    can mark with Lot entry {
        here.recalled = True;
        report {"lot": here.code, "recalled": here.recalled};
        disengage;
    }
}

walker CountRecipients(FindLot) {
    has reports: list[int] = [];
    can count with Lot entry {
        report len([here ->:GaveTo:->]);
        disengage;
    }
}

# --- multi-node-type walker: union entry + typed context blocks ---
walker Census {
    has lines: list[str] = [];
    has reports: list[list[str]] = [];

    can start with Root entry { visit [-->]; }

    can any_node with Pantry | Lot | Household entry {
        if isinstance(here, Pantry) { self.lines.append(f"P:{here.name}"); }
        elif isinstance(here, Lot) { self.lines.append(f"L:{here.code}"); }
        elif isinstance(here, Household) { self.lines.append(f"H:{here.name}"); }
        visit [-->];
    }

    can fin with Root exit { report self.lines; }
}

with entry {
    p = (root spawn EnsurePantry(name="Main"));
    print("A:", p.reports);
    p2 = (root spawn EnsurePantry(name="Main"));
    print("B:", p2.reports);
    print("pantry count:", len([root --> [?:Pantry]]));

    pantry = [root --> [?:Pantry]][0];
    lot = Lot(code="L-77");
    pantry +>:Holds:+> lot;
    h1 = Household(name="Alvarez"); h2 = Household(name="Brooks");
    lot +>:GaveTo(qty=2):+> h1;
    lot +>:GaveTo(qty=1):+> h2;

    lid = jid(lot);
    print("MARK :", (root spawn MarkRecalled(lot_id=lid)).reports);
    print("COUNT:", (root spawn CountRecipients(lot_id=lid)).reports);
    print("CENSUS:", (root spawn Census()).reports);
}
