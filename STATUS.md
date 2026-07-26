# Backshelf — build status

Paused 12:20 PM, Jul 26 2026. Resume by reading this file top to bottom.

## Where we are

Local pipeline is **green**: `jac start main.jac` serves the scaffold, walkers answer
on `POST /walker/<Name>`, a node round-trips through the graph, client HTML renders.
That was the 12:30 milestone (§10) — met early.

Not yet written: the real graph schema, the four walkers, the byLLM functions, the
three client screens, the deploy.

## Stack — corrected from the spec

The spec assumes the jac-cloud era. That path is dead:

- `jac-cloud` hard-pins `jaclang==0.9.0`; byllm 0.6.19 ships its plugin as `plugin.jac`,
  which 0.9.0 cannot import (it loads plugin entrypoints *before* registering the `.jac`
  import hook). `jac` will not even start. Do not reinstall jac-cloud.
- **We are on `jaclang==0.16.7` + `byllm==0.6.19` + `jac-client`.** `jac start` serves the
  REST API natively — jac-cloud is not needed and must not be added back.

```
python3 -m venv .venv
./.venv/bin/pip install jaclang==0.16.7 byllm==0.6.19 jac-client
```

### The authoritative Jac reference is local, not the web

`jac guide` lists ~25 version-matched guides shipped inside the compiler.
**docs.jaseci.org describes the old jac-cloud era and is wrong for us.**

```
.venv/bin/jac guide                      # list all
.venv/bin/jac guide jac-walker-patterns  # etc.
.venv/bin/jac guide --search <keyword>
```

Most relevant: `jac-core-cheatsheet`, `jac-node-edge-patterns`, `jac-walker-patterns`,
`jac-by-llm`, `jac-sv-endpoints`, `jac-sv-multi-user`, `jac-cl-components`, `jac-sv-deploy`.

Validate with `jac check <file>` — its diagnostics link to the guide that explains the error.

## Verified facts (executed, not assumed)

**API shape.** `POST /walker/<Name>`, body = the walker's `has` fields as JSON.
Response envelope:
```json
{"ok": true, "data": {"result": {...}, "reports": [...]}, "error": null, "meta": {...}}
```
`GET /walkers` lists them; `GET /walker/<Name>` returns its field schema.

**Spawning on a specific node**: body field `_jac_spawn_node` (a node id, defaults to
`root`). That is how `ClearItem` and `MatchNeeds` will target an Item / Household.
In Jac, `jid(node)` gets that id and `jobj(id)` resolves it back.

**Shared graph — solved.** `:pub` walkers operate on the **shared global `root`**;
`:priv` gives each logged-in user an isolated root. So the pantry graph is shared across
anonymous callers with zero auth work. `walker:pub` is the syntax.

Caveat seen: for ~30s after `jac start`, walker POSTs return `{"error":"Unauthorized"}`
while registration finishes. Wait for `Server ready` before curling. It is not an auth bug.

**Backward traversal** (`RecallSweep`, the money shot) — proven in
`docs/spikes/walkers/05_recall_sweep.jac`, which runs:
```jac
edge Issued: Lot --> Household { has qty: int = 1; }

lot +>:Issued(qty=2):+> hh;         # create edge with attributes
[here ->:Issued:->]                 # forward, typed
visit [here <--];                   # BACKWARD — everything pointing at this node
```
Two guards that sweep **needs**, both already worked out in that spike:
1. a `resolved: bool` flag on the lookup-base walker — `root` gets re-entered when the
   backward sweep walks back up to it, and refires the base ability without this;
2. a `seen` list of `jid`s — a diamond graph (one Item on two shipments) double-counts otherwise.

**byLLM** — proven in `docs/spikes/byllm/s05_image.jac`:
```jac
import from byllm.lib { Image, MockLLM }

obj LabelRead { has product_name: str; has date_type: str; }
sem LabelRead.product_name = "Product name exactly as printed.";

def read_label(photo: Image, hint: str) -> LabelRead by llm(temperature=0.0);
sem read_label = "Transcribe the food label...";
sem read_label.photo = "A phone photo taken at the intake desk.";
```
- `Image("path.png")`, `Image(raw_bytes)` and `Image("https://…")` all work; exposes
  `.mime_type` and `.url`.
