# Backshelf — Jac Core + Graph Layer (VERIFIED)

**Environment:** jaclang 0.16.7, Python 3.13.6, macOS arm64, plugin byllm 0.6.19
**CLI:** `/Users/tanayvinaykya/ShelfyJaq/Shelfy/.venv/bin/jac`
**Sources:** local `jac guide` output for `jac-project-kinds`, `jac-core-cheatsheet`, `jac-has-fields`, `jac-node-edge-patterns`, `jac-types`. Every snippet below was EXECUTED unless explicitly marked NOT EXECUTED.
**Spikes:** `/private/tmp/claude-501/-Users-tanayvinaykya-ShelfyJaq-Shelfy/4f56bd43-419e-450b-83d0-78e9d8bcffd7/scratchpad/spikes/core-graph/`

---

## 0. TL;DR for the implementer

1. Backshelf is the **CLI tool** project kind (guide `jac-project-kinds`): graph persists in `.jac/data/<entryfile>.db` between `jac run` invocations. No plugins needed. Load guides `jac-node-edge-patterns` + `jac-walker-patterns`.
2. Typed connect is `+>:Edge(field=val):+>` — **`+` on BOTH sides**. Typed read is `->:Edge:->` — **SINGLE arrows**.
3. Backward traversal is `<-:Edge:<-`. Multi-hop backward chains fine: `[recall <-:FlaggedBy:<- <-:Received:<-]`.
4. **Node reads DEDUPE by node identity; `[edge ...]` reads do NOT.** This is the single most important semantic for recall fan-out.
5. Declare edge endpoints (`edge R: Src --> Tgt {...}`) or your traversals return `Unknown` and blow up at typed function boundaries.

---

## 1. Minimal module shape

`01_minimal.jac`:

```jac
import from datetime { datetime }

glob APP_NAME: str = "Backshelf";

def label_for(count: int) -> str {
    return "empty" if count == 0 else f"{count} items";
}

obj Config {
    has name: str;
    has debug: bool = False;
}

with entry {
    cfg = Config(name=APP_NAME);
    print(cfg.name, cfg.debug);
    print(label_for(0), label_for(3));
    print(type(datetime.now()).__name__);
}
```

Real output:

```
$ jac check 01_minimal.jac
  Checking 01_minimal.jac...
01_minimal.jac PASSED [100%]
============================== 1 passed in 1.03s ===============================

$ jac run 01_minimal.jac
Backshelf False
empty 3 items
datetime
```

Rules confirmed from `jac-core-cheatsheet`:
- Every statement ends `;`. Every block is `{ }`. **Exception: `match`/`case` bodies use Python indentation with `:`** — `case 0 { }` is a parse error E0001.
- `import from X { Y }` takes **NO trailing semicolon**. `import os;` DOES take one.
- Module-level variables need `glob`.
- `with entry { }` runs on EVERY import. Use **`with entry:__main__ { }`** for CLI/demo code — all Backshelf entry points should use this so the module stays importable by tests/walkers.
- Booleans `True`/`False`, null `None` (capitalized). `false` → misleading `E1002`.
- No `pass`; write `{}`.
- Ternary is Python-style `A if cond else B`.
- Lambdas must be typed: `lambda x: int : x + 1` or `lambda(x: int) -> int { return x * x; }`.
- Reserved words that WILL bite us: `node`, `edge`, `walker`, `obj`, `visit`, `report`, `spawn`, `del`, `has`, `can`, `with`, `skip`, `disengage`. **`entry` and `exit` are NOT reserved.**
- Unused names warn W2003. Prefix `_` or discard `_ = f();`.

---

## 2. `node` / `edge` / `obj` with typed `has`, defaults, postinit

### Field rules (guide `jac-has-fields`, both VERIFIED by negative test)

**E2004 — required fields must precede defaulted ones.** `10_neg_ordering.jac`:

```jac
node Item { has qty: int = 1; has sku: str; }
```

```
$ jac check 10_neg_ordering.jac
✖ Error: error[E2004]: Non default attribute 'sku' follows default attribute
  --> 10_neg_ordering.jac:1:35
    1 | node Item { has qty: int = 1; has sku: str; }
      |                                   ^^^
```

