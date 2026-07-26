node Lot { has code: str; }

walker Inner {
    has out: list[str] = [];
    has reports: list[str] = [];
    can go with Root entry { visit [-->]; }
    can l with Lot entry { self.out.append(here.code); report f"inner:{here.code}"; }
}

walker Outer {
    has reports: list[str] = [];
    can go with Root entry {
        i = root spawn Inner();
        print("  inner.reports inside outer =", i.reports);
        print("  inner.out     inside outer =", i.out);
        report f"outer saw {len(i.out)}";
    }
}

walker NoField {
    can go with Root entry { report "orphan"; }
}

with entry {
    root ++> Lot(code="A");
    root ++> Lot(code="B");
    print("standalone inner:", (root spawn Inner()).reports);
    o = root spawn Outer();
    print("outer.reports:", o.reports);
    n = root spawn NoField();
    print("NoField.reports:", n.reports);
}
