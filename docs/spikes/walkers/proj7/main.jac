node Lot { has code: str; }
walker Sweep {
    has reports: list[str] = [];
    can go with Root entry;
    can at_lot with Lot entry;
}
impl Sweep.go { visit [-->]; }
impl Sweep.at_lot { report here.code; }
with entry { root ++> Lot(code="A"); print((root spawn Sweep()).reports); }