**Parent default forces child default — `jac check` PASSES, runtime CRASHES.** `11_neg_parentdefault.jac`:

```jac
node Base { has name: str = "?"; }
node Child(Base) { has code: str; }      # code has no default
with entry:__main__ { print(Child(code="c")); }
```

```
$ jac check 11_neg_parentdefault.jac
11_neg_parentdefault.jac PASSED [100%]

$ jac run 11_neg_parentdefault.jac
  at _init_fn() .../dataclasses.py:627
  at _process_class() .../dataclasses.py:1078
  ... TypeError: non-default argument 'code' follows default argument
```

> **Backshelf rule: once any node in an inheritance chain has a default, give EVERY field in EVERY subclass a default.** `jac check` will not save you here.

### Derived field via `by postinit` (VERIFIED)

```jac
node Item {
    has sku: str;
    has name: str;
    has lot: str = "";
    has qty: int = 1;
    has slug: str by postinit;

    def postinit {
        self.slug = f"{self.sku}-{self.lot}";
    }
}
```

Real output (`03_dedupe_delete.jac`):

```
=== postinit derived field ===
PB-100-L77
```

`by postinit` excludes the field from the constructor. It may draw a spurious W1051; `jac check` still passes.

### `obj` is OFF the graph (VERIFIED, `09_obj_inherit.jac`)

```jac
obj IntakeLine {
    has sku: str;
    has qty: int = 1;
}

def summarize(lines: list[IntakeLine]) -> int {
    total = 0;
    for l in lines { total += l.qty; }
    return total;
}
```

```
=== obj is plain in-memory data ===
total qty: 7
```

Use `obj` for DTOs / view models / parsed CSV rows. Use `node`/`edge` for anything that must persist or be traversed.

---

## 3. The Backshelf schema, verbatim and running

`02_schema.jac` — full file at the spikes path. Declarations:

```jac
node Pantry      { has name: str; has city: str = "unknown"; }
node Shelf       { has code: str; has temp_c: float = 20.0; }
node Allergen    { has label: str; }
node Household   { has family: str; has size: int = 1; }
node RecallRecord{ has recall_id: str; has reason: str = ""; has severity: int = 1; }

node Item {
    has sku: str;
    has name: str;
    has lot: str = "";
    has qty: int = 1;
    has slug: str by postinit;
    def postinit { self.slug = f"{self.sku}-{self.lot}"; }
}

edge Stocks:    Shelf     --> Item         { has placed_on: str = "2026-01-01"; }
edge Contains:  Item      --> Allergen     { has evidence: str = "label"; has confidence: float = 1.0; }
edge Received:  Household --> Item         { has pickup_code: str; has qty: int = 1; }
edge FlaggedBy: Item      --> RecallRecord { has confidence: float = 0.5; has method: str = "lot-match"; }
```

> **ALWAYS write `edge E: Src --> Tgt`.** Without endpoint types, `[src ->:E:->]` yields `Unknown`-typed nodes: attribute access only *warns* (W1051) but passing that node to a typed `def` parameter fails **E1053**. This is a silent landmine.

Construction + connection:

```jac
pantry = Pantry(name="Eastside Pantry", city="Ann Arbor");
root ++> pantry;                                    # untyped connect

shelf_a = Shelf(code="A1", temp_c=4.0);
pantry ++> shelf_a;

peanut_butter = Item(sku="PB-100", name="Peanut Butter", lot="L77", qty=12);
shelf_a +>:Stocks(placed_on="2026-07-01"):+> peanut_butter;    # TYPED connect with attrs
shelf_b +>:Stocks:+> rice;                                      # typed, all defaults

hh_lopez +>:Received(pickup_code="PU-001", qty=2):+> peanut_butter;
peanut_butter +>:Contains(evidence="ingredient-list", confidence=0.99):+> peanuts;
peanut_butter +>:FlaggedBy(confidence=0.95, method="lot-match"):+> recall;
```

**Operator spelling (memorize):**

