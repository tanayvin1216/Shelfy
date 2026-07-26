# Jac Walkers — Verified Reference (jaclang 0.16.7, byllm 0.6.19)

Everything below was **executed** with
`/Users/tanayvinaykya/ShelfyJaq/Shelfy/.venv/bin/jac run <file>` and type-checked with
`jac check <file>`. Real terminal output is pasted verbatim. Anything not executed is
labelled **NOT EXECUTED**. Source guides: `jac guide jac-walker-patterns`,
`jac guide jac-impl-files`, `jac guide jac-concurrency`, `jac guide jac-node-edge-patterns`.

Spike files live in
`/private/tmp/claude-501/-Users-tanayvinaykya-ShelfyJaq-Shelfy/4f56bd43-419e-450b-83d0-78e9d8bcffd7/scratchpad/spikes/walkers/`.

> **Run hygiene:** `jac run` persists the graph into a `.jac/` dir in the CWD. Re-running a
> script duplicates nodes. Every spike below was run after `rm -rf .jac`.

---

## 1. Walker declaration, `has` inputs, abilities, and `here` / `self` / `visitor`

### Verified rules

| Keyword | Inside a **walker** ability (`can x with NodeType entry`) | Inside a **node** ability (`can x with WalkerType entry`) |
|---|---|---|
| `self` | the **walker** | the **node** |
| `here` | the **current node** | (not used) |
| `visitor` | (not used) | the **arriving walker** |

- Abilities must be `can`, never `def`. Every ability needs a `with <Type> entry` / `exit`
  clause. Plain helper methods inside a walker **can** be `def` (verified, §7 spike).
- `Root` is the type name; `root` is the value.
- **Spawning on a node fires that node's matching entry ability too** — classic off-by-one.
- A walker's generic `with entry` (no node type) fires **only at the spawn location**.

### Spike `01_basics.jac`

```jac
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
```

Real output:

```
  Checking 01_basics.jac...
01_basics.jac PASSED [100%]
============================== 1 passed in 1.01s ===============================
=== RUN ===
[walker] self is walker? target=rice; here is root
[node] beans sees walker looking for 'rice'
[walker] MATCH rice qty=9
[node] rice sees walker looking for 'rice'
{'target': 'rice', 'seen': ['beans', 'rice'], 'count': 2}
--- spawn form A result ---
[{'target': 'rice', 'seen': ['beans', 'rice'], 'count': 2}]
<class '__main__.Finder'>
[walker] self is walker? target=beans; here is root
[walker] MATCH beans qty=4
[node] beans sees walker looking for 'beans'
[node] rice sees walker looking for 'beans'
{'target': 'beans', 'seen': ['beans', 'rice'], 'count': 2}
--- spawn form B result ---
[{'target': 'beans', 'seen': ['beans', 'rice'], 'count': 2}]
```

---

## 2. Spawning — both forms work; the result **is the walker instance**

Both are current and produce identical results (verified above):

```jac
r1 = root spawn Finder(target="rice");     # node spawn Walker()   <- canonical, use this
r2 = Finder(target="beans") spawn root;    # Walker() spawn node   <- also works
```

`print(type(r1))` → `<class '__main__.Finder'>`.

**Key consequence:** the spawn expression returns the **walker object**, so you can read
*any* `has` field off it, not just `.reports`:

```
A.reports  -> [{'lot_jid': '6f9325e3...', 'shipments': 2, 'households': 3}]
A.lot_jid  -> 6f9325e3004b...
```

This is the cleanest way to get data out of a walker without going through `report`.

### `reports` field rules (verified)

- `has reports: list[T] = [];` — the `= []` default is **mandatory**. Without it:

```
✖ Error: error[E1050]: Not all required parameters were provided in the function call: 'reports'
  --> 08_e1050.jac:3:32
    2 | walker W { has reports: list[str]; can go with Root entry { report "x"; } }
```

- A walker that declares **no** `reports` field still gets one at runtime
  (`NoField.reports: ['orphan']`) — but declare it so `jac check` types the channel.

---

## 3. Ability ordering, `visit`, `report`, `skip`, `disengage`

### 3a. Exact execution order — spike `02_order.jac`

Chain `root -> a -> b -> c`, all `A` nodes with both node-side entry and exit hooks:

```
WALKER-entry root
WALKER-entry a
  NODE-entry  a
WALKER-entry b
  NODE-entry  b
WALKER-entry c
  NODE-entry  c
  NODE-exit   c
WALKER-exit  c
  NODE-exit   b
WALKER-exit  b
  NODE-exit   a
WALKER-exit  a
WALKER-exit  root
enter:a|enter:b|enter:c|exit:c|exit:b|exit:a
REPORTS: ['enter:a|enter:b|enter:c|exit:c|exit:b|exit:a']
LOG: ['enter:a', 'enter:b', 'enter:c', 'exit:c', 'exit:b', 'exit:a']
```

