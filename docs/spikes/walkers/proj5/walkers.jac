import from graph { Lot }
walker Sweep {
    has reports: list[str] = [];
    can go with Root entry;
    can at_lot with Lot entry;
}