| Purpose | Spelling | Notes |
|---|---|---|
| untyped connect | `a ++> b` | **returns a LIST**, not the node. `n = a ++> Item(...)` → `n[0]` is the Item |
| untyped connect, both dirs | `a <++> b` | creates TWO edges — easy to double-count |
| typed connect | `a +>:E(f=v):+> b` | `+` on BOTH sides of the colons |
| typed connect, no args | `a +>:E:+> b` | |
| outgoing nodes | `[a -->]` | |
| incoming nodes | `[a <--]` | |
| either direction | `[a <-->]` | |
| typed outgoing | `[a ->:E:->]` | **single** arrows. `-->:E:-->` is a parse error |
| typed incoming | `[a <-:E:<-]` | |
| typed bidirectional | **DOES NOT EXIST** | `[a <->:E:<->]` is a parse error; do the two directed reads |
| edge objects out | `[edge a ->:E:->]` | how you read edge `has` fields |
| edge objects in | `[edge a <-:E:<-]` | VERIFIED working |
| edge objects to a specific target | `[edge a ->:E:-> b]` | VERIFIED — this is the existence check |

---

## 4. Traversal & filtering — every form, with real output

All from `02_schema.jac`.

```jac
# 1. all outgoing (untyped)
[pantry -->]

# 2. by node type
[pantry -->[?:Shelf]]
[pantry -->[?:Household]]

# 3. by edge type
[shelf_a ->:Stocks:->]

# 4. by EDGE ATTRIBUTE value  <-- predicate sits between the colons
[shelf_a ->:Stocks:placed_on == "2026-07-01":->]
[hh_chen ->:Received:qty > 0:->]
[peanut_butter ->:Contains:confidence > 0.5:->]

# 5. by NODE FIELD value
[pantry -->[?:Household, size > 2]]
[shelf_a ->:Stocks:->[?qty > 10]]          # filter AFTER a typed hop

# 6. edge objects (read edge has-fields)
for e in [edge hh_chen ->:Received:->] { print(e.pickup_code, e.qty); }

# 7. multi-hop forward
[pantry --> ->:Stocks:->]
[pantry --> ->:Stocks:-> ->:Contains:->]
```

Real output:

```
=== 1. all outgoing from pantry (untyped) ===
[Shelf(code='A1', temp_c=4.0), Shelf(code='B2', temp_c=20.0), Household(family='Lopez', size=4), Household(family='Chen', size=2), Household(family='Okoro', size=3)]
=== 2. by node type ===
['A1', 'B2']
['Lopez', 'Chen', 'Okoro']
=== 3. by edge type ===
['Peanut Butter', 'Oat Milk']
=== 4. by EDGE ATTRIBUTE value ===
['Peanut Butter']
['Peanut Butter', 'Rice']
['peanuts']
=== 5. by NODE FIELD value ===
['Lopez', 'Okoro']
['Peanut Butter']
=== 6. reading edge OBJECTS (edge has-fields) ===
PU-002 1
PU-003 1
=== 7. multi-hop FORWARD ===
['Peanut Butter', 'Oat Milk', 'Rice']
['peanuts', 'gluten']
```

### 4b. BACKWARD TRAVERSAL — the core Backshelf pattern

```jac
# one hop back: which Items does this RecallRecord flag?
flagged = [recall <-:FlaggedBy:<-];

# TWO HOPS BACK — the money query
affected = [recall <-:FlaggedBy:<- <-:Received:<-];

# backward + node filter
[recall <-:FlaggedBy:<- <-:Received:<-[?:Household, size >= 3]]

# backward untyped
[shelf_a <--]
```

Real output:

```
=== 8. BACKWARD traversal (the money query) ===
items flagged by recall: ['Peanut Butter']
--- one-liner: RecallRecord -> Households that received a flagged item ---
affected households: ['Lopez', 'Chen']
--- with edge-attribute detail (pickup codes) ---
Peanut Butter -> PU-001 qty 2
Peanut Butter -> PU-002 qty 1
--- backward with node filter (size >= 3) ---
['Lopez']
--- backward untyped (<--): who points at shelf_a ---
[Pantry(name='Eastside Pantry', city='Ann Arbor')]
=== 9. bidirectional <--> ===
5
```

---

## 5. THE ANSWER: RecallRecord → affected Households

### The exact query

```jac
affected = [recall <-:FlaggedBy:<- <-:Received:<-];
```

Verified output: `affected households: ['Lopez', 'Chen']`

