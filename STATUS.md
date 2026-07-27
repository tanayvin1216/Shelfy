# Backshelf — build status

**Built.** All four spec walkers plus two seeders run end to end, the §12 demo replays
in one command, and the whole thing is deployed. Read this file for environment facts
and known rough edges; read `README.md` for how to run it.

## Where we are

| §11 definition of done | State |
|---|---|
| Scan an item → verdict in under 10s | done — whole demo is ~10s on MockLLM |
| Past-date shelf-stable → REVIEW with shelf-life guidance | done — `review`, 847 days past code, "2-5 years past code" |
| Brand-only recall match shows lot codes, does not discard | done — WEAK tier, item stays available |
| `ClearItem` refuses on CONFIRMED | done — refusal enforced at `intake.sv.jac:992` |
| Free-text client search → filtered shelf, plain language | done — `MatchNeeds` |
| Client output in a second language | done — Spanish in the demo |
| **`RecallSweep` names the pickup codes** | **done — 4471, 8830, 2210** |
| Railway URL loads | done — https://backshelf-production.up.railway.app |
| README "Where Jac runs" with file:line | done — verified line numbers, not invented |

## Stack — do not "fix" this

- **`jaclang==0.16.7` + `byllm==0.6.19` + `jac-client`.** `jac start` serves the REST
  API natively.
- **Never install `jac-cloud`.** It hard-pins `jaclang==0.9.0`, which loads plugin
  entrypoints before registering the `.jac` import hook and so cannot import byllm's
  `plugin.jac`. The `jac` binary will not start at all.
- The authoritative Jac reference is **local**: `./.venv/bin/jac guide <name>`,
  `jac guide --search <kw>`. docs.jaseci.org describes the jac-cloud era and is wrong
  for this version.
- `jac check <file>` must pass on every file. Diagnostics link to the relevant guide.

## The Gemini key — settled, verified by execution

**One place: `.env` at the repo root. One command: `jac start main.jac`.** No export.

`jac start` reads `.env` by itself. byLLM imports litellm; litellm calls `load_dotenv()`
at import; that search walks up from `.venv/lib/python3.13/site-packages/litellm` and
the repo root is on the path (confirmed with `dotenv.main._walk_to_root`).

Proven both directions:

- `.env` present with a dummy key, `GEMINI_API_KEY` absent from the shell →
  `IntakeScan` reached `generativelanguage.googleapis.com` and returned
  `litellm.AuthenticationError: GeminiException — API key not valid`. The switch took
  the Gemini branch.
- `.env` deleted → same call returned `using_mock_llm: true`, `verdict: review`.

The switch is `_select_model` at `llm.sv.jac:480–491`. The model is chosen **once, at
import** — restart the server after adding the key.

> **This works locally only because `.venv` sits inside the repo.** In the Dockerfile
> the venv is `/opt/venv` and the code is `/app`, so `load_dotenv()` never reaches
> `/app/.env`; `.env` is also gitignored and dockerignored. On Railway set
> `GEMINI_API_KEY` as a service variable and redeploy.

## Verified environment facts

**API shape.** `POST /walker/<Name>`, body = the walker's `has` fields as JSON.

```json
{"ok": true, "data": {"result": {...}, "reports": [...]}, "error": null, "meta": {...}}
```

`GET /walkers` lists them; `GET /walker/<Name>` returns its field schema.

**A walker that raises still returns HTTP 200 with `"ok": true`.** The traceback is at
`data.error` and `data.reports` is absent. Checking only `ok` will silently swallow a
crashed walker — `scripts/demo.sh` checks `data.error` too, and anything else that
calls these endpoints must as well.

**Spawning on a node**: body field `_jac_spawn_node` (a node id, defaults to `root`).
`jid(node)` gets the id, `jobj(id)` resolves it back.