- **MockLLM unblocks all development with no API key**:
  `glob llm = MockLLM(model_name="mockllm", config={"verbose": True, "show_params": True, "outputs": [ …typed objs… ]});`
  `show_params` prints the assembled prompt — use it to check that `sem` text is landing.

## Spec bugs found

1. **§8 openFDA `status:"On-Going"` returns zero records.** The live field value is
   `"Ongoing"`. Cached snapshot at `data/openfda-snapshot.json`: 100 ongoing recalls
   (41 Class I), fetched 12:00 today, real lot codes in `code_info`.
2. **§9's `.cl.jac` fallback is moot** — the Jac-native frontend is confirmed GO.
   `jac create --kind fullstack` generates `main.jac` + `endpoints.sv.jac` +
   `frontend.cl.jac` + `components/`, JSX with reactive `has` state, and `sv import`
   giving the client typed access to server walkers. Do not trigger the §9 fallback.

## Demo recall candidates (from the live snapshot)

Best fit for the Maria story — Class I, undeclared **peanut**, clean single lot code,
and a shelf-stable item a pantry would actually hand out:

- `H-1125-2026` — Western Mixers, *FIRST STREET Dark Chocolate Raisins 9oz*,
  "Undeclared peanuts.", `Lot: 260562 BB: 022527`
- `H-1150-2026` — Lehi Valley, *High Valley Orchard Chocolate Covered Raisins 15oz*,
  "Undeclared Peanut.", `Lot # 0160933 Best by Jan 23, 2027`
- `H-1137-2026` — NARA ORGANICS *Infant Formula*, C. botulinum — use this one to demo the
  §4 rule that infant formula is the one category that **does** discard.

## Research artifacts

`docs/spikes/` — 94 executed `.jac` files from the research fan-out. Highest value:
- `walkers/05_recall_sweep.jac` — backward sweep, guards, structured report
- `walkers/proj_final/` — multi-file layout with `impl/walkers.impl.jac`
- `byllm/s05_image.jac`, `s02_shelf_verdict.jac`, `s07_structured.jac`, `s06_tools_react.jac`
- `core-graph/02_schema.jac`, `07_recall_fanout.jac`, `03_dedupe_delete.jac`
- `server/shared_app/main.sv.jac` — shared-root pattern
- `client/backshelf_rt/` — a 3-page client (IntakeForm / ShelfList / RecallSweep) with routing

The recon workflow was stopped mid-flight at the pause, so `docs/jac-cheatsheet.md` and
`docs/ARCHITECTURE.md` were never written. The spikes are the surviving evidence and they
are the more useful artifact anyway — they all ran.

## Next steps, in order

1. `cp .env.example .env` and put the **Gemini** key in `GEMINI_API_KEY` (user is fetching it).
   Until then everything below is buildable against MockLLM.
2. Graph schema per §5 in a `graph.jac` — nodes, typed edges with attributes, seed the
   FDA big-9 Allergen nodes plus the dietary tags.
3. `IntakeScan` + `extract_label` + `shelf_life_verdict` (MockLLM first, real key after).
   The §4 shelf-life table goes in the `sem` annotation, not a prompt string.
4. `ClearItem` — the CONFIRMED-recall refusal gate, enforced in the walker.
5. `MatchNeeds` (`walker:pub`) + `explain_for_client` + `resolve_constraints`.
6. `RecallSweep` — port `docs/spikes/walkers/05_recall_sweep.jac` onto the real schema.
7. Three client screens, then deploy.

## Deploy — still unknown, decide early

`jac start` binds a port; Railway CLI is **not** installed locally, `vercel` **is**.
Unresolved: whether the client bundle can be hosted on Vercel separately from the backend,
and how the client is pointed at a remote backend URL. Read `jac guide jac-sv-deploy` and
`jac guide jac-cl-components` first thing. Do not leave this past 4:00 PM.