### With confidence threshold on the FlaggedBy edge

```jac
hi = [rec <-:FlaggedBy:confidence >= 0.9:<- <-:Received:<-];
```

Verified output: `['Lopez', 'Chen']`

### With the per-household pickup detail (what a notification actually needs)

```jac
for itm in [rec <-:FlaggedBy:<-] {
    for e in [edge itm <-:Received:<-] {
        print(f"  {itm.sku}/{itm.lot} lot -> {e.pickup_code}");
    }
}
```

Verified output (`07_recall_fanout.jac`):

```
  PB-100/L77 lot -> PU-001
  PB-100/L77 lot -> PU-003
  PB-100/L78 lot -> PU-002
```

### CRITICAL: node reads dedupe, edge reads do not

`07_recall_fanout.jac` — Lopez received BOTH recalled lots (pb lot L77, pb2 lot L78), Chen received pb only:

```
=== raw two-hop backward (DUPLICATES) ===
['Lopez', 'Chen'] len: 2
```

There were **no** duplicates. Confirmed head-on in `08_dedup_semantics.jac` with two parallel `R` edges `a --> b`:

```
single-hop node read  [a ->:R:->] : ['b']
single-hop edge read  [edge ...]  : ['r1', 'r2']
two-hop node read [a ->:R:-> ->:S:->]: ['c']
diamond forward  : ['c', 'c2']
diamond BACKWARD : ['a']
backward edges   : ['p', 'q']
```

> **Node-reference reads (`[... -->]`, `[... ->:E:->]`, `[... <-:E:<-]`) return each distinct node ONCE regardless of how many edge paths reach it. `[edge ...]` returns every edge.**
>
> Practical consequence for Backshelf:
> - "Which households to notify?" → node read. Already deduped, no work needed.
> - "How many pickups are affected / what pickup codes?" → **must** use `[edge ...]`, and you will get one row per pickup.

A defensive dedupe idiom (still useful when you union results from several recalls):

```jac
ids: set[str] = set();
uniq: list[Household] = [];
for h in raw {
    k = jid(h);
    if k not in ids { ids.add(k); uniq.append(h); }
}
```

Verified: `['Lopez', 'Chen']`

---

## 6. Avoiding duplicates on rescan (get-or-create)

### GOTCHA: filter predicate name-shadowing (VERIFIED — checker warning is a FALSE ALARM at runtime)

```jac
def by_same_name(p: Pantry, code: str) -> list[Shelf] {
    return [p -->[?:Shelf, code == code]];     # param named same as node field
}
```

`jac check` output:

```
⚠ warning[W3040]: Filter comparison 'code == code' is always true — both sides resolve to the same node field [filter-compare-tautology]
```

But `jac run` (`04_filter_vars.jac`):

```
same-name param 'code': ['B2']
diff-name param 'wanted': ['B2']
local var in filter: ['C3']
literal in filter: ['A1']
two predicates: ['B2']
f-string built value: ['A1']
```

Runtime **does** bind LHS to the node field and RHS to the enclosing scope. The behaviour is correct but the checker cannot see it.

> **Backshelf rule: NEVER name a parameter/local the same as the node field you compare it to.** Use `wanted_code`, `target_sku`, etc. This removes the W3040 noise and keeps the intent unambiguous.

Verified working forms inside a filter predicate: literal, local variable, parameter, f-string expression, multiple comma-separated predicates.

### Idiomatic upsert

```jac
def find_shelf(p: Pantry, wanted: str) -> Shelf | None {
    hits = [p -->[?:Shelf, code == wanted]];
    if len(hits) > 0 { return hits[0]; }
    return None;
}

def upsert_shelf(p: Pantry, wanted: str) -> Shelf {
    hit = find_shelf(p, wanted);
    if hit is not None { return hit; }
    fresh = Shelf(code=wanted);
    p ++> fresh;
    return fresh;
}
```

Verified (`03_dedupe_delete.jac`, using the explicit-loop variant):

```
=== CORRECT upsert (explicit loop) ===
shelves: ['A1', 'B2']
x1 is x3 (deduped)? True | x1 is x2? False
```

### Edge existence check (avoid duplicate edges on rescan)