**Shared graph.** `:pub` walkers operate on the shared global `root`; `:priv` gives each
logged-in user an isolated root. The pantry graph is shared across anonymous callers
with zero auth work.

**Boot timing.** For ~30s after `jac start`, walker POSTs return
`{"error":"Unauthorized"}` while registration finishes. Wait for `Server ready`, then
poll a harmless walker until it answers. Not an auth bug.

**`jac start` exits when stdin closes** — background it with `< /dev/null`, and in the
container the command must end in `< /dev/null`.

**Backgrounding it inherits your pipe.** `jac start` launched from a script keeps the
script's stdout open, so `demo.sh | tee` hangs forever after the last step. Cost an
hour to find. `scripts/demo.sh` launches the server with
`( cd "$REPO" && exec nohup jac start ... < /dev/null >> log 2>&1 ) &` so no caller
descriptor survives.

## Spec bugs found

1. **§8 `status:"On-Going"` returns zero records.** The live field value is `"Ongoing"`.
2. **§9's `.cl.jac` fallback is moot** — the Jac-native frontend works. Do not trigger it.
3. The live openFDA query returns an arbitrary page of ongoing recalls and does **not**
   reliably contain `H-1125-2026`, the recall the demo is built on. The demo therefore
   runs against `data/openfda-snapshot.json` (100 ongoing recalls, 41 Class I, real lot
   codes) and proves the network path separately in step 6b.

## Demo recall records in use

- `H-1125-2026` — Western Mixers, *FIRST STREET Dark Chocolate Raisins 9oz*,
  "Undeclared peanuts.", `Lot: 260562 BB: 022527`. This is the Maria story.
- `H-1137-2026` — NARA ORGANICS *Infant Formula*, C. botulinum — the §4 rule that
  infant formula is the one category that **does** discard.

## Scripts

| Script | Does |
|---|---|
| `scripts/setup.sh` | venv + deps + npm from scratch |
| `scripts/demo.sh --reset` | wipe graph, start server, replay all of §12 (~10s) |
| `scripts/demo.sh` | replay against a running server (~2s), idempotent |
| `scripts/eval.sh <dir>` | real-photo eval through `IntakeScan` |

`--reset` deletes `.jac/data/main.db*`. Persistence is root-reachability backed by
SQLite, so that file **is** the database.

## Known rough edges

- **Everything currently runs on MockLLM.** There is no Gemini key on this machine.
  Every code path is exercised, but `extract_label` returns the same canned label for
  any photo, so the demo's scanned can is always DEL MONTE Cut Green Beans and every
  client explanation is the same sentence. This is the single biggest gap between what
  is demoed and what the product does. Adding the key fixes it with no code change.
- `scripts/eval.sh` has never been run against real photographs, because that requires
  the key. Its MockLLM path is tested (4 photos, end to end) and its accuracy path is
  tested against synthetic reads plus a truth CSV. What is untested is Gemini's actual
  extraction quality — that number does not exist yet and the script deliberately
  refuses to invent one.
- `assets/` is empty. The §10 eval needs 20–30 photos of real labels taken at the venue.
- Re-running `demo.sh` without `--reset` accumulates scanned cans, so the shelf listings
  in steps 5 and 8 grow. Correct behaviour, noisy on stage. Use `--reset`.
- A graph left over from an earlier schema iteration can produce a sweep that flags
  items but reports **zero** households. Observed once on a `.jac/data` directory built
  up across a day of schema changes; not reproducible after `--reset`, and the root
  cause was not chased. If the money shot comes up empty on stage, `--reset` is the fix.

## Research artifacts

`docs/spikes/` — 94 executed `.jac` files. Highest value:
`walkers/05_recall_sweep.jac` (the backward sweep in miniature),
`walkers/proj_final/` (multi-file layout), `byllm/s05_image.jac`,
`core-graph/02_schema.jac`, `server/shared_app/main.sv.jac`,
`client/backshelf_rt/` (3-page client with routing).
