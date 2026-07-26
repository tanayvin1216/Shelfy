node Item {
    has name: str;
    has qty: int = 0;

    can noticed with Finder entry {
        # node side: self = this node, visitor = arriving walker
        print(f"[node] {self.name} sees walker looking for '{visitor.target}'");
    }
}

walker Finder {
    has target: str;
    has seen: list[str] = [];
    has reports: list[dict] = [];

    can on_root with Root entry {
        print(f"[walker] self is walker? target={self.target}; here is root");
        visit [-->];
    }

    can on_item with Item entry {
        # walker side: self = walker, here = current node
        self.seen.append(here.name);
        if here.name == self.target {
            print(f"[walker] MATCH {here.name} qty={here.qty}");
        }
        visit [-->];
    }

    can finish with Root exit {
        report {"target": self.target, "seen": self.seen, "count": len(self.seen)};
    }
}

with entry {
    root ++> Item(name="beans", qty=4);
    root ++> Item(name="rice", qty=9);

    r1 = root spawn Finder(target="rice");
    print("--- spawn form A result ---");
    print(r1.reports);
    print(type(r1));

    r2 = Finder(target="beans") spawn root;
    print("--- spawn form B result ---");
    print(r2.reports);
}