```jac
def stocks_edge_exists(s: Shelf, i: Item) -> bool {
    return len([edge s ->:Stocks:-> i]) > 0;
}
```

Verified:

```
=== edge existence check ===
before connect: False
after connect: True
edge count after guarded re-connect: 1
```

---

## 7. Deletion

```jac
# TYPED edge — the ONLY working form: query edge objects, del each
for e in [edge x1 ->:Stocks:-> it] { del e; }

# UNTYPED edge
p2 del --> x2;

# NODE — cascades to ALL its edges (in AND out). Capture jid BEFORE deleting.
gone_id = jid(x1);
del x1;
```

Verified output:

```
=== delete a TYPED edge (iterate + del) ===
after typed edge delete: False
=== delete an UNTYPED edge with del --> ===
before: ['A1', 'B2']
after : ['A1']
=== delete a NODE (cascades all edges) ===
removed jid: d65e2631 ... shelves left: []
```

### NEGATIVE: `del [a ->:E:-> b]` passes `jac check` and CRASHES at runtime

`12_neg_deledge.jac`:

```
$ jac check 12_neg_deledge.jac
12_neg_deledge.jac PASSED [100%]

$ jac run 12_neg_deledge.jac
✖ Error: error[E5043]: Bytecode compilation failed: expression which can't be assigned to in Del context
```

`a del-->:E: b;` is a parse error. **Only the `for e in [edge ...] { del e; }` loop works for typed edges.**

---

## 8. `root`, persistence-by-reachability, schema drift

### `root` is a builtin — no import, no declaration

```jac
root ++> pantry;
[root -->]                  # direct children
[root -->[?:Pantry]]        # typed children
jid(root)                   # '000000000000...' — root always has the zero jid
```

Verified: `root jid: 000000000000`

### Persistence across `jac run` (VERIFIED, `05_persist.jac`, three consecutive runs)

```
### RUN 1 ###
root children BEFORE: []
pantries reachable: []
created Eastside
root children AFTER: ['Pantry']
### RUN 2 ###
root children BEFORE: ['Pantry']
pantries reachable: ['Eastside']
Eastside already exists -> skipped create
root children AFTER: ['Pantry']
### RUN 3 ###
root children BEFORE: ['Pantry']
pantries reachable: ['Eastside']
Eastside already exists -> skipped create
root children AFTER: ['Pantry']
```

A node built but never attached (`Ghost(tag="never-attached")`) **never appears** in `[root -->]` and never persists. **Reachability from `root` is the persistence rule.** Attach every node the moment you create it.

Store layout — **the DB is PER ENTRY FILE**:

```
$ find .jac -type f
.jac/cache/05b.ed3e86f1.cpython-313.jir
.jac/cache/05_persist.9ff1f418.cpython-313.jir
.jac/data/05b.db
.jac/data/05_persist.db
```

> Consequence: `jac run main.jac` and `jac run seed.jac` get **different roots and different graphs**. Backshelf must funnel ALL graph work through ONE entry file (or a server), otherwise the seeder writes to a DB the app never reads.

### Schema drift behaviour (VERIFIED)

Additive change (new field with a default) — best-effort load, works:

```
INFO - SqliteMemory: schema drift on __main__.Pantry (stored fingerprint=8f649b2ad32e2fd8, current=fb81afefefcedcca, anchor id=...); attempting best-effort load.
pantry: Eastside midwest
```

Breaking change (rename `name` → `title`, no default) — **hard crash**:

```
INFO - SqliteMemory: schema drift on __main__.Pantry ...; attempting best-effort load.
INFO - Serializer: preserved unknown fields in attic on __main__.Pantry: ['name']
WARNING - Serializer: __main__.Pantry.title: required field missing from stored data and no default available; attribute left unset.
✖ Error: Error: 'Pantry' object has no attribute 'title'
```

Recovery (verified to work immediately):

```bash
rm -f .jac/data/<entryfile>.db      # nuke one graph
rm -rf .jac                         # nuke everything (no jac.toml needed)
jac clean --all                     # only if a jac.toml exists
```

> **Hackathon survival rule: any time a node/edge `has` field is renamed, retyped, or added without a default, `rm -rf .jac` before the next run.** Add a `make reset` / shell alias on day one. Symptoms of a stale graph: `'X' object has no attribute 'y'`, or `NodeAnchor ... is not a valid reference!`.

