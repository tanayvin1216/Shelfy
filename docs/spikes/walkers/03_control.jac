node Bin {
    has code: str;
    has flagged: bool = False;
}

walker MultiReport {
    has reports: list[str] = [];
    can go with Root entry { visit [-->]; }
    can each with Bin entry {
        report here.code;          # per-node report -> one outer slot each
        visit [-->];
    }
}

walker SkipDemo {
    has reports: list[str] = [];
    has touched: list[str] = [];
    can go with Root entry { visit [-->]; }
    can each with Bin entry {
        self.touched.append(here.code);
        if here.flagged {
            skip;                  # ends THIS ability only; children NOT visited
        }
        visit [-->];
    }
    can done with Root exit { report ",".join(self.touched); }
}

walker DisengageDemo {
    has want: str;
    has found: str = "";
    has reports: list[str] = [];
    can go with Root entry { visit [-->]; }
    can each with Bin entry {
        if here.code == self.want {
            self.found = here.code;
            report here.code;
            disengage;             # kills the whole walker, queued visits dropped
        }
        visit [-->];
    }
    can done with Root exit { report "ROOT-EXIT-RAN"; }
}

walker DepthFirst {
    has order: list[str] = [];
    has reports: list[str] = [];
    can go with Root entry { visit :0: [-->]; }
    can each with Bin entry {
        self.order.append(here.code);
        visit :0: [-->];
    }
    can done with Root exit { report ">".join(self.order); }
}

with entry {
    # root -> b1 -> b1a ; root -> b2 -> b2a
    b1 = Bin(code="b1"); b1a = Bin(code="b1a");
    b2 = Bin(code="b2", flagged=True); b2a = Bin(code="b2a");
    root ++> b1; b1 ++> b1a;
    root ++> b2; b2 ++> b2a;

    print("MULTI :", (root spawn MultiReport()).reports);
    print("SKIP  :", (root spawn SkipDemo()).reports);
    d = root spawn DisengageDemo(want="b2");
    print("DISENG:", d.reports, "found=", d.found);
    print("DFS   :", (root spawn DepthFirst()).reports);
}
