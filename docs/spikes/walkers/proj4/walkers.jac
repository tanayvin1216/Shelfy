import from graph { Supplier, Lot }

walker LotLookup {
    has lot_jid: str = "";
    has resolved: bool = False;
    can locate with Root entry;              # declaration only
}

walker RecallSweep(LotLookup) {
    has chain: list[str] = [];
    has reports: list[dict] = [];
    can at_lot with Lot entry;
    can at_supplier with Supplier entry;
    can finish with Lot exit;
}