### find-by-id: `jid` / `jobj` (VERIFIED)

```jac
rid = jid(rec);                 # -> 'f2b5fe06545f4971bd604e20b9571102'
back = jobj(rid);               # -> any
if isinstance(back, RecallRecord) { print(back.recall_id); }
```

```
recall jid: f2b5fe06545f4971bd604e20b9571102
jobj type: RecallRecord
recovered recall_id: FDA-2026-441
```

`jobj()` returns `any` — `isinstance`-narrow it (or `as`-cast) before it flows into a typed parameter.

---

## 9. Bulk update: assign comprehension (VERIFIED)

```jac
[rec <-:FlaggedBy:<-](=recalled=True);          # mark every flagged Item
uniq(=notified=True);                            # works on a plain list[Household] too
```

```
items recalled flags: [('PB-100', 'L77', True), ('PB-100', 'L78', True), ('RC-300', '', False)]
household notified: [('Lopez', True), ('Chen', True)]
```

Multiple assignments in one go: `items(=status="done", count=0);`

---

## 10. Inheritance on nodes and edges (VERIFIED, `09_obj_inherit.jac`)

```jac
node Perishable       { has name: str = "?"; has days_left: int = 7; }
node Dairy(Perishable){ has fat_pct: float = 3.5; }
node Produce(Perishable){ has organic: bool = False; }

edge Holds: Pantry --> Perishable { has bin: str = "b0"; }
edge ColdHolds(Holds)             { has temp_c: float = 4.0; }   # inherits endpoints
```

```
=== polymorphic node filter [?:Perishable] matches subclasses ===
['Milk', 'Kale', 'Bread']
only Dairy : ['Milk']
only Produce: ['Kale']
=== edge subtype: [->:Holds:->] matches ColdHolds too ===
Holds     : ['Milk', 'Kale', 'Bread']
ColdHolds : ['Milk']
=== inherited field predicate ===
expiring<=3: ['Kale', 'Bread']
=== edge attrs across subtype ===
  ColdHolds C1
  Holds A2
  Holds A3
=== BACKWARD from a subclass node to its Pantry ===
['Eastside']
['Eastside']
```

- `[?:Base]` matches subclasses. `->:BaseEdge:->` matches subtype edges.
- **A subtype edge inherits its base's declared endpoints** — do not re-declare them (`E2027` otherwise).
- Predicates on inherited fields work.
- Remember the parent-default trap from §2: `Perishable` gives everything a default, so `Dairy`/`Produce` must too.

---

## 11. `jac check` semantics — read this before you panic

- `jac check` prints warnings under a scary `=================================== FAILURES ===================================` banner but still reports `PASSED [100%]`. **Verified exit code with W1051 warnings present: `0`.** Warnings are not failures.
- **W1051 "Expression type could not be resolved (Unknown)" fires on EVERY filter predicate expression** (`->:Stocks:placed_on == "...":->`, `[?:Household, size > 2]`, `[?qty > 10]`). This is checker noise on a correct construct — the runtime results were all correct. Do not chase it. Do not "fix" it with `any`.
- **W2001 "Name 'qty' may be undefined"** also fires on bare node-field predicates like `[?qty > 10]`. Same story: noise.
- W3040 tautology on same-named param — see §6, real behaviour is correct, but rename anyway.
- Errors that are REAL and must be fixed: `E2004` (has ordering), `E0030` (`;` after brace import), `E0001` (braces on `case`), `E1053`/`E1001`/`E1002` (`any`/Unknown crossing a typed boundary), `E1032` (Unknown attribute access).
- Things `jac check` will NOT catch — verified runtime-only failures: parent-default dataclass crash (§2), `del [a ->:E:-> b]` E5043 (§7), schema drift (§8), backtick-escaped keyword in `has`.

---

## 12. Type-system notes that matter here (guide `jac-types`)

