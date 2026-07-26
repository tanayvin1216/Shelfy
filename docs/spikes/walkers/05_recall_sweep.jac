"""Two-walker spike: walker A builds the graph, walker B does a BACKWARD sweep
from a leaf Lot up to every ancestor that references it, reporting a structured list.

Includes the two guards a backward sweep NEEDS:
  1. `resolved` guard on the lookup base  -> stops the re-entry loop when the
     backward sweep arrives back at Root and refires the base's Root entry.
  2. `seen` jid set                        -> stops double-counting on diamond graphs
     (one Lot referenced by two Shipments that share one Supplier).
"""

import json;

node Supplier  { has name: str; }
node Shipment  { has ref: str;  has arrived: str; }
node Lot       { has code: str; has product: str; has recalled: bool = False; }
node Household { has name: str; }

edge Sent:      Supplier --> Shipment {}
edge Contains:  Shipment --> Lot { has cases: int = 1; }
edge Issued:    Lot --> Household { has qty: int = 1; }

obj TraceHop {
    has depth: int;
    has kind: str;
    has label: str;
    has ref_id: str;
}

# ---------- Walker A: build the graph ----------
walker SeedGraph {
    has lot_jid: str = "";
    has reports: list[dict] = [];

    can build with Root entry {
        sup = Supplier(name="Valley Foods");
        here ++> sup;

        ship = Shipment(ref="SH-2201", arrived="2026-07-01");
        sup +>:Sent:+> ship;

        lot = Lot(code="L-8842", product="Peanut Butter 16oz");
        ship +>:Contains(cases=12):+> lot;

        # a second shipment that also contains the SAME lot (diamond / multi-parent)
        ship2 = Shipment(ref="SH-2209", arrived="2026-07-05");
        sup +>:Sent:+> ship2;
        ship2 +>:Contains(cases=3):+> lot;

        for n in ["Alvarez", "Brooks", "Chen"] {
            hh = Household(name=n);
            here ++> hh;
            lot +>:Issued(qty=2):+> hh;
        }

        self.lot_jid = jid(lot);
        report {"lot_jid": self.lot_jid, "shipments": 2, "households": 3};
    }
}

# ---------- lookup base (guarded) ----------
walker LotLookup {
    has lot_jid: str = "";
    has resolved: bool = False;

    can locate with Root entry {
        if self.resolved { skip; }      # CRITICAL: root can be re-entered from <--
        self.resolved = True;
        target = jobj(self.lot_jid);
        if isinstance(target, Lot) {
            visit [target];
        }
    }
}

# ---------- Walker B: backward sweep from the leaf Lot to the roots ----------
walker RecallSweep(LotLookup) {
    has hops: list[TraceHop] = [];
    has seen: list[str] = [];
    has households: list[str] = [];
    has reports: list[dict] = [];

    def mark(depth: int, kind: str, label: str, ref: str) -> bool {
        if ref in self.seen { return False; }
        self.seen.append(ref);
        self.hops.append(TraceHop(depth=depth, kind=kind, label=label, ref_id=ref));
        return True;
    }

    can at_lot with Lot entry {
        here.recalled = True;
        self.mark(0, "Lot", f"{here.code} / {here.product}", jid(here));
        self.households = [h.name for h in [here ->:Issued:->]];
        visit [here <--];                  # BACKWARD: everything pointing at this lot
    }

    can at_shipment with Shipment entry {
        if self.mark(1, "Shipment", f"{here.ref} arrived {here.arrived}", jid(here)) {
            visit [here <--];
        }
    }

    can at_supplier with Supplier entry {
        if self.mark(2, "Supplier", here.name, jid(here)) {
            visit [here <--];
        }
    }

    can finish with Lot exit {
        report {
            "lot": self.hops[0].label if self.hops else "",
            "recalled": True,
            "affected_households": self.households,
            "chain": [
                {"depth": h.depth, "kind": h.kind, "label": h.label}
                for h in self.hops
            ]
        };
    }
}

with entry {
    a = root spawn SeedGraph();
    print("A.reports  ->", a.reports);
    print("A.lot_jid  ->", a.lot_jid[:12] + "...");

    b = root spawn RecallSweep(lot_jid=a.lot_jid);
    print("--- B.reports (structured, UI-renderable) ---");
    print(json.dumps(b.reports, indent=2));
}
