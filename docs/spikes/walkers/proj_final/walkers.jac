import from graph { Supplier, Lot }

walker LotLookup {
    has lot_jid: str = "";
    has resolved: bool = False;

    can locate with Root entry {          # ability BODY stays inline
        if self.resolved { skip; }
        self.resolved = True;
        target = jobj(self.lot_jid);
        if isinstance(target, Lot) { visit [target]; }
    }
}

walker RecallSweep(LotLookup) {
    has chain: list[str] = [];
    has reports: list[dict] = [];

    def label(kind: str, text: str) -> str;   # helper DECL -> body in annex

    can at_lot with Lot entry {
        here.recalled = True;
        self.chain.append(self.label("Lot", here.code));
        visit [here <--];
    }
    can at_supplier with Supplier entry {
        self.chain.append(self.label("Supplier", here.name));
    }
    can finish with Lot exit {
        report {"chain": self.chain, "hops": len(self.chain)};
    }
}