- Use `T | None`, **not** `Optional[T]`. Lowercase builtins `list[X]`, `dict[K,V]`, `set[X]`.
- Lowercase `any` is the gradual type; `Any` from `typing` warns W1104/W2001.
- Ambient (no import): `Callable`, `Protocol`, `Literal`, `Iterable`, `Sequence`, `Mapping`, `TypeVar`, `Generic`.
- Every `def` param needs a type (E0052); a value-returning `def` needs a return type (E1003). Do NOT write `-> None` (W3037).
- `value as Type` is the escape hatch — unchecked, type-erased. Use it to land `jobj()` / walker-report / `json.loads` results into a concrete type.
- Do NOT reach for `any` to silence an error; it just relocates the failure to the next typed boundary.
- `-> Self` parses but resolves to Unknown (E1032 downstream) — return the concrete archetype name from builders.

---

## 13. Known limitation that changes our design

From `jac-node-edge-patterns`, stated as a documented Known Limitation:

> **Edge abilities are a silent no-op.** `can x with SomeWalker entry` inside an `edge` compiles cleanly and never fires.

NOT EXECUTED (I did not spike a walker — that is the walker-patterns area) but it is stated flatly in the version-matched guide. **Do not put recall/confidence/notification logic in an edge ability.** Put it in the walker's node abilities and read edge data with `[edge ...]`.

---

## 14. Copy-paste Backshelf cheat card

```jac
# CREATE + ATTACH (always attach, or it does not persist)
p = Pantry(name="Eastside"); root ++> p;
s = Shelf(code="A1");        p ++> s;
i = Item(sku="PB-100", name="Peanut Butter", lot="L77");
s +>:Stocks(placed_on="2026-07-01"):+> i;
h = Household(family="Lopez"); p ++> h;
h +>:Received(pickup_code="PU-001", qty=2):+> i;
r = RecallRecord(recall_id="FDA-2026-441"); root ++> r;
i +>:FlaggedBy(confidence=0.95, method="lot-match"):+> r;

# READ
[p -->[?:Shelf]]                                   # children by type
[s ->:Stocks:->]                                   # by edge type
[s ->:Stocks:placed_on == "2026-07-01":->]         # by edge attribute
[p -->[?:Household, size > 2]]                     # by node field
[edge h ->:Received:->]                            # edge objects (pickup_code)

# BACKWARD — the Backshelf core
[r <-:FlaggedBy:<-]                                # items this recall flags
[r <-:FlaggedBy:<- <-:Received:<-]                 # HOUSEHOLDS TO NOTIFY (deduped)
[r <-:FlaggedBy:confidence >= 0.9:<- <-:Received:<-]   # high-confidence only

# EXISTS / UPSERT
len([edge s ->:Stocks:-> i]) > 0
hits = [p -->[?:Shelf, code == wanted_code]];      # NOTE: param name != field name

# UPDATE / DELETE
[r <-:FlaggedBy:<-](=recalled=True);
for e in [edge s ->:Stocks:-> i] { del e; }        # typed edge
p del --> s;                                        # untyped edge
gone = jid(n); del n;                               # node (cascades)

# ID
jid(x); jobj(id_str);   # jobj returns `any` -> isinstance/as-cast
```

## 15. Spike index

| File | Proves |
|---|---|
| `01_minimal.jac` | module shape, glob, entry, obj, f-string, ternary |
| `02_schema.jac` | full Backshelf schema, all traversal forms, backward multi-hop |
| `03_dedupe_delete.jac` | postinit, upsert, edge-exists, typed/untyped/node delete, root reachability |
| `04_filter_vars.jac` | how filter predicates bind names (W3040 false alarm) |
| `05_persist.jac` / `05b.jac` | persistence across runs, per-file DB |
| `06_schemachange.jac` | additive drift OK, breaking drift crashes, `rm .jac/data/*.db` recovery |
| `07_recall_fanout.jac` | recall fan-out, dedupe, jid/jobj, assign comprehension, printgraph |
| `08_dedup_semantics.jac` | node reads dedupe / edge reads do not (parallel edges + diamond) |
| `09_obj_inherit.jac` | obj vs node, node + edge inheritance, polymorphic filters |
| `10_neg_ordering.jac` | E2004 has-ordering |
| `11_neg_parentdefault.jac` | parent-default runtime crash that `check` misses |
| `12_neg_deledge.jac` | E5043 on `del [a ->:E:-> b]` |
