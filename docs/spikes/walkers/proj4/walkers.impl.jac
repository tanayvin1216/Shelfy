impl LotLookup.locate {
    if self.resolved { skip; }
    self.resolved = True;
    target = jobj(self.lot_jid);
    if isinstance(target, Lot) { visit [target]; }
}

impl RecallSweep.at_lot {
    here.recalled = True;
    self.chain.append(f"Lot:{here.code}");
    visit [here <--];
}

impl RecallSweep.at_supplier {
    self.chain.append(f"Supplier:{here.name}");
}

impl RecallSweep.finish {
    report {"chain": self.chain, "hops": len(self.chain)};
}
