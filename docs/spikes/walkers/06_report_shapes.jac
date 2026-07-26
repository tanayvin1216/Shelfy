node Lot { has code: str; has qty: int = 0; }
obj LotView { has code: str; has qty: int; has status: str; }

walker RepNode { has reports: list[Lot] = [];
    can go with Root entry { visit [-->]; }
    can l with Lot entry { report here; }
}
walker RepObj { has reports: list[LotView] = [];
    can go with Root entry { visit [-->]; }
    can l with Lot entry { report LotView(code=here.code, qty=here.qty, status="ok"); }
}
walker RepDict { has reports: list[dict] = [];
    can go with Root entry { visit [-->]; }
    can l with Lot entry { report {"code": here.code, "qty": here.qty}; }
}
walker RepNone { }   # no reports field at all

with entry {
    root ++> Lot(code="A", qty=1);
    rn = (root spawn RepNode()).reports;
    print("NODE  :", rn, "| typed field access:", rn[0].code);
    ro = (root spawn RepObj()).reports;
    print("OBJ   :", ro, "| typed field access:", ro[0].status);
    print("DICT  :", (root spawn RepDict()).reports);
    w = root spawn RepNone();
    print("NOFIELD walker ran, has reports attr?", hasattr(w, "reports"));
}