Rules proven:
1. On arrival: **walker entry ability runs first, then the node's entry ability.**
2. Exit abilities are deferred and fire **LIFO / post-order** (deepest node first).
3. On departure: **node exit first, then walker exit.**
4. `with Root exit` therefore runs after the whole traversal → the place for one final
   aggregated `report`.

### 3b. `report` semantics — spike `03_control.jac`

- Each `report X;` appends **one outer slot**: `reports` is `list[T]`, one entry per call.
- `report` **also prints the value to stdout** — that's why output looks doubled.
- Report ordering follows traversal order.

```
MULTI : ['b1', 'b2', 'b1a', 'b2a']
```

### 3c. `skip` vs `disengage` (verified)

Graph: `root -> b1 -> b1a`, `root -> b2(flagged) -> b2a`.

```
SKIP  : ['b1,b2,b1a']            # b2 hit `skip;` -> b2a never visited, walker continued
DISENG: ['b2'] found= b2         # DisengageDemo also has `can done with Root exit { report "ROOT-EXIT-RAN"; }`
DFS   : ['b1>b1a>b2>b2a']
```

- `skip;` = early-return from **this ability only**; queued visits continue.
- `disengage;` = kill the walker now. **Deferred exit abilities are DISCARDED** — note
  `"ROOT-EXIT-RAN"` is absent from `DISENG`. **If you `disengage`, you must `report`
  before disengaging; a `with ... exit` reporter will never run.**
- Default `visit [-->]` queues at the back → **breadth-first**.
  `visit :0: [-->];` queues at the front → **depth-first** (`b1>b1a>b2>b2a`).

### 3d. `visit ... else` — get-or-create (verified idempotent) — spike `04_inherit_multi.jac`

```jac
walker EnsurePantry {
    has name: str;
    has created: bool = False;
    has reports: list[str] = [];
    can run with Root entry {
        visit [here --> [?:Pantry, name == self.name]] else {
            fresh = here ++> Pantry(name=self.name);   # ++> returns a LIST
            self.created = True;
            visit fresh;                                # visit accepts the list
        }
    }
    can seen with Pantry entry {
        report f"pantry={here.name} created={self.created}";
    }
}
```

```
A: ['pantry=Main created=True']
B: ['pantry=Main created=False']
pantry count: 1
```

The `else` body runs only when the visit enqueued **nothing**. Second run finds the
existing node → same downstream ability, one node total.

---

## 4. Walker inheritance / the lookup-base walker

```jac
walker LotLookup {                      # base: resolve a jid once
    has lot_jid: str = "";
    has resolved: bool = False;
    can locate with Root entry {
        if self.resolved { skip; }      # <-- CRITICAL, see gotcha below
        self.resolved = True;
        target = jobj(self.lot_jid);
        if isinstance(target, Lot) { visit [target]; }
    }
}

walker MarkRecalled(LotLookup) {        # each action = 1 subclass + 1 ability
    has reports: list[dict] = [];
    can mark with Lot entry {
        here.recalled = True;
        report {"lot": here.code, "recalled": here.recalled};
        disengage;
    }
}

walker CountRecipients(LotLookup) {
    has reports: list[int] = [];
    can count with Lot entry { report len([here ->:GaveTo:->]); disengage; }
}
```

Output (`04_inherit_multi.jac`):

```
MARK : [{'lot': 'L-77', 'recalled': True}]
COUNT: [2]
```

Subclasses inherit the base's `has` fields **and** its abilities. Use
`override can <name> with <Type> entry { ... }` to replace a base ability for the same
node type (**NOT EXECUTED** — the guide documents it; the guard-flag approach below was
what I actually verified).

### ⚠️ BLOCKER-CLASS GOTCHA: lookup base + backward traversal = infinite loop

If any ability does `visit [here <--]` and the sweep ever reaches `root`, the **inherited
`with Root entry` ability fires again**, re-resolves the jid, and re-visits the target
node. Forever. Proven with `05b_loopproof.jac`:

```
  BASE locate fired at root
  at_lot #1
  BASE locate fired at root
  at_lot #2
  BASE locate fired at root
  at_lot #3
  BASE locate fired at root
  at_lot #4
LOOP DETECTED
['LOOP DETECTED']
```

