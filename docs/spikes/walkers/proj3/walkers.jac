import from graph { Lot }
walker Sweep {
    has reports: list[str] = [];
    can at_lot with Lot entry { report here.code; }
    can go with Root entry { visit [-->]; }
}
