node A {
    has n: str;
    can hook with W entry {
        print(f"  NODE-entry  {self.n}");
    }
    can hook_out with W exit {
        print(f"  NODE-exit   {self.n}");
    }
}

walker W {
    has log: list[str] = [];
    has reports: list[str] = [];

    can w_root with Root entry {
        print("WALKER-entry root");
        visit [-->];
    }
    can w_a with A entry {
        print(f"WALKER-entry {here.n}");
        self.log.append(f"enter:{here.n}");
        visit [-->];
    }
    can w_a_exit with A exit {
        print(f"WALKER-exit  {here.n}");
        self.log.append(f"exit:{here.n}");
    }
    can w_root_exit with Root exit {
        print("WALKER-exit  root");
        report "|".join(self.log);
    }
}

with entry {
    a = A(n="a");
    b = A(n="b");
    c = A(n="c");
    root ++> a;
    a ++> b;
    b ++> c;
    res = root spawn W();
    print("REPORTS:", res.reports);
    print("LOG:", res.log);
}
