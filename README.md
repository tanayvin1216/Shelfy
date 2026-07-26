# Backshelf

**A food pantry intake and recall-propagation system, built in Jac.**

Roughly 60,000 food pantries in the US run on volunteers and clipboards. Donations
arrive unsorted, unbarcoded and undated. A grocery shopper gets recall alerts and
clear labels for free; a family picking up food from a pantry shelf gets neither.

**The gap this targets:** a recall announced on Tuesday affects the can that went out
the door on Saturday. Food banks brief volunteers and post notices, which protects
food still in the building. Nobody can tell a *specific household* that the jar in
their cupboard is now recalled — because nobody keeps a graph connecting recalls to
items to the households that received them.

Backshelf keeps that graph. `RecallSweep` walks it **backwards**, from a new FDA recall
to the pickup codes of the households that took the item home.

---

## Try it without installing anything

The deployed app is the zero-setup path — no clone, no key, no node, no Python:

> ### **https://backshelf-production.up.railway.app**

One `jac start` process serves the REST API and the client bundle. Try it directly:

```bash
curl https://backshelf-production.up.railway.app/walkers
curl -X POST https://backshelf-production.up.railway.app/walker/RecallSweep \
     -H 'Content-Type: application/json' -d '{"live":false,"limit":100}'
```

That last call traverses the graph backward from a live FDA recall to the pickup codes
of the households that took the item home. No other pantry system does that.

Everything below is only needed if you want to run it locally.

---

## Quickstart

```bash
git clone https://github.com/tanayvin1216/Shelfy.git && cd Shelfy

python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt   # exact pins matter — see the trap below
./.venv/bin/jac install                       # npm deps for the client bundle (needs node)

cp .env.example .env                          # optional: add your Gemini key
./.venv/bin/jac start main.jac                # http://localhost:8000
```

Then seed demo state (see [Seeding](#seeding-the-demo) — the graph starts empty).

Requirements: **Python ≥ 3.12** and **node ≥ 20**. Node is not optional — the `.cl.jac`
client is bundled by vite. If you only want the API and no UI, `jac start main.jac --no_client`.

### The version trap — read this before installing anything

**Do not `pip install jaclang byllm jac-cloud`.** That is the obvious command and it
produces a `jac` binary that will not start:

```
ModuleNotFoundError: No module named 'byllm.plugin'
```

`jac-cloud` hard-pins `jaclang==0.9.0`. byllm ships its plugin as `plugin.jac`, and
jaclang 0.9.0 loads plugin entrypoints *before* registering the `.jac` import hook, so
it cannot import its own plugin format. **jac-cloud is not needed at all** — `jac start`
in jaclang 0.16.7 serves the REST API natively. Use `requirements.txt` and nothing else.

### Working on the Jac source

Your training data and most of the web describe an older Jac. The compiler ships
version-matched reference guides — treat these as authoritative:

```bash
./.venv/bin/jac guide                       # list all ~25 guides
./.venv/bin/jac guide jac-walker-patterns   # traversal
./.venv/bin/jac guide jac-by-llm            # by llm(), sem, images, MockLLM
./.venv/bin/jac guide jac-sv-endpoints      # /walker/<Name>, walker:pub
./.venv/bin/jac check <file>                # diagnostics link to the relevant guide
```

`docs/spikes/` holds ~94 small `.jac` programs written while learning the language.
They all actually ran. `docs/spikes/walkers/05_recall_sweep.jac` is the backward
traversal in miniature and is the best single file to read first.

---

## Without a Gemini key

The app runs fine without one. `llm.sv.jac` switches on `GEMINI_API_KEY`:

- **key set** → real Gemini through byLLM, real label extraction from photos
- **key unset** → `DemoLLM`, a MockLLM subclass that returns canned structured output

MockLLM proves every code path executes, but the label scan is not real — it returns
fixed values regardless of the photo. Get a key at
[aistudio.google.com/apikey](https://aistudio.google.com/apikey) and put it in `.env`.

---

## Seeding the demo

**The graph starts empty.** Persistence is root-reachability backed by SQLite in
`.jac/data/`, which is gitignored — a fresh clone has no pantry, no households and no
recall records, so `RecallSweep` would traverse backwards and find nothing.

```bash
./scripts/setup.sh          # venv + deps + npm, from scratch
./scripts/demo.sh           # seeds pantry, shelves, allergens, demo households + items
```

`SeedPantry` is idempotent — running it twice will not duplicate nodes.

> **If you redeploy, you must re-seed.** The SQLite file lives in the container's
> filesystem and is wiped on every deploy. Seed *after* the final deploy, then don't
> redeploy before demoing.

---

## Where Jac runs

Everything below is Jac. There is no database layer, no hand-written REST route, and
no prompt string anywhere in the codebase.

| What | File | Notes |
|---|---|---|
| Graph schema | `graph.sv.jac:56–135` | 7 node types, 6 typed edge types carrying attributes |
| Idempotent seed | `graph.sv.jac:356` | `walker:pub SeedPantry` |
| View projections | `graph.sv.jac:141–226` | UI-renderable objects, not raw nodes |
| Label extraction | `llm.sv.jac:134` | `def extract_label(photo: Image, ...) -> LabelRead by llm()` |
| Constraint parsing | `llm.sv.jac:335` | free text → allergen names, `by llm()` |
| Model switch | `llm.sv.jac:446–468` | Gemini ⇄ MockLLM on one env var |
| Intake + clearance | `intake.sv.jac` | `IntakeScan`, `ClearItem` |
| Client search | `client_search.sv.jac` | `MatchNeeds`, `walker:pub` |
| **Backward recall sweep** | `sweep.sv.jac` | `RecallSweep` — the traversal the project exists for |
| Client UI | `frontend.cl.jac`, `components/` | `.cl.jac` components, JSX + reactive `has` state |

Walkers auto-generate `POST /walker/<Name>`. `GET /walkers` lists them.
Pass `_jac_spawn_node` in the body to spawn a walker on a specific node.

---

## Rebuild note

This is a rebuild of my own earlier prototype, Shelfy (React Native + Gemini + SQLite),
which scanned donations at intake for recalls, expiry and allergens. v1 shipped, then
showed three design flaws:

1. **"expired → discard" was backwards.** Date labels are not federally regulated and
   are not safety dates. v1 destroyed edible food at organizations that are chronically
   supply-constrained. v2 routes past-date shelf-stable goods to REVIEW with shelf-life
   guidance, never to discard.
2. **Brand-only recall matching.** Recalls are lot- and date-code specific; matching on
   brand alone flags every jar of a brand in the building. v2 is lot-aware with explicit
   CONFIRMED / POSSIBLE / WEAK confidence tiers, and never auto-discards below CONFIRMED.
3. **Intake-time checking only.** That protects nothing already distributed, which is
   where the real harm is. v2 adds the retroactive `RecallSweep`.

Fixing those three is most of the value of v2.

---

## Stack

- **jaclang 0.16.7** — nodes, edges, walkers, `by llm()`, root-reachability persistence
- **byllm 0.6.19** — label extraction, shelf-life reasoning, client explanations
- **openFDA food enforcement API** — active recall records, with a cached snapshot at
  `data/openfda-snapshot.json` so a bad network never blocks intake

Note: the openFDA `status` field value is `"Ongoing"`. `"On-Going"` returns zero results.
