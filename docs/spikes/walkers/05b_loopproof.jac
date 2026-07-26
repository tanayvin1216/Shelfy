node Lot { has code: str; }

walker LotLookup {
    has lot_jid: str = "";
    can locate with Root entry {
        print("  BASE locate fired at root");
        target = jobj(self.lot_jid);
        if isinstance(target, Lot) { visit [target]; }
    }
}

walker Sweep(LotLookup) {
    has n: int = 0;
    has reports: list[str] = [];
    can at_lot with Lot entry {
        self.n += 1;
        print(f"  at_lot #{self.n}");
        if self.n > 3 { report "LOOP DETECTED"; disengage; }
        visit [here <--];
    }
}

with entry {
    lot = Lot(code="X");
    root ++> lot;
    print((root spawn Sweep(lot_jid=jid(lot))).reports);
}