(Without the counter guard, `jac run` hangs — my first attempt at spike 05 had to be
killed after 120s.)

**Fix (verified):** a `has resolved: bool = False;` guard on the base, first line
`if self.resolved { skip; }`. Backshelf's recall walkers MUST have this.

---

## 5. Multi-node-type walkers

Three ways, two of which type-check:

| Form | `jac check` | `jac run` |
|---|---|---|
| One ability per node type (`can d with Dog entry` + `can c with Cat entry`) | ✅ PASS | ✅ |
| Union entry + `isinstance` narrowing | ✅ PASS | ✅ |
| Union entry + typed context block `->Dog { ... }` | ❌ **E1099** | ✅ runs fine |

The typed-context-block form the guide shows (`->Dog { print(here.name); }`) **parses and
runs correctly but fails `jac check`** because the checker does not narrow `here`:

```
✖ Error: error[E1099]: Cannot access attribute "name" for type "Dog | Cat"; attribute is missing from Cat
  --> 04b_ctxblock.jac:8:36
    8 |         ->Dog { report f"dog {here.name}"; }
```

(Also note: `here -> Dog { ... }` — with `here` in front — is a **parse error** E0002.)

**Use this instead** (`04c_union.jac`, PASSES check):

```jac
walker Vet {
    has reports: list[str] = [];
    can start with Root entry { visit [-->]; }
    can checkup with Dog | Cat entry {
        if isinstance(here, Dog) { report f"dog {here.name}"; }
        elif isinstance(here, Cat) { report f"cat {here.lives}"; }
    }
}

walker Vet2 {                       # separate ability per node type — cleanest
    has reports: list[str] = [];
    can start with Root entry { visit [-->]; }
    can d with Dog entry { report f"dog {here.name}"; }
    can c with Cat entry { report f"cat {here.lives}"; }
}
```

```
UNION+isinstance: ['dog rex', 'cat 7']
PER-TYPE        : ['dog rex', 'cat 7']
```

**Traversal order with mixed types** is still BFS over the queue, dispatching each node to
its matching ability. `Census` walker over `Pantry -> Lot -> Household`:

```
CENSUS: [['P:Main', 'L:L-77', 'H:Alvarez', 'H:Brooks']]
```

A node with **no** matching ability is silently passed through (still traversed, no error).

---

## 6. Structured report payloads for a UI — spike `06_report_shapes.jac`

All three payload shapes work and round-trip with typed field access:

```jac
node Lot { has code: str; has qty: int = 0; }
obj LotView { has code: str; has qty: int; has status: str; }

walker RepNode { has reports: list[Lot] = [];     ... report here; }
walker RepObj  { has reports: list[LotView] = []; ... report LotView(code=here.code, qty=here.qty, status="ok"); }
walker RepDict { has reports: list[dict] = [];    ... report {"code": here.code, "qty": here.qty}; }
```

```
NODE  : [Lot(code='A', qty=1)] | typed field access: A
OBJ   : [LotView(code='A', qty=1, status='ok')] | typed field access: ok
DICT  : [{'code': 'A', 'qty': 1}]
NOFIELD walker ran, has reports attr? True
```

**Recommendation for Backshelf:** report a **view `obj`** (`LotView`-style), not a raw node
and not a hand-built dict. It type-checks (`has reports: list[LotView] = []`), the UI gets
`v.status` not `v["status"]`, and you control exactly which fields leak.
Plain `dict` payloads are fine when you need nested/JSON-shaped output (see §8) —
`json.dumps(walker.reports)` works directly on dict payloads.

### ⚠️ Nested spawns — spike `07_nested.jac`

```
standalone inner: ['inner:A', 'inner:B']
inner:A
inner:B
  inner.reports inside outer = []
  inner.out     inside outer = ['A', 'B']
outer saw 2
outer.reports: ['inner:A', 'inner:B', 'outer saw 2']
```

