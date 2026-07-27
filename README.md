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

## The Gemini key — paste it into the running app

Open the app, put the key in the **byLLM panel** in the left rail, and press save. It
takes effect on the next call — no restart, no redeploy, no shell. Press clear to go
back to MockLLM.

That works on the deployed URL too, which is the point: nothing about supplying a key
requires access to the host.

Two other sources still work, in this resolution order:

| Order | Source | Notes |
|---|---|---|
| 1 | key saved in the app | stored on an `LlmConfig` node, survives restarts |
| 2 | `GEMINI_API_KEY` env var | `.env` locally, a service variable on Railway |
| 3 | neither | `DemoLLM`, a MockLLM returning canned structured output |

The router is `LlmRouter` at `llm.sv.jac:566`; resolution is `_resolve_llm` at
`llm.sv.jac:536`, cached behind a sha256 fingerprint of the key so a saved key
invalidates the cache without the raw value ever being compared or logged.

**A bad key degrades to MockLLM rather than failing the scan.** A walker never 500s
because the key is wrong — the error is redacted and surfaced as `last_error` on
`LlmStatus`. That means `using_mock_llm: false` can coexist with a mock-sourced
answer; `last_error` is the signal to check.

> **Security note.** The walker that sets the key is `:pub` like everything else here,
> so anyone who can reach the URL can set or clear it. That is an accepted tradeoff for
> a demo deployment, not an oversight. The key is never returned, logged, or written to
> disk — only a masked `AIza...tail` form. Put the walker behind auth before this is
> anything but a demo.

