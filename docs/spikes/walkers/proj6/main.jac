node Lot { has code: str; }
walker Sweep {
    has reports: list[str] = [];
    can go with Root entry;
    can at_lot with Lot entry;
}
with entry { root ++> Lot(code="A"); print((root spawn Sweep()).reports); }