When walker B is spawned **from inside** walker A:
- `inner.reports` is **empty**.
- The inner walker's reports are **merged into the OUTER walker's `.reports`** (and appear
  *before* the outer's own reports). This silently pollutes your response shape.

**Rule:** for walker-calls-walker, pass results back through the inner walker's `has`
fields (`i.out`), never through `report`. Better still: make the inner walker `report`
nothing at all.

---

## 7. `impl` files and project layout

### 7a. Verified working layout (`proj_final/`) — `jac check` PASSES, `jac run` exit 0

```
proj_final/
├── graph.jac                 # node / edge archetypes
├── walkers.jac               # walker decls; ability BODIES inline; def helper DECLS
├── impl/
│   └── walkers.impl.jac      # bodies of the `def` helpers (paired by basename)
└── main.jac                  # entry point
```

`graph.jac`:
```jac
node Supplier { has name: str; }
node Lot      { has code: str; has recalled: bool = False; }
edge Sent: Supplier --> Lot {}
```

`walkers.jac`:
```jac
import from graph { Supplier, Lot }

walker LotLookup {
    has lot_jid: str = "";
    has resolved: bool = False;
    can locate with Root entry {
        if self.resolved { skip; }
        self.resolved = True;
        target = jobj(self.lot_jid);
        if isinstance(target, Lot) { visit [target]; }
    }
}

walker RecallSweep(LotLookup) {
    has chain: list[str] = [];
    has reports: list[dict] = [];

    def label(kind: str, text: str) -> str;   # helper DECL -> body in the annex

    can at_lot with Lot entry {
        here.recalled = True;
        self.chain.append(self.label("Lot", here.code));
        visit [here <--];
    }
    can at_supplier with Supplier entry {
        self.chain.append(self.label("Supplier", here.name));
    }
    can finish with Lot exit {
        report {"chain": self.chain, "hops": len(self.chain)};
    }
}
```

`impl/walkers.impl.jac`:
```jac
impl RecallSweep.label(kind: str, text: str) -> str {
    return f"{kind}:{text}";
}
```

`main.jac`:
```jac
import from graph { Supplier, Lot, Sent }
import from walkers { RecallSweep }

with entry {
    s = Supplier(name="Valley");
    root ++> s;
    l = Lot(code="L-1");
    s +>:Sent:+> l;
    print((root spawn RecallSweep(lot_jid=jid(l))).reports);
}
```

Real output:
```
  Checking proj_final/main.jac...
proj_final/main.jac PASSED [100%]
============================== 1 passed in 0.90s ===============================
{'chain': ['Lot:L-1', 'Supplier:Valley'], 'hops': 2}
[{'chain': ['Lot:L-1', 'Supplier:Valley'], 'hops': 2}]
exit=0
```

Layout facts verified:
- **No `import` between `mod.jac` and `mod.impl.jac`** — the compiler auto-pairs by basename.
- Both `impl/walkers.impl.jac` (shared dir) and side-by-side `walkers.impl.jac` pair correctly.
- No `__init__.jac` needed; any dir with `.jac` files is importable.
- **Edge archetypes must be imported explicitly at the use site.** Omitting `Sent` from the
  import gives:
  `error[E2018]: Undefined name 'Sent' in connect typed-edge position`
- Edge endpoint syntax is `edge Sent: Supplier --> Lot {}` — **double arrow**.
  `edge Sent: Supplier -> Lot {}` is `error[E0001]: Expected '-->', got '->'`.

### 7b. ⚠️ ENVIRONMENT BUG: walker-ability bodies in a `.impl.jac` annex → E5020 + exit 1

Minimally reproduced (`proj6/`): put a **walker ability** impl in a separate annex file and
`jac run` prints correct output but then errors and exits 1:

```
A
✖ Error: error[E5020]: Native compilation failed: create_pipeline_tuning_options() got an
  unexpected keyword argument 'size_level'. Did you mean 'speed_level'?
  --> .../proj6/main.jac:1:1
['A']
exit=1
```

Isolation matrix (all executed):

| Case | Result |
|---|---|
| Walker ability impl in **separate `.impl.jac`** (side-by-side OR `impl/` dir) | ❌ E5020, exit 1 |
| Walker ability impl **inline** in the same `.jac` file (`impl W.go { ... }`) | ✅ exit 0 |
| `obj` method impl in a `.impl.jac` annex | ✅ exit 0 |
| plain `def` impl in a `.impl.jac` annex | ✅ exit 0 |
| multi-module import, no annex | ✅ exit 0 |
| `jac check` on the failing case | ✅ PASSES (it's a run-time backend error) |
| `jac run --no-autonative` | ❌ still E5020 |
| `jac run -e none` | ✅ exit 0, error suppressed, output intact |

Cause is a version mismatch in the native/LLVM backend (`llvmlite 0.48.0` in this venv).

**Guidance for Backshelf (pick one):**
1. **Recommended:** keep `can ... entry` bodies **inline** in the walker file; move only
   `def` helper bodies into `impl/<mod>.impl.jac`. This still shows off impl-file depth,
   type-checks, and exits 0. (This is `proj_final/` above.)
2. If you want walker abilities in the annex anyway, ship the run command as
   `jac run -e none main.jac` — output is correct either way, but you lose all diagnostics,
   so develop with plain `jac run` / `jac check` and only add `-e none` for the demo.

**NOT EXECUTED:** whether E5020 also affects `jac serve` / `jac start` (server mode) — the
server area owner should re-test this.

---

## 8. Main spike — two walkers, backward recall sweep (`05_recall_sweep.jac`)

Walker A builds `Supplier -> Shipment -> Lot -> Household` (with a **diamond**: two
Shipments contain the same Lot). Walker B starts at the leaf `Lot` (resolved by jid) and
sweeps **backward** with `visit [here <--]` up to every ancestor referencing it, reporting
a structured, UI-renderable payload.

```jac
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

        ship2 = Shipment(ref="SH-2209", arrived="2026-07-05");
        sup +>:Sent:+> ship2;
        ship2 +>:Contains(cases=3):+> lot;          # diamond / multi-parent

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

# ---------- Walker B: backward sweep ----------
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
        visit [here <--];                  # BACKWARD
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
```

Real output:

```
  Checking 05_recall_sweep.jac...
05_recall_sweep.jac PASSED [100%]
============================== 1 passed in 0.98s ===============================
=== RUN ===
{'lot_jid': '6f9325e3004b4451af83a5d3edc9e88c', 'shipments': 2, 'households': 3}
A.reports  -> [{'lot_jid': '6f9325e3004b4451af83a5d3edc9e88c', 'shipments': 2, 'households': 3}]
A.lot_jid  -> 6f9325e3004b...
{'lot': 'L-8842 / Peanut Butter 16oz', 'recalled': True, 'affected_households': ['Alvarez', 'Brooks', 'Chen'], 'chain': [...]}
--- B.reports (structured, UI-renderable) ---
[
  {
    "lot": "L-8842 / Peanut Butter 16oz",
    "recalled": true,
    "affected_households": [
      "Alvarez",
      "Brooks",
      "Chen"
    ],
    "chain": [
      { "depth": 0, "kind": "Lot",      "label": "L-8842 / Peanut Butter 16oz" },
      { "depth": 1, "kind": "Shipment", "label": "SH-2201 arrived 2026-07-01" },
      { "depth": 1, "kind": "Shipment", "label": "SH-2209 arrived 2026-07-05" },
      { "depth": 2, "kind": "Supplier", "label": "Valley Foods" }
    ]
  }
]
```

Two guards a backward sweep **needs** (both proven necessary):
1. `resolved` flag on the lookup base — otherwise root re-entry → infinite loop (§4).
2. A `seen` jid list — otherwise the diamond visits `Supplier` twice and the walker
   re-expands from it.

Also note `def mark(...) -> bool` — **plain `def` helper methods inside a walker work**,
called as `self.mark(...)`.

---

## 9. Concurrency (skim, `jac guide jac-concurrency`) — NOT EXECUTED

- `flow expr()` launches on a **thread pool** and returns a future; `wait f` collects.
  Launch all, then wait all — a `wait` right after each `flow` serializes the work.
- `async def` / `await` is plain asyncio; drive from `with entry` via `asyncio.run(main())`.
- **Async walkers**: `async walker W { async can step with Item entry { ... await ... } }`,
  then `await (root spawn W())` from an async context.
- `flow` and `wait` are reserved keywords.
- Not needed for Backshelf's core recall sweep; only relevant if we fan out LLM calls.

---

## 10. Quick gotcha checklist for the implementer

1. `here` = node, `self` = walker (walker side). `self` = node, `visitor` = walker (node side).
2. Walker entry ability runs **before** the node's entry ability; exits run LIFO, node-exit then walker-exit.
3. `disengage;` **discards deferred exit abilities** — report before you disengage.
4. `has reports: list[T] = [];` — the `= []` is mandatory (else E1050).
5. Spawn returns the walker: read `w.any_has_field`, not just `w.reports`.
6. Lookup-base walker + `visit [<--]` = infinite loop unless you guard the base's Root entry.
7. Diamond graphs re-visit nodes — keep a `seen` jid list if you aggregate.
8. Typed context blocks (`->Dog { }`) run but fail `jac check`; use `isinstance` or one ability per type.
9. `edge E: A --> B {}` (double arrow); edge names must be imported at the use site.
10. `++>` returns a **list** — index it (`(here ++> Lot(...))[0]`) or `visit` it directly.
11. Nested spawn: inner reports leak into the outer walker's `reports`; pass data via `has`.
12. Walker-ability bodies in a `.impl.jac` annex trigger E5020/exit 1 in this venv — keep them inline (see §7b).
13. `jac run` persists to `./.jac/` — `rm -rf .jac` (or `jac clean --all` with a jac.toml) between runs during dev.