MockLLM proves every code path executes, but the label read is not real — it returns
fixed values regardless of the photo, which is why `scripts/eval.sh` refuses to print
an accuracy number in that mode. Get a key at
[aistudio.google.com/apikey](https://aistudio.google.com/apikey).

> **Deployed, `.env` does not apply.** In the Dockerfile the venv is `/opt/venv` and
> the code is `/app`, so `load_dotenv()` walks up from `/opt/venv` and never reaches
> `/app/.env` — and `.env` is gitignored and dockerignored, so it is not in the image
> at all. On Railway set `GEMINI_API_KEY` in the service Variables tab instead and
> redeploy. Nothing in the code changes; `os.getenv` finds it either way.

---

## Seeding the demo

**The graph starts empty.** Persistence is root-reachability backed by SQLite in
`.jac/data/`, which is gitignored — a fresh clone has no pantry, no households and no
recall records, so `RecallSweep` would traverse backwards and find nothing.

```bash
./scripts/setup.sh          # venv + deps + npm, from scratch
./scripts/demo.sh --reset   # starts a server, seeds everything, replays the demo
```

`SeedPantry` and `SeedDemo` are both idempotent — running them twice will not
duplicate nodes, so `./scripts/demo.sh` on its own is safe to re-run. Use `--reset`
before demoing anyway: without it every run leaves another scanned can on the shelf
and the listings get noisy.

> **If you redeploy, you must re-seed.** The SQLite file lives in the container's
> filesystem and is wiped on every deploy. Seed *after* the final deploy, then don't
> redeploy before demoing.

---

## Where Jac runs

Everything below is Jac. There is no database layer, no hand-written REST route, and
no prompt string anywhere in the codebase.

**If you read one thing, read `sweep.sv.jac:960`.** That single `visit` is the
backward traversal from a recalled can to the households holding it, and it is the
reason this project is written in Jac.

### The graph

| What | Where | Notes |
|---|---|---|
| Node types | `graph.sv.jac:56–110` | `Pantry`, `Shelf`, `Allergen`, `Household`, `RecallFeed`, `RecallRecord`, `Item` |
| Typed edges | `graph.sv.jac:116–135` | `Stocks`, `Contains`, `FlaggedBy`, `Avoids`, `Received`, `Lists` — four carry attributes |
| View projections | `graph.sv.jac:141–225` | walkers report these objects, never raw nodes |
| Graph helpers | `graph.sv.jac:241–350` | lookups by reachability from `root`; no query language, no ORM |

### The walkers — each one is an endpoint

| Walker | Where | Notes |
|---|---|---|
| `SeedPantry` | `graph.sv.jac:356–408` | `walker:pub`, idempotent |
| `SeedDemo` | `demo.sv.jac:125–201` | Maria's distribution history |
| `IntakeScan` | `intake.sv.jac:636–935` | abilities at `675` Root, `686` Shelf, `792` RecallFeed, `804` RecallRecord, `832` RecallFeed exit |
| `ClearItem` | `intake.sv.jac:941–1061` | **refusal gate at `992–1025`** — a `CONFIRMED` `FlaggedBy` edge cannot be cleared |
| `MatchNeeds` | `client_search.sv.jac:134–304` | `walker:pub`; abilities at `168`, `188`, `208`, `222`, `261` |
| **`RecallSweep`** | `sweep.sv.jac:725–1043` | **the backward traversal is `sweep.sv.jac:960`** |

`RecallSweep`'s traversal, in the order the abilities fire:

| Line | Ability | Direction |
|---|---|---|
| `sweep.sv.jac:788` | `enter_root with Root entry` | spawn |
| `sweep.sv.jac:849` | `sync with RecallFeed entry` → `visit [here <--]` | **backward** to the Pantry |
| `sweep.sv.jac:852` | `span_pantry with Pantry entry` | forward to Shelves and Households |
| `sweep.sv.jac:858` | `scan_shelf with Shelf entry` → `visit [here ->:Stocks:->]` | forward, typed |
| `sweep.sv.jac:864` | `check_item with Item entry` | classifies, writes `FlaggedBy` |
| **`sweep.sv.jac:960`** | `visit [here <-:Received:<-]` | **backward, to the households** |
| `sweep.sv.jac:964` | `notify with Household entry` | builds the notice |
| `sweep.sv.jac:1018` | `finish with RecallFeed exit` | assembles the report |

### byLLM — signature and `sem` are the prompt

| Function | Where | Notes |
|---|---|---|
| `extract_label` | `llm.sv.jac:139–155` | `(photo: Image, hint: str) -> LabelRead by llm(temperature=0.0)` |
| `shelf_life_verdict` | `llm.sv.jac:198–278` | the §4 shelf-life table lives in `sem` at `205–278`; this is the fix to Flaw 1 |
| `explain_for_client` | `llm.sv.jac:309–356` | plain language, any language, "the label lists" framing |
| `resolve_constraints` | `llm.sv.jac:362–392` | free text → allergen tag names |
| Model switch | `llm.sv.jac:480–491` | Gemini ⇄ MockLLM on one env var |
| Recall tiering | `sweep.sv.jac:570–612` | `_classify` — the single source of the CONFIRMED/POSSIBLE/WEAK decision |
| Lot-code parsing | `sweep.sv.jac:426–467` | `_lot_candidates`, which is what makes matching lot-aware instead of brand-only |

Every `sem` block is the prompt. There is no f-string, no `.format`, and no
hand-assembled message list anywhere in this repo.

### The client

| What | Where |
|---|---|
| Client UI | `frontend.cl.jac`, `frontend.impl.jac`, `components/` |
| Entry point + `cl { }` block | `main.jac` |

Walkers auto-generate `POST /walker/<Name>`. `GET /walkers` lists them.
Pass `_jac_spawn_node` in the body to spawn a walker on a specific node.

---

## Demo

One command replays the whole four-minute demo against a live server:

```bash
./scripts/demo.sh --reset
```

`--reset` wipes `.jac/data/main.db*`, starts `jac start main.jac` on port 8390,
waits for walker registration and then walks every beat in order: seed → scan →
past-date item routed to REVIEW → clear → client search in Spanish → **`RecallSweep`
naming the pickup codes** → the refusal gate → the same client search again, now
filtered by a graph that changed underneath it.

It takes about 10 seconds end to end on the MockLLM fallback and is safe to re-run
while rehearsing. Without `--reset` it replays against whatever server is already
up (about 2 seconds), which is what you want mid-rehearsal.

```bash
./scripts/demo.sh                                   # against a running local server
./scripts/demo.sh --base https://backshelf-production.up.railway.app
./scripts/demo.sh --reset --no-live                 # skip the openFDA network call
BACKSHELF_PHOTO=$(base64 -i can.jpg | tr -d '\n') ./scripts/demo.sh   # scan a real photo
```

The money shot, verbatim from a real run:

```
  === HOUSEHOLDS TO NOTIFY - reached by walking Received BACKWARDS ===
   pickup code 4471  [CONFIRMED]  lang=en  contact on file=True  picked up 2026-07-18
   pickup code 8830  [CONFIRMED]  lang=es  contact on file=False picked up 2026-07-18
   pickup code 2210  [POSSIBLE]   lang=en  contact on file=False picked up 2026-07-19

  === TRAVERSAL ===
   depth 0  >>> spawn    RecallFeed  openFDA feed
   depth 1  <<< backward Pantry      Backshelf Community Pantry
   depth 2  >>> forward  Shelf       canned goods
   depth 3  >>> forward  Item        FIRST STREET Dark Chocolate Raisins 9 oz
   depth 4  <<< backward Household   pickup code 4471
   depth 4  <<< backward Household   pickup code 8830
   depth 4  <<< backward Household   pickup code 2210
```

### Real-photo eval

```bash
./scripts/eval.sh <dir-of-label-photos>
./scripts/eval.sh assets/labels --truth assets/labels/truth.csv
```

Every photo goes through `IntakeScan` exactly as the phone client sends it. The
summary reports the §4 routing distribution, how many past-date items were *not*
discarded, and self-reported extraction confidence.

**It will not print an accuracy number it cannot justify.** On the MockLLM fallback
the same canned label comes back for every photo, so the script says so and reports
only the routing distribution. With a Gemini key it lists the per-photo reads, and
scores per-field accuracy only if you supply a `--truth` CSV
(`filename,brand,product,date_value,date_type,lot_code`). Reporting accuracy
without ground truth would be guessing, so it refuses to.

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
